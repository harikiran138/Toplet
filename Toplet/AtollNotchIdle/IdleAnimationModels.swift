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

// Defaults-free models of the idle animation engine (Foundation only, so plain `swiftc` can test them).
//
// Compatibility contract (docs/IDLE-ENGINE.md): `Toplet/models/Constants.swift` keeps its existing
// `CustomIdleAnimation`, `AnimationSource` and `AnimationTransformConfig` UNCHANGED. The extended fields live in
// `IdleAnimationExtras`, stored in a sidecar Defaults dictionary keyed by the animation's UUID string, and the
// source URL carries a sentinel scheme for built-ins (`atoll-bundled:`, `atoll-preset:`). `IdleAnimationRecord` is the
// complete extended shape with every NEW field optional, so a blob written by an old build still decodes and a blob
// written by this build still decodes in an old build (unknown keys are ignored by the synthesized decoder).

// MARK: - Kinds and presets

enum IdleAnimationKind: String, Codable, CaseIterable, Hashable {
    case lottie
    case sprite
    case preset
}

/// The procedural, native presets. Raw values are persisted (`presetID`) and must stay stable.
enum IdlePresetID: String, Codable, CaseIterable, Hashable {
    case breathing
    case pulse
    case eyes

    var displayName: String {
        switch self {
        case .breathing: return "Breathing"
        case .pulse: return "Pulse"
        case .eyes: return "Eyes"
        }
    }

    /// Fixed UUIDs so per-animation transform overrides and the selection survive a library reset.
    var stableID: UUID {
        switch self {
        case .breathing: return UUID(uuidString: "A7011E00-0000-4000-8000-00000000B001")!
        case .pulse: return UUID(uuidString: "A7011E00-0000-4000-8000-00000000B002")!
        case .eyes: return UUID(uuidString: "A7011E00-0000-4000-8000-00000000B003")!
        }
    }
}

/// Sprite sheet layout: a PNG grid, frames read left-to-right then top-to-bottom.
struct SpriteSheetSpec: Codable, Hashable {
    var columns: Int
    var rows: Int
    var frameCount: Int
    var fps: Double
    var frameWidth: Int
    var frameHeight: Int
    var loop: Bool

    init(columns: Int, rows: Int, frameCount: Int, fps: Double, frameWidth: Int, frameHeight: Int, loop: Bool = true) {
        self.columns = columns
        self.rows = rows
        self.frameCount = frameCount
        self.fps = fps
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.loop = loop
    }

    private enum CodingKeys: String, CodingKey { case columns, rows, frameCount, fps, frameWidth, frameHeight, loop }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        columns = try c.decode(Int.self, forKey: .columns)
        rows = try c.decode(Int.self, forKey: .rows)
        frameCount = try c.decode(Int.self, forKey: .frameCount)
        fps = try c.decode(Double.self, forKey: .fps)
        frameWidth = try c.decode(Int.self, forKey: .frameWidth)
        frameHeight = try c.decode(Int.self, forKey: .frameHeight)
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? true
    }

    /// The spec a user gets from "columns x rows, N frames, F fps" once the image size is known. nil when the grid
    /// does not divide the image evenly (the validator reports that case with a typed error).
    static func derived(imageWidth: Int, imageHeight: Int, columns: Int, rows: Int, frameCount: Int,
                        fps: Double, loop: Bool = true) -> SpriteSheetSpec? {
        guard columns > 0, rows > 0, imageWidth > 0, imageHeight > 0,
              imageWidth % columns == 0, imageHeight % rows == 0 else { return nil }
        return SpriteSheetSpec(columns: columns, rows: rows, frameCount: frameCount, fps: fps,
                               frameWidth: imageWidth / columns, frameHeight: imageHeight / rows, loop: loop)
    }

    /// Pixel rect (top-left origin) of frame `index` inside the sheet.
    func frameRect(_ index: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let i = max(0, min(index, max(0, frameCount - 1)))
        let col = columns > 0 ? i % columns : 0
        let row = columns > 0 ? i / columns : 0
        return (col * frameWidth, row * frameHeight, frameWidth, frameHeight)
    }
}

// MARK: - Source (mirror of the app's AnimationSource, same Codable shape)

