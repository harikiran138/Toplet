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
import Defaults

// MARK: - Gallery

/// Pick the idle animation shown in the closed notch. Choosing is all there is: the animations are drawn natively or
/// bundled with the app, so there is nothing to import, edit or tune.
struct IdleAnimationsSettingsSection: View {
    @Default(.customIdleAnimations) var customIdleAnimations
    @Default(.selectedIdleAnimation) var selectedIdleAnimation
    @Default(.showNotHumanFace) var showNotHumanFace
    @Default(.idleAnimationMaxFPS) var maxFPS
    @Default(.idleAnimationInactivityMinutes) var inactivityMinutes

    @State private var focusedID: UUID?
    @State private var selectedForDeletion: CustomIdleAnimation?
    @State private var showingDeleteAlert = false

    private var presets: [CustomIdleAnimation] {
        customIdleAnimations.filter { IdleAnimationManager.shared.kind(of: $0) == .preset }
    }
    private var library: [CustomIdleAnimation] {
        customIdleAnimations.filter { IdleAnimationManager.shared.kind(of: $0) != .preset }
    }
    private var focused: CustomIdleAnimation? {
        customIdleAnimations.first(where: { $0.id == (focusedID ?? selectedIdleAnimation?.id) })
    }

    var body: some View {
        Group {
            Section {
                if showNotHumanFace {
                    galleryRow(title: "Shapes", systemImage: "circle.hexagongrid", items: presets)
                    galleryRow(title: "Characters", systemImage: "figure.wave", items: library)
                    controlBar
                } else {
                    Label("Turn on Idle Animation to choose one", systemImage: "moon.zzz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            } header: {
                Text("Idle Animation")
            } footer: {
                if showNotHumanFace {
                    Text("Click an animation to preview it, then choose Use (or double-click it). Thumbnails move while hovered; Reduce Motion always shows a still frame.")
                }
            }

            if showNotHumanFace {
                Section {
                    Picker("Maximum frame rate", selection: $maxFPS) {
                        ForEach([12, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    Picker("Pause when I am away", selection: $inactivityMinutes) {
                        Text("Never").tag(0)
                        ForEach([2, 5, 10, 30], id: \.self) { Text("After \($0) min").tag($0) }
                    }
                } header: {
                    Text("Energy")
                } footer: {
                    Text("The animation stops while another activity is shown, the notch is open, or the screen is locked or asleep. Low Power Mode caps it at 12 fps.")
                }
            }
        }
        .alert("Remove Animation", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                if let animation = selectedForDeletion {
                    IdleAnimationManager.shared.deleteAnimation(animation)
                    if focusedID == animation.id { focusedID = nil }
                }
            }
        } message: {
            if let animation = selectedForDeletion { Text("Remove \"\(animation.name)\" from the gallery?") }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func galleryRow(title: String, systemImage: String, items: [CustomIdleAnimation]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(items) { animation in
                            AnimationPreviewCard(
                                animation: animation,
                                isSelected: selectedIdleAnimation?.id == animation.id,
                                isFocused: focused?.id == animation.id,
                                onFocus: { focusedID = animation.id },
                                onApply: { apply(animation) },
                                onDelete: animation.isBuiltIn ? nil : { requestDelete(animation) }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                }
                .frame(height: 132)
            }
        }
    }

    private var controlBar: some View {
        HStack(alignment: .center, spacing: 12) {
            if let focused {
                NotchWingPreview(animation: focused)
                VStack(alignment: .leading, spacing: 4) {
                    Text(focused.name).font(.headline).lineLimit(1).truncationMode(.tail)
                    if selectedIdleAnimation?.id == focused.id {
                        Label("In use", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.accentColor)
                    } else {
                        Label("Preview", systemImage: "eye").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                if !focused.isBuiltIn {
                    Button(role: .destructive) { requestDelete(focused) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                Button { apply(focused) } label: {
                    Label("Use", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIdleAnimation?.id == focused.id)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Actions

    private func apply(_ animation: CustomIdleAnimation) {
        withAnimation(.easeInOut(duration: 0.2)) { selectedIdleAnimation = animation }
        focusedID = animation.id
    }

    private func requestDelete(_ animation: CustomIdleAnimation) {
        selectedForDeletion = animation
        showingDeleteAlert = true
    }
}

// MARK: - Live thumbnail / preview

/// Draws any idle animation through the same host the notch uses. `animating == false` shows the poster frame and runs
/// no clock; hover turns the clock on.
struct IdleAnimationPreviewHost: View {
    let content: IdleResolvedContent
    let transform: IdleTransformConfig
    let speed: Double
    let loop: IdleLoopMode
    let animating: Bool

    @StateObject private var controller = IdlePlaybackController()

    var body: some View {
        IdleAnimationHost(
            content: content,
            transform: transform,
            speed: speed,
            controller: controller,
            frozen: animating ? nil : IdleFrozenClock(plan: .pauseAtPosterFrame, time: 0),
            makeLottie: { url, plan in
                IdleLottieView(url: url, speed: speed, loop: loop, plan: plan)
                    .id("\(url.absoluteString)|\(speed)|\(loop.rawValue)")
            }
        )
        .onAppear { sync() }
        .onChange(of: content) { _, _ in sync() }
        .onChange(of: speed) { _, _ in sync() }
    }

    private func sync() {
        controller.update { i in
            switch content {
            case .sprite(_, let spec): i.renderer = .sprite; i.contentFPS = spec.fps * speed
            case .lottie: i.renderer = .lottie; i.contentFPS = nil
            default: i.renderer = .preset; i.contentFPS = nil
            }
            i.inactivityMinutes = 0
        }
    }
}

/// A black notch-wing swatch that previews an animation at its real transform.
struct NotchWingPreview: View {
    let animation: CustomIdleAnimation
    @Default(.animationTransformOverrides) var overrides

    var body: some View {
        let content = IdleAnimationManager.shared.resolve(animation)
        let config = IdleAnimationManager.effectiveTransform(for: animation, content: content, overrides: overrides)
        ZStack {
            UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
                .fill(Color.black)
            IdleAnimationPreviewHost(content: content, transform: config, speed: Double(animation.speed),
                                     loop: overrides[animation.id.uuidString]?.loopMode.idleLoopMode ?? .loop, animating: true)
                .id(animation.id)
        }
        .frame(width: 96, height: 44)
    }
}

// MARK: - Animation Preview Card
struct AnimationPreviewCard: View {
    let animation: CustomIdleAnimation
    let isSelected: Bool
    let isFocused: Bool
    let onFocus: () -> Void
    let onApply: () -> Void
    let onDelete: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isSelected ? Color.accentColor : (isFocused ? Color.secondary.opacity(0.6) : Color.clear),
                                          lineWidth: isSelected ? 2.5 : 1.5)
                    )
                AnimationPreview(animation: animation, animating: isHovering)
                    .frame(width: 60, height: 40)
                if let onDelete, isHovering {
                    VStack {
                        HStack {
                            Spacer()
                            Button { onDelete() } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .red)
                                    .font(.system(size: 20))
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                        }
                        Spacer()
                    }
                }
            }
            .frame(width: 100, height: 80)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
            }

            VStack(spacing: 4) {
                Text(animation.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 100)
                if isSelected {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onApply() }
        .onTapGesture { onFocus() }
        .contextMenu {
            Button("Use", systemImage: "checkmark") { onApply() }
            if let onDelete {
                Divider()
                Button("Remove", systemImage: "trash", role: .destructive) { onDelete() }
            }
        }
    }
}

// MARK: - Animation Preview (thumbnail)
struct AnimationPreview: View {
    let animation: CustomIdleAnimation
    var animating = false
    @Default(.animationTransformOverrides) var overrides

    var body: some View {
        // Thumbnails fit the animation into the card (no user transform), a still unless hovered.
        IdleAnimationPreviewHost(content: IdleAnimationManager.shared.resolve(animation),
                                 transform: IdleTransformConfig(cropWidth: 60, cropHeight: 40),
                                 speed: Double(animation.speed),
                                 loop: overrides[animation.id.uuidString]?.loopMode.idleLoopMode ?? .loop,
                                 animating: animating)
            .id("\(animation.id)|\(animating)")
            .frame(width: 60, height: 40)
    }
}
