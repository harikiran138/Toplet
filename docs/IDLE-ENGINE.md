# Idle animation engine

Extension of `IdleAnimationManager` (no second manager, no second renderer). Audit references: `docs/NOTIFICATIONS-IDLE-AUDIT.md` sections 1.B, 3, 6 (E1, E7-E9), 7.2-7.4, 7.6 T4-T7.

## What ships

| Area | Files |
|---|---|
| Pure core (Foundation, ImageIO) | `AtollNotch/Core/IdleAnimationModels.swift`, `IdleAnimationValidation.swift`, `IdleAnimationPlayback.swift`, `IdleAnimationPresetMotion.swift` |
| SwiftUI (no Lottie, no Defaults) | `AtollNotch/UI/IdlePresetViews.swift` (Breathing, Pulse, Eyes), `IdleSpriteSheetPlayer.swift`, `IdlePlaybackController.swift`, `IdleAnimationHost.swift` |
| App edits (existing files) | `Toplet/managers/IdleAnimationManager.swift`, `components/IdleAnimationView.swift`, `components/Settings/IdleAnimationsSettingsSection.swift`, `components/Settings/AnimationEditorView.swift` |
| Build hook | `local/prepare.py`: copies ONLY `AtollNotch/Core/IdleAnimation*.swift` and `AtollNotch/UI/Idle*.swift` into the app module (`Sources/Atoll/AtollNotchIdle/`) |
| Tests | `AtollNotch/Tests/run_idle.sh` (pure tests + offscreen snapshots), `Tests/IdleTest*.swift`, `Tests/Snapshot/*.swift` |

## Constants.swift: NO patch needed

`models/Constants.swift` is untouched. Decision: keep `CustomIdleAnimation`, `AnimationSource`, `AnimationTransformConfig` exactly as they are and extend through new types, so the app compiles at every step and old blobs cannot be wiped.