/// Same synthesized Codable shape as `AnimationSource` in Constants.swift:
/// `{"lottieFile":{"_0":"file:///..."}}` and `{"lottieURL":{"_0":"https://..."}}`.
enum IdleSource: Codable, Hashable {
    case lottieFile(URL)
    case lottieURL(URL)

    var url: URL {
        switch self {
        case .lottieFile(let u), .lottieURL(let u): return u
        }
    }
}

// MARK: - Sentinel URLs (built-ins are never persisted as absolute bundle URLs)

enum IdleSentinel {
    static let bundledScheme = "atoll-bundled"
    static let presetScheme = "atoll-preset"
    static let legacyFaceURL = "builtin://face"

    /// `atoll-bundled:///<name>` : a Lottie JSON shipped inside the app bundle, resolved with `Bundle.url(forResource:)`.
    static func bundledURL(name: String) -> URL {
        var c = URLComponents()
        c.scheme = bundledScheme
        c.host = ""
        c.path = "/" + name
        return c.url ?? URL(string: "\(bundledScheme):///bundled")!
    }

    /// `atoll-preset:///<presetID>`.
    static func presetURL(_ id: IdlePresetID) -> URL {
        var c = URLComponents()
        c.scheme = presetScheme
        c.host = ""
        c.path = "/" + id.rawValue
        return c.url ?? URL(string: "\(presetScheme):///\(id.rawValue)")!
    }

    static func bundledName(from url: URL) -> String? {
        guard url.scheme == bundledScheme else { return nil }
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    static func presetID(from url: URL) -> IdlePresetID? {
        guard url.scheme == presetScheme else { return nil }
        return IdlePresetID(rawValue: url.lastPathComponent)
    }

    static func isLegacyFace(_ url: URL) -> Bool { url.absoluteString == legacyFaceURL }
}

// MARK: - Extras (the sidecar: every field optional)

struct IdleAnimationExtras: Codable, Hashable {
    var kind: IdleAnimationKind?
    var presetID: String?
    var sprite: SpriteSheetSpec?
    var schemaVersion: Int?

    init(kind: IdleAnimationKind? = nil, presetID: String? = nil, sprite: SpriteSheetSpec? = nil, schemaVersion: Int? = nil) {
        self.kind = kind
        self.presetID = presetID
        self.sprite = sprite
        self.schemaVersion = schemaVersion
    }

    // Tolerant decoding: a wrong-typed or unknown value in the sidecar degrades to nil instead of failing the whole map.
    private enum CodingKeys: String, CodingKey { case kind, presetID, sprite, schemaVersion }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(IdleAnimationKind.self, forKey: .kind)) ?? nil
        presetID = (try? c.decodeIfPresent(String.self, forKey: .presetID)) ?? nil
        sprite = (try? c.decodeIfPresent(SpriteSheetSpec.self, forKey: .sprite)) ?? nil
        schemaVersion = (try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? nil
    }
}

// MARK: - Record (the complete extended CustomIdleAnimation shape)

struct IdleAnimationRecord: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var source: IdleSource
    var speed: Double
    var isBuiltIn: Bool
    // NEW, all optional:
    var kind: IdleAnimationKind?
    var presetID: String?
    var sprite: SpriteSheetSpec?
    var schemaVersion: Int?

    init(id: UUID = UUID(), name: String, source: IdleSource, speed: Double = 1, isBuiltIn: Bool = false,
         kind: IdleAnimationKind? = nil, presetID: String? = nil, sprite: SpriteSheetSpec? = nil, schemaVersion: Int? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.speed = speed
        self.isBuiltIn = isBuiltIn
        self.kind = kind
        self.presetID = presetID
        self.sprite = sprite
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, source, speed, isBuiltIn, kind, presetID, sprite, schemaVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        source = try c.decode(IdleSource.self, forKey: .source)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        kind = (try? c.decodeIfPresent(IdleAnimationKind.self, forKey: .kind)) ?? nil
        presetID = (try? c.decodeIfPresent(String.self, forKey: .presetID)) ?? nil
        sprite = (try? c.decodeIfPresent(SpriteSheetSpec.self, forKey: .sprite)) ?? nil
        schemaVersion = (try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? nil
    }

    var extras: IdleAnimationExtras {
        IdleAnimationExtras(kind: kind, presetID: presetID, sprite: sprite, schemaVersion: schemaVersion)
    }

    mutating func apply(_ extras: IdleAnimationExtras?) {
        guard let extras else { return }
        if let k = extras.kind { kind = k }
        if let p = extras.presetID { presetID = p }
        if let s = extras.sprite { sprite = s }
        if let v = extras.schemaVersion { schemaVersion = v }
    }

    /// Kind inferred from the extras first, then from the sentinel/URL when an old blob has none.
    var resolvedKind: IdleAnimationKind {
        if let kind { return kind }
        if IdleSentinel.presetID(from: source.url) != nil { return .preset }
        if sprite != nil { return .sprite }
        if source.url.pathExtension.lowercased() == "png" { return .sprite }
        return .lottie
    }

    var resolvedPresetID: IdlePresetID? {
        if let presetID, let id = IdlePresetID(rawValue: presetID) { return id }
        return IdleSentinel.presetID(from: source.url)
    }
}

