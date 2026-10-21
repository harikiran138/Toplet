/*
 * Toplet — based on Atoll (DynamicIsland)
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

/// Where Toplet keeps its own files: ~/Library/Application Support/Toplet/<name>.
/// Unlike ~/Documents this is not a privacy-protected folder, so using it never makes macOS ask
/// for permission. Older versions kept some data in ~/Documents; it is moved here once.
enum AppDataDirectory {
    static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Toplet", isDirectory: true)
    }

    /// The folder `name`, created if needed. `legacyDocumentsName` is the folder older versions used
    /// inside ~/Documents: if it exists it is moved here (a rename on the same volume, so nothing is
    /// copied or lost), and that check happens only once, so Documents is not touched again.
    static func folder(_ name: String, legacyDocumentsName: String? = nil) -> URL {
        let fm = FileManager.default
        let dir = base.appendingPathComponent(name, isDirectory: true)
        if let legacy = legacyDocumentsName {
            let doneKey = "movedFromDocuments.\(legacy)"
            if !UserDefaults.standard.bool(forKey: doneKey) {
                UserDefaults.standard.set(true, forKey: doneKey)
                let old = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
                    .appendingPathComponent(legacy, isDirectory: true)
                if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
                    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
                    try? fm.moveItem(at: old, to: dir)
                }
            }
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
