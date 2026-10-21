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

import SwiftUI
import ImageIO
import CoreGraphics

// Sprite-sheet playback: a PNG grid, frames cropped with CGImage.cropping (which shares the sheet's storage, so a
// "frame" costs a few bytes) and cached by index. The player owns no clock: the host's single TimelineView asks for
// `frame(at:)` with the index computed by `IdleSpriteTiming`.

final class IdleSpriteFrameStore {
    let spec: SpriteSheetSpec
    private let sheet: CGImage
    private var cache: [Int: CGImage] = [:]
    private let cacheLimit = 96

    init?(sheet: CGImage, spec: SpriteSheetSpec) {
        guard spec.columns > 0, spec.rows > 0, spec.frameCount > 0,
              sheet.width >= spec.columns * spec.frameWidth, sheet.height >= spec.rows * spec.frameHeight else { return nil }
        self.sheet = sheet
        self.spec = spec
    }

    /// Decodes the sheet through ImageIO. Call off the main thread for large sheets.
    static func load(url: URL, spec: SpriteSheetSpec) -> IdleSpriteFrameStore? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return IdleSpriteFrameStore(sheet: image, spec: spec)
    }

    var cachedFrameCount: Int { cache.count }

    func frame(at index: Int) -> CGImage? {
        let i = max(0, min(index, spec.frameCount - 1))
        if let hit = cache[i] { return hit }
        let r = spec.frameRect(i)
        guard let cropped = sheet.cropping(to: CGRect(x: r.x, y: r.y, width: r.width, height: r.height)) else { return nil }
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[i] = cropped
        return cropped
    }
}

/// Draws one frame of a loaded sheet, aspect-fit inside whatever frame the host proposes.
struct IdleSpriteFrameView: View {
    let store: IdleSpriteFrameStore
    let frameIndex: Int

    var body: some View {
        if let cg = store.frame(at: frameIndex) {
            Image(decorative: cg, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }
}

/// Loads a sheet once, off the main thread, and publishes the store. Recreated (`.id(url)`) when the file changes and
/// released with the view, so an unmounted idle animation keeps no pixels in memory.
@MainActor
final class IdleSpriteLoader: ObservableObject {
    @Published private(set) var store: IdleSpriteFrameStore?
    private var task: Task<Void, Never>?

    init(url: URL, spec: SpriteSheetSpec) {
        task = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { () -> IdleSpriteStoreBox in
                IdleSpriteStoreBox(IdleSpriteFrameStore.load(url: url, spec: spec))
            }.value
            guard !Task.isCancelled else { return }
            self?.store = loaded.store
        }
    }

    deinit { task?.cancel() }
}

/// Carries a non-Sendable store across the detached task boundary (it is only touched on one thread at a time).
struct IdleSpriteStoreBox: @unchecked Sendable {
    let store: IdleSpriteFrameStore?
    init(_ store: IdleSpriteFrameStore?) { self.store = store }
}

struct IdleSpriteView: View {
    @StateObject private var loader: IdleSpriteLoader
    let frameIndex: Int

    init(url: URL, spec: SpriteSheetSpec, frameIndex: Int) {
        _loader = StateObject(wrappedValue: IdleSpriteLoader(url: url, spec: spec))
        self.frameIndex = frameIndex
    }

    var body: some View {
        if let store = loader.store {
            IdleSpriteFrameView(store: store, frameIndex: frameIndex)
        } else {
            Color.clear
        }
    }
}
