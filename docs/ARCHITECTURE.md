# Toplet architecture

Toplet is a native macOS app (Swift 5, SwiftUI + AppKit, macOS 14.6+) that draws a living panel
around the MacBook notch. This page explains how the pieces fit so you can find your way around
before changing anything. File paths are relative to the repository root.

> Historical names: the Swift module is still `Atoll`, and many types start with `Atoll` or
> `DynamicIsland`. They are kept on purpose (the extension kit and saved data depend on them).
> Everything a user sees says **Toplet**.

## The big picture

```
DynamicIslandApp.swift  ── @main DynamicNotchApp ── AppDelegate
        │                     (menu bar item, Sparkle, migrations)   (windows, observers, hotkeys)
        ▼
DynamicIslandWindow (NSPanel per screen)  ──hosts──▶  ContentView
        │                                                │
        │                     closed notch: one live activity at a time (if/else chain)
        │                     open notch:   TabSelectionView + the selected tab view
        ▼                                                ▼
DynamicIslandViewModel (per screen)          DynamicIslandViewCoordinator (shared: current tab, sneak peeks)
        │
        ▼
managers/*  (singletons: MusicManager, TimerManager, BatteryStatusViewModel, LLMUsageManager,
             AlarmManager, ShipCompanionModel, AgentsRuntime, …)  ──▶  system APIs
```

- **Entry point.** `Toplet/DynamicIslandApp.swift` defines `DynamicNotchApp` (a SwiftUI
  `App` whose only scene is the menu bar extra) and `AppDelegate`, which does the real work in
  `applicationDidFinishLaunching`: creates the notch window(s), starts managers, registers
  shortcuts and observers. The first stored property runs `LegacySettingsMigration`
  (`models/TopletProject.swift`) so settings from the pre-rename app are copied in before anything reads them.
- **Windows.** `components/Notch/DynamicIslandWindow.swift` is a borderless, non-activating
  `NSPanel` at `.mainMenu + 3`, one per screen when "show on all displays" is on. It is also placed in
  a private CGS space (`managers/NotchSpaceManager.swift`) so it stays above full-screen apps.
- **Geometry.** All notch sizing lives in `Toplet/sizing/matters.swift`
  (`getClosedNotchSize`, `openNotchSize`, width clamps). A physical notch is detected from
  `NSScreen.safeAreaInsets.top`; screens without one get a drawn notch or a floating pill.
- **The notch view.** `Toplet/ContentView.swift` draws both states:
  - *closed*: a single if/else chain picks one live activity (battery HUD, music, timer, agents,
    reminder, recording, downloads, Focus, privacy, extensions, shelf, the ship companion, the idle
    face). Two optional strips sit below it: pinned lyrics and pinned AI usage.
  - *open*: the tab bar (`components/Tabs/TabSelectionView.swift`) and a `switch` over
    `NotchViews` (`enums/generic.swift`) that shows one tab view from `components/Notch/`.
- **State.** Per-screen state is in `models/DynamicIslandViewModel.swift`; app-wide UI state
  (current tab, sneak peek) in `DynamicIslandViewCoordinator.swift`. Feature state lives in
  manager singletons under `Toplet/managers/`.
- **Settings.** Keys are declared once in `models/Constants.swift` with the
  [Defaults](https://github.com/sindresorhus/Defaults) library. The Settings window is
  `components/Settings/SettingsView.swift` (large; split into sections) plus feature sections.

## Modules worth knowing

| Area | Where | Notes |
|---|---|---|
| Media | `MediaControllers/`, `managers/MusicManager.swift` | Apple Music and Spotify by AppleScript + distributed notifications; other players through a bundled MediaRemote adapter (`mediaremote-adapter/`, run by `/usr/bin/perl`). |
| AI usage limits | `managers/LLMUsage/`, `components/Notch/NotchLLMUsageView.swift`, `PinnedUsageView.swift` | Plan limits worded like the Claude app. Pure wording rules in `UsageLimitWording.swift`. Reads other tools' local tokens **read-only**. |
| AI agents | `managers/Agents/`, `components/Notch/Agents/` | Live Claude Code / Codex sessions through hooks and a private unix socket (`~/.atoll/run/agent.sock`). Canonical, tested copy: `AtollAgents/` (see below). |
| Clock & alarms | `managers/Clock/`, `components/Notch/NotchClockView.swift` | `ClockRules.swift` is pure and tested; `AlarmManager` aims one timer at the next alarm and catches up after sleep. |
| Games | `managers/Games/`, `components/Notch/NotchGamesView.swift` | `NotchGameBoards.swift` holds pure, tested rules. |
| Ship companion | `managers/Ship/`, `components/Ship/` | `ShipMood.swift` is the pure state machine; `ShipCompanionModel` feeds it real signals; `ShipView` draws vectors in a `Canvas`. |
| Glass surfaces | `components/Notch/NotchSurface.swift` | `.notchSurface()`: Liquid Glass on macOS 26, material before, opaque with Reduce Transparency. Use it instead of ad-hoc backgrounds. |
| Lock screen | `managers/LockScreen*`, `components/LockScreen/` | Windows above the lock screen via the SkyLightWindow package (private API). |
| Extensions | `services/Extensions/` | Third-party live activities through AtollExtensionKit over XPC or a loopback WebSocket (port 9020, off unless extensions are enabled, browser origins rejected). |
| Idle animations | `AtollNotch/` → `Toplet/AtollNotchIdle/` | Synced with `local/sync-notch.sh`. |

## Stand-alone modules and syncing

`AtollAgents/` and `AtollNotch/` are built and tested on their own with plain `swiftc`, no Xcode
needed. The app compiles copies of them:

- `local/sync-agents.sh` copies `AtollAgents/{Core,Hooks,UI}` into `Toplet/managers/Agents`
  and `Toplet/components/Notch/Agents`.
- `local/sync-notch.sh` copies the idle-animation engine into `Toplet/AtollNotchIdle`.

Edit the module first, run its tests, then sync. Editing only the app copy means the change is
lost on the next sync.

## Building

Two equivalent paths (details in [DEVELOPMENT.md](DEVELOPMENT.md)):

- **Xcode**: `Toplet.xcodeproj`, scheme *Toplet*. The project uses folder-synced
  groups, so new files under `Toplet/` are picked up automatically.
- **Command Line Tools only**: `local/build.sh` generates a SwiftPM package in `local/.work/`
  (`local/prepare.py`), builds it, and assembles and ad-hoc signs `dist/Toplet.app`
  (`local/assemble.py`). Upstream Atoll's Sparkle feed and key are stripped there.

## Design rules we follow

1. **Event-driven, not polling.** Prefer notifications, KVO/Combine and one timer aimed at the next
   event. Anything visible in the closed notch must not animate continuously; see the ship's burst
   model (`ShipCompanionModel`).
2. **Pure rules, thin views.** Logic that decides something (wording, recurrence, game rules,
   moods) lives in plain Swift types with no UI so it can be tested with `swiftc` alone.
3. **Privacy first.** No analytics. Network calls are explained in their settings footer. Never
   write another app's credentials; never log tokens or personal data.
4. **Accessibility.** Respect Reduce Motion, Reduce Transparency and Increase Contrast; label
   icon-only buttons.
5. **Compatibility.** macOS 14.6 is the minimum; newer APIs go behind `#available`.

## Known architectural debt

Tracked in [audits](audits/) and the [roadmap](ROADMAP.md): screens are identified by name
rather than display ID; screen changes rebuild every window without debounce; `SettingsView.swift`
is very large; the agents code exists in two copies that must be synced by hand; several features
depend on private APIs that can break with macOS updates.
