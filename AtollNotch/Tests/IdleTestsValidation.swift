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

// T4: Lottie validator, sprite validator, safe import.

private func has(_ r: LottieReport, _ pred: (IdleValidationError) -> Bool) -> Bool { r.errors.contains(where: pred) }

func runLottieValidatorTests() {
    section("T4 lottie validator: positive")
    let ok = LottieValidator.validate(data: lottieData())
    check("minimal valid file passes", ok.isValid, "\(ok.errors)")
    checkEqual("info fps", ok.info?.fps, 30)
    checkEqual("info layers", ok.info?.layerCount, 1)
    checkEqual("info duration", ok.info?.durationSeconds, 2)
    check("no warnings for minimal file", ok.warnings.isEmpty)
    check("unknown extra keys are ignored", LottieValidator.validate(data: lottieData { $0["zzz"] = ["a": 1]; $0["meta"] = ["g": "x"] }).isValid)
    check("fr exactly 1 passes", LottieValidator.validate(data: lottieData { $0["fr"] = 1; $0["op"] = 30 }).isValid)
    check("fr exactly 120 passes", LottieValidator.validate(data: lottieData { $0["fr"] = 120 }).isValid)
    check("w,h exactly 4096 pass", LottieValidator.validate(data: lottieData { $0["w"] = 4096; $0["h"] = 4096 }).isValid)
    check("w,h exactly 1 pass", LottieValidator.validate(data: lottieData { $0["w"] = 1; $0["h"] = 1 }).isValid)
    check("200 layers pass", LottieValidator.validate(data: lottieData { $0["layers"] = Array(repeating: ["ty": 4], count: 200) }).isValid)
    check("duration exactly 60 s passes", LottieValidator.validate(data: lottieData { $0["fr"] = 1; $0["op"] = 60 }).isValid)
    check("negative ip with op>ip passes", LottieValidator.validate(data: lottieData { $0["ip"] = -10; $0["op"] = 20 }).isValid)
    check("fractional frame numbers pass", LottieValidator.validate(data: lottieData { $0["fr"] = 29.97; $0["op"] = 143.0000058 }).isValid)
    check("precomp asset without p passes", LottieValidator.validate(data: lottieData { $0["assets"] = [["id": "c1", "layers": [["ty": 4]]]] }).isValid)
    check("data URI image asset passes", LottieValidator.validate(data: lottieData { $0["assets"] = [["id": "i", "p": "data:image/png;base64,AAAA", "u": "", "e": 1]] }).isValid)
    check("short expression is a warning, not an error", {
        let r = LottieValidator.validate(data: lottieData { $0["layers"] = [["ty": 4, "ks": ["o": ["x": "time*10", "k": 0]]]] })
        return r.isValid && r.warnings.contains(.containsExpressions(count: 1))
    }())
    check("expression of exactly 4096 bytes passes", LottieValidator.validate(data: lottieData {
        $0["layers"] = [["ty": 4, "ks": ["o": ["x": String(repeating: "a", count: 4096)]]]]
    }).isValid)
    check("fr > 60 is a warning", LottieValidator.validate(data: lottieData { $0["fr"] = 100; $0["op"] = 200 }).warnings.contains(.highFrameRate(100)))
    check("canvas > 2560 is a warning", LottieValidator.validate(data: lottieData { $0["w"] = 3000 }).warnings.contains(.largeCanvas(width: 3000, height: 100)))
    check("relative asset path is a warning", LottieValidator.validate(data: lottieData { $0["assets"] = [["id": "i", "p": "img_0.png", "u": "images/"]] }).warnings.contains(.relativeAssetPath(index: 0)))
    check("101 layers warn", LottieValidator.validate(data: lottieData { $0["layers"] = Array(repeating: ["ty": 4], count: 101) }).warnings.contains(.manyLayers(101)))

    section("T4 lottie validator: bundled files")
    let dir = repoRoot().appendingPathComponent("LottieAnimations")
    let names = ["Dog waiting", "FingerprintScan", "Lock", "Moody Dog", "Orange Cat Peeping", "Reindeer"]
    for n in names {
        let url = dir.appendingPathComponent(n + ".json")
        let data = try? Data(contentsOf: url)
        check("bundled \(n).json readable", data != nil)
        if let data {
            let r = LottieValidator.validate(data: data)
            check("bundled \(n).json passes", r.isValid, "\(r.errors)")
            check("bundled \(n).json has info", r.info != nil)
            let rf = LottieValidator.validate(fileURL: url)
            check("bundled \(n).json passes via file URL", rf.isValid, "\(rf.errors)")
        }
    }
    let moody = LottieValidator.validate(fileURL: dir.appendingPathComponent("Moody Dog.json"))
    checkEqual("Moody Dog layers", moody.info?.layerCount, 11)
    checkEqual("Moody Dog fps", moody.info?.fps, 30)
    let lock = LottieValidator.validate(fileURL: dir.appendingPathComponent("Lock.json"))
    checkEqual("Lock canvas", lock.info?.width, 500)

    section("T4 lottie validator: negative fixtures")
    let empty = LottieValidator.validate(data: Data())
    check("empty data rejected", has(empty) { $0 == .empty })
    let braces = LottieValidator.validate(data: Data("{}".utf8))
    check("{} rejected", !braces.isValid)
    check("{} reports missing v", has(braces) { $0 == .missingField("v") })
    check("{} reports missing fr", has(braces) { $0 == .missingField("fr") })
    check("{} reports missing layers", has(braces) { $0 == .missingField("layers") })
    check("{} reports missing w and h", has(braces) { $0 == .missingField("w") } && has(braces) { $0 == .missingField("h") })
    check("{} has no info", braces.info == nil)
    let arr = LottieValidator.validate(data: Data("[]".utf8))
    check("[] rejected as not an object", has(arr) { $0 == .notAnObject })
    check("[1,2,3] rejected", has(LottieValidator.validate(data: Data("[1,2,3]".utf8))) { $0 == .notAnObject })
    check("scalar JSON rejected", !LottieValidator.validate(data: Data("42".utf8)).isValid)
    check("garbage rejected", has(LottieValidator.validate(data: Data("not json at all".utf8))) { $0 == .notValidJSON })
    check("truncated JSON rejected", has(LottieValidator.validate(data: Data("{\"v\":\"5\",".utf8))) { $0 == .notValidJSON })
    check("binary junk rejected", !LottieValidator.validate(data: Data([0xFF, 0xFE, 0x00, 0x01, 0x80])).isValid)
    check("null JSON rejected", !LottieValidator.validate(data: Data("null".utf8)).isValid)

    // NaN / infinity
    let nanRaw = "{\"v\":\"5\",\"fr\":NaN,\"ip\":0,\"op\":60,\"w\":100,\"h\":100,\"layers\":[{}]}"
    check("NaN fps literal rejected", !LottieValidator.validate(data: Data(nanRaw.utf8)).isValid)
    let infRaw = "{\"v\":\"5\",\"fr\":1e999,\"ip\":0,\"op\":60,\"w\":100,\"h\":100,\"layers\":[{}]}"
    check("overflowing fps 1e999 rejected", !LottieValidator.validate(data: Data(infRaw.utf8)).isValid)
    let infW = "{\"v\":\"5\",\"fr\":30,\"ip\":0,\"op\":60,\"w\":-1e999,\"h\":100,\"layers\":[{}]}"
    check("overflowing width rejected", !LottieValidator.validate(data: Data(infW.utf8)).isValid)
    let infNested = "{\"v\":\"5\",\"fr\":30,\"ip\":0,\"op\":60,\"w\":10,\"h\":10,\"layers\":[{\"ks\":{\"o\":{\"k\":1e999}}}]}"
    check("overflowing nested number rejected", !LottieValidator.validate(data: Data(infNested.utf8)).isValid)
    check("-Infinity literal rejected", !LottieValidator.validate(data: Data("{\"v\":\"5\",\"fr\":-Infinity}".utf8)).isValid)

    // fps
    for (label, value) in [("0", 0.0), ("0.5", 0.5), ("121", 121.0), ("-30", -30.0), ("1000", 1000.0)] {
        let r = LottieValidator.validate(data: lottieData { $0["fr"] = value })
        check("fr \(label) rejected", has(r) { if case .outOfRange(let f, _, _, _) = $0 { return f == "fr" } else { return false } }, "\(r.errors)")
    }
    // in/out points
    check("op == ip rejected", has(LottieValidator.validate(data: lottieData { $0["ip"] = 10; $0["op"] = 10 })) { if case .endNotAfterStart = $0 { return true } else { return false } })
    check("op < ip rejected", has(LottieValidator.validate(data: lottieData { $0["ip"] = 50; $0["op"] = 10 })) { if case .endNotAfterStart = $0 { return true } else { return false } })
    check("op == 0 ip == 0 rejected", !LottieValidator.validate(data: lottieData { $0["op"] = 0 }).isValid)
    // canvas
    for (label, k, v) in [("w 0", "w", 0.0), ("w 4097", "w", 4097.0), ("h -5", "h", -5.0), ("h 99999", "h", 99999.0), ("w 0.5", "w", 0.5)] {
        check("canvas \(label) rejected", has(LottieValidator.validate(data: lottieData { $0[k] = v })) { if case .outOfRange(let f, _, _, _) = $0 { return f == k } else { return false } })
    }
    // layers
    let hugeLayers = "{\"v\":\"5\",\"fr\":30,\"ip\":0,\"op\":60,\"w\":100,\"h\":100,\"layers\":[" + Array(repeating: "{}", count: 100_000).joined(separator: ",") + "]}"
    let hugeReport = LottieValidator.validate(data: Data(hugeLayers.utf8))
    check("100k layers rejected", has(hugeReport) { if case .tooManyLayers(let c, _) = $0 { return c == 100_000 } else { return false } }, "\(hugeReport.errors)")
    check("201 layers rejected", has(LottieValidator.validate(data: lottieData { $0["layers"] = Array(repeating: ["ty": 4], count: 201) })) { if case .tooManyLayers = $0 { return true } else { return false } })
    check("empty layers rejected", has(LottieValidator.validate(data: lottieData { $0["layers"] = [] })) { $0 == .noLayers })
    check("layers as object rejected", has(LottieValidator.validate(data: lottieData { $0["layers"] = ["a": 1] })) { if case .wrongType(let f, _) = $0 { return f == "layers" } else { return false } })
    check("layers missing rejected", has(LottieValidator.validate(data: lottieData { $0["layers"] = nil })) { $0 == .missingField("layers") })
    // types
    check("v number rejected", has(LottieValidator.validate(data: lottieData { $0["v"] = 5 })) { if case .wrongType(let f, _) = $0 { return f == "v" } else { return false } })
    check("v empty string rejected", !LottieValidator.validate(data: lottieData { $0["v"] = "" }).isValid)
    check("fr string rejected", has(LottieValidator.validate(data: lottieData { $0["fr"] = "30" })) { if case .wrongType(let f, _) = $0 { return f == "fr" } else { return false } })
    check("fr boolean rejected", !LottieValidator.validate(data: lottieData { $0["fr"] = true }).isValid)
    check("w null rejected", !LottieValidator.validate(data: lottieData { $0["w"] = NSNull() }).isValid)
    check("assets not an array rejected", !LottieValidator.validate(data: lottieData { $0["assets"] = "x" }).isValid)
    // duration
    check("duration 61 s rejected", has(LottieValidator.validate(data: lottieData { $0["fr"] = 1; $0["op"] = 61 })) { if case .durationTooLong = $0 { return true } else { return false } })
    check("duration 10 minutes rejected", !LottieValidator.validate(data: lottieData { $0["fr"] = 30; $0["op"] = 18000 }).isValid)

    // External assets
    for (label, u) in [("http", "http://evil.example/a/"), ("https", "https://evil.example/a/"), ("HTTPS uppercase", "HTTPS://evil.example/"),
                       ("protocol-relative", "//evil.example/a/"), ("file", "file:///etc/"), ("ftp scheme", "ftp://x/")] {
        let r = LottieValidator.validate(data: lottieData { $0["assets"] = [["id": "i", "u": u, "p": "a.png"]] })
        check("external u (\(label)) rejected", has(r) { if case .externalAsset = $0 { return true } else { return false } }, "\(r.errors)")
    }
    for (label, p) in [("absolute path", "/etc/passwd"), ("home path", "~/secret.png"), ("file URL", "file:///etc/passwd"),
                       ("https p", "https://evil.example/a.png"), ("windows drive", "C:\\x.png"), ("parent dir", "../../x.png"), ("backslash root", "\\\\server\\share\\a.png")] {
        let r = LottieValidator.validate(data: lottieData { $0["assets"] = [["id": "i", "u": "", "p": p]] })
        check("external p (\(label)) rejected", has(r) { if case .externalAsset = $0 { return true } else { return false } }, "\(r.errors)")
    }
    check("second asset external is found with index", has(LottieValidator.validate(data: lottieData { $0["assets"] = [["id": "a", "layers": []], ["id": "b", "p": "/etc/passwd"]] })) { if case .externalAsset(let i, _) = $0 { return i == 1 } else { return false } })
    // Embedded data
    let big = "data:image/png;base64," + String(repeating: "A", count: 1_200_000)
    check("1.2 MB embedded data rejected", has(LottieValidator.validate(data: lottieData { $0["assets"] = [["id": "i", "p": big, "u": ""]] })) { if case .embeddedDataTooLarge = $0 { return true } else { return false } })
    let half = "data:image/png;base64," + String(repeating: "A", count: 600_000)
    check("two 600 KB data URIs (total over 1 MiB) rejected", has(LottieValidator.validate(data: lottieData { $0["assets"] = [["id": "a", "p": half, "u": ""], ["id": "b", "p": half, "u": ""]] })) { if case .embeddedDataTooLarge = $0 { return true } else { return false } })
    check("500 KB data URI passes", LottieValidator.validate(data: lottieData { $0["assets"] = [["id": "a", "p": "data:image/png;base64," + String(repeating: "A", count: 500_000), "u": ""]] }).isValid)
    // Oversize
    let oversize = Data(repeating: 0x20, count: 3 * 1024 * 1024)
    check("3 MiB file rejected", has(LottieValidator.validate(data: oversize)) { if case .fileTooLarge = $0 { return true } else { return false } })
    var exact = Data(lottieData()); exact.append(Data(repeating: 0x20, count: 2 * 1024 * 1024 - exact.count))
    check("exactly 2 MiB file accepted", LottieValidator.validate(data: exact).isValid)
    exact.append(0x20)
    check("2 MiB + 1 byte rejected", !LottieValidator.validate(data: exact).isValid)
    // Deep nesting
    let deepOpen = Data(String(repeating: "[", count: 100_000).utf8)
    check("100k nested [ rejected by the depth scan", has(LottieValidator.validate(data: deepOpen)) { if case .nestingTooDeep = $0 { return true } else { return false } })
    let deepObj = String(repeating: "{\"a\":", count: 5000) + "1" + String(repeating: "}", count: 5000)
    check("5000 nested objects rejected", has(LottieValidator.validate(data: Data(deepObj.utf8))) { if case .nestingTooDeep = $0 { return true } else { return false } })
    func nested(_ depth: Int) -> Data {
        var inner: Any = 1
        for _ in 0..<depth { inner = [inner] }
        return lottieData { $0["layers"] = [["ty": 4, "deep": inner]] }
    }
    check("nesting 40 deep passes", LottieValidator.validate(data: nested(40)).isValid)
    check("nesting 70 deep rejected", !LottieValidator.validate(data: nested(70)).isValid)
    check("brackets inside strings do not count", LottieValidator.validate(data: lottieData { $0["layers"] = [["ty": 4, "nm": String(repeating: "[", count: 500)]] }).isValid)
    check("escaped quotes do not end strings", LottieValidator.validate(data: Data(("{\"v\":\"5\",\"fr\":30,\"ip\":0,\"op\":60,\"w\":10,\"h\":10,\"layers\":[{\"nm\":\"" + String(repeating: "\\\"[", count: 300) + "\"}]}").utf8)).isValid)
    // Expressions
    check("expression of 4097 bytes rejected", has(LottieValidator.validate(data: lottieData { $0["layers"] = [["ty": 4, "ks": ["o": ["x": String(repeating: "a", count: 4097)]]]] })) { if case .expressionTooLong(let n, _) = $0 { return n == 4097 } else { return false } })
    check("a 1 MB expression rejected", !LottieValidator.validate(data: lottieData { $0["layers"] = [["ty": 4, "ks": ["o": ["x": String(repeating: "a", count: 1_000_000)]]]] }).isValid)
    check("multibyte expression counted in bytes", !LottieValidator.validate(data: lottieData { $0["layers"] = [["ty": 4, "ks": ["o": ["x": String(repeating: "\u{20AC}", count: 1400)]]]] }).isValid)
    // Typed errors carry messages
    check("every error has a description", IdleValidationError.allSamples.allSatisfy { ($0.errorDescription ?? "").count > 5 })
    // File based
    let tmp = makeTempDir("lv")
    let good = tmp.appendingPathComponent("good.json")
    try? lottieData().write(to: good)
    check("validate(fileURL:) accepts a good file", LottieValidator.validate(fileURL: good).isValid)
    check("validate(fileURL:) rejects a missing file", !LottieValidator.validate(fileURL: tmp.appendingPathComponent("nope.json")).isValid)
    let link = tmp.appendingPathComponent("link.json")
    try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: good)
    check("validate(fileURL:) rejects a symlink", !LottieValidator.validate(fileURL: link).isValid)
    let folder = tmp.appendingPathComponent("folder.json", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    check("validate(fileURL:) rejects a directory", !LottieValidator.validate(fileURL: folder).isValid)
    let bigFile = tmp.appendingPathComponent("big.json")
    try? oversize.write(to: bigFile)
    check("validate(fileURL:) rejects an oversize file without reading it all", has(LottieValidator.validate(fileURL: bigFile)) { if case .fileTooLarge = $0 { return true } else { return false } })
    try? FileManager.default.removeItem(at: tmp)

    section("T4 lottie validator: helpers")
    checkEqual("depth scan counts nesting", LottieValidator.maxBracketDepth(Data("[[{\"a\":[]}]]".utf8), stopAbove: 100), 4)
    check("externalReason nil for relative names", LottieValidator.externalReason("img_0.png", isDirectory: false) == nil)
    check("externalReason nil for empty", LottieValidator.externalReason("", isDirectory: true) == nil)
    check("externalReason flags tilde", LottieValidator.externalReason("~/x", isDirectory: false) != nil)
    check("isDataURI is case-insensitive", LottieValidator.isDataURI("DATA:image/png;base64,xx"))
}

