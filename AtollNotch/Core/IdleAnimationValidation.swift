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
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import ImageIO
import CoreGraphics

// Pure validators and the safe file import for idle animations (docs/NOTIFICATIONS-IDLE-AUDIT.md section 7.3).
// Nothing in here executes, renders or fetches anything: JSON is parsed as data, images are inspected through ImageIO
// (dimensions first, pixels only after the size gates pass) and files are copied byte-for-byte after validation.

// MARK: - Limits

struct LottieLimits {
    var maxFileBytes = 2 * 1024 * 1024
    var maxEmbeddedDataBytes = 1024 * 1024
    var maxExpressionLength = 4096
    var maxNestingDepth = 64
    var maxNodes = 1_500_000
    var minFPS = 1.0, maxFPS = 120.0
    var maxDimension = 4096.0
    var maxLayers = 200
    var maxDurationSeconds = 60.0
    static let `default` = LottieLimits()
}

struct SpriteLimits {
    var maxFileBytes = 16 * 1024 * 1024
    var maxTotalPixels = 16_000_000          // 16 MP
    var minFrameSide = 8, maxFrameSide = 1024
    var maxFrameCount = 240
    var minFPS = 1.0, maxFPS = 60.0
    var maxGridSide = 64
    static let `default` = SpriteLimits()
}

// MARK: - Typed issues

enum IdleValidationError: Error, Equatable, LocalizedError {
    // shared
    case empty
    case fileTooLarge(bytes: Int, limit: Int)
    // lottie
    case nestingTooDeep(limit: Int)
    case notValidJSON
    case notAnObject
    case missingField(String)
    case wrongType(field: String, expected: String)
    case nonFiniteNumber(path: String)
    case outOfRange(field: String, value: Double, lower: Double, upper: Double)
    case endNotAfterStart(ip: Double, op: Double)
    case tooManyLayers(count: Int, limit: Int)
    case noLayers
    case durationTooLong(seconds: Double, limit: Double)
    case externalAsset(index: Int, reason: String)
    case embeddedDataTooLarge(bytes: Int, limit: Int)
    case expressionTooLong(length: Int, limit: Int)
    case tooManyNodes(limit: Int)
    // sprite
    case notAPNG
    case unreadableImage
    case imageTooLarge(pixels: Int, limit: Int)
    case invalidGrid(String)
    case gridDoesNotDivide(imageWidth: Int, imageHeight: Int, columns: Int, rows: Int)
    case frameCountExceedsGrid(frameCount: Int, cells: Int)
    case frameCountOutOfRange(Int)
    case frameSizeOutOfRange(width: Int, height: Int)
    case frameSizeMismatch(expectedWidth: Int, expectedHeight: Int, specWidth: Int, specHeight: Int)
    case fpsOutOfRange(Double)
    case frameDecodeFailed(index: Int)

