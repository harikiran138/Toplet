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
import Defaults
import AppKit

// The idle animation library. The model, validation, migration and playback decisions live in AtollNotch/Core
// (IdleAnimation*.swift, Foundation only, tested by AtollNotch/Tests/run_idle.sh); this manager is the only place that
// touches Defaults and the file system.
//
// Stored shape (docs/IDLE-ENGINE.md): `customIdleAnimations` / `selectedIdleAnimation` / `animationTransformOverrides`
// keep their existing types in Constants.swift. Built-ins are identified by sentinel URLs (atoll-bundled:///Name,
// atoll-preset:///breathing), never by an absolute bundle URL. The extended fields (kind, sprite layout, schema
// version) live in the sidecar `idleAnimationExtras`, keyed by the animation's UUID string.

extension IdleAnimationExtras: Defaults.Serializable {}

extension Defaults.Keys {
    static let idleAnimationExtras = Key<[String: IdleAnimationExtras]>("idleAnimationExtras", default: [:])
    static let idleAnimationLibraryVersion = Key<Int>("idleAnimationLibraryVersion", default: 0)
    /// 0 = never pause for inactivity.
    static let idleAnimationInactivityMinutes = Key<Int>("idleAnimationInactivityMinutes", default: 10)
    static let idleAnimationMaxFPS = Key<Int>("idleAnimationMaxFPS", default: 24)
    /// Off by default: remote animations are downloaded once (https only), validated, and stored locally.
    static let idleAnimationAllowRemoteURL = Key<Bool>("idleAnimationAllowRemoteURL", default: false)
}

final class IdleAnimationManager {
    static let shared = IdleAnimationManager()

    /// `~/Library/Application Support/DynamicIsland/IdleAnimations/<UUID>.json|png`
    let store: IdleAnimationStore

    private init() {
        store = IdleAnimationStore(directory: IdleAnimationStore.defaultDirectory())
        _ = try? store.ensureDirectory()
    }

    // MARK: - Record conversion

    private func record(_ a: CustomIdleAnimation, extras: [String: IdleAnimationExtras]) -> IdleAnimationRecord {
        let source: IdleSource
        switch a.source {
        case .lottieFile(let u): source = .lottieFile(u)
        case .lottieURL(let u): source = .lottieURL(u)
        }
        var r = IdleAnimationRecord(id: a.id, name: a.name, source: source, speed: Double(a.speed), isBuiltIn: a.isBuiltIn)
        r.apply(extras[a.id.uuidString])
        return r
    }

    private func animation(_ r: IdleAnimationRecord) -> CustomIdleAnimation {
        let source: AnimationSource
        switch r.source {
        case .lottieFile(let u): source = .lottieFile(u)
        case .lottieURL(let u): source = .lottieURL(u)
        }
        return CustomIdleAnimation(id: r.id, name: r.name, source: source, speed: CGFloat(r.speed), isBuiltIn: r.isBuiltIn)
    }

    /// Temp folders the settings UI stages picked/downloaded files in; removed after a successful import.
    static let stagingPrefix = "atoll-idle-import-"

