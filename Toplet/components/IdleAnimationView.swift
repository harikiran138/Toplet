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
import Lottie
import Defaults

/// The closed-notch idle animation. It renders through the shared `IdleAnimationHost` (presets, sprite sheets, Lottie),
/// with the decision "animate, hold a still, or release everything" made by `IdlePlaybackPlanner` through an
/// `IdlePlaybackController`. The view is created by ContentView only when the idle surface wins the closed notch, so
/// the three extra inputs default to the values that situation implies; the arbiter can pass the real ones.
struct IdleAnimationView: View {
    @Default(.selectedIdleAnimation) var selectedAnimation
    @Default(.animationTransformOverrides) var overrides
    @Default(.idleAnimationMaxFPS) var maxFPS
    @Default(.idleAnimationInactivityMinutes) var inactivityMinutes

    var surfaceIsIdle = true
    var notchOpen = false
    var hideOnClosed = false

    @StateObject private var controller = IdlePlaybackController()
    @State private var resolved: IdleResolvedContent = .unavailable("not resolved yet")

    var body: some View {
        Group {
            if let animation = selectedAnimation {
                IdleAnimationHost(
                    content: resolved,
                    transform: IdleAnimationManager.effectiveTransform(for: animation, content: resolved, overrides: overrides),
                    speed: Double(animation.speed),
                    controller: controller,
                    makeLottie: { url, plan in
                        let config = overrides[animation.id.uuidString]
                        let loop = config?.loopMode.idleLoopMode ?? .loop
                        // Re-created whenever speed or loop mode changes (Lottie reads them at creation).
                        return IdleLottieView(url: url, speed: Double(animation.speed), loop: loop, plan: plan)
                            .id("\(url.absoluteString)|\(animation.speed)|\(loop.rawValue)")
                    }
                )
                .id(animation.id)
            }
        }
        .onAppear { refresh() }
        .onChange(of: selectedAnimation) { _, _ in refresh() }
        .onChange(of: maxFPS) { _, _ in syncInputs() }
        .onChange(of: inactivityMinutes) { _, _ in syncInputs() }
        .onChange(of: surfaceIsIdle) { _, _ in syncInputs() }
        .onChange(of: notchOpen) { _, _ in syncInputs() }
        .onChange(of: hideOnClosed) { _, _ in syncInputs() }
        .onReceive(LockScreenManager.shared.$isLocked) { locked in controller.update { $0.isLocked = locked } }
    }

    private func refresh() {
        if let animation = selectedAnimation {
            resolved = IdleAnimationManager.shared.resolve(animation)
        } else {
            resolved = .unavailable("nothing selected")
        }
        syncInputs()
    }

    private func syncInputs() {
        let speed = Double(selectedAnimation?.speed ?? 1)
        controller.update { i in
            i.resolvedSurfaceIsIdle = surfaceIsIdle
            i.notchOpen = notchOpen
            i.hideOnClosed = hideOnClosed
            i.userMaxFPS = Double(maxFPS)
            i.inactivityMinutes = inactivityMinutes
            switch resolved {
            case .sprite(_, let spec): i.renderer = .sprite; i.contentFPS = spec.fps * speed
            case .lottie: i.renderer = .lottie; i.contentFPS = nil
            default: i.renderer = .preset; i.contentFPS = nil
            }
        }
    }
}

// MARK: - Lottie playback with real speed / loop / pause

private final class IdleLottieAnimationBox: @unchecked Sendable {
    let animation: LottieAnimation?
    init(_ animation: LottieAnimation?) { self.animation = animation }
}

/// A small NSViewRepresentable around Lottie's own view, replacing LottieUI on the idle path: speed, loop mode and
/// pause/poster are applied for real, the animation file is parsed off the main thread, and dismantling releases it.
struct IdleLottieView: NSViewRepresentable {
    let url: URL
    let speed: Double
    let loop: IdleLoopMode
    let plan: IdlePlaybackPlan

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Lottie.LottieAnimationView {
        let view = Lottie.LottieAnimationView()
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.configure(speed: speed, loop: loop, plan: plan)
        context.coordinator.load(url: url, into: view)
        return view
    }

    func updateNSView(_ view: Lottie.LottieAnimationView, context: Context) {
        context.coordinator.apply(to: view, speed: speed, loop: loop, plan: plan)
    }

    static func dismantleNSView(_ view: Lottie.LottieAnimationView, coordinator: Coordinator) {
        coordinator.cancel()
        view.stop()
        view.animation = nil
    }

    final class Coordinator {
        private var task: Task<Void, Never>?
        private var speed = 1.0
        private var loop = IdleLoopMode.loop
        private var plan = IdlePlaybackPlan.stopped

        func configure(speed: Double, loop: IdleLoopMode, plan: IdlePlaybackPlan) {
            self.speed = speed; self.loop = loop; self.plan = plan
        }

        func load(url: URL, into view: Lottie.LottieAnimationView) {
            task?.cancel()
            if url.isFileURL {
                task = Task { [weak self, weak view] in
                    let box = await Task.detached(priority: .utility) { () -> IdleLottieAnimationBox in
                        guard let data = try? SafeFileReader.read(url, maxBytes: LottieLimits.default.maxFileBytes) else { return IdleLottieAnimationBox(nil) }
                        return IdleLottieAnimationBox(try? LottieAnimation.from(data: data))
                    }.value
                    guard !Task.isCancelled, let coordinator = self, let target = view else { return }
                    await MainActor.run { coordinator.finish(box.animation, target) }
                }
            } else {
                // Legacy remote entries (saved by older builds) keep working; new remote imports are stored locally.
                LottieAnimation.loadedFrom(url: url, closure: { [weak self, weak view] animation in
                    let box = IdleLottieAnimationBox(animation)
                    DispatchQueue.main.async { self?.finish(box.animation, view) }
                }, animationCache: nil)
            }
        }

        @MainActor
        private func finish(_ animation: LottieAnimation?, _ view: Lottie.LottieAnimationView?) {
            guard let view, let animation else { return }
            view.animation = animation
            apply(to: view, speed: speed, loop: loop, plan: plan)
        }

        func apply(to view: Lottie.LottieAnimationView, speed: Double, loop: IdleLoopMode, plan: IdlePlaybackPlan) {
            configure(speed: speed, loop: loop, plan: plan)
            guard view.animation != nil else { return }
            switch loop {
            case .loop: view.loopMode = .loop
            case .playOnce: view.loopMode = .playOnce
            case .autoReverse: view.loopMode = .autoReverse
            }
            view.animationSpeed = CGFloat(speed)
            switch plan {
            case .play:
                if !view.isAnimationPlaying { view.play() }
            case .pauseAtFirstFrame, .pauseAtPosterFrame, .stopped:
                if view.isAnimationPlaying || view.currentProgress != 0 { view.stop() }
            }
        }

        func cancel() { task?.cancel(); task = nil }
        deinit { task?.cancel() }
    }
}