// MARK: - Transform config (tolerant mirror of AnimationTransformConfig)

enum IdleLoopMode: String, Codable, CaseIterable, Hashable {
    case loop = "Loop"
    case playOnce = "Play Once"
    case autoReverse = "Auto Reverse"
}

/// Mirror of `AnimationTransformConfig` with a decoder that tolerates ANY missing key, so adding a field later never
/// wipes a user's overrides. The renderer works on this type; the app converts the Defaults type into it.
struct IdleTransformConfig: Codable, Hashable {
    var scale: Double = 1
    var offsetX: Double = 0
    var offsetY: Double = 0
    var cropWidth: Double = 30
    var cropHeight: Double = 20
    var rotation: Double = 0
    var opacity: Double = 1
    var paddingBottom: Double = 0
    var expandWithAnimation: Bool = false
    var loopMode: IdleLoopMode = .loop

    static let `default` = IdleTransformConfig()
    /// Default frame of the procedural presets: they are drawn to fit the closed-notch slot (about 20 pt square).
    static let presetDefault = IdleTransformConfig(cropWidth: 22, cropHeight: 18)

    init() {}

    init(scale: Double = 1, offsetX: Double = 0, offsetY: Double = 0, cropWidth: Double = 30, cropHeight: Double = 20,
         rotation: Double = 0, opacity: Double = 1, paddingBottom: Double = 0, expandWithAnimation: Bool = false,
         loopMode: IdleLoopMode = .loop) {
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.cropWidth = cropWidth
        self.cropHeight = cropHeight
        self.rotation = rotation
        self.opacity = opacity
        self.paddingBottom = paddingBottom
        self.expandWithAnimation = expandWithAnimation
        self.loopMode = loopMode
    }

    private enum CodingKeys: String, CodingKey {
        case scale, offsetX, offsetY, cropWidth, cropHeight, rotation, opacity, paddingBottom, expandWithAnimation, loopMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IdleTransformConfig()
        scale = (try? c.decodeIfPresent(Double.self, forKey: .scale)) ?? d.scale
        offsetX = (try? c.decodeIfPresent(Double.self, forKey: .offsetX)) ?? d.offsetX
        offsetY = (try? c.decodeIfPresent(Double.self, forKey: .offsetY)) ?? d.offsetY
        cropWidth = (try? c.decodeIfPresent(Double.self, forKey: .cropWidth)) ?? d.cropWidth
        cropHeight = (try? c.decodeIfPresent(Double.self, forKey: .cropHeight)) ?? d.cropHeight
        rotation = (try? c.decodeIfPresent(Double.self, forKey: .rotation)) ?? d.rotation
        opacity = (try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? d.opacity
        paddingBottom = (try? c.decodeIfPresent(Double.self, forKey: .paddingBottom)) ?? d.paddingBottom
        expandWithAnimation = (try? c.decodeIfPresent(Bool.self, forKey: .expandWithAnimation)) ?? d.expandWithAnimation
        loopMode = (try? c.decodeIfPresent(IdleLoopMode.self, forKey: .loopMode)) ?? d.loopMode
    }

    /// Frame size the renderer proposes (same arithmetic the old IdleAnimationView used).
    var frameWidth: Double { max(1, cropWidth * scale) }
    var frameHeight: Double { max(1, cropHeight * scale) }
}

// MARK: - Resolution (what to draw for a record)

enum IdleResolvedContent: Equatable {
    case preset(IdlePresetID)
    case sprite(URL, SpriteSheetSpec)
    case lottie(URL)
    case unavailable(String)

