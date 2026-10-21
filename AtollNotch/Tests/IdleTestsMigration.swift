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

// T6: models, legacy decoding, migration, resolution.

// Exact copies of the shipped types in Toplet/models/Constants.swift (synthesized Codable), used to prove both
// directions: old blob -> new record, new record -> old decoder.
private struct LegacyCustomIdleAnimation: Codable, Hashable {
    let id: UUID
    var name: String
    var source: LegacyAnimationSource
    var speed: Double = 1.0
    var isBuiltIn: Bool = false
}
private enum LegacyAnimationSource: Codable, Hashable {
    case lottieFile(URL)
    case lottieURL(URL)
}
private struct LegacyTransform: Codable, Hashable {
    var scale: Double = 1.0
    var offsetX: Double = 0
    var offsetY: Double = 0
    var cropWidth: Double = 30
    var cropHeight: Double = 20
    var rotation: Double = 0
    var opacity: Double = 1.0
    var paddingBottom: Double = 0
    var expandWithAnimation: Bool = false
    var loopMode: String = "Loop"
}

// Captured read-only on this Mac: `defaults read com.Ebullioscopic.Atoll selectedIdleAnimation` and `customIdleAnimations`.
private let realSelectedBlob = #"{"id":"6016D6E7-6C89-4495-96A7-B7E04071FE67","isBuiltIn":true,"name":"Orange Cat Peeping","source":{"lottieFile":{"_0":"file:\/\/\/Users\/you\/Desktop\/github\/Atoll-Local\/Atoll\/dist\/Atoll.app\/Contents\/Resources\/Orange%20Cat%20Peeping.json"}},"speed":1}"#
private let realListBlobs: [String] = [
    #"{"id":"6D3E7CB8-28D2-4D95-88A8-8E0DB7ED8F3F","isBuiltIn":true,"name":"Dog waiting","source":{"lottieFile":{"_0":"file:\/\/\/Users\/you\/Desktop\/github\/Atoll-Local\/Atoll\/dist\/Atoll.app\/Contents\/Resources\/Dog%20waiting.json"}},"speed":1}"#,
    #"{"id":"08F85A26-E463-4338-B525-E65FECE7AB5F","isBuiltIn":true,"name":"Moody Dog","source":{"lottieFile":{"_0":"file:\/\/\/Users\/you\/Desktop\/github\/Atoll-Local\/Atoll\/dist\/Atoll.app\/Contents\/Resources\/Moody%20Dog.json"}},"speed":1}"#,
    #"{"id":"6016D6E7-6C89-4495-96A7-B7E04071FE67","isBuiltIn":true,"name":"Orange Cat Peeping","source":{"lottieFile":{"_0":"file:\/\/\/Users\/you\/Desktop\/github\/Atoll-Local\/Atoll\/dist\/Atoll.app\/Contents\/Resources\/Orange%20Cat%20Peeping.json"}},"speed":1}"#,
    #"{"id":"0B3224B7-66AB-4E11-B4D4-CE0386D4C9B5","isBuiltIn":true,"name":"Reindeer","source":{"lottieFile":{"_0":"file:\/\/\/Users\/you\/Desktop\/github\/Atoll-Local\/Atoll\/dist\/Atoll.app\/Contents\/Resources\/Reindeer.json"}},"speed":1}"#,
]

private func decodeRecord(_ s: String) -> IdleAnimationRecord? { try? JSONDecoder().decode(IdleAnimationRecord.self, from: Data(s.utf8)) }