    var errorDescription: String? {
        switch self {
        case .empty: return "The file is empty."
        case .fileTooLarge(let b, let l): return "The file is \(b / 1024) KB; the limit is \(l / 1024) KB."
        case .nestingTooDeep(let l): return "The JSON is nested more than \(l) levels deep."
        case .notValidJSON: return "The file is not valid JSON."
        case .notAnObject: return "A Lottie file must be a JSON object."
        case .missingField(let f): return "Missing required Lottie field \"\(f)\"."
        case .wrongType(let f, let e): return "Field \"\(f)\" must be \(e)."
        case .nonFiniteNumber(let p): return "A number at \(p) is not finite."
        case .outOfRange(let f, let v, let lo, let hi): return "\"\(f)\" is \(v); it must be between \(lo) and \(hi)."
        case .endNotAfterStart(let ip, let op): return "Out point (\(op)) must be after in point (\(ip))."
        case .tooManyLayers(let c, let l): return "\(c) layers; the limit is \(l)."
        case .noLayers: return "The animation has no layers."
        case .durationTooLong(let s, let l): return "The animation lasts \(Int(s)) s; the limit is \(Int(l)) s."
        case .externalAsset(_, let r): return "The animation references an external asset (\(r)); only self-contained files are accepted."
        case .embeddedDataTooLarge(let b, let l): return "Embedded image data is \(b / 1024) KB; the limit is \(l / 1024) KB."
        case .expressionTooLong(let n, let l): return "An expression is \(n) characters; the limit is \(l)."
        case .tooManyNodes: return "The animation is too complex."
        case .notAPNG: return "Sprite sheets must be PNG images."
        case .unreadableImage: return "The image could not be read."
        case .imageTooLarge(let p, let l): return "The image has \(p / 1_000_000) megapixels; the limit is \(l / 1_000_000)."
        case .invalidGrid(let s): return "Invalid grid: \(s)."
        case .gridDoesNotDivide(let w, let h, let c, let r): return "\(w)x\(h) px does not divide evenly into \(c) columns x \(r) rows."
        case .frameCountExceedsGrid(let f, let c): return "\(f) frames do not fit a grid with \(c) cells."
        case .frameCountOutOfRange(let n): return "Frame count \(n) is outside the allowed range."
        case .frameSizeOutOfRange(let w, let h): return "Frames are \(w)x\(h) px; each side must be 8 to 1024 px."
        case .frameSizeMismatch(let ew, let eh, let sw, let sh): return "The grid gives \(ew)x\(eh) px frames but the layout says \(sw)x\(sh)."
        case .fpsOutOfRange(let f): return "\(f) fps is outside 1 to 60."
        case .frameDecodeFailed(let i): return "Frame \(i) could not be decoded."
        }
    }
}

enum IdleValidationWarning: Equatable {
    case containsExpressions(count: Int)
    case highFrameRate(Double)
    case largeCanvas(width: Double, height: Double)
    case manyLayers(Int)
    case relativeAssetPath(index: Int)
    case unusualFrameSize(width: Int, height: Int)
    case nonSquarePixels

    var message: String {
        switch self {
        case .containsExpressions(let n): return "\(n) expression(s) found; Toplet's renderer ignores most expressions."
        case .highFrameRate(let f): return "\(Int(f)) fps is heavier than needed for a notch icon."
        case .largeCanvas(let w, let h): return "\(Int(w))x\(Int(h)) canvas is large; it is scaled down to the notch."
        case .manyLayers(let n): return "\(n) layers may be slow to render."
        case .relativeAssetPath: return "An image asset uses a relative path and will not load."
        case .unusualFrameSize(let w, let h): return "\(w)x\(h) px frames are unusually large for a 30x20 pt slot."
        case .nonSquarePixels: return "Frames are not square."
        }
    }
}

struct LottieInfo: Equatable {
    var version: String
    var fps: Double
    var inPoint: Double
    var outPoint: Double
    var width: Double
    var height: Double
    var layerCount: Int
    var durationSeconds: Double
    var embeddedDataBytes: Int
    var fileBytes: Int
}

struct SpriteInfo: Equatable {
    var imageWidth: Int
    var imageHeight: Int
    var fileBytes: Int
}

struct IdleValidationReport<Info: Equatable>: Equatable {
    var errors: [IdleValidationError] = []
    var warnings: [IdleValidationWarning] = []
    var info: Info?
    var isValid: Bool { errors.isEmpty }
    var firstError: IdleValidationError? { errors.first }
}

typealias LottieReport = IdleValidationReport<LottieInfo>
typealias SpriteReport = IdleValidationReport<SpriteInfo>

// MARK: - Lottie validator

