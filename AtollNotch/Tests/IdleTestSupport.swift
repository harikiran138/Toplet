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
import CoreGraphics
import ImageIO

// Minimal assertion framework (no XCTest on Command Line Tools) shared by the idle engine tests.

enum IdleT {
    nonisolated(unsafe) static var passes = 0
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var verbose = ProcessInfo.processInfo.environment["IDLE_VERBOSE"] != nil
    nonisolated(unsafe) static var currentSection = ""
}

func section(_ name: String) {
    IdleT.currentSection = name
    print("== \(name) ==")
}

func check(_ name: String, _ ok: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    if ok() {
        IdleT.passes += 1
        if IdleT.verbose { print("PASS  \(name)") }
    } else {
        IdleT.failures += 1
        print("FAIL  [\(IdleT.currentSection)] \(name)  \(detail())")
    }
}

func checkEqual<T: Equatable>(_ name: String, _ a: T, _ b: T) {
    check(name, a == b, "got \(a), expected \(b)")
}

func repoRoot() -> URL {
    if let p = ProcessInfo.processInfo.environment["IDLE_REPO_ROOT"] { return URL(fileURLWithPath: p) }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

func makeTempDir(_ tag: String = "idle") -> URL {
    let base = ProcessInfo.processInfo.environment["IDLE_TMP"] ?? NSTemporaryDirectory()
    let dir = URL(fileURLWithPath: base).appendingPathComponent("\(tag)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A PNG (public.png) with `columns x rows` cells of `cell x cell` pixels, each cell a distinct colour.
func makePNG(width: Int, height: Int, cellsAcross: Int = 1, cellsDown: Int = 1) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
    let cw = max(1, width / max(1, cellsAcross)), ch = max(1, height / max(1, cellsDown))
    var k = 0
    for r in 0..<cellsDown {
        for c in 0..<cellsAcross {
            let hue = CGFloat(k % 12) / 12
            ctx.setFillColor(CGColor(red: hue, green: 1 - hue, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: c * cw, y: height - (r + 1) * ch, width: cw, height: ch))
            k += 1
        }
    }
    guard let image = ctx.makeImage() else { return Data() }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return Data() }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

func makeJPEG(width: Int, height: Int) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = ctx.makeImage() else { return Data() }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return Data() }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

/// A valid minimal Lottie object that individual tests mutate.
func lottieObject() -> [String: Any] {
    ["v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 100, "h": 100, "layers": [["ty": 4, "ind": 1]]]
}

func jsonData(_ obj: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
}

func lottieData(_ mutate: (inout [String: Any]) -> Void = { _ in }) -> Data {
    var o = lottieObject()
    mutate(&o)
    return jsonData(o)
}