extension IdleValidationError {
    static var allSamples: [IdleValidationError] {
        [.empty, .fileTooLarge(bytes: 3_000_000, limit: 2_000_000), .nestingTooDeep(limit: 64), .notValidJSON, .notAnObject,
         .missingField("v"), .wrongType(field: "fr", expected: "a number"), .nonFiniteNumber(path: "$.fr"),
         .outOfRange(field: "fr", value: 0, lower: 1, upper: 120), .endNotAfterStart(ip: 1, op: 1), .tooManyLayers(count: 300, limit: 200),
         .noLayers, .durationTooLong(seconds: 100, limit: 60), .externalAsset(index: 0, reason: "network URL"),
         .embeddedDataTooLarge(bytes: 2_000_000, limit: 1_000_000), .expressionTooLong(length: 5000, limit: 4096), .tooManyNodes(limit: 10),
         .notAPNG, .unreadableImage, .imageTooLarge(pixels: 20_000_000, limit: 16_000_000), .invalidGrid("0 x 0"),
         .gridDoesNotDivide(imageWidth: 10, imageHeight: 10, columns: 3, rows: 3), .frameCountExceedsGrid(frameCount: 9, cells: 4),
         .frameCountOutOfRange(0), .frameSizeOutOfRange(width: 4, height: 4),
         .frameSizeMismatch(expectedWidth: 16, expectedHeight: 16, specWidth: 8, specHeight: 8), .fpsOutOfRange(0), .frameDecodeFailed(index: 3)]
    }
}