enum LottieValidator {
    static func validate(data: Data, limits: LottieLimits = .default) -> LottieReport {
        var report = LottieReport()
        if data.isEmpty { report.errors.append(.empty); return report }
        if data.count > limits.maxFileBytes {
            report.errors.append(.fileTooLarge(bytes: data.count, limit: limits.maxFileBytes))
            return report
        }
        // Iterative bracket depth scan on the raw bytes BEFORE any parser sees the file (parser recursion bomb).
        if let depth = maxBracketDepth(data, stopAbove: limits.maxNestingDepth), depth > limits.maxNestingDepth {
            report.errors.append(.nestingTooDeep(limit: limits.maxNestingDepth))
            return report
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            report.errors.append(.notValidJSON)
            return report
        }
        guard let root = parsed as? [String: Any] else {
            report.errors.append(.notAnObject)
            return report
        }

        // One pass over the whole tree (iterative): non-finite numbers, node count, expressions, embedded data URIs.
        var walk = TreeWalk()
        walk.run(root: root, limits: limits)
        if walk.tooManyNodes { report.errors.append(.tooManyNodes(limit: limits.maxNodes)); return report }
        if let path = walk.nonFinitePath { report.errors.append(.nonFiniteNumber(path: path)) }
        if let longest = walk.longestExpression, longest > limits.maxExpressionLength {
            report.errors.append(.expressionTooLong(length: longest, limit: limits.maxExpressionLength))
        }
        if walk.expressionCount > 0 { report.warnings.append(.containsExpressions(count: walk.expressionCount)) }

        // Required scalar fields.
        var version = ""
        if let v = root["v"] {
            if let s = v as? String, !s.isEmpty { version = s } else { report.errors.append(.wrongType(field: "v", expected: "a string")) }
        } else {
            report.errors.append(.missingField("v"))
        }
        let fr = number(root, "fr", &report)
        let ip = number(root, "ip", &report)
        let op = number(root, "op", &report)
        let w = number(root, "w", &report)
        let h = number(root, "h", &report)

        if let fr, fr.isFinite, !(limits.minFPS...limits.maxFPS).contains(fr) {
            report.errors.append(.outOfRange(field: "fr", value: fr, lower: limits.minFPS, upper: limits.maxFPS))
        }
        for (name, value) in [("w", w), ("h", h)] {
            if let value, value.isFinite, !(1...limits.maxDimension).contains(value) {
                report.errors.append(.outOfRange(field: name, value: value, lower: 1, upper: limits.maxDimension))
            }
        }
        if let ip, let op, ip.isFinite, op.isFinite, !(op > ip) {
            report.errors.append(.endNotAfterStart(ip: ip, op: op))
        }

        // Layers.
        var layerCount = 0
        if let layersAny = root["layers"] {
            if let layers = layersAny as? [Any] {
                layerCount = layers.count
                if layers.isEmpty { report.errors.append(.noLayers) }
                if layers.count > limits.maxLayers {
                    report.errors.append(.tooManyLayers(count: layers.count, limit: limits.maxLayers))
                }
            } else {
                report.errors.append(.wrongType(field: "layers", expected: "an array"))
            }
        } else {
            report.errors.append(.missingField("layers"))
        }

        // Duration cap.
        var duration = 0.0
        if let fr, let ip, let op, fr.isFinite, fr > 0, ip.isFinite, op.isFinite, op > ip {
            duration = (op - ip) / fr
            if duration > limits.maxDurationSeconds {
                report.errors.append(.durationTooLong(seconds: duration, limit: limits.maxDurationSeconds))
            }
        }

        // Assets: nothing may be fetched from outside the file.
        var embedded = 0
        if let assetsAny = root["assets"] {
            if let assets = assetsAny as? [Any] {
                for (i, a) in assets.enumerated() {
                    guard let asset = a as? [String: Any] else { continue }
                    if let u = asset["u"] as? String, let reason = externalReason(u, isDirectory: true) {
                        report.errors.append(.externalAsset(index: i, reason: reason))
                    }
                    if let p = asset["p"] as? String {
                        if isDataURI(p) {
                            embedded += p.utf8.count
                        } else if let reason = externalReason(p, isDirectory: false) {
                            report.errors.append(.externalAsset(index: i, reason: reason))
                        } else if !p.isEmpty {
                            report.warnings.append(.relativeAssetPath(index: i))
                        }
                    }
                }
            } else {
                report.errors.append(.wrongType(field: "assets", expected: "an array"))
            }
        }
        embedded = max(embedded, walk.dataURIBytes)
        if embedded > limits.maxEmbeddedDataBytes {
            report.errors.append(.embeddedDataTooLarge(bytes: embedded, limit: limits.maxEmbeddedDataBytes))
        }

        // Soft findings.
        if let fr, fr.isFinite, fr > 60 { report.warnings.append(.highFrameRate(fr)) }
        if let w, let h, w.isFinite, h.isFinite, max(w, h) > 2560 { report.warnings.append(.largeCanvas(width: w, height: h)) }
        if layerCount > 100 { report.warnings.append(.manyLayers(layerCount)) }

        if report.errors.isEmpty, let fr, let ip, let op, let w, let h {
            report.info = LottieInfo(version: version, fps: fr, inPoint: ip, outPoint: op, width: w, height: h,
                                     layerCount: layerCount, durationSeconds: duration, embeddedDataBytes: embedded,
                                     fileBytes: data.count)
        }
        return report
    }