* Extended fields (`kind`, `presetID`, `sprite: SpriteSheetSpec`, `schemaVersion`, all optional) live in `IdleAnimationExtras`, stored in a sidecar Defaults dictionary `idleAnimationExtras: [String: IdleAnimationExtras]` keyed by the animation UUID string.
* Built-ins are identified by sentinel URLs inside the existing `AnimationSource.lottieFile(URL)`: `atoll-bundled:///Orange%20Cat%20Peeping` and `atoll-preset:///breathing`. Absolute bundle URLs are never written again; a one-time migration (`IdleAnimationMigration`) rewrites stale ones (this Mac's `selectedIdleAnimation` pointed into `dist/Atoll.app`).
* New Defaults keys are declared next to the manager (`extension Defaults.Keys` in `IdleAnimationManager.swift`): `idleAnimationExtras`, `idleAnimationLibraryVersion` (0 -> 2), `idleAnimationInactivityMinutes` (10, 0 = never), `idleAnimationMaxFPS` (24), `idleAnimationAllowRemoteURL` (false). Do not declare them again in Constants.swift.
* `IdleAnimationExtras: Defaults.Serializable` is declared in the same file.
* Optional follow-up for the integrator, not required: when the model is eventually extended in Constants.swift, `IdleAnimationRecord` already has the exact target shape (same Codable layout, new keys optional) and the synthesized decoder of the old type ignores unknown keys, so old and new builds can read each other's blobs (proved in T6 with a copy of the shipped types).

## Integrator checklist

1. Compile the idle files into the app target: the local overlay already does it (`prepare.py` hook above). For a real Xcode build, add `AtollNotch/Core/IdleAnimation*.swift` and `AtollNotch/UI/Idle*.swift` to the target (or generalise the hook to all of `AtollNotch/`, then delete the narrow hook). Files use default (internal) access.
2. `ContentView.swift` needs no edit: `IdleAnimationView()` keeps its zero-argument init. When the arbiter exists, pass its decision: `IdleAnimationView(surfaceIsIdle: resolved == .idle, notchOpen: vm.notchState == .open, hideOnClosed: vm.hideOnClosed)`. All three default to what mounting implies.
3. The view is mounted only while the idle surface wins; on unmount SwiftUI tears down the TimelineView, the Lottie NSView (`dismantleNSView` stops and releases it) and the sprite sheet. That is the "release the renderer" behaviour.
4. `IdleAnimationManager.shared.initializeDefaultAnimations()` is already called at launch (`DynamicIslandApp.swift`); it now migrates and only writes when something changed.
5. The Settings section keeps its name `IdleAnimationsSettingsSection()`; nothing in `SettingsView.swift` changes.

## Playback rules (`IdlePlaybackPlanner`, truth table T5)

First match wins: not the idle surface / notch open / fullscreen-hidden / locked / display asleep / window not visible -> `.stopped` (no view, no clock). Reduce Motion -> `.pauseAtPosterFrame` (a still; presets show a designed poster pose, sprites frame 0, Lottie frame 0). Inactivity (default 10 min, hover counts as activity) -> `.pauseAtFirstFrame`. Low Power -> `<= 12 fps` for presets and sprites, Lottie pauses (it cannot be rate-limited). Else `.play(min(user cap, content fps))`, cap 1...60, default 24.

ONE clock: a single `TimelineView` with a plan-dependent schedule (frame rate; 5 s heartbeat for inactivity or for a playing Lottie; a single entry for stills; none when stopped). No `Timer` exists anywhere in the engine. Reduce Motion, Low Power, display sleep and app hide arrive as notifications; "seconds since last user event" (`CGEventSource.secondsSinceLastEventType`, no permission) is sampled at most once per second from inside the tick, or on the 5 s heartbeat.

## Bugs from the audit fixed

* Editing an existing animation keeps name and speed (`IdleAnimationManager.update`).
* A new import persists the transform settings (`importLottieFile(..., transform:)`).
* Editor preview honours speed and loop (shared host, re-created with `.id`; Lottie goes through `IdleLottieView`, an `NSViewRepresentable` over Lottie's own view, replacing LottieUI on the idle path).
* No `print` in view bodies or the manager; the transform lookup comes from the already-decoded `@Default(.animationTransformOverrides)`; content resolution is cached in `@State` and refreshed on selection change.
* Reset (per animation: speed + adjustments; gallery: restores built-ins and presets, keeps imports); Delete only removes files that live directly in the library folder.
* Remote URLs: off by default, https only, downloaded once, validated, stored locally; legacy `.lottieURL` entries keep rendering.
* Gallery thumbnails are stills that animate only while hovered (no more N looping Lotties).

## Validation (T4)

Lottie: object, `v` string, `fr` 1...120, `op > ip`, `w`/`h` 1...4096, layers 1...200, file <= 2 MiB, no `assets[].u` http(s)/protocol-relative/file or absolute/`~`/drive/`..` `p` paths, embedded data URIs <= 1 MiB total, expression strings <= 4 KiB, nesting depth <= 64 (raw byte scan before parsing), duration <= 60 s, NaN/Inf rejected. The 6 bundled files pass. Sprite sheet: PNG only (ImageIO type check), <= 16 MiB, <= 16 MP (checked before any pixel decode), grid divides evenly, frame 8...1024 px, frameCount <= columns*rows and <= 240, fps 1...60, first and last frame cropped to prove the pixels decode. Import copies bytes only after validation, atomically, to `<UUID>.json|png` (0700 folder), refuses symlinks, directories, FIFOs and non-file URLs, sanitises display names, never executes anything.

## Tests

`AtollNotch/Tests/run_idle.sh [outdir]` (about 30 s, Command Line Tools only): part 1 pure (validators incl. negative fixtures, planner truth table + 3,072-combination invariants, legacy-blob migration with the real shape captured from this Mac, preset motion, seeded eyes schedule), part 2 offscreen snapshots (film strips for every preset, Reduce Motion == poster, sprite frame stepping and loop, clipping and transform semantics, controller state machine). PNGs land in the output directory; look at them, assertions cannot judge taste.

## Needs a person

Real notch placement and feel: how the presets read at 22 x 18 pt next to the camera housing, eye-blink timing, whether the 5 s heartbeat and 10 min inactivity default feel right, and Lottie behaviour on the real engine (the snapshot harness cannot link the Lottie binary framework).
