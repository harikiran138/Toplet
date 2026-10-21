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

/// Safe file operations for editing the agents' config files: symlink-aware read, writability checks BEFORE any
/// side effect, timestamped backups with rotation, atomic same-directory replace that preserves the file mode.
enum HooksFileIO {
    static let maxFileBytes = 64 * 1024 * 1024
    static let backupsToKeep = 5

    struct Snapshot {
        let userPath: String        // the path the user/agent uses (may be a symlink)
        let resolvedPath: String    // where the bytes really live (symlinks followed)
        let exists: Bool
        let data: Data?
        let mode: mode_t?           // permission bits of the real file
    }

    /// Follows a chain of symlinks (also dangling ones) without requiring the final target to exist.
    static func resolveSymlinks(_ path: String) throws -> String {
        let fm = FileManager.default
        var cur = path
        var hops = 0
        while let dest = try? fm.destinationOfSymbolicLink(atPath: cur) {
            hops += 1
            if hops > 32 { throw HookInstallError.io(path: path, reason: "too many levels of symbolic links") }
            let base = (cur as NSString).deletingLastPathComponent
            cur = URL(fileURLWithPath: dest.hasPrefix("/") ? dest : base + "/" + dest).standardized.path
        }
        return cur
    }

    static func read(_ userPath: String) throws -> Snapshot {
        let resolved = try resolveSymlinks(userPath)
        var st = stat()
        if lstat(resolved, &st) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return Snapshot(userPath: userPath, resolvedPath: resolved, exists: false, data: nil, mode: nil) }
            throw HookInstallError.io(path: userPath, reason: String(cString: strerror(errno)))
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw HookInstallError.io(path: userPath, reason: "not a regular file") }
        if st.st_size > off_t(maxFileBytes) {
            throw HookInstallError.unparseable(path: userPath, reason: "file is larger than \(maxFileBytes / 1_048_576) MiB")
        }
        do {
            let d = try Data(contentsOf: URL(fileURLWithPath: resolved))
            return Snapshot(userPath: userPath, resolvedPath: resolved, exists: true, data: d, mode: st.st_mode & 0o7777)
        } catch {
            throw HookInstallError.io(path: userPath, reason: "cannot read file (\(error.localizedDescription))")
        }
    }

    /// Everything that can be checked up front. Throws before any backup or write happens.
    static func checkWritable(_ snap: Snapshot) throws {
        let dir = (snap.resolvedPath as NSString).deletingLastPathComponent
        if snap.exists {
            if access(snap.resolvedPath, W_OK) != 0 { throw HookInstallError.readOnly(path: snap.userPath) }
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) {
            if !isDir.boolValue { throw HookInstallError.notWritable(path: snap.userPath, reason: "\(dir) is not a directory") }
            if access(dir, W_OK | X_OK) != 0 { throw HookInstallError.notWritable(path: snap.userPath, reason: "directory \(dir) is not writable") }
        }
        // the backup lives next to the path the user gave (which may be the symlink, not its target)
        let udir = (snap.userPath as NSString).deletingLastPathComponent
        if snap.exists, udir != dir, FileManager.default.fileExists(atPath: udir), access(udir, W_OK | X_OK) != 0 {
            throw HookInstallError.notWritable(path: snap.userPath, reason: "directory \(udir) is not writable (needed for the backup)")
        }
    }

    // MARK: Backups

    static func backupPrefix(for userPath: String) -> String { (userPath as NSString).lastPathComponent + ".atoll-backup-" }

    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// Writes `<userPath>.atoll-backup-YYYYMMDD-HHMMSS` (mode 0600) and returns its path. Never overwrites a backup.
    static func writeBackup(userPath: String, data: Data, now: Date) throws -> String {
        let stamp = timestamp(now)
        var path = userPath + ".atoll-backup-" + stamp
        var n = 0
        while FileManager.default.fileExists(atPath: path) {
            n += 1
            if n > 99 { throw HookInstallError.io(path: userPath, reason: "too many backups in one second") }
            path = userPath + ".atoll-backup-" + stamp + String(format: "-%02d", n)
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 { throw HookInstallError.io(path: path, reason: "cannot create backup: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        try writeAll(fd: fd, data: data, path: path)
        fsync(fd)
        return path
    }

    /// Keeps the newest `keep` backups of this file; only names that match the backup pattern exactly are ever deleted.
    static func rotateBackups(userPath: String, keep: Int = backupsToKeep) {
        let dir = (userPath as NSString).deletingLastPathComponent
        let prefix = backupPrefix(for: userPath)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.isEmpty ? "." : dir) else { return }
        let mine = names.filter { isBackupName($0, prefix: prefix) }.sorted()
        guard mine.count > keep else { return }
        for old in mine.prefix(mine.count - keep) {
            try? FileManager.default.removeItem(atPath: (dir.isEmpty ? "." : dir) + "/" + old)
        }
    }

    static func isBackupName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let tail = Array(name.dropFirst(prefix.count).utf8)   // YYYYMMDD-HHMMSS or YYYYMMDD-HHMMSS-NN
        func digits(_ r: Range<Int>) -> Bool { r.allSatisfy { $0 < tail.count && tail[$0] >= 0x30 && tail[$0] <= 0x39 } }
        guard tail.count == 15 || tail.count == 18 else { return false }
        guard digits(0..<8), tail[8] == 0x2D, digits(9..<15) else { return false }
        if tail.count == 18 { return tail[15] == 0x2D && digits(16..<18) }
        return true
    }

    // MARK: Atomic write

    private static func writeAll(fd: Int32, data: Data, path: String) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw HookInstallError.io(path: path, reason: String(cString: strerror(errno)))
                }
                off += n
            }
        }
    }

    /// Temp file in the SAME directory as the real file (so rename is atomic), fsync, mode copied from the original
    /// (0600 for new files), re-check that nobody changed the original meanwhile, then rename over it.
    static func atomicWrite(_ data: Data, to snap: Snapshot) throws {
        let fm = FileManager.default
        let dir = (snap.resolvedPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            do { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw HookInstallError.notWritable(path: snap.userPath, reason: "cannot create \(dir): \(error.localizedDescription)") }
        }
        let tmp = dir + "/." + (snap.resolvedPath as NSString).lastPathComponent + ".atoll-tmp-" + String(UUID().uuidString.prefix(8))
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 { throw HookInstallError.notWritable(path: snap.userPath, reason: "cannot create temp file in \(dir): \(String(cString: strerror(errno)))") }
        var closed = false
        func cleanup() { if !closed { close(fd); closed = true }; unlink(tmp) }
        do {
            try writeAll(fd: fd, data: data, path: snap.userPath)
            if fsync(fd) != 0 { throw HookInstallError.io(path: snap.userPath, reason: "fsync failed: \(String(cString: strerror(errno)))") }
            if fchmod(fd, snap.mode ?? 0o600) != 0 { throw HookInstallError.io(path: snap.userPath, reason: "chmod failed: \(String(cString: strerror(errno)))") }
            close(fd); closed = true
            // lost-update guard: Claude Code / the user may write settings.json at any time
            let now = try? Data(contentsOf: URL(fileURLWithPath: snap.resolvedPath))
            if now != snap.data { cleanup(); throw HookInstallError.modifiedConcurrently(path: snap.userPath) }
            if rename(tmp, snap.resolvedPath) != 0 {
                throw HookInstallError.io(path: snap.userPath, reason: "rename failed: \(String(cString: strerror(errno)))")
            }
        } catch {
            cleanup()
            throw error
        }
    }
}