    static func validate(fileURL: URL, limits: LottieLimits = .default) -> LottieReport {
        do {
            let data = try SafeFileReader.read(fileURL, maxBytes: limits.maxFileBytes)
            return validate(data: data, limits: limits)
        } catch let e as IdleImportError {
            var r = LottieReport()
            switch e {
            case .tooLarge(let b, let l): r.errors.append(.fileTooLarge(bytes: b, limit: l))
            default: r.errors.append(.unreadableImage)
            }
            return r
        } catch {
            var r = LottieReport()
            r.errors.append(.empty)
            return r
        }
    }

    // MARK: helpers

    private static func number(_ root: [String: Any], _ key: String, _ report: inout LottieReport) -> Double? {
        guard let raw = root[key] else { report.errors.append(.missingField(key)); return nil }
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
            report.errors.append(.wrongType(field: key, expected: "a number"))
            return nil
        }
        return n.doubleValue
    }

    static func isDataURI(_ s: String) -> Bool { s.lowercased().hasPrefix("data:") }

    /// Why a path/URL string counts as external, or nil when it is relative or empty.
    static func externalReason(_ s: String, isDirectory: Bool) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        let l = t.lowercased()
        if l.hasPrefix("http://") || l.hasPrefix("https://") || l.hasPrefix("//") { return "network URL" }
        if l.hasPrefix("file:") { return "file URL" }
        if l.contains("://") { return "URL with scheme" }
        if t.hasPrefix("/") || t.hasPrefix("~") || t.hasPrefix("\\") { return "absolute path" }
        if t.count >= 2, t[t.index(after: t.startIndex)] == ":" { return "drive path" }
        if t.contains("../") || t.contains("..\\") { return "parent-directory path" }
        return nil
    }

    /// Max nesting depth of [] and {} outside strings. Returns early once the depth exceeds `stopAbove`.
    static func maxBracketDepth(_ data: Data, stopAbove: Int) -> Int? {
        var depth = 0, maxDepth = 0
        var inString = false, escaped = false
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int? in
            for b in buf {
                if inString {
                    if escaped { escaped = false }
                    else if b == 0x5C { escaped = true }
                    else if b == 0x22 { inString = false }
                    continue
                }
                switch b {
                case 0x22: inString = true
                case 0x5B, 0x7B:
                    depth += 1
                    if depth > maxDepth { maxDepth = depth }
                    if maxDepth > stopAbove { return maxDepth }
                case 0x5D, 0x7D: depth -= 1
                default: break
                }
            }
            return maxDepth
        }
    }

    /// Iterative walk (no recursion, so a hostile tree cannot overflow the stack).
    private struct TreeWalk {
        var nonFinitePath: String?
        var nodes = 0
        var tooManyNodes = false
        var longestExpression: Int?
        var expressionCount = 0
        var dataURIBytes = 0

        mutating func run(root: [String: Any], limits: LottieLimits) {
            var stack: [(Any, String)] = [(root, "$")]
            while let (node, path) = stack.popLast() {
                nodes += 1
                if nodes > limits.maxNodes { tooManyNodes = true; return }
                if let dict = node as? [String: Any] {
                    for (k, v) in dict {
                        if k == "x", let s = v as? String {
                            expressionCount += 1
                            longestExpression = max(longestExpression ?? 0, s.utf8.count)
                        } else if let s = v as? String, s.count > 5, s.lowercased().hasPrefix("data:") {
                            dataURIBytes += s.utf8.count
                        }
                        if v is [String: Any] || v is [Any] {
                            stack.append((v, nonFinitePath == nil ? path + "." + k : path))
                        } else if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !n.doubleValue.isFinite {
                            if nonFinitePath == nil { nonFinitePath = path + "." + k }
                        }
                    }
                } else if let arr = node as? [Any] {
                    for (i, v) in arr.enumerated() {
                        if v is [String: Any] || v is [Any] {
                            stack.append((v, nonFinitePath == nil && i < 4 ? path + "[\(i)]" : path))
                        } else if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !n.doubleValue.isFinite {
                            if nonFinitePath == nil { nonFinitePath = path + "[\(i)]" }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Sprite sheet validator

enum SpriteSheetValidator {
    /// Validates a PNG against a layout. `decodeFrames` decodes the image and crops the first and last frame to prove the
    /// pixels are readable (skipped by tests that only exercise the metadata gates).
    static func validate(data: Data, spec: SpriteSheetSpec, limits: SpriteLimits = .default, decodeFrames: Bool = true) -> SpriteReport {
        var report = SpriteReport()
        if data.isEmpty { report.errors.append(.empty); return report }
        if data.count > limits.maxFileBytes {
            report.errors.append(.fileTooLarge(bytes: data.count, limit: limits.maxFileBytes))
            return report
        }
        // Layout gates first: they need no image at all.
        report.errors.append(contentsOf: layoutErrors(spec, limits: limits))

        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1 else {
            report.errors.append(.unreadableImage)
            return report
        }
        guard (CGImageSourceGetType(source) as String?) == "public.png" else {
            report.errors.append(.notAPNG)
            return report
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let wNum = props[kCGImagePropertyPixelWidth] as? Int,
              let hNum = props[kCGImagePropertyPixelHeight] as? Int, wNum > 0, hNum > 0 else {
            report.errors.append(.unreadableImage)
            return report
        }
        let (w, h) = (wNum, hNum)
        let (pixels, overflow) = w.multipliedReportingOverflow(by: h)
        if overflow || pixels > limits.maxTotalPixels {
            report.errors.append(.imageTooLarge(pixels: overflow ? Int.max : pixels, limit: limits.maxTotalPixels))
            return report
        }

        // Grid against the image.
        if spec.columns > 0, spec.rows > 0 {
            if w % spec.columns != 0 || h % spec.rows != 0 {
                report.errors.append(.gridDoesNotDivide(imageWidth: w, imageHeight: h, columns: spec.columns, rows: spec.rows))
            } else {
                let ew = w / spec.columns, eh = h / spec.rows
                if ew != spec.frameWidth || eh != spec.frameHeight {
                    report.errors.append(.frameSizeMismatch(expectedWidth: ew, expectedHeight: eh,
                                                            specWidth: spec.frameWidth, specHeight: spec.frameHeight))
                }
                if !(limits.minFrameSide...limits.maxFrameSide).contains(ew) || !(limits.minFrameSide...limits.maxFrameSide).contains(eh) {
                    let e = IdleValidationError.frameSizeOutOfRange(width: ew, height: eh)
                    if !report.errors.contains(e) { report.errors.append(e) }
                }
                if ew != eh { report.warnings.append(.nonSquarePixels) }
                if max(ew, eh) > 256 { report.warnings.append(.unusualFrameSize(width: ew, height: eh)) }
            }
        }
        report.info = SpriteInfo(imageWidth: w, imageHeight: h, fileBytes: data.count)

        if report.errors.isEmpty, decodeFrames {
            guard let full = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: false] as CFDictionary) else {
                report.errors.append(.unreadableImage)
                return report
            }
            for index in Set([0, spec.frameCount - 1]).sorted() {
                let r = spec.frameRect(index)
                let rect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
                guard let cropped = full.cropping(to: rect), cropped.width == r.width, cropped.height == r.height else {
                    report.errors.append(.frameDecodeFailed(index: index))
                    break
                }
            }
        }
        return report
    }

    /// Checks that need only the layout numbers.
    static func layoutErrors(_ spec: SpriteSheetSpec, limits: SpriteLimits = .default) -> [IdleValidationError] {
        var errors: [IdleValidationError] = []
        if spec.columns < 1 || spec.rows < 1 || spec.columns > limits.maxGridSide || spec.rows > limits.maxGridSide {
            errors.append(.invalidGrid("\(spec.columns) x \(spec.rows) (each side 1 to \(limits.maxGridSide))"))
        } else if spec.frameCount > spec.columns * spec.rows {
            errors.append(.frameCountExceedsGrid(frameCount: spec.frameCount, cells: spec.columns * spec.rows))
        }
        if spec.frameCount < 1 || spec.frameCount > limits.maxFrameCount { errors.append(.frameCountOutOfRange(spec.frameCount)) }
        if !spec.fps.isFinite || spec.fps < limits.minFPS || spec.fps > limits.maxFPS { errors.append(.fpsOutOfRange(spec.fps)) }
        let sideOK = (limits.minFrameSide...limits.maxFrameSide)
        if !sideOK.contains(spec.frameWidth) || !sideOK.contains(spec.frameHeight) {
            errors.append(.frameSizeOutOfRange(width: spec.frameWidth, height: spec.frameHeight))
        }
        return errors
    }

    static func validate(fileURL: URL, spec: SpriteSheetSpec, limits: SpriteLimits = .default) -> SpriteReport {
        do {
            let data = try SafeFileReader.read(fileURL, maxBytes: limits.maxFileBytes)
            return validate(data: data, spec: spec, limits: limits)
        } catch let e as IdleImportError {
            var r = SpriteReport()
            if case .tooLarge(let b, let l) = e { r.errors.append(.fileTooLarge(bytes: b, limit: l)) } else { r.errors.append(.unreadableImage) }
            return r
        } catch {
            var r = SpriteReport()
            r.errors.append(.unreadableImage)
            return r
        }
    }

    /// Image size without decoding pixels, for the import form (so it can derive the frame size from the grid).
    static func imageSize(data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              (CGImageSourceGetType(source) as String?) == "public.png",
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return (w, h)
    }
}

// MARK: - Safe file import

enum IdleImportError: Error, Equatable, LocalizedError {
    case notAFileURL
    case isSymlink
    case notARegularFile
    case wrongExtension(expected: String)
    case tooLarge(bytes: Int, limit: Int)
    case unreadable
    case validation(IdleValidationError)
    case writeFailed
    case outsideStore
    case storeUnavailable

    var errorDescription: String? {
        switch self {
        case .notAFileURL: return "Only local files can be imported."
        case .isSymlink: return "Symbolic links are not imported."
        case .notARegularFile: return "Folders and special files are not imported."
        case .wrongExtension(let e): return "Expected a .\(e) file."
        case .tooLarge(let b, let l): return "The file is \(b / 1024) KB; the limit is \(l / 1024) KB."
        case .unreadable: return "The file could not be read."
        case .validation(let v): return v.errorDescription
        case .writeFailed: return "The animation could not be saved."
        case .outsideStore: return "That file is not part of the animation library."
        case .storeUnavailable: return "The animation library folder is not available."
        }
    }
}

enum SafeFileReader {
    /// Reads at most `maxBytes` from a regular, non-symlink file. The size is checked before AND while reading.
    static func read(_ url: URL, maxBytes: Int) throws -> Data {
        guard url.isFileURL else { throw IdleImportError.notAFileURL }
        let path = url.path
        var st = stat()
        guard lstat(path, &st) == 0 else { throw IdleImportError.unreadable }
        if (st.st_mode & S_IFMT) == S_IFLNK { throw IdleImportError.isSymlink }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw IdleImportError.notARegularFile }
        if Int(st.st_size) > maxBytes { throw IdleImportError.tooLarge(bytes: Int(st.st_size), limit: maxBytes) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw IdleImportError.unreadable }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? nil
        guard let data else { throw IdleImportError.unreadable }
        if data.count > maxBytes { throw IdleImportError.tooLarge(bytes: data.count, limit: maxBytes) }
        return data
    }
}

struct ImportedIdleFile: Equatable {
    var id: UUID
    var url: URL
    var displayName: String
    var kind: IdleAnimationKind
    var warnings: [IdleValidationWarning]
}

/// The on-disk library: `<directory>/<UUID>.json|png`. Names come from UUIDs, never from the user's file name.
struct IdleAnimationStore {
    let directory: URL

    init(directory: URL) { self.directory = directory }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DynamicIsland/IdleAnimations", isDirectory: true)
    }

    @discardableResult
    func ensureDirectory() throws -> URL {
        let fm = FileManager.default
        var st = stat()
        if lstat(directory.path, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFLNK || (st.st_mode & S_IFMT) != S_IFDIR { throw IdleImportError.storeUnavailable }
            return directory
        }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw IdleImportError.storeUnavailable }
        return directory
    }

    /// User-visible name from an arbitrary file name: no path separators or control characters, trimmed, <= 60 chars.
    static func sanitizedName(_ raw: String, fallback: String = "Animation") -> String {
        var s = (raw as NSString).deletingPathExtension
        s = s.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: "\\", with: " ")
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "\u{202E}" && $0 != "\u{200B}" })
        s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if s.count > 60 { s = String(s.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? fallback : s
    }

    func importLottie(from source: URL, name: String? = nil, limits: LottieLimits = .default) throws -> ImportedIdleFile {
        guard source.isFileURL else { throw IdleImportError.notAFileURL }
        guard source.pathExtension.lowercased() == "json" else { throw IdleImportError.wrongExtension(expected: "json") }
        let data = try SafeFileReader.read(source, maxBytes: limits.maxFileBytes)
        let report = LottieValidator.validate(data: data, limits: limits)
        if let first = report.firstError { throw IdleImportError.validation(first) }
        return try store(data, ext: "json", kind: .lottie, name: name ?? source.lastPathComponent, warnings: report.warnings)
    }

    func importSprite(from source: URL, spec: SpriteSheetSpec, name: String? = nil, limits: SpriteLimits = .default) throws -> ImportedIdleFile {
        guard source.isFileURL else { throw IdleImportError.notAFileURL }
        guard source.pathExtension.lowercased() == "png" else { throw IdleImportError.wrongExtension(expected: "png") }
        let data = try SafeFileReader.read(source, maxBytes: limits.maxFileBytes)
        let report = SpriteSheetValidator.validate(data: data, spec: spec, limits: limits)
        if let first = report.firstError { throw IdleImportError.validation(first) }
        return try store(data, ext: "png", kind: .sprite, name: name ?? source.lastPathComponent, warnings: report.warnings)
    }

    /// Stores already-validated bytes (also used for the one-time https download).
    func store(_ data: Data, ext: String, kind: IdleAnimationKind, name: String, warnings: [IdleValidationWarning]) throws -> ImportedIdleFile {
        try ensureDirectory()
        let id = UUID()
        let dest = directory.appendingPathComponent("\(id.uuidString).\(ext)")
        // Defence in depth: the destination must be a direct child of the store.
        guard dest.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else {
            throw IdleImportError.outsideStore
        }
        do { try data.write(to: dest, options: [.atomic]) } catch { throw IdleImportError.writeFailed }
        return ImportedIdleFile(id: id, url: dest, displayName: Self.sanitizedName(name), kind: kind, warnings: warnings)
    }

    /// True when `url` is a direct child of the store (symlinks resolved on the parent only).
    func contains(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        return parent == directory.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Deletes a stored file; refuses anything outside the store and anything that is not a regular file.
    @discardableResult
    func remove(_ url: URL) -> Bool {
        guard contains(url) else { return false }
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    func storedFiles() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { ["json", "png"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Stored files no animation references any more (for an optional "clean up" action).
    func orphans(referenced: [URL]) -> [URL] {
        let names = Set(referenced.filter { contains($0) }.map(\.lastPathComponent))
        return storedFiles().filter { !names.contains($0.lastPathComponent) }
    }
}
