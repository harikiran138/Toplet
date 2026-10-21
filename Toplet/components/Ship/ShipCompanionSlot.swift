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

import Defaults
import SwiftUI

extension ShipAppearance: Defaults.Serializable {}

/// The ship beside the closed notch, shown when nothing else needs the space. Same layout recipe
/// as the idle face: an empty left wing, the black notch body, and the ship in the right wing, so
/// the shape stays centred on the camera housing.
struct ShipCompanionSlot: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var model = ShipCompanionModel.shared
    @Default(.shipAppearance) private var appearance
    var isHovering: Bool

    private var wingHeight: CGFloat { max(0, vm.effectiveClosedNotchHeight - 10) }
    private var wingWidth: CGFloat { wingHeight * 1.6 }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: wingWidth, height: wingHeight)
            Rectangle().fill(.black).frame(width: vm.closedNotchSize.width - 20)
            ShipView(mood: model.mood, palette: appearance.palette,
                     animating: model.isAnimating, showsBadge: wingHeight >= 18)
            .frame(width: wingWidth, height: wingHeight)
            .padding(.trailing, 2)
            .contentShape(Rectangle())
            .onTapGesture { model.clicked() }
            .help(model.mood.title)
        }
        .frame(height: vm.effectiveClosedNotchHeight + (isHovering ? 8 : 0), alignment: .center)
        .onAppear { model.start() }
        .onChange(of: isHovering) { _, hovering in model.setHovering(hovering) }
        .transition(.opacity.animation(.smooth(duration: 0.25)))
    }
}

/// Settings: switch the ship on, pick an appearance, and preview every mood without faking any system state.
struct ShipSettingsSection: View {
    @Default(.showShipCompanion) private var showShip
    @Default(.shipAppearance) private var appearance
    @State private var previewMood: ShipMood = .idle

    var body: some View {
        Section {
            Defaults.Toggle(key: .showShipCompanion) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show the ship next to the closed notch")
                    Text("A small companion that reacts to charging, downloads, timers, being offline and night. It moves for a few seconds when something changes, then rests.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if showShip {
                Picker("Appearance", selection: $appearance) {
                    ForEach(ShipAppearance.allCases) { Text($0.title).tag($0) }
                }
                HStack(alignment: .center, spacing: 16) {
                    // The preview moves while Settings is open (Reduce Motion still freezes it).
                    ShipView(mood: previewMood, palette: appearance.palette, animating: true)
                    .frame(width: 150, height: 96)
                    .padding(10)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Preview mood", selection: $previewMood) {
                            ForEach(ShipMood.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        Text(previewMood.accessibilityDescription)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Ship companion")
        } footer: {
            Text("The ship only reacts to things Toplet can actually see on this Mac. It stays still with Reduce Motion or Low Power Mode on.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
