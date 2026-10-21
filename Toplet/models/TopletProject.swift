/*
 * Toplet — based on Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 * Copyright (C) 2026 Toplet Contributors
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

/// Project identity in one place. Fill in `repositoryURL` and `updatesFeedBase` when the public
/// repository and its release feed exist; until then update checks stay off and links credit upstream.
enum TopletProject {
    static let name = "Toplet"
    static let bundleIdentifier = "app.toplet.Toplet"

    /// The identity this app had before it was renamed from Atoll. Settings are copied from it once.
    static let legacyBundleIdentifier = "com.Ebullioscopic.Atoll"

    /// Public source repository, e.g. URL(string: "https://github.com/harikiran138/Toplet").
    static let repositoryURL: URL? = URL(string: "https://github.com/harikiran138/Toplet")

    /// Folder that holds Toplet's Sparkle appcasts, e.g. "https://raw.githubusercontent.com/harikiran138/Toplet/main/Updates".
    /// nil disables update checks entirely, so an upstream Atoll release can never install over Toplet.
    static let updatesFeedBase: String? = nil

    /// The project Toplet is built on; credited in About and used as the source link until ours exists.
    static let upstreamURL = URL(string: "https://github.com/Ebullioscopic/Atoll")!
}

/// Copies settings saved under the pre-rename bundle id into this app's preferences, once.
/// Only keys this app has not set yet are copied, and the old preferences are left untouched,
/// so the previous app keeps working if it is ever opened again.
enum LegacySettingsMigration {
    private static let doneKey = "migratedSettingsFromAtoll"

    static func runIfNeeded(defaults: UserDefaults = .standard) {
        copyLegacySettings(defaults: defaults)
        releaseDemoTimerShortcut(defaults: defaults)
    }

    /// The demo-timer shortcut used to default to ⌘⇧T, which steals "reopen closed tab" from every
    /// browser. KeyboardShortcuts saved that default, so clear it once if it is still the old value;
    /// a shortcut the user picks afterwards is left alone.
    private static func releaseDemoTimerShortcut(defaults: UserDefaults) {
        let doneKey = "releasedDemoTimerShortcut", key = "KeyboardShortcuts_startDemoTimer"
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        if let stored = defaults.string(forKey: key), stored.contains("\"carbonKeyCode\":17"), stored.contains("\"carbonModifiers\":768") {
            defaults.removeObject(forKey: key)
        }
    }

    private static func copyLegacySettings(defaults: UserDefaults) {
        guard Bundle.main.bundleIdentifier != TopletProject.legacyBundleIdentifier,
              !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard let old = defaults.persistentDomain(forName: TopletProject.legacyBundleIdentifier), !old.isEmpty else { return }
        // Sparkle's bookkeeping belongs to the old feed; it must not carry over.
        for (key, value) in old where !key.hasPrefix("SU") && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