func runMigrationTests() {
    let dec = JSONDecoder(), enc = JSONEncoder()

    section("T6 legacy blob decoding (real shape from this Mac)")
    let sel = decodeRecord(realSelectedBlob)
    check("real selectedIdleAnimation decodes", sel != nil)
    checkEqual("id", sel?.id, UUID(uuidString: "6016D6E7-6C89-4495-96A7-B7E04071FE67"))
    checkEqual("name", sel?.name, "Orange Cat Peeping")
    checkEqual("isBuiltIn", sel?.isBuiltIn, true)
    checkEqual("speed", sel?.speed, 1)
    check("source is lottieFile", { if case .lottieFile? = sel?.source { return true } else { return false } }())
    check("source points into dist/Atoll.app (the stale path)", sel?.source.url.path.contains("dist/Atoll.app/Contents/Resources/") == true)
    check("source path decodes the %20", sel?.source.url.lastPathComponent == "Orange Cat Peeping.json")
    check("new fields are nil", sel?.kind == nil && sel?.presetID == nil && sel?.sprite == nil && sel?.schemaVersion == nil)
    checkEqual("kind resolves to lottie", sel?.resolvedKind, .lottie)
    var decodedAll = 0
    for b in realListBlobs where decodeRecord(b) != nil { decodedAll += 1 }
    checkEqual("all four real list blobs decode", decodedAll, 4)
    // The same blob through the legacy (shipped) decoder: proves the mirror matches.
    let legacy = try? dec.decode(LegacyCustomIdleAnimation.self, from: Data(realSelectedBlob.utf8))
    check("real blob decodes with the shipped-shape legacy struct", legacy != nil)
    checkEqual("legacy and record agree on id", legacy?.id, sel?.id)
    checkEqual("legacy and record agree on url", legacy.map { l -> URL in if case .lottieFile(let u) = l.source { return u } else { return URL(fileURLWithPath: "/") } }, sel?.source.url)

    section("T6 forward/backward compatibility")
    if var rec = sel {
        rec.kind = .preset; rec.presetID = "breathing"; rec.schemaVersion = 2
        rec.sprite = SpriteSheetSpec(columns: 2, rows: 2, frameCount: 4, fps: 8, frameWidth: 16, frameHeight: 16)
        let data = try? enc.encode(rec)
        check("extended record encodes", data != nil)
        let back = data.flatMap { try? dec.decode(IdleAnimationRecord.self, from: $0) }
        checkEqual("extended record round-trips", back, rec)
        let old = data.flatMap { try? dec.decode(LegacyCustomIdleAnimation.self, from: $0) }
        check("an OLD build can still decode a NEW blob (unknown keys ignored)", old != nil)
        checkEqual("old build sees the same id", old?.id, rec.id)
        checkEqual("old build sees the same name", old?.name, rec.name)
    }
    let unknown = #"{"id":"6016D6E7-6C89-4495-96A7-B7E04071FE67","name":"X","source":{"lottieFile":{"_0":"file:///tmp/a.json"}},"speed":2,"isBuiltIn":false,"futureField":{"a":[1,2,3]},"anotherOne":"x"}"#
    let u = decodeRecord(unknown)
    check("unknown fields are ignored", u != nil && u?.speed == 2)
    check("missing speed defaults to 1", decodeRecord(#"{"id":"6016D6E7-6C89-4495-96A7-B7E04071FE67","name":"X","source":{"lottieFile":{"_0":"file:///tmp/a.json"}}}"#)?.speed == 1)
    check("missing isBuiltIn defaults to false", decodeRecord(#"{"id":"6016D6E7-6C89-4495-96A7-B7E04071FE67","name":"X","source":{"lottieFile":{"_0":"file:///tmp/a.json"}}}"#)?.isBuiltIn == false)
    check("a wrong-typed new field degrades to nil instead of failing", decodeRecord(#"{"id":"6016D6E7-6C89-4495-96A7-B7E04071FE67","name":"X","source":{"lottieFile":{"_0":"file:///tmp/a.json"}},"kind":"hologram","sprite":"nope","schemaVersion":"two"}"#)?.kind == nil)
    check("remote source decodes", { if case .lottieURL? = decodeRecord(#"{"id":"6016D6E7-6C89-4495-96A7-B7E04071FE67","name":"R","source":{"lottieURL":{"_0":"https://example.com/a.json"}},"speed":1,"isBuiltIn":false}"#)?.source { return true } else { return false } }())
    check("a missing id fails (it is the identity)", decodeRecord(#"{"name":"X","source":{"lottieFile":{"_0":"file:///tmp/a.json"}}}"#) == nil)
    check("garbage fails cleanly", decodeRecord("not json") == nil)
    // extras sidecar
    let extrasJSON = #"{"kind":"sprite","sprite":{"columns":4,"rows":2,"frameCount":8,"fps":12,"frameWidth":16,"frameHeight":16},"schemaVersion":2,"unknown":1}"#
    let ex = try? dec.decode(IdleAnimationExtras.self, from: Data(extrasJSON.utf8))
    check("extras decode and ignore unknown keys", ex?.kind == .sprite && ex?.sprite?.columns == 4 && ex?.schemaVersion == 2)
    check("empty extras object decodes to all nil", (try? dec.decode(IdleAnimationExtras.self, from: Data("{}".utf8))) == IdleAnimationExtras())
    check("extras with a bad kind degrade to nil", (try? dec.decode(IdleAnimationExtras.self, from: Data(#"{"kind":"zzz","presetID":"eyes"}"#.utf8)))?.presetID == "eyes")
    let sidecar = try? dec.decode([String: IdleAnimationExtras].self, from: Data(#"{"a":{"kind":"preset"},"b":{"kind":7}}"#.utf8))
    check("one bad sidecar entry does not wipe the others", sidecar?["a"]?.kind == .preset && sidecar?["b"] != nil)
    var merged = IdleAnimationRecord(name: "M", source: .lottieFile(URL(fileURLWithPath: "/tmp/m.png")))
    merged.apply(IdleAnimationExtras(kind: .sprite, sprite: SpriteSheetSpec(columns: 1, rows: 1, frameCount: 1, fps: 1, frameWidth: 16, frameHeight: 16)))
    check("apply(extras) merges fields", merged.kind == .sprite && merged.sprite != nil)
    check("apply(nil) is a no-op", { var c = merged; c.apply(nil); return c == merged }())
    checkEqual("record.extras mirrors fields", merged.extras.kind, .sprite)
    checkEqual("kind inferred from .png extension", IdleAnimationRecord(name: "p", source: .lottieFile(URL(fileURLWithPath: "/tmp/p.png"))).resolvedKind, .sprite)
    checkEqual("kind inferred from preset sentinel", IdleAnimationRecord(name: "p", source: .lottieFile(IdleSentinel.presetURL(.pulse))).resolvedKind, .preset)

    section("T6 old AnimationTransformConfig without new fields")
    let oldFull = try? enc.encode(LegacyTransform(scale: 1.5, offsetX: 2, offsetY: -3, cropWidth: 40, cropHeight: 25, rotation: 10, opacity: 0.8, paddingBottom: 1, expandWithAnimation: true, loopMode: "Auto Reverse"))
    let t1 = oldFull.flatMap { try? dec.decode(IdleTransformConfig.self, from: $0) }
    check("full legacy transform decodes", t1 != nil)
    checkEqual("scale", t1?.scale, 1.5)
    checkEqual("offsetY", t1?.offsetY, -3)
    checkEqual("cropWidth", t1?.cropWidth, 40)
    checkEqual("loop mode string", t1?.loopMode, .autoReverse)
    checkEqual("expandWithAnimation", t1?.expandWithAnimation, true)
    let t2 = try? dec.decode(IdleTransformConfig.self, from: Data(#"{"scale":2}"#.utf8))
    check("a partial transform (only scale) decodes", t2?.scale == 2 && t2?.cropWidth == 30 && t2?.cropHeight == 20 && t2?.loopMode == .loop && t2?.opacity == 1)
    check("empty object gives the defaults", (try? dec.decode(IdleTransformConfig.self, from: Data("{}".utf8))) == IdleTransformConfig.default)
    check("unknown loop mode falls back to loop", (try? dec.decode(IdleTransformConfig.self, from: Data(#"{"loopMode":"Ping Pong"}"#.utf8)))?.loopMode == .loop)
    check("a wrong-typed field falls back to its default", (try? dec.decode(IdleTransformConfig.self, from: Data(#"{"scale":"big","offsetX":4}"#.utf8)))?.scale == 1)
    check("…and keeps the other fields", (try? dec.decode(IdleTransformConfig.self, from: Data(#"{"scale":"big","offsetX":4}"#.utf8)))?.offsetX == 4)
    check("unknown transform keys are ignored", (try? dec.decode(IdleTransformConfig.self, from: Data(#"{"scale":2,"shear":9}"#.utf8)))?.scale == 2)
    let rt = IdleTransformConfig(scale: 2, offsetX: 1, cropWidth: 22, loopMode: .playOnce)
    checkEqual("transform round-trips", try? dec.decode(IdleTransformConfig.self, from: try enc.encode(rt)), rt)
    let backToLegacy = try? dec.decode(LegacyTransform.self, from: try enc.encode(rt))
    check("a legacy decoder reads our encoding", backToLegacy?.scale == 2 && backToLegacy?.loopMode == "Play Once")
    let overrides = try? dec.decode([String: IdleTransformConfig].self, from: Data(#"{"A":{"scale":2},"B":{}}"#.utf8))
    check("overrides dictionary with partial entries decodes", overrides?.count == 2 && overrides?["A"]?.scale == 2)
    checkEqual("frame size arithmetic", IdleTransformConfig(scale: 1.5, cropWidth: 30, cropHeight: 20).frameWidth, 45)
    check("frame size never collapses to 0", IdleTransformConfig(scale: 0, cropWidth: 0, cropHeight: 0).frameWidth >= 1)

    section("T6 sentinel URLs")
    for name in ["Dog waiting", "Orange Cat Peeping", "Moody Dog", "Reindeer", "Kätzchen", "a b  c"] {
        let url = IdleSentinel.bundledURL(name: name)
        checkEqual("bundled sentinel round-trips \(name)", IdleSentinel.bundledName(from: url), name)
        check("bundled sentinel for \(name) is not a file URL", !url.isFileURL && url.scheme == "atoll-bundled")
        let encoded = try? enc.encode(IdleSource.lottieFile(url))
        let decoded = encoded.flatMap { try? dec.decode(IdleSource.self, from: $0) }
        checkEqual("bundled sentinel survives JSON for \(name)", decoded?.url, url)
    }
    for p in IdlePresetID.allCases {
        checkEqual("preset sentinel round-trips \(p.rawValue)", IdleSentinel.presetID(from: IdleSentinel.presetURL(p)), p)
    }
    check("bundledName is nil for file URLs", IdleSentinel.bundledName(from: URL(fileURLWithPath: "/tmp/x.json")) == nil)
    check("presetID is nil for unknown ids", IdleSentinel.presetID(from: URL(string: "atoll-preset:///nope")!) == nil)
    check("legacy face URL is recognised", IdleSentinel.isLegacyFace(URL(string: "builtin://face")!))
    check("stable preset ids are unique", Set(IdlePresetID.allCases.map(\.stableID)).count == IdlePresetID.allCases.count)
    check("preset raw values are the persisted names", IdlePresetID.allCases.map(\.rawValue) == ["breathing", "pulse", "eyes"])

    section("T6 migration of the real library")
    let realList = realListBlobs.compactMap(decodeRecord)
    let m1 = IdleAnimationMigration.migrate(animations: realList, selected: sel)
    checkEqual("four built-ins + three presets", m1.animations.count, 7)
    checkEqual("four stale bundle URLs rewritten", m1.report.rewrittenBundled, 4)
    checkEqual("three presets added", m1.report.addedPresets, 3)
    checkEqual("nothing else added", m1.report.addedBundled, 0)
    check("report says changed", m1.report.changed)
    check("no persisted absolute bundle URL remains", m1.animations.allSatisfy { !$0.source.url.isFileURL || !$0.source.url.path.contains(".app/") })
    check("no dist/ path remains anywhere", m1.animations.allSatisfy { !$0.source.url.absoluteString.contains("dist") })
    check("rewritten built-ins keep their ids", Set(m1.animations.filter { IdleSentinel.bundledName(from: $0.source.url) != nil }.map(\.id)) == Set(realList.map(\.id)))
    check("bundled names recovered", Set(m1.animations.compactMap { IdleSentinel.bundledName(from: $0.source.url) }) == Set(["Dog waiting", "Moody Dog", "Orange Cat Peeping", "Reindeer"]))
    check("selection keeps its id", m1.selected?.id == sel?.id)
    checkEqual("selection is rewritten too", m1.selected.flatMap { IdleSentinel.bundledName(from: $0.source.url) }, "Orange Cat Peeping")
    check("selection is the list's own element", m1.selected == m1.animations.first(where: { $0.id == sel?.id }))
    check("selection repaired flag set (it was a stale copy)", m1.report.selectionRepaired)
    check("every record has a schemaVersion", m1.animations.allSatisfy { $0.schemaVersion == IdleAnimationMigration.schemaVersion })
    check("every record has a kind", m1.animations.allSatisfy { $0.kind != nil })
    check("built-in flag kept", m1.animations.allSatisfy { $0.isBuiltIn })
    for preset in IdlePresetID.allCases {
        let r = m1.animations.first(where: { $0.id == preset.stableID })
        check("preset \(preset.rawValue) present with its stable id", r != nil)
        checkEqual("preset \(preset.rawValue) kind", r?.kind, .preset)
        checkEqual("preset \(preset.rawValue) presetID", r?.presetID, preset.rawValue)
        checkEqual("preset \(preset.rawValue) name", r?.name, preset.displayName)
    }
    let m2 = IdleAnimationMigration.migrate(animations: m1.animations, selected: m1.selected)
    check("second run is a no-op (idempotent)", !m2.report.changed, "\(m2.report)")
    checkEqual("second run keeps the list", m2.animations, m1.animations)
    checkEqual("second run keeps the selection", m2.selected, m1.selected)
    // Encoding the migrated list never writes a bundle path
    let encoded = String(data: (try? enc.encode(m1.animations)) ?? Data(), encoding: .utf8) ?? ""
    check("serialised library has no '.app/Contents' text", !encoded.contains(".app\\/Contents") && !encoded.contains(".app/Contents"))
    check("serialised library has no 'file:' URL for built-ins", !encoded.contains("file:"))

    section("T6 migration edge cases")
    let userFile = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/DynamicIsland/IdleAnimations/3F2A1B00-0000-4000-8000-000000000001.json")
    let userRec = IdleAnimationRecord(id: UUID(uuidString: "3F2A1B00-0000-4000-8000-000000000001")!, name: "Mine", source: .lottieFile(userFile), speed: 1.5, isBuiltIn: false)
    let m3 = IdleAnimationMigration.migrate(animations: realList + [userRec], selected: userRec)
    check("user import is preserved untouched (URL)", m3.animations.last?.source.url == userFile)
    check("user import keeps its speed and name", m3.animations.last?.speed == 1.5 && m3.animations.last?.name == "Mine")
    check("user import is not marked built-in", m3.animations.last?.isBuiltIn == false)
    check("user import selection preserved", m3.selected?.id == userRec.id)
    check("user imports sort after the built-ins", m3.animations.firstIndex(where: { $0.id == userRec.id })! == m3.animations.count - 1)
    check("user import gets kind lottie", m3.animations.last?.kind == .lottie)
    let namesake = IdleAnimationRecord(name: "Moody Dog", source: .lottieFile(userFile), isBuiltIn: false)
    let m4 = IdleAnimationMigration.migrate(animations: [namesake], selected: nil)
    check("a user file that merely shares a built-in name is not rewritten", m4.animations.contains(where: { $0.source.url == userFile && !$0.isBuiltIn }))
    check("…and the real Moody Dog is still added", m4.animations.contains(where: { IdleSentinel.bundledName(from: $0.source.url) == "Moody Dog" }))
    let face = IdleAnimationRecord(name: "Face", source: .lottieFile(URL(string: "builtin://face")!), isBuiltIn: true)
    let m5 = IdleAnimationMigration.migrate(animations: [face] + realList, selected: face)
    checkEqual("legacy face removed", m5.report.removedLegacy, 1)
    check("selection that was the face moves to the first entry", m5.selected == m5.animations.first)
    check("face is gone from the list", !m5.animations.contains(where: { IdleSentinel.isLegacyFace($0.source.url) }))
    let installed = IdleAnimationRecord(id: UUID(), name: "Dog waiting", source: .lottieFile(URL(fileURLWithPath: NSHomeDirectory() + "/Applications/Atoll.app/Contents/Resources/Dog waiting.json")), isBuiltIn: true)
    let m6 = IdleAnimationMigration.migrate(animations: [installed], selected: installed)
    check("a ~/Applications/Atoll.app URL is rewritten too", m6.animations.first.map { IdleSentinel.bundledName(from: $0.source.url) } == "Dog waiting")
    check("duplicate built-ins (stale + new) are de-duplicated", { let dup = IdleAnimationMigration.migrate(animations: [installed, installed], selected: nil); return dup.report.deduplicated == 1 && dup.animations.filter { IdleSentinel.bundledName(from: $0.source.url) == "Dog waiting" }.count == 1 }())
    let m7 = IdleAnimationMigration.migrate(animations: [], selected: nil)
    checkEqual("empty library gets 4 bundled + 3 presets", m7.animations.count, 7)
    check("empty library: selection stays nil for the manager to choose", m7.selected == nil)
    checkEqual("empty library reports 7 additions", m7.report.addedBundled + m7.report.addedPresets, 7)
    let m8 = IdleAnimationMigration.migrate(animations: [], selected: nil, includeBundled: false)
    checkEqual("without bundled files only presets are added", m8.animations.count, 3)
    let m9 = IdleAnimationMigration.migrate(animations: [], selected: nil, availableBundledNames: ["Dog waiting"])
    checkEqual("only the available bundled names are added", m9.animations.count, 4)
    let gone = IdleAnimationRecord(name: "Deleted", source: .lottieFile(userFile))
    check("selection that is not in the list falls back to the first entry", IdleAnimationMigration.migrate(animations: realList, selected: gone).selected?.id == IdleAnimationMigration.migrate(animations: realList, selected: gone).animations.first?.id)
    let remote = IdleAnimationRecord(name: "Remote", source: .lottieURL(URL(string: "https://example.com/a.json")!))
    check("legacy remote entries survive migration", IdleAnimationMigration.migrate(animations: [remote], selected: nil).animations.contains(where: { $0.name == "Remote" }))
    check("normalize returns nil only for the legacy face", IdleAnimationMigration.normalize(face) == nil && IdleAnimationMigration.normalize(userRec) != nil)
    check("normalize is idempotent", { let a = IdleAnimationMigration.normalize(realList[0])!.record; let b = IdleAnimationMigration.normalize(a)!; return b.record == a && !b.rewritten }())
    check("currentVersion is 2", IdleAnimationMigration.currentVersion == 2)
    let tmpDir = makeTempDir("mig")
    let store = IdleAnimationStore(directory: tmpDir)
    checkEqual("empty storage directory lists nothing", store.storedFiles().count, 0)
    checkEqual("empty storage directory has no orphans", store.orphans(referenced: realList.map { $0.source.url }).count, 0)
    try? FileManager.default.removeItem(at: tmpDir)

    section("T6 content resolution")
    let bundleDir = URL(fileURLWithPath: "/Apps/Atoll.app/Contents/Resources")
    let lookup: (String) -> URL? = { name in ["Dog waiting", "Moody Dog", "Orange Cat Peeping", "Reindeer"].contains(name) ? bundleDir.appendingPathComponent(name + ".json") : nil }
    let migrated = m1.animations
    let cat = migrated.first(where: { IdleSentinel.bundledName(from: $0.source.url) == "Orange Cat Peeping" })!
    checkEqual("bundled sentinel resolves to the CURRENT bundle URL", IdleAnimationResolver.resolve(cat, bundleLookup: lookup, fileExists: { _ in true }), .lottie(bundleDir.appendingPathComponent("Orange Cat Peeping.json")))
    checkEqual("a moved app still resolves (different bundle dir)", IdleAnimationResolver.resolve(cat, bundleLookup: { _ in URL(fileURLWithPath: "/Elsewhere/Atoll.app/Contents/Resources/Orange Cat Peeping.json") }, fileExists: { _ in true }), .lottie(URL(fileURLWithPath: "/Elsewhere/Atoll.app/Contents/Resources/Orange Cat Peeping.json")))
    check("bundled sentinel unknown to the bundle is unavailable", { if case .unavailable = IdleAnimationResolver.resolve(cat, bundleLookup: { _ in nil }, fileExists: { _ in true }) { return true } else { return false } }())
    for preset in IdlePresetID.allCases {
        let r = migrated.first(where: { $0.id == preset.stableID })!
        checkEqual("preset \(preset.rawValue) resolves", IdleAnimationResolver.resolve(r, bundleLookup: lookup, fileExists: { _ in false }), .preset(preset))
    }
    let staleBuiltIn = realList[0]   // still the absolute dist/ URL, not migrated
    checkEqual("a stale absolute built-in falls back to the bundle by name", IdleAnimationResolver.resolve(staleBuiltIn, bundleLookup: lookup, fileExists: { _ in false }), .lottie(bundleDir.appendingPathComponent("Dog waiting.json")))
    check("an existing absolute built-in file is used as is", IdleAnimationResolver.resolve(staleBuiltIn, bundleLookup: lookup, fileExists: { _ in true }) == .lottie(staleBuiltIn.source.url))
    check("a missing user file is unavailable", { if case .unavailable = IdleAnimationResolver.resolve(userRec, bundleLookup: lookup, fileExists: { _ in false }) { return true } else { return false } }())
    checkEqual("an existing user file resolves", IdleAnimationResolver.resolve(userRec, bundleLookup: lookup, fileExists: { _ in true }), .lottie(userFile))
    let spec = SpriteSheetSpec(columns: 4, rows: 2, frameCount: 8, fps: 12, frameWidth: 16, frameHeight: 16)
    let spriteURL = URL(fileURLWithPath: "/tmp/lib/AAAA.png")
    let spriteRec = IdleAnimationRecord(name: "S", source: .lottieFile(spriteURL), kind: .sprite, sprite: spec)
    checkEqual("sprite resolves with its spec", IdleAnimationResolver.resolve(spriteRec, bundleLookup: lookup, fileExists: { _ in true }), .sprite(spriteURL, spec))
    check("sprite file missing is unavailable", { if case .unavailable = IdleAnimationResolver.resolve(spriteRec, bundleLookup: lookup, fileExists: { _ in false }) { return true } else { return false } }())
    var noSpec = spriteRec; noSpec.sprite = nil
    check("sprite without a layout is unavailable", { if case .unavailable = IdleAnimationResolver.resolve(noSpec, bundleLookup: lookup, fileExists: { _ in true }) { return true } else { return false } }())
    checkEqual("legacy remote URL still resolves", IdleAnimationResolver.resolve(remote, bundleLookup: lookup, fileExists: { _ in false }), .lottie(URL(string: "https://example.com/a.json")!))
    check("legacy face is unavailable", { if case .unavailable = IdleAnimationResolver.resolve(face, bundleLookup: lookup) { return true } else { return false } }())
    check("resolved kind accessor", IdleResolvedContent.preset(.eyes).kind == .preset && IdleResolvedContent.unavailable("x").kind == nil && IdleResolvedContent.lottie(userFile).kind == .lottie)
}