    var kind: IdleAnimationKind? {
        switch self {
        case .preset: return .preset
        case .sprite: return .sprite
        case .lottie: return .lottie
        case .unavailable: return nil
        }
    }
}

enum IdleAnimationResolver {
    /// `bundleLookup` maps a bundled resource name to its CURRENT url (Bundle.main.url(forResource:)). `fileExists` is
    /// injected so tests need no disk.
    static func resolve(_ r: IdleAnimationRecord,
                        bundleLookup: (String) -> URL?,
                        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> IdleResolvedContent {
        let url = r.source.url
        if IdleSentinel.isLegacyFace(url) { return .unavailable("legacy face") }
        if let preset = r.resolvedPresetID, r.resolvedKind == .preset || IdleSentinel.presetID(from: url) != nil {
            return .preset(preset)
        }
        if let name = IdleSentinel.bundledName(from: url) {
            guard let real = bundleLookup(name) else { return .unavailable("bundled animation \(name) not found") }
            return .lottie(real)
        }
        switch r.resolvedKind {
        case .preset:
            return .unavailable("unknown preset")
        case .sprite:
            guard let spec = r.sprite else { return .unavailable("sprite sheet has no layout") }
            guard url.isFileURL, fileExists(url) else { return .unavailable("sprite file missing") }
            return .sprite(url, spec)
        case .lottie:
            switch r.source {
            case .lottieURL(let remote):
                return .lottie(remote)       // legacy remote entries keep working; new remote imports are downloaded
            case .lottieFile(let file):
                guard file.isFileURL else { return .unavailable("not a file URL") }
                guard fileExists(file) else {
                    // A stale absolute built-in URL (app moved / dist deleted): fall back to the bundled copy by name.
                    if r.isBuiltIn, let real = bundleLookup(file.deletingPathExtension().lastPathComponent) { return .lottie(real) }
                    return .unavailable("file missing")
                }
                return .lottie(file)
            }
        }
    }
}

// MARK: - Migration

struct IdleMigrationReport: Equatable {
    var removedLegacy = 0
    var rewrittenBundled = 0
    var addedPresets = 0
    var addedBundled = 0
    var deduplicated = 0
    var selectionRepaired = false
    var changed: Bool {
        removedLegacy + rewrittenBundled + addedPresets + addedBundled + deduplicated > 0 || selectionRepaired
    }
}

enum IdleAnimationMigration {
    /// Bumped when the stored representation changes. 2 = sentinel URLs + presets + sidecar extras.
    static let currentVersion = 2
    static let schemaVersion = 2
    static let bundledNames = ["Dog waiting", "Moody Dog", "Orange Cat Peeping", "Reindeer"]
    static let bundleMarker = ".app/Contents/Resources/"

    static func presetRecord(_ id: IdlePresetID) -> IdleAnimationRecord {
        IdleAnimationRecord(id: id.stableID, name: id.displayName, source: .lottieFile(IdleSentinel.presetURL(id)),
                            speed: 1, isBuiltIn: true, kind: .preset, presetID: id.rawValue, schemaVersion: schemaVersion)
    }

    /// Rewrites one record to its canonical form. nil = drop it (the removed legacy procedural face).
    static func normalize(_ r: IdleAnimationRecord, knownBundled: [String] = bundledNames) -> (record: IdleAnimationRecord, rewritten: Bool)? {
        if IdleSentinel.isLegacyFace(r.source.url) { return nil }
        var out = r
        var rewritten = false
        let url = r.source.url
        // Already canonical sentinels only get their extras filled in.
        if let name = IdleSentinel.bundledName(from: url) {
            if out.kind == nil { out.kind = .lottie; rewritten = true }
            if out.schemaVersion == nil { out.schemaVersion = schemaVersion; rewritten = true }
            if !out.isBuiltIn { out.isBuiltIn = true; rewritten = true }
            _ = name
            return (out, rewritten)
        }
        if let preset = IdleSentinel.presetID(from: url) {
            if out.kind != .preset || out.presetID != preset.rawValue || !out.isBuiltIn || out.schemaVersion == nil {
                out.kind = .preset; out.presetID = preset.rawValue; out.isBuiltIn = true; out.schemaVersion = schemaVersion
                rewritten = true
            }
            return (out, rewritten)
        }
        // A persisted absolute URL pointing into some app bundle (dist/Atoll.app, ~/Applications/Atoll.app, ...).
        if case .lottieFile(let file) = r.source, file.isFileURL {
            let base = file.deletingPathExtension().lastPathComponent
            let isBundlePath = file.path.contains(bundleMarker)
            let isKnownBuiltIn = r.isBuiltIn && (knownBundled.contains(base) || knownBundled.contains(r.name))
            if isBundlePath || isKnownBuiltIn {
                let name = knownBundled.contains(base) ? base : (knownBundled.contains(r.name) ? r.name : base)
                out.source = .lottieFile(IdleSentinel.bundledURL(name: name))
                out.isBuiltIn = true
                out.kind = .lottie
                out.schemaVersion = schemaVersion
                return (out, true)
            }
        }
        // Everything else (user imports, remote) stays as stored; only the extras are completed.
        let kind = r.resolvedKind
        if out.kind == nil { out.kind = kind; rewritten = true }
        if out.schemaVersion == nil { out.schemaVersion = schemaVersion; rewritten = true }
        return (out, rewritten)
    }