// MARK: - Sprite sheet

private func spriteHas(_ r: SpriteReport, _ pred: (IdleValidationError) -> Bool) -> Bool { r.errors.contains(where: pred) }

func runSpriteValidatorTests() {
    section("T4 sprite validator")
    let png = makePNG(width: 64, height: 32, cellsAcross: 4, cellsDown: 2)
    check("generated PNG is non-empty", png.count > 50)
    let spec = SpriteSheetSpec(columns: 4, rows: 2, frameCount: 8, fps: 12, frameWidth: 16, frameHeight: 16, loop: true)
    let ok = SpriteSheetValidator.validate(data: png, spec: spec)
    check("valid 4x2 sheet passes", ok.isValid, "\(ok.errors)")
    checkEqual("info dims", ok.info?.imageWidth, 64)
    checkEqual("info height", ok.info?.imageHeight, 32)
    check("square frames: no warnings", ok.warnings.isEmpty)
    check("fewer frames than cells passes", SpriteSheetValidator.validate(data: png, spec: SpriteSheetSpec(columns: 4, rows: 2, frameCount: 5, fps: 12, frameWidth: 16, frameHeight: 16)).isValid)
    check("single frame passes", SpriteSheetValidator.validate(data: png, spec: SpriteSheetSpec(columns: 4, rows: 2, frameCount: 1, fps: 1, frameWidth: 16, frameHeight: 16)).isValid)
    check("fps 60 passes", SpriteSheetValidator.validate(data: png, spec: SpriteSheetSpec(columns: 4, rows: 2, frameCount: 8, fps: 60, frameWidth: 16, frameHeight: 16)).isValid)
    check("fps 1 passes", SpriteSheetValidator.validate(data: png, spec: SpriteSheetSpec(columns: 4, rows: 2, frameCount: 8, fps: 1, frameWidth: 16, frameHeight: 16)).isValid)
    check("single row strip passes", SpriteSheetValidator.validate(data: makePNG(width: 96, height: 16, cellsAcross: 6), spec: SpriteSheetSpec(columns: 6, rows: 1, frameCount: 6, fps: 8, frameWidth: 16, frameHeight: 16)).isValid)
    check("non-square frames pass with a warning", { let r = SpriteSheetValidator.validate(data: makePNG(width: 64, height: 32, cellsAcross: 4), spec: SpriteSheetSpec(columns: 4, rows: 1, frameCount: 4, fps: 8, frameWidth: 16, frameHeight: 32)); return r.isValid && r.warnings.contains(.nonSquarePixels) }())

    check("columns that do not divide the width rejected", spriteHas(SpriteSheetValidator.validate(data: png, spec: SpriteSheetSpec(columns: 3, rows: 2, frameCount: 6, fps: 12, frameWidth: 21, frameHeight: 16))) { if case .gridDoesNotDivide = $0 { return true } else { return false } })
    check("rows that do not divide the height rejected", spriteHas(SpriteSheetValidator.validate(data: png, spec: SpriteSheetSpec(columns: 4, rows: 3, frameCount: 6, fps: 12, frameWidth: 16, frameHeight: 10))) { if case .gridDoesNotDivide = $0 { return true } else { return false } })
    check("frameCount > cells rejected", spriteHas(SpriteSheetValidator.validate(data: png, spec: SpriteSheetSpec(columns: 4, rows: 2, frameCount: 9, fps: 12, frameWidth: 16, frameHeight: 16))) { if case .frameCountExceedsGrid = $0 { return true } else { return false } })
    check("frameCount 0 rejected", spriteHas(SpriteSheetValidator.validate(data: png, spec: SpriteSheetSpec(columns: 4, rows: 2, frameCount: 0, fps: 12, frameWidth: 16, frameHeight: 16))) { if case .frameCountOutOfRange = $0 { return true } else { return false } })
    check("frameCount negative rejected", !SpriteSheetValidator.validate(data: png, spec: SpriteSheetSpec(columns: 4, rows: 2, frameCount: -3, fps: 12, frameWidth: 16, frameHeight: 16)).isValid)
    for fps in [0.0, 0.5, 61.0, -1.0, Double.nan, Double.infinity] {
        check("fps \(fps) rejected", spriteHas(SpriteSheetValidator.validate(data: png, spec: SpriteSheetSpec(columns: 4, rows: 2, frameCount: 8, fps: fps, frameWidth: 16, frameHeight: 16))) { if case .fpsOutOfRange = $0 { return true } else { return false } })
    }
    check("columns 0 rejected", spriteHas(SpriteSheetValidator.validate(data: png, spec: SpriteSheetSpec(columns: 0, rows: 2, frameCount: 2, fps: 12, frameWidth: 16, frameHeight: 16))) { if case .invalidGrid = $0 { return true } else { return false } })
    check("rows negative rejected", !SpriteSheetValidator.validate(data: png, spec: SpriteSheetSpec(columns: 4, rows: -1, frameCount: 2, fps: 12, frameWidth: 16, frameHeight: 16)).isValid)
    check("65 columns rejected", !SpriteSheetValidator.validate(data: png, spec: SpriteSheetSpec(columns: 65, rows: 1, frameCount: 2, fps: 12, frameWidth: 1, frameHeight: 32)).isValid)
    // Frame size
    let tiny = makePNG(width: 28, height: 14, cellsAcross: 4, cellsDown: 2)
    check("7 px frames rejected", spriteHas(SpriteSheetValidator.validate(data: tiny, spec: SpriteSheetSpec(columns: 4, rows: 2, frameCount: 8, fps: 12, frameWidth: 7, frameHeight: 7))) { if case .frameSizeOutOfRange = $0 { return true } else { return false } })
    check("8 px frames pass", SpriteSheetValidator.validate(data: makePNG(width: 32, height: 16, cellsAcross: 4, cellsDown: 2), spec: SpriteSheetSpec(columns: 4, rows: 2, frameCount: 8, fps: 12, frameWidth: 8, frameHeight: 8)).isValid)
    let wide = makePNG(width: 2050, height: 1025, cellsAcross: 2, cellsDown: 1)
    check("1025 px frames rejected", spriteHas(SpriteSheetValidator.validate(data: wide, spec: SpriteSheetSpec(columns: 2, rows: 1, frameCount: 2, fps: 12, frameWidth: 1025, frameHeight: 1025))) { if case .frameSizeOutOfRange = $0 { return true } else { return false } })
    let wide1024 = makePNG(width: 2048, height: 1024, cellsAcross: 2, cellsDown: 1)
    check("1024 px frames pass", SpriteSheetValidator.validate(data: wide1024, spec: SpriteSheetSpec(columns: 2, rows: 1, frameCount: 2, fps: 12, frameWidth: 1024, frameHeight: 1024)).isValid)
    check("1024 px frames warn about size", SpriteSheetValidator.validate(data: wide1024, spec: SpriteSheetSpec(columns: 2, rows: 1, frameCount: 2, fps: 12, frameWidth: 1024, frameHeight: 1024)).warnings.contains(.unusualFrameSize(width: 1024, height: 1024)))
    check("spec frame size mismatch rejected", spriteHas(SpriteSheetValidator.validate(data: png, spec: SpriteSheetSpec(columns: 4, rows: 2, frameCount: 8, fps: 12, frameWidth: 8, frameHeight: 8))) { if case .frameSizeMismatch = $0 { return true } else { return false } })
    // Not a PNG
    let jpeg = makeJPEG(width: 64, height: 32)
    check("JPEG rejected as not PNG", spriteHas(SpriteSheetValidator.validate(data: jpeg, spec: spec)) { $0 == .notAPNG })
    check("random bytes rejected", spriteHas(SpriteSheetValidator.validate(data: Data((0..<400).map { UInt8($0 % 251) }), spec: spec)) { $0 == .unreadableImage || $0 == .notAPNG })
    check("text file rejected", !SpriteSheetValidator.validate(data: Data("hello".utf8), spec: spec).isValid)
    check("empty data rejected", spriteHas(SpriteSheetValidator.validate(data: Data(), spec: spec)) { $0 == .empty })
    check("PNG header only (truncated) rejected", !SpriteSheetValidator.validate(data: png.prefix(30), spec: spec).isValid)
    check("corrupted PNG body does not pass as valid", {
        var bad = png
        for i in stride(from: 60, to: bad.count - 20, by: 3) { bad[i] ^= 0xFF }
        return !SpriteSheetValidator.validate(data: bad, spec: spec).isValid
    }())
    // Pixel and byte caps
    let huge = makePNG(width: 5000, height: 4000, cellsAcross: 1, cellsDown: 1)
    check("20 MP image rejected without decoding", spriteHas(SpriteSheetValidator.validate(data: huge, spec: SpriteSheetSpec(columns: 5, rows: 4, frameCount: 20, fps: 12, frameWidth: 1000, frameHeight: 1000))) { if case .imageTooLarge = $0 { return true } else { return false } })
    check("exactly 4096x4096 (16.7 MP) rejected", !SpriteSheetValidator.validate(data: makePNG(width: 4096, height: 4096), spec: SpriteSheetSpec(columns: 8, rows: 8, frameCount: 64, fps: 12, frameWidth: 512, frameHeight: 512)).isValid)
    check("4000x4000 (16 MP) accepted", SpriteSheetValidator.validate(data: makePNG(width: 4000, height: 4000), spec: SpriteSheetSpec(columns: 8, rows: 8, frameCount: 64, fps: 12, frameWidth: 500, frameHeight: 500), decodeFrames: false).isValid)
    check("17 MiB of bytes rejected", spriteHas(SpriteSheetValidator.validate(data: Data(repeating: 0, count: 17 * 1024 * 1024), spec: spec)) { if case .fileTooLarge = $0 { return true } else { return false } })
    // Decode check
    check("decode validation crops first and last frame", SpriteSheetValidator.validate(data: png, spec: spec, decodeFrames: true).isValid)
    check("decodeFrames false skips pixels but keeps the gates", !SpriteSheetValidator.validate(data: png, spec: SpriteSheetSpec(columns: 3, rows: 2, frameCount: 6, fps: 12, frameWidth: 21, frameHeight: 16), decodeFrames: false).isValid)

    section("T4 sprite spec helpers")
    let d = SpriteSheetSpec.derived(imageWidth: 64, imageHeight: 32, columns: 4, rows: 2, frameCount: 8, fps: 12)
    checkEqual("derived frame width", d?.frameWidth, 16)
    checkEqual("derived frame height", d?.frameHeight, 16)
    check("derived is nil when width does not divide", SpriteSheetSpec.derived(imageWidth: 65, imageHeight: 32, columns: 4, rows: 2, frameCount: 8, fps: 12) == nil)
    check("derived is nil when height does not divide", SpriteSheetSpec.derived(imageWidth: 64, imageHeight: 33, columns: 4, rows: 2, frameCount: 8, fps: 12) == nil)
    check("derived is nil for zero columns", SpriteSheetSpec.derived(imageWidth: 64, imageHeight: 32, columns: 0, rows: 2, frameCount: 8, fps: 12) == nil)
    let r0 = spec.frameRect(0), r5 = spec.frameRect(5), rLast = spec.frameRect(99)
    check("frameRect 0 is the top-left cell", r0.x == 0 && r0.y == 0 && r0.width == 16)
    check("frameRect 5 is column 1 row 1", r5.x == 16 && r5.y == 16)
    check("frameRect clamps beyond the last frame", rLast.x == 48 && rLast.y == 16)
    check("frameRect clamps negative to 0", spec.frameRect(-4).x == 0)
    check("imageSize reads dimensions", { let s = SpriteSheetValidator.imageSize(data: png); return s?.width == 64 && s?.height == 32 }())
    check("imageSize is nil for JPEG", SpriteSheetValidator.imageSize(data: jpeg) == nil)
    check("spec decodes without loop key (defaults true)", {
        let j = Data("{\"columns\":2,\"rows\":1,\"frameCount\":2,\"fps\":10,\"frameWidth\":16,\"frameHeight\":16}".utf8)
        return (try? JSONDecoder().decode(SpriteSheetSpec.self, from: j))?.loop == true
    }())
}