    private func cleanStaged(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        if dir.lastPathComponent.hasPrefix(Self.stagingPrefix), dir.deletingLastPathComponent().standardizedFileURL.path == FileManager.default.temporaryDirectory.standardizedFileURL.path {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    static func bundledURL(_ name: String) -> URL? { Bundle.main.url(forResource: name, withExtension: "json") }

    // MARK: - Initialisation / migration

    /// Runs at launch. Creates the library on first launch, otherwise migrates it in place: stale absolute bundle URLs
    /// become sentinels, missing built-ins and presets are added, the removed legacy face is dropped, and the selection is
    /// re-pointed at the list's own element. Writes only when something changed.
    func initializeDefaultAnimations() {
        var extras = Defaults[.idleAnimationExtras]
        let list = Defaults[.customIdleAnimations].map { record($0, extras: extras) }
        let selected = Defaults[.selectedIdleAnimation].map { record($0, extras: extras) }
        let available = IdleAnimationMigration.bundledNames.filter { Self.bundledURL($0) != nil }
        let firstLaunch = list.isEmpty
        let result = IdleAnimationMigration.migrate(animations: list, selected: selected, availableBundledNames: available)

        var newSelected = result.selected
        if firstLaunch {
            newSelected = result.animations.first(where: { $0.id == IdlePresetID.breathing.stableID }) ?? result.animations.first
        }

        let versionStale = Defaults[.idleAnimationLibraryVersion] < IdleAnimationMigration.currentVersion
        guard result.report.changed || versionStale || firstLaunch else { return }

        for r in result.animations { extras[r.id.uuidString] = r.extras }
        let ids = Set(result.animations.map { $0.id.uuidString })
        for key in extras.keys where !ids.contains(key) { extras[key] = nil }
        Defaults[.idleAnimationExtras] = extras
        Defaults[.customIdleAnimations] = result.animations.map(animation)
        if let newSelected { Defaults[.selectedIdleAnimation] = animation(newSelected) }
        Defaults[.idleAnimationLibraryVersion] = IdleAnimationMigration.currentVersion
    }

    // MARK: - Resolution

    func resolve(_ a: CustomIdleAnimation) -> IdleResolvedContent {
        IdleAnimationResolver.resolve(record(a, extras: Defaults[.idleAnimationExtras]),
                                      bundleLookup: { Self.bundledURL($0) })
    }

    func kind(of a: CustomIdleAnimation) -> IdleAnimationKind {
        record(a, extras: Defaults[.idleAnimationExtras]).resolvedKind
    }

    /// The effective frame of an animation: the user's override, else the preset default, else the classic 30 x 20.
    static func effectiveTransform(for a: CustomIdleAnimation, content: IdleResolvedContent,
                                   overrides: [String: AnimationTransformConfig]) -> IdleTransformConfig {
        if let o = overrides[a.id.uuidString] { return IdleTransformConfig(o) }
        if case .preset = content { return .presetDefault }
        return .default
    }

    // MARK: - Import

    /// Imports a local Lottie JSON file (validated, copied into the library). A remote URL is refused here: remote
    /// animations are downloaded once through `downloadRemoteLottie` and imported as a local file.
    func importLottieFile(from url: URL, name: String? = nil, speed: CGFloat = 1.0,
                          transform: AnimationTransformConfig? = nil) -> Result<CustomIdleAnimation, Error> {
        if url.scheme == "http" || url.scheme == "https" { return .failure(AnimationImportError.remoteMustBeDownloaded) }
        do {
            let imported = try store.importLottie(from: url, name: name)
            let name = (name.map { IdleAnimationStore.sanitizedName($0) }) ?? imported.displayName
            cleanStaged(url)
            return .success(register(imported, name: name, speed: speed, transform: transform, extras: IdleAnimationExtras(kind: .lottie, schemaVersion: IdleAnimationMigration.schemaVersion)))
        } catch {
            return .failure(error)
        }
    }

    func importSprite(from url: URL, spec: SpriteSheetSpec, name: String? = nil, speed: CGFloat = 1.0,
                      transform: AnimationTransformConfig? = nil) -> Result<CustomIdleAnimation, Error> {
        do {
            let imported = try store.importSprite(from: url, spec: spec, name: name)
            let name = (name.map { IdleAnimationStore.sanitizedName($0) }) ?? imported.displayName
            cleanStaged(url)
            return .success(register(imported, name: name, speed: speed, transform: transform,
                                     extras: IdleAnimationExtras(kind: .sprite, sprite: spec, schemaVersion: IdleAnimationMigration.schemaVersion)))
        } catch {
            return .failure(error)
        }
    }

    private func register(_ file: ImportedIdleFile, name: String, speed: CGFloat, transform: AnimationTransformConfig?,
                          extras newExtras: IdleAnimationExtras) -> CustomIdleAnimation {
        let animation = CustomIdleAnimation(id: file.id, name: name, source: .lottieFile(file.url), speed: speed, isBuiltIn: false)
        var list = Defaults[.customIdleAnimations]
        list.append(animation)
        Defaults[.customIdleAnimations] = list
        var extras = Defaults[.idleAnimationExtras]
        extras[file.id.uuidString] = newExtras
        Defaults[.idleAnimationExtras] = extras
        if let transform {
            // The editor's transform settings are persisted with the import (they used to be discarded).
            var overrides = Defaults[.animationTransformOverrides]
            overrides[file.id.uuidString] = transform
            Defaults[.animationTransformOverrides] = overrides
        }
        return animation
    }

    /// One-time https download of a Lottie JSON into a temp file, validated before it is returned. Off unless the user
    /// allowed remote URLs; never streams at render time.
    func downloadRemoteLottie(from url: URL) async throws -> URL {
        guard Defaults[.idleAnimationAllowRemoteURL] else { throw AnimationImportError.remoteDisabled }
        guard url.scheme?.lowercased() == "https", url.host != nil else { throw AnimationImportError.httpsRequired }
        let limits = LottieLimits.default
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https" else { throw AnimationImportError.downloadFailed }
        if response.expectedContentLength > Int64(limits.maxFileBytes) {
            throw AnimationImportError.validation(.fileTooLarge(bytes: Int(response.expectedContentLength), limit: limits.maxFileBytes))
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limits.maxFileBytes { throw AnimationImportError.validation(.fileTooLarge(bytes: data.count, limit: limits.maxFileBytes)) }
        }
        let report = LottieValidator.validate(data: data, limits: limits)
        if let first = report.firstError { throw AnimationImportError.validation(first) }
        let name = IdleAnimationStore.sanitizedName(url.lastPathComponent, fallback: "Remote animation")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent("\(name).json")
        try data.write(to: tmp, options: .atomic)
        return tmp
    }

    // MARK: - Editing

    /// Saves an edit of an EXISTING animation: name, speed and transform all persist (the editor used to keep only the
    /// transform). The selection copy is kept in sync.
    func update(_ animation: CustomIdleAnimation, name: String, speed: CGFloat, transform: AnimationTransformConfig) {
        var list = Defaults[.customIdleAnimations]
        guard let index = list.firstIndex(where: { $0.id == animation.id }) else { return }
        var updated = list[index]
        let clean = IdleAnimationStore.sanitizedName(name, fallback: updated.name)
        updated.name = clean
        updated.speed = speed
        list[index] = updated
        Defaults[.customIdleAnimations] = list
        var overrides = Defaults[.animationTransformOverrides]
        overrides[animation.id.uuidString] = transform
        Defaults[.animationTransformOverrides] = overrides
        if Defaults[.selectedIdleAnimation]?.id == animation.id { Defaults[.selectedIdleAnimation] = updated }
    }

    // MARK: - Reset / delete

    /// Forgets the user's adjustments for one animation (frame, rotation, opacity...) and its speed.
    func resetAdjustments(for animation: CustomIdleAnimation) {
        var overrides = Defaults[.animationTransformOverrides]
        overrides[animation.id.uuidString] = nil
        Defaults[.animationTransformOverrides] = overrides
        var list = Defaults[.customIdleAnimations]
        if let i = list.firstIndex(where: { $0.id == animation.id }) {
            list[i].speed = 1
            Defaults[.customIdleAnimations] = list
            if Defaults[.selectedIdleAnimation]?.id == animation.id { Defaults[.selectedIdleAnimation] = list[i] }
        }
    }

    /// Restores the built-in set: every bundled animation and preset is present with its canonical name and speed, built-in
    /// adjustments are cleared, the selection falls back to Breathing when it is invalid. User imports are kept.
    func resetLibrary() {
        initializeDefaultAnimations()
        var list = Defaults[.customIdleAnimations]
        var overrides = Defaults[.animationTransformOverrides]
        let extras = Defaults[.idleAnimationExtras]
        for i in list.indices where list[i].isBuiltIn {
            let r = record(list[i], extras: extras)
            if let preset = r.resolvedPresetID { list[i].name = preset.displayName }
            else if let n = IdleSentinel.bundledName(from: r.source.url) { list[i].name = n }
            list[i].speed = 1
            overrides[list[i].id.uuidString] = nil
        }
        Defaults[.customIdleAnimations] = list
        Defaults[.animationTransformOverrides] = overrides
        if let sel = Defaults[.selectedIdleAnimation], let match = list.first(where: { $0.id == sel.id }) {
            Defaults[.selectedIdleAnimation] = match
        } else {
            Defaults[.selectedIdleAnimation] = list.first(where: { $0.id == IdlePresetID.breathing.stableID }) ?? list.first
        }
    }

    /// Delete a user-added animation (built-ins cannot be deleted; use Reset). Its stored file is removed only when it
    /// lives directly inside the library folder.
    @discardableResult
    func deleteAnimation(_ animation: CustomIdleAnimation) -> Bool {
        guard !animation.isBuiltIn else { return false }
        var list = Defaults[.customIdleAnimations]
        guard let index = list.firstIndex(where: { $0.id == animation.id }) else { return false }
        list.remove(at: index)
        Defaults[.customIdleAnimations] = list
        if case .lottieFile(let url) = animation.source { store.remove(url) }
        var extras = Defaults[.idleAnimationExtras]
        extras[animation.id.uuidString] = nil
        Defaults[.idleAnimationExtras] = extras
        var overrides = Defaults[.animationTransformOverrides]
        overrides[animation.id.uuidString] = nil
        Defaults[.animationTransformOverrides] = overrides
        if Defaults[.selectedIdleAnimation]?.id == animation.id {
            Defaults[.selectedIdleAnimation] = list.first(where: { $0.id == IdlePresetID.breathing.stableID }) ?? list.first
        }
        return true
    }
}

extension IdleTransformConfig {
    init(_ c: AnimationTransformConfig) {
        self.init(scale: Double(c.scale), offsetX: Double(c.offsetX), offsetY: Double(c.offsetY),
                  cropWidth: Double(c.cropWidth), cropHeight: Double(c.cropHeight), rotation: Double(c.rotation),
                  opacity: Double(c.opacity), paddingBottom: Double(c.paddingBottom),
                  expandWithAnimation: c.expandWithAnimation,
                  loopMode: IdleLoopMode(rawValue: c.loopMode.rawValue) ?? .loop)
    }
}

extension AnimationLoopMode {
    var idleLoopMode: IdleLoopMode { IdleLoopMode(rawValue: rawValue) ?? .loop }
}

// MARK: - Error Types
enum AnimationImportError: LocalizedError {
    case invalidFileType
    case invalidJSON
    case downloadFailed
    case remoteDisabled
    case httpsRequired
    case remoteMustBeDownloaded
    case validation(IdleValidationError)

    var errorDescription: String? {
        switch self {
        case .invalidFileType:
            return "Only .json (Lottie) and .png (sprite sheet) files are supported"
        case .invalidJSON:
            return "Invalid Lottie JSON format"
        case .downloadFailed:
            return "Failed to download animation"
        case .remoteDisabled:
            return "Downloading animations from the web is turned off. Enable it in Idle Animation settings."
        case .httpsRequired:
            return "Only https:// links can be downloaded."
        case .remoteMustBeDownloaded:
            return "Remote animations are downloaded first and then imported as a local file."
        case .validation(let v):
            return v.errorDescription
        }
    }
}