    /// Migrates the whole library: rewrites stale built-ins, drops the legacy face, de-duplicates built-ins by name
    /// (keeps the first, so the selection id stays valid), ensures every preset and every bundled name is present, and
    /// repairs the selection so it is the list's own element (or the first entry when it vanished).
    static func migrate(animations: [IdleAnimationRecord], selected: IdleAnimationRecord?,
                        availableBundledNames: [String] = bundledNames,
                        includeBundled: Bool = true) -> (animations: [IdleAnimationRecord], selected: IdleAnimationRecord?, report: IdleMigrationReport) {
        var report = IdleMigrationReport()
        var list: [IdleAnimationRecord] = []
        var seenBuiltInKeys = Set<String>()

        func key(_ r: IdleAnimationRecord) -> String? {
            guard r.isBuiltIn else { return nil }
            if let n = IdleSentinel.bundledName(from: r.source.url) { return "b:" + n }
            if let p = IdleSentinel.presetID(from: r.source.url) { return "p:" + p.rawValue }
            return nil
        }

        for r in animations {
            guard let (n, rewritten) = normalize(r) else { report.removedLegacy += 1; continue }
            if rewritten, IdleSentinel.bundledName(from: n.source.url) != nil, IdleSentinel.bundledName(from: r.source.url) == nil {
                report.rewrittenBundled += 1
            }
            if let k = key(n) {
                if seenBuiltInKeys.contains(k) { report.deduplicated += 1; continue }
                seenBuiltInKeys.insert(k)
            }
            list.append(n)
        }

        // Presets first among built-ins (after the bundled Lottie files), appended before user imports.
        let firstUser = list.firstIndex(where: { !$0.isBuiltIn }) ?? list.count
        var insertAt = firstUser
        if includeBundled {
            for name in availableBundledNames where !seenBuiltInKeys.contains("b:" + name) {
                let rec = IdleAnimationRecord(name: name, source: .lottieFile(IdleSentinel.bundledURL(name: name)), speed: 1,
                                              isBuiltIn: true, kind: .lottie, schemaVersion: schemaVersion)
                list.insert(rec, at: insertAt); insertAt += 1
                seenBuiltInKeys.insert("b:" + name)
                report.addedBundled += 1
            }
        }
        for preset in IdlePresetID.allCases where !seenBuiltInKeys.contains("p:" + preset.rawValue) {
            list.insert(presetRecord(preset), at: insertAt); insertAt += 1
            seenBuiltInKeys.insert("p:" + preset.rawValue)
            report.addedPresets += 1
        }

        var newSelected: IdleAnimationRecord?
        if let selected {
            if let match = list.first(where: { $0.id == selected.id }) {
                newSelected = match
                if match != selected { report.selectionRepaired = true }
            } else if let (n, _) = normalize(selected), let match = list.first(where: { key($0) != nil && key($0) == key(n) }) {
                newSelected = match
                report.selectionRepaired = true
            } else if IdleSentinel.isLegacyFace(selected.source.url) {
                newSelected = list.first
                report.selectionRepaired = true
            } else {
                // A user animation that is not in the list (deleted elsewhere): fall back to the first entry.
                newSelected = list.first
                report.selectionRepaired = true
            }
        }
        return (list, newSelected, report)
    }
}