// MARK: - Safe import

func runImportTests() {
    section("T4 safe import")
    let tmp = makeTempDir("imp")
    let store = IdleAnimationStore(directory: tmp.appendingPathComponent("lib", isDirectory: true))
    let srcDir = tmp.appendingPathComponent("src", isDirectory: true)
    try? FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)

    let good = srcDir.appendingPathComponent("My Cool Animation.json")
    try? lottieData().write(to: good)
    let imported = try? store.importLottie(from: good)
    check("importLottie succeeds", imported != nil)
    if let imported {
        check("stored under <UUID>.json", imported.url.lastPathComponent == imported.id.uuidString + ".json")
        check("stored in the library directory", store.contains(imported.url))
        check("stored bytes equal the source", (try? Data(contentsOf: imported.url)) == (try? Data(contentsOf: good)))
        checkEqual("display name from file name", imported.displayName, "My Cool Animation")
        checkEqual("kind", imported.kind, .lottie)
        let attrs = try? FileManager.default.attributesOfItem(atPath: store.directory.path)
        checkEqual("library directory is 0700", (attrs?[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        checkEqual("exactly one file in the library", store.storedFiles().count, 1)
        checkEqual("no temp files left behind", ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []).count, 1)
        check("source file untouched", FileManager.default.fileExists(atPath: good.path))
        check("remove deletes a stored file", store.remove(imported.url))
        check("file is gone after remove", !FileManager.default.fileExists(atPath: imported.url.path))
        check("remove of a missing file is false", !store.remove(imported.url))
    }
    // Uppercase extension accepted
    let upper = srcDir.appendingPathComponent("UP.JSON")
    try? lottieData().write(to: upper)
    check("uppercase .JSON accepted", (try? store.importLottie(from: upper)) != nil)
    // Wrong extension
    let txt = srcDir.appendingPathComponent("anim.txt")
    try? lottieData().write(to: txt)
    do { _ = try store.importLottie(from: txt); check("wrong extension error type", false) } catch let e as IdleImportError { check("wrong extension error type", e == .wrongExtension(expected: "json")) } catch { check("wrong extension error type", false) }
    // Invalid content
    let before = store.storedFiles().count
    let bad = srcDir.appendingPathComponent("bad.json")
    try? Data("{}".utf8).write(to: bad)
    do { _ = try store.importLottie(from: bad); check("invalid content rejected", false) } catch let e as IdleImportError {
        if case .validation = e { check("invalid content rejected with a validation error", true) } else { check("invalid content rejected with a validation error", false, "\(e)") }
    } catch { check("invalid content rejected", false) }
    checkEqual("nothing written for an invalid file", store.storedFiles().count, before)
    // External asset
    let ext = srcDir.appendingPathComponent("ext.json")
    try? lottieData { $0["assets"] = [["id": "i", "u": "https://evil.example/", "p": "a.png"]] }.write(to: ext)
    check("external asset import rejected", (try? store.importLottie(from: ext)) == nil)
    checkEqual("still nothing written", store.storedFiles().count, before)
    // Symlink
    let link = srcDir.appendingPathComponent("link.json")
    try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: good)
    do { _ = try store.importLottie(from: link); check("symlink rejected", false) } catch let e as IdleImportError { check("symlink rejected", e == .isSymlink) } catch { check("symlink rejected", false) }
    // Directory
    let dirAsFile = srcDir.appendingPathComponent("dir.json", isDirectory: true)
    try? FileManager.default.createDirectory(at: dirAsFile, withIntermediateDirectories: true)
    do { _ = try store.importLottie(from: dirAsFile); check("directory rejected", false) } catch let e as IdleImportError { check("directory rejected", e == .notARegularFile) } catch { check("directory rejected", false) }
    // Missing
    check("missing file rejected", (try? store.importLottie(from: srcDir.appendingPathComponent("missing.json"))) == nil)
    // Oversize
    let over = srcDir.appendingPathComponent("over.json")
    try? Data(repeating: 0x20, count: 3 * 1024 * 1024).write(to: over)
    do { _ = try store.importLottie(from: over); check("oversize rejected", false) } catch let e as IdleImportError { if case .tooLarge = e { check("oversize rejected", true) } else { check("oversize rejected", false) } } catch { check("oversize rejected", false) }
    // Non-file URL
    do { _ = try store.importLottie(from: URL(string: "https://example.com/a.json")!); check("network URL rejected", false) } catch let e as IdleImportError { check("network URL rejected", e == .notAFileURL) } catch { check("network URL rejected", false) }
    // A FIFO must not be opened (would block)
    let fifo = srcDir.appendingPathComponent("pipe.json")
    mkfifo(fifo.path, 0o600)
    do { _ = try store.importLottie(from: fifo); check("fifo rejected", false) } catch let e as IdleImportError { check("fifo rejected without blocking", e == .notARegularFile) } catch { check("fifo rejected", false) }
    // Sprite
    let spriteSrc = srcDir.appendingPathComponent("sheet.png")
    try? makePNG(width: 64, height: 32, cellsAcross: 4, cellsDown: 2).write(to: spriteSrc)
    let spriteSpec = SpriteSheetSpec(columns: 4, rows: 2, frameCount: 8, fps: 12, frameWidth: 16, frameHeight: 16)
    let spriteImp = try? store.importSprite(from: spriteSrc, spec: spriteSpec)
    check("importSprite succeeds", spriteImp != nil)
    check("sprite stored as <UUID>.png", spriteImp?.url.pathExtension == "png" && spriteImp.map { store.contains($0.url) } == true)
    checkEqual("sprite kind", spriteImp?.kind, .sprite)
    check("sprite with a bad layout rejected", (try? store.importSprite(from: spriteSrc, spec: SpriteSheetSpec(columns: 3, rows: 2, frameCount: 6, fps: 12, frameWidth: 21, frameHeight: 16))) == nil)
    check("sprite with a .json extension rejected", (try? store.importSprite(from: good, spec: spriteSpec)) == nil)
    let jpgAsPng = srcDir.appendingPathComponent("fake.png")
    try? makeJPEG(width: 64, height: 32).write(to: jpgAsPng)
    check("JPEG renamed to .png rejected", (try? store.importSprite(from: jpgAsPng, spec: spriteSpec)) == nil)
    // Orphans
    let all = store.storedFiles()
    check("storedFiles lists json and png only", all.allSatisfy { ["json", "png"].contains($0.pathExtension) })
    let referenced = spriteImp.map { [$0.url] } ?? []
    check("orphans excludes referenced files", !store.orphans(referenced: referenced).contains(where: { $0 == spriteImp?.url }))
    check("orphans includes the unreferenced upper-case import", store.orphans(referenced: referenced).count == all.count - 1)
    // remove refuses outside / dirs
    let outside = srcDir.appendingPathComponent("outside.json")
    try? lottieData().write(to: outside)
    check("remove refuses a file outside the library", !store.remove(outside))
    check("outside file still exists", FileManager.default.fileExists(atPath: outside.path))
    check("contains() is false for a sibling directory file", !store.contains(outside))
    check("contains() is false for a nested path", !store.contains(store.directory.appendingPathComponent("sub/x.json")))
    check("contains() is false for a non-file URL", !store.contains(URL(string: "https://x/y.json")!))
    // ensureDirectory on a symlinked library
    let realLib = tmp.appendingPathComponent("real", isDirectory: true)
    try? FileManager.default.createDirectory(at: realLib, withIntermediateDirectories: true)
    let linkedLib = tmp.appendingPathComponent("linked")
    try? FileManager.default.createSymbolicLink(at: linkedLib, withDestinationURL: realLib)
    let linkedStore = IdleAnimationStore(directory: linkedLib)
    do { _ = try linkedStore.ensureDirectory(); check("symlinked library directory refused", false) } catch let e as IdleImportError { check("symlinked library directory refused", e == .storeUnavailable) } catch { check("symlinked library directory refused", false) }
    check("import into a symlinked library fails", (try? linkedStore.importLottie(from: good)) == nil)
    // Empty / fresh library
    let freshStore = IdleAnimationStore(directory: tmp.appendingPathComponent("fresh", isDirectory: true))
    checkEqual("storedFiles of a missing directory is empty", freshStore.storedFiles().count, 0)
    checkEqual("orphans of a missing directory is empty", freshStore.orphans(referenced: []).count, 0)
    check("ensureDirectory creates the directory", (try? freshStore.ensureDirectory()) != nil && FileManager.default.fileExists(atPath: freshStore.directory.path))

    section("T4 name sanitising")
    checkEqual("path traversal in name", IdleAnimationStore.sanitizedName("../../etc/passwd.json"), "etc passwd")
    checkEqual("plain name", IdleAnimationStore.sanitizedName("Happy Dog.json"), "Happy Dog")
    checkEqual("empty name falls back", IdleAnimationStore.sanitizedName(""), "Animation")
    checkEqual("whitespace name falls back", IdleAnimationStore.sanitizedName("   \n\t "), "Animation")
    checkEqual("dots-only falls back", IdleAnimationStore.sanitizedName("..."), "Animation")
    checkEqual("custom fallback", IdleAnimationStore.sanitizedName("", fallback: "Sprite"), "Sprite")
    check("control characters removed", !IdleAnimationStore.sanitizedName("a\u{0000}b\u{0007}c\u{001B}[31m").unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
    check("RTL override removed", !IdleAnimationStore.sanitizedName("evil\u{202E}gnp.json").contains("\u{202E}"))
    check("long names are cut to 60", IdleAnimationStore.sanitizedName(String(repeating: "x", count: 500)).count <= 60)
    check("backslashes are not path separators in the result", !IdleAnimationStore.sanitizedName("a\\b\\c.json").contains("\\"))
    checkEqual("unicode names kept", IdleAnimationStore.sanitizedName("Kätzchen 🐱.json"), "Kätzchen 🐱")
    try? FileManager.default.removeItem(at: tmp)
}
