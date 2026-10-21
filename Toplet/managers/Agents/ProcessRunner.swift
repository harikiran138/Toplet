/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 */

import Foundation
import Darwin

/// Runs a child process with an argument array (never through a shell), a timeout and bounded output.
protocol ProcessRunning {
    func run(executable: String, arguments: [String], cwd: String?, timeout: TimeInterval, maxOutput: Int) -> ProcessRunResult
}

struct ProcessRunResult: Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    var launchError: String?
    var succeeded: Bool { launchError == nil && !timedOut && status == 0 }
}

enum ExecutableLocator {
    /// PATH entries Atoll adds because a GUI app starts with a minimal PATH.
    static func searchDirs(home: String = NSHomeDirectory(), path: String? = ProcessInfo.processInfo.environment["PATH"]) -> [String] {
        var dirs = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for extra in [(home as NSString).appendingPathComponent(".local/bin"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        where !dirs.contains(extra) { dirs.append(extra) }
        return dirs
    }

    static func find(_ name: String, dirs: [String] = searchDirs(), isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for d in dirs {
            let p = (d as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue, isExecutable(p) { return p }
        }
        return nil
    }
}

final class SystemProcessRunner: ProcessRunning {
    init() {}

    func run(executable: String, arguments: [String], cwd: String?, timeout: TimeInterval, maxOutput: Int) -> ProcessRunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let c = cwd { p.currentDirectoryURL = URL(fileURLWithPath: c, isDirectory: true) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ExecutableLocator.searchDirs().joined(separator: ":")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice

        let lock = NSLock()
        var outData = Data(), errData = Data()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            lock.lock(); if outData.count < maxOutput { outData.append(d.prefix(maxOutput - outData.count)) }; lock.unlock()
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            lock.lock(); if errData.count < maxOutput { errData.append(d.prefix(maxOutput - errData.count)) }; lock.unlock()
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
            return ProcessRunResult(status: -1, stdout: "", stderr: "", timedOut: false, launchError: error.localizedDescription)
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 1) }
        }
        // Drain whatever is left.
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let restOut = (try? out.fileHandleForReading.read(upToCount: maxOutput)) ?? Data()
        let restErr = (try? err.fileHandleForReading.read(upToCount: maxOutput)) ?? Data()
        lock.lock()
        if outData.count < maxOutput { outData.append(restOut.prefix(maxOutput - outData.count)) }
        if errData.count < maxOutput { errData.append(restErr.prefix(maxOutput - errData.count)) }
        let so = String(decoding: outData, as: UTF8.self), se = String(decoding: errData, as: UTF8.self)
        lock.unlock()
        return ProcessRunResult(status: timedOut ? -1 : p.terminationStatus, stdout: so, stderr: se, timedOut: timedOut, launchError: nil)
    }
}
