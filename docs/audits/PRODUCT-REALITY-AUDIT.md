# Toplet: product reality audit

**Date:** 2026-10-21.
**Branch:** `feature-ai-agents`, HEAD `5b2b94a`, app version 2.3.3 (`VERSION`). 88 tracked files modified, 11 deleted, 26 untracked paths.

> **Update after the audit (same day):** everything listed as untracked here was committed on the new `toplet` branch (commits 13f02a1…7d5de62). The ship companion has a Settings section (Appearance › Ship companion: on/off, appearance, mood preview). Backlog item 1 is therefore done except for unifying the two Agents copies; the launch-time resume of stopped OSDUIHelper/wallpaper processes, the notch window forced to the dark appearance and VoiceOver labels on tab buttons were also added after this audit.

**Method.** The code was only read. Nothing was edited, built, run or committed. Every claim cites `file:line` and paths are relative to the repo root. Five read-only research agents gathered the evidence. The highest-impact citations were then re-checked by hand on the final tree. Where two sources disagreed, the code decided.

**Line-number caveat.** Another session was editing `Toplet/DynamicIslandApp.swift`, `ContentView.swift` and `models/Constants.swift` during the audit. Lines in those three files can drift by a few. Search for the quoted symbol if a line does not match.

**What "verified" means here.** "Working and verified" is used only where unit tests cover the logic, or where the code path is short and unambiguous. Nothing was run, so runtime behaviour (animation, permission prompts, multi-display) is otherwise **Cannot currently verify** or **Working but requires improvement**, with the reason given.

**Prior audits.** `docs/FEATURE-MATRIX-A.md`, `docs/DEAD-CODE-REPORT.md` and `docs/TEST-RESULTS.md` were written against a different checkout (`Atoll`, branch `local-build`, `f039ca9`). They were used only as leads. Their line numbers do not apply here.

---

## 0. Repository state (read this first)

| Fact | Evidence |
|---|---|
| The AI agents module, the idle-animation module and several of this week's features are **not committed**: `AtollAgents/`, `AtollNotch/`, `managers/Clock/`, `managers/Games/`, `NotchClockView.swift`, `NotchGamesView.swift`, `NotchSurface.swift`, `PinnedUsageView.swift`, `models/TopletProject.swift`, `local/tools/rebrand.py` | `git status --short` (`??` entries); `git ls-files AtollAgents AtollNotch` returns 0 files |
| The app ships its own copy of the agents code. The `AtollAgents/` module that the tests exercise is a second, drifted copy (6–8 files differ, e.g. `UsageSnapshot` vs `AgentUsageSnapshot`). It is synced by hand | `managers/AgentsIntegration.swift:23` (comment about `local/sync-agents.sh`); file comparison of `AtollAgents/Core` vs `Toplet/managers/Agents` |
| Idle-animation sources are now copied into `Toplet/AtollNotchIdle/` (8 files), so the Xcode synchronized group compiles them | `Toplet/AtollNotchIdle/IdlePlaybackController.swift` etc.; synchronized root group `Toplet.xcodeproj/project.pbxproj:147-164` |

Risk: a fresh clone of the committed tree does not contain the Agents, Clock, Games or idle code. Commit these before any release (backlog #1).

---

## 1. Architecture summary

### 1.1 Language, frameworks, targets
- **Language and UI.** Swift 5 (`SWIFT_VERSION = 5.0`, `project.pbxproj:579`), SwiftUI plus AppKit, about 377 Swift files under `Toplet/`. One C++/ObjC++ audio piece (`Toplet/audio/AudioBridge.mm`), bridged through `Toplet/Toplet-Bridging-Header.h:16`.
- **Minimum macOS.** The app target is **14.6** (`project.pbxproj:830`, and `:906` for Release). The unit tests target 15.0 (`:574`) and the UI tests 14.0 (`:620`).
- **Bundle IDs.**
  - App: `app.toplet.Toplet` (Release, `:908`) and `app.toplet.Toplet.dev` (Debug, `:832`).
  - The UI test target is still `com.atoll.TopletUITests` (`:621`).
  - Defined in `models/TopletProject.swift:22-23`.
- **Sandbox and signing.**
  - Sandbox **off** (`ENABLE_APP_SANDBOX = NO`, `:791`); hardened runtime on (`:792`).
  - Library validation is disabled (`Toplet/Toplet.entitlements:5`).
  - The signing team is still upstream's (`project.pbxproj:790`).

### 1.2 Swift packages (`Toplet.xcodeproj/project.pbxproj`)

| Package | Requirement | Line |
|---|---|---|
| MacroVisionKit (fullscreen detection) | upToNextMajor 0.1.0 | 972-975 |
| LaunchAtLogin-Modern | **branch main** | 980-983 |
| Sparkle | upToNextMajor 2.6.4 | 988-991 |
| open-meteo | upToNextMajor 1.4.16, **declared, never linked or imported** | 996-999 |
| AtollExtensionKit (Ebullioscopic) | **branch main** | 1004-1007 |
| SkyLightWindow (private SkyLight) | **branch main** | 1012-1015 |
| SwiftTerm | upToNextMajor 1.5.0 | 1020-1023 |
| Pow | upToNextMajor 1.0.4, **declared, never linked or imported** | 1028-1031 |
| swiftui-introspect | upToNextMajor 1.3.0 | 1036-1039 |
| KeyboardShortcuts | upToNextMajor 2.2.4 | 1044-1047 |
| Defaults | upToNextMajor 9.0.2 | 1052-1055 |
| LottieUI (Lottie comes in transitively) | **branch main** | 1060-1063 |
| swift-collections | upToNextMajor 1.1.4 | 1068-1071 |

There are no local package references. Four packages track `main`, so a build is not reproducible from the project file alone.

`local/.work/Package.swift` does not exist in this worktree. `local/prepare.py` generates it, and pins upstream packages by revision for the Command Line Tools build.

**Local build pipeline (`local/`).**
- `prepare.py` copies sources, applies patches, vendors patched packages and writes `Package.swift`.
- `build.sh` runs `swift build -c release`, then `assemble.py`, then `codesign --verify`.
- `assemble.py` writes the Info.plist (it turns off Sparkle automatic checks) and signs ad hoc.

### 1.3 Entry points
- **App struct.** `@main struct DynamicNotchApp: App` (`Toplet/DynamicIslandApp.swift:28-29`).
  - The first stored property runs `LegacySettingsMigration.runIfNeeded()` (`:32`), which copies non-`SU*` preferences from `com.Ebullioscopic.Atoll` once (`models/TopletProject.swift:42-55`).
  - The Sparkle controller is started only when a Toplet feed exists: `startingUpdater: !AppRuntimeEnvironment.isUITesting && TopletProject.updatesFeedBase != nil` (`DynamicIslandApp.swift:49`).
- **Only scene.** `MenuBarExtra("Toplet", systemImage: "sailboat.fill", isInserted: $showMenuBarIcon)` with four items: Settings, Check for Updates…, Restart Toplet, Quit ⌘Q (`DynamicIslandApp.swift:55-81`).
  - There is no `Settings {}` scene and no `WindowGroup`.
  - A `commands` property (`:84-91`) is never attached with `.commands`, so it is dead.
- **AppDelegate.** `class AppDelegate: NSObject, NSApplicationDelegate` (`DynamicIslandApp.swift:106`). Per-screen windows and view models are held in `[NSScreen: NSWindow]` and `[NSScreen: DynamicIslandViewModel]` (`:108-109`).
  - `applicationDidFinishLaunching`, in order: disables sudden termination; posts a distributed lifecycle notification; configures lock-screen managers; starts alarms (`:722-723`, `:752`); starts the XPC host; starts the RPC server **only if** `enableThirdPartyExtensions` (`:755-759`); runs migrations; starts HUD, DDC, privacy, network and audio-tap services; registers about 20 resize sinks, space and screen observers, lock/unlock observers and hotkeys; creates the notch window; shows onboarding on first launch.
- **File open.** `application(_:open:)` accepts file URLs only and adds them to the Shelf (`DynamicIslandApp.swift:164-184`). There are no URL schemes, no `CFBundleURLTypes` and no App Intents.

### 1.4 Windows and panels
- **Notch window.** `DynamicIslandWindow: NSPanel` (`components/Notch/DynamicIslandWindow.swift:25`).
  - Level `.mainMenu + 3`; behaviour `[.fullScreenAuxiliary, .canJoinAllSpaces, .ignoresCycle, .stationary]`.
  - Created borderless and non-activating, hosting `FirstMouseHostingView(ContentView)` (`DynamicIslandApp.swift:94-98`).
  - Also placed in a private CGS Space at level 2147483647 (`managers/NotchSpaceManager.swift:32`).
- **Settings window.** `SettingsWindowController: NSWindowController` (`components/Settings/SettingsWindowController.swift:27`). It switches the activation policy between regular and accessory while open.
- **Onboarding.** A plain 400×600 `NSWindow` hosting `OnboardingView`, created in the AppDelegate on first launch.
- **Floating panels** (`NSPanel`, `.floating`): `ColorPickerPanel`, `ClipboardPanel`, `ScreenAssistantPanel`, `ChatMessagesPanel`/`ChatInputPanel`, `ModelSelectionPanel` (under `components/ColorPicker/`, `components/Clipboard/`, `components/ScreenAssistant/`).
- **Lock-screen windows** at `CGShieldingWindowLevel()`, handed to SkyLight:
  - `LockScreenLiveActivityWindowManager.swift:114-115, 230`
  - `LockScreenPanelManager.swift:174`
  - `LockScreenTimerWidgetManager.swift:239`
  - `LockScreenWeatherPanelManager.swift:115`
  - `LockScreenReminderWidgetPanelManager.swift:117`
- **HUD windows.** `CustomOSDWindowManager` (`.statusBar + 1`, delegated to SkyLight, `:200`), `VerticalHUDWindowManager` and `CircularHUDWindowManager` (`.screenSaver`).
- **Full-screen artwork windows.** `FullScreenArtworkWindowManager.swift:1237`.

### 1.5 Menus
- **MenuBarExtra.** Listed in 1.3.
- **Status item.** `var statusItem: NSStatusItem?` (`DynamicIslandApp.swift:107`) is never assigned, so the related `showMenu`/`togglePopover` code is dead.
- **Main-menu items** added by `installTopMenuItemsIfNeeded`, reachable only while the Settings window makes the app regular:
  - Focus > Use (without) DevTools
  - Accessibility > Request / Open Settings
  - Permissions > Full Disk Access / Developer Tools
  - Tools > Logging Level and Export Logs, which runs `/usr/bin/log` and `zip` (`DynamicIslandApp.swift:~1176-1290`)

### 1.6 Background services
- **Timers.** About 35 timer sites in `Toplet/` (29 `scheduledTimer`/`publish`/`makeTimerSource` matches by grep, plus `Timer(timeInterval:)` uses). Examples:
  - clipboard 0.5 s (`managers/ClipboardManager.swift:378`)
  - DND file poll 2 s (`managers/DoNotDisturbManager.swift:588`)
  - stats 1 s (`managers/StatsManager.swift:532`)
  - menu-bar layout 3 s (`managers/MenuBarLayout.swift:111`)
  - YouTube Music 2 s fallback (`MediaControllers/YouTube Music Controller/YouTubeMusicController.swift:325`)
  - hide-until-hover edge polling that never stops (`ContentView.swift:2207-2215`)
- **NSWorkspace observers.** About 43 registrations across 21 files: wake, sleep, space change, app launch/terminate.
- **Distributed notifications.** 34 references:
  - screen locked/unlocked: `DynamicIslandApp.swift:1073-1078`, `managers/LockScreenManager.swift:141-152`
  - private DND notifications: `DoNotDisturbManager.swift:91-104`
  - Bluetooth, BetterDisplay and media
- **Sockets.**
  - Extension JSON-RPC over WebSocket on loopback port 9020, IPv4 and IPv6 bound separately. Browser `Origin` is rejected (`services/Extensions/ExtensionRPCServer.swift:92, 106-110`). The server is **off by default** (`models/Constants.swift:1399`).
  - LocalSend: TCP 53317 on all interfaces plus UDP multicast 224.0.0.167 (`components/Shelf/Services/LocalSendService.swift:60-61, 86-87, 602-635`).
  - Lunar `NWConnection` to localhost:23803 (`managers/LunarManager.swift:152-154`).
  - YouTube Music WebSocket (`YouTubeMusicNetworking.swift:162`).
  - Agents Unix socket `~/.atoll/run/agent.sock`, mode 0600 with a peer-UID check (`managers/Agents/AgentSocketServer.swift:101, 146, 153-167`), only when Agents is on.
- **XPC.** `NSXPCListener(machServiceName: "com.ebullioscopic.Atoll.xpc")` (`services/Extensions/ExtensionXPCServiceHost.swift:25, 55`). The name is still upstream's, and no launchd `MachServices` registration exists in the repo.
- **Other system hooks.**
  - Event tap for media keys (`managers/MediaKeyInterceptor.swift:200`)
  - `IOPSNotificationCreateRunLoopSource` for battery (`managers/BatteryActivityManager.swift:92`)
  - Darwin notify for AirPods listening mode (`managers/BluetoothAudioManager.swift:216`)
  - `NWPathMonitor` (`NetworkConnectivityManager.swift:43`)
- **External processes.** 20 files use `Process()`:
  - `/usr/bin/perl` MediaRemote adapter
  - `killall -STOP/-CONT OSDUIHelper`
  - `/usr/bin/log stream`
  - `system_profiler`, `ps`, `lsof`, `security`, `screencapture`, `networksetup`
  - NSAppleScript in `helpers/AppleScriptHelper.swift:30` and `managers/Agents/TerminalJumper.swift:62`

### 1.7 Persistence
- **Defaults keys.** 384 `Key<` declarations in `models/Constants.swift`, inside `extension Defaults.Keys` from about `:981`. There are also 22 direct `UserDefaults.standard` uses (clipboard, color picker, settings, timer, alarms).
- **Application Support files:**
  - `Toplet/AppIcons` (`models/Constants.swift:56-59`)
  - `Toplet/Shelf/items.json` (`components/Shelf/Services/ShelfPersistenceService.swift:38`)
  - `Atoll/agents-board.json` (`managers/Agents/BoardStore.swift:46-48`)
  - `AtollExtensions/` snapshots (`managers/Extensions/ExtensionEventBridge.swift:117`)
  - idle animation assets (`Toplet/AtollNotchIdle/IdleAnimationValidation.swift:595`)
  - Note images go in `Documents/NoteImages`.
- **Keychain items the app writes** still use upstream names:
  - `com.Ebullioscopic.Atoll.Cider` (`MediaControllers/CiderTokenStore.swift:25`)
  - `com.Ebullioscopic.Atoll.SpotifyLibrary` (`managers/Spotify/SpotifyTokenStore.swift:39`)
  - `com.Ebullioscopic.Atoll.new-api` (`managers/LLMUsage/NewAPIUsage.swift:38`)
- **Keychain items the app only reads** (other tools' credentials): Claude Code, Codex and Cursor, via `managers/LLMUsage/Quota/KeychainReader.swift`. The Claude client is read-only by design (`managers/LLMUsage/Quota/ClaudeQuotaClient.swift:192`).
- **AI chat keys are in plain UserDefaults**, not the Keychain: `geminiApiKey`, `openaiApiKey`, `claudeApiKey`, `groqApiKey` (`models/Constants.swift:1388-1391`).

### 1.8 Info.plist and entitlements
- **`Toplet/Info.plist`:**
  - `NSAllowsArbitraryLoads` true (`:5-8`)
  - `NSAppleMusicUsageDescription` (`:10`), `NSAudioCaptureUsageDescription` (`:12`), `NSScreenCaptureUsageDescription` (`:14`)
  - Sparkle downloader and installer services (`:16-19`)
  - an empty `UTImportedTypeDeclarations` stub (`:20`)
  - **No `SUFeedURL` any more** (fixed, see §5).
- **Build-setting plist keys** (`project.pbxproj:808-825`): Apple Events, Bluetooth, Calendars, Camera, Desktop/Documents/Downloads, Location (now mentions the Clock map, `:821-822`), Microphone, Reminders, `LSUIElement`.
- **Missing key.** There is no `NSLocalNetworkUsageDescription`, although LocalSend uses multicast and LAN HTTP.
- **Entitlements:**
  - camera (`Toplet.entitlements:7`)
  - mach-services `com.ebullioscopic.Atoll.xpc` (`:9-12`)
  - apple-events (`:13`)
  - calendars (`:15`)
  - temporary apple-events exception for Spotify, Music and Notes (`:17-22`)
  - Sparkle mach-lookup (`:23-27`)

### 1.9 Tests

| Suite | Size | Runs where |
|---|---|---|
| `TopletTests/` | 22 files, 276 `func test`. Lyrics (110), partial downloads (31), per-app volume (16), Apple Music (13), Cider favouriting (12), clipboard persistence (12), Now Playing payload (10), RPC server (9), menu-bar clearance (9), Spotify library (9), AudioTap (7), Caffeinate (7), media-key retry (7), JSONL usage (6), New API (5), and others | Xcode only |
| `TopletUITests/` | 1 file, 2 tests (launch, expansion) | Xcode only |
| `AtollAgents/Tests/` | 13 files, about 900 custom `check`/`eq` assertions plus 14 `func test` in HooksTests | `swiftc` scripts, against the **module copy**, not the app copy |
| `tests/` | Python and standalone Swift scripts: privacy configuration, timer lifecycle, Cursor payload, Claude Keychain | Not in any Xcode target |

There are no tests for Shelf, LocalSend, Notes, Calendar, Stats, Terminal, Color Picker, Screen Assistant, Bluetooth, DND, lock screen, onboarding, gestures, minimalistic mode, Games, Clock or Ship.

---

## 2. Feature inventory

**Legend.**
- States: **WV** = Working and verified; **WI** = Working but requires improvement; **PI** = Partially implemented; **UI** = UI-only / placeholder; **BR** = Broken; **NI** = Not implemented; **CV** = Cannot currently verify.
- Severity is the severity of the remaining problem, not of the feature.

### 2.1 Notch shell and interaction

| Feature | State | Evidence (file:line) | User impact | Sev. | Proposed correction |
|---|---|---|---|---|---|
| Notch window and closed notch shape | WI | `components/Notch/DynamicIslandWindow.swift:25-70`; `sizing/matters.swift:398-441`; `ContentView.swift:655-689` | Works on a single built-in display. Identity is by screen name (§4) | Medium | Key windows by `CGDirectDisplayID` |
| Hover and click to open | WI | `ContentView.swift:2311-2362` (0.3 s hover delay, `Constants.swift:~992`); click monitors `ContentView.swift:2223-2265` | Normal use OK. Global mouse monitors run while hovering | Low | None urgent |
| Trackpad gestures (swipe open/close, media skip, haptics) | WI | `extensions/PanGesture.swift:46-182`; `ContentView.swift:725-747`; haptics `:837` | Settings toggles are read with `Defaults[...]` inside the view body, so a change may apply only on the next redraw | Low | Use `@Default` |
| Tab bar | WI | `components/Tabs/TabSelectionView.swift:66-127` | Tabs are gated by `Defaults[...]` reads (`:73,82,87,96,101,104,107`), so they may not refresh immediately after a toggle | Low | Observe keys with `@Default` |
| Minimalistic mode | CV | `enableMinimalisticUI`, default false; about 115 references in 17 files; coordinator forces Home except during a ringing alarm (`DynamicIslandViewCoordinator.swift:110`) | Many branches, no tests | Low | Add snapshot tests |
| Non-notch displays (fake notch / pill / hide until hover) | WI | `sizing/matters.swift:335-352, 423-435`; `ContentView.swift:452-458, 2136-2215` | `.matchMenuBar` height likely becomes 0 with an auto-hidden menu bar (inferred from `matters.swift:428-435`). Edge-polling task never stops | Medium | Clamp the height; stop polling when off |
| Multi-display (all displays / specific / auto-switch) | WI | `DynamicIslandApp.swift:1617-1663`; preferred screen stored as a name (`DynamicIslandViewCoordinator.swift:155-162`) | Two identical monitors cannot be told apart. The notch silently disappears if the preferred name is not found and auto-switch is off (`:1648-1663`) | High | Store a display UUID; fall back visibly |
| Ship companion (new, closed-notch idle slot) | CV | `ContentView.swift:1172-1174`; `components/Ship/ShipCompanionSlot.swift`; `managers/Ship/ShipCompanionModel.swift`; key `showShipCompanion` default **true** (`Constants.swift:1277`) | Shown by default when idle. No Settings toggle found in `components/Settings/`, so users cannot turn it off | Medium | Add a toggle and appearance picker in Appearance |
| Idle face / custom idle animations | WI | `components/IdleAnimationView.swift:37-43`; `managers/IdleAnimationManager.swift:23-35`; engine in `Toplet/AtollNotchIdle/` | Now compiled. Module source untracked; `local/prepare.py:84` refers to a missing `AtollNotch/Tests/run_idle.sh` | Low | Commit; add the idle test script or drop the reference |

### 2.2 Notch tabs (`enums/generic.swift:73-86`, view switch `ContentView.swift:1291-1320`)

| Feature | State | Evidence (file:line) | User impact | Sev. | Proposed correction |
|---|---|---|---|---|---|
| Home (media, webcam mirror, calendar) | WI | `ContentView.swift:1292`; `components/Notch/NotchHomeView.swift` (1827 lines) | Inherited from upstream; no view tests | Low | — |
| Shelf (drag and drop, persistence) | WI | `components/Shelf/Services/ShelfDropService.swift:28-103`; `ShelfPersistenceService.swift:36-59` | Save errors only `print` (`:59`). Old items never cleaned (`components/Shelf/DropItem.swift:66`, always false) | Low | Surface errors; add an age cleanup |
| AirDrop / Quick Share from Shelf | WI | `components/Shelf/Services/QuickShareService.swift:64-127`; `models/SharingStateManager.swift:136-162` | Standard `NSSharingService`; untested | Low | — |
| LocalSend | PI | **Send only**: listener answers `/register` and `/info` and returns 404 for everything else (`LocalSendService.swift:675-738`). TLS challenge trusts any certificate (`:1042-1046`). Listener on all interfaces (`:86-87`). No `NSLocalNetworkUsageDescription` | Toplet cannot receive files. A spoofed peer is trusted. LAN discovery may be silently blocked by Local Network privacy | High | Add `NSLocalNetworkUsageDescription`; pin the peer certificate fingerprint; implement receive or label it send-only |
| Timer tab and live activity | WI | `managers/TimerManager.swift:191-521`; regression `tests/TimerLifecycleRegression.swift` (not in the Xcode target) | Works by reading. The demo shortcut no longer has a default (§5) | Low | Move the regression into XCTest |
| Mirror of the macOS Clock-app timer | CV | `managers/SystemTimerBridge.swift:262-279` (`/usr/bin/log stream` parsing), AX fallback `:197-207` | Depends on unstable log text | Medium | Feature-flag; degrade quietly |
| Stats | WI | `managers/StatsManager.swift:796` (CPU), `:862-884` (RAM), `:109-150` (GPU via IOAccelerator), `:1033` (net), `:1304` (disk), `ps` per sample `:1451` | Spawns `ps` every sample (default 1 s, `Constants.swift:1295`); no tests | Medium | Use `proc_pidinfo` only; throttle the process list |
| Usage (LLM plan limits) | WI | Providers in `managers/LLMUsage/` (Claude, Codex, Cursor, Antigravity, New API); key `enableLLMUsageFeature` default **false** (`Constants.swift:1274`); toggle sits inside **Stats** settings (`components/Settings/SettingsView.swift:8010`) | README advertises it. Network clients have no tests. Antigravity scrapes `ps`/`lsof` output (`AntigravityUsageProvider.swift:228-327`). Pricing is fetched from **upstream** `raw.githubusercontent.com/Ebullioscopic/Atoll/dev` (`ModelPricingManager.swift:98`) | Medium | Give Usage its own Settings page; host `pricing.json` in Toplet; add payload tests |
| Pinned usage strip (closed notch) | WI | `components/Notch/PinnedUsageView.swift:29-69`; `ContentView.swift:1278`; refresh loop `LLMUsageManager.swift:103-126` | Works by reading; no tests | Low | — |
| Agents (Claude Code / Codex sessions, approvals) | WI | `managers/AgentsIntegration.swift:91-141`; socket `managers/Agents/AgentSocketServer.swift:101-167`; approvals `components/Notch/Agents/AgentsApprovalViews.swift:162-224`; default off (`Constants.swift:~1304`) | Core logic has about 900 assertions, but against the **`AtollAgents/` copy**, which has drifted from what the app compiles. Socket path still `~/.atoll` (`AgentsIntegration.swift:289`) | High | One source of truth: make the app consume the module, or test the app copy |
| Color Picker **as a tab** | BR | `.colorPicker` is in the enum and the switch (`ContentView.swift:1304`), but `TabSelectionView.swift` never adds it and nothing sets `currentView = .colorPicker` | Dead tab | Low | Remove the case, or add the tab behind `enableColorPickerFeature` |
| Color Picker panel (⌘⇧P) | WI | `managers/ColorPickerManager.swift:52-127` (`NSColorSampler`) | History-size setting ignored: hard-coded 50 (`:126-127`) | Low | Read `colorHistorySize` |
| Notes | WI | `components/Notch/NotchNotesView.swift:198-345`; key `savedNotes` | No tests | Low | — |
| Apple Notes sync | WI | `managers/AppleNotesSyncManager.swift:56-58` (folder rename "Atoll"→"Toplet"), AppleScript `:200-343`, error -1743 mapped `:405-406` | AppleScript on every save, no retry; untested | Medium | Debounce; queue retries |
| Clipboard history | WI | `managers/ClipboardManager.swift:378` (0.5 s poll), `:537-546` (trim), `:771-777` (UserDefaults); concealed and transient types skipped `:582-583`; 12 persistence tests | Image save errors print only (`:104, :521`). History stored unencrypted in UserDefaults | Medium | Store history in an app-support file with file protection |
| Terminal | WI | `components/Notch/NotchTerminalView.swift:36-47`; `TerminalManager.swift:228, 288-301` (SwiftTerm pty) | Shell path not validated; `isProcessRunning` set true even if launch fails (`:301`) | Low | Validate the path; reflect launch failure |
| Clock: time, 12/24 h, world clocks | WI | `components/Notch/NotchClockView.swift:39, 144, 169`; `worldClockZones` | Settings for Clock live inside the **Stats** page (`SettingsView.swift:8020-8028`) | Low | Own Settings page |
| Clock: alarms | PI | `managers/Clock/AlarmManager.swift:119-159`. In-process `Timer` only; no `UNUserNotification` or `IOPMSchedulePowerEvent` (grep: none). Wake catch-up `:140-148` and Clock-off guard `:159` now exist | An alarm does **not** ring if the app is quit or the Mac is asleep (it rings on wake if within the grace period). Snooze state is in memory only | Medium | Back alarms with `UNUserNotificationCenter`; persist snooze |
| Clock: "where am I" map | CV | MapKit + `CLLocationManager` (`managers/Clock/NotchLocation.swift:24-72`) | Needs Location permission at runtime | Low | — |
| Games (Pairs, Tic-Tac-Toe, Lights Out) | WI | `managers/Games/NotchGameBoards.swift:21-239`; `NotchGamesStore.swift:20-192`; `enableGamesFeature` default **true** (`Constants.swift:1275`) | Upgrading users get a new tab without opting in; no tests | Low | Default off for migrated users; add board tests |
| Extension tabs, notch experiences, live activities, lock widgets | PI | RPC registration auto-approves any self-declared bundle ID (`services/Extensions/ExtensionRPCService.swift:151`, comment "Auto-authorize for now"). XPC mach service unregistered and named for Atoll (`ExtensionXPCServiceHost.swift:25`). Marketplace link `getatoll.app` (`components/Settings/ExtensionsSettings.swift:72`) | Once enabled, any local process can claim another app's identity. XPC path likely never connects. Store points to upstream | High | Prompt the user per extension; verify the caller code signature; register or remove the XPC path |

### 2.3 Closed-notch live activities (single `if/else` chain, `ContentView.swift:1108-1177`, first match wins)

| Feature | State | Evidence (file:line) | User impact | Sev. | Proposed correction |
|---|---|---|---|---|---|
| Music live activity (plus secondary slot) | WI | `ContentView.swift:1134-1136`; secondary slots `:1531-1560` | Works by reading | Low | — |
| Camera / microphone privacy indicator | WI | Detection via CoreMediaIO/CoreAudio (`managers/CameraMonitor.swift:67, 218`; `MicrophoneMonitor.swift:68, 196`). Branch `ContentView.swift:1156` sits **after** music (`:1134`) and is not a secondary slot | While music plays, the camera/mic indicator never shows in the closed notch. Which app is using the device is never identified (`CameraMonitor.swift:346`, `MicrophoneMonitor.swift:265` TODOs) | High | Move privacy above music, or make it a secondary slot |
| AI agents closed indicator | WI | `ContentView.swift:1140` (after music) | Hidden while music plays | Medium | Allow as a secondary slot |
| Timer, reminder, recording, downloads, LocalSend, Focus | WI | `ContentView.swift:1138-1154` | Same precedence pattern, but most are also secondary slots (`:1531-1560`) | Low | — |
| Downloads detection | WV | `managers/DownloadManager.swift:111-258`; 31 `PartialDownloadTests` | — | — | — |
| Screen-recording indicator | WI | Private `CGSIsScreenWatcherPresent`/`CGSRegisterNotifyProc` (`managers/ScreenRecordingManager.swift:23-30`); stop via `killall -TERM screencaptureui` (`:332`) | Private API; forced kill | Medium | Prefer ScreenCaptureKit signals where possible |
| Focus / DND | WI | Private distributed notifications (`DoNotDisturbManager.swift:91-104`); polls `~/Library/DoNotDisturb/DB/Assertions.json` every 2 s (`:45-46, 588`); reads use `try?` | Likely silent failure without Full Disk Access | Medium | Detect and prompt for FDA; show the state in Settings |
| Battery and charging HUDs | WI | `managers/BatteryActivityManager.swift:92, 239, 332` | No tests | Low | — |
| Bluetooth / AirPods HUD | WI | `managers/BluetoothAudioManager.swift:24, 179-187, 1321-1335`; `system_profiler` spawn `:1576`; 8 `.mov` files in `Toplet/BluetoothHUDAnimations/` | Provenance of the AirPods artwork is unclear (`COPYRIGHT_ASSETS`) | Medium | Confirm the licence or replace the artwork |
| Caps Lock indicator | CV | `ContentView.swift:1131`; `CapsLockManager.swift:47` | — | Low | — |
| Reminder live activity | WI | `ContentView.swift:1144`; `managers/CalendarManager.swift:419` | — | Low | — |

### 2.4 HUD / OSD replacement and lock screen

| Feature | State | Evidence (file:line) | User impact | Sev. | Proposed correction |
|---|---|---|---|---|---|
| Volume/brightness HUD (replaces system OSD) | WI | `managers/SystemOSDManager.swift:530-531` (`killall -STOP OSDUIHelper`), `:200-201` (`-CONT`), `:109` (`killall -9`); resumed on quit `DynamicIslandApp.swift:~316` | If Toplet crashes, the system volume HUD stays frozen until OSDUIHelper restarts | High | Run `-CONT` in a crash/exit handler or a launchd watchdog; prefer not suspending |
| Custom OSD window | WI | `managers/CustomOSDWindowManager.swift:175` `fatalError("Unsupported OSD type")` | A new OSD type crashes the app | Medium | Replace with a logged early return |
| Media keys interception | WI | `managers/MediaKeyInterceptor.swift:200, 215, 470`; 7 retry-policy tests | Needs Accessibility | Low | — |
| Keyboard backlight / display brightness | CV | CoreBrightness via `NSClassFromString` (`helpers/CoreBrightnessDisplayClient.swift:48-63`; `managers/KeyboardBrightnessSensor.swift:157-171`); DisplayServices `dlsym` (`helpers/DisplayServicesDynamic.swift:34-44`) | Private; may break on OS updates | Medium | — |
| Lock-screen widgets (media, timer, weather, reminders, charging) | CV | SkyLight delegation (§1.4); lock detection `LockScreenManager.swift:141-166, 352-380` | Cannot verify without a lock cycle | Medium | — |
| Full-screen artwork / wallpaper | CV | `FullScreenArtworkWindowManager.swift:452-502` (SIGSTOP/SIGCONT on `WallpaperAgent` and Aerials); writes the wallpaper `Index.plist` after a backup (`:272-289`) | A crash can leave the wallpaper agent stopped | High | Same as OSD: guaranteed resume |

### 2.5 Media

| Feature | State | Evidence (file:line) | User impact | Sev. | Proposed correction |
|---|---|---|---|---|---|
| Source selection | WI | `mediaController` key (`Constants.swift:~1234`); controller factory `managers/MusicManager.swift:826-886`; deprecation probe `helpers/MediaChecker.swift:33-54` (needs arm64-only `Contents/Helpers/NowPlayingTestClient`) | Intel Macs cannot run the probe | Low | Document arm64 only |
| Apple Music | WV | `MediaControllers/AppleMusicController.swift:167-229` (notifications + AppleScript); 13 tests | — | — | — |
| Spotify | WI | `MediaControllers/SpotifyController.swift:83-143`; 9 library tests | Repeat is on/off only, no "repeat one" (`:141-143`) | Low | Map to Spotify's 3-state repeat |
| Now Playing (system) | WI | `/usr/bin/perl mediaremote-adapter.pl … stream` (`MediaControllers/NowPlayingController.swift:259-276`); commands via private MediaRemote (`:60-134`); 10 payload tests | Depends on a Perl entitlement loophole (works around the macOS 15.4 restriction) | High (fragility) | Track the adapter upstream; keep Apple Music fallback |
| Cider | WI | `MediaControllers/CiderController.swift:90-97` (localhost:10767); token in Keychain; 12 favouriting tests | Only favouriting is tested | Low | — |
| TIDAL | WI | `MediaControllers/TidalController.swift:110-155` (menu scripting via AX) | Needs Accessibility | Low | — |
| Amazon Music | WI | `MediaControllers/AmazonMusicController.swift:29-190, 359-367` | Shuffle/repeat update local state before the app confirms (`:162-190`) | Low | Reflect the confirmed state |
| YouTube Music (th-ch app) | WI | `YouTubeMusicModels.swift:33` (localhost:26538), WebSocket plus 2 s polling | Needs the third-party app and its API plugin (`docs/YOUTUBE-MUSIC-SETUP.md`) | Low | — |
| Lyrics (LRCLIB, NetEase fallback) | WV | `managers/MusicManager.swift:1801-1909`; `managers/NetEaseLyrics.swift:95-103`; about 110 lyrics tests | Off by default (`Constants.swift:~1516`) | — | — |
| Real-time waveform | WI | `audio/AudioTap.swift:248-292`; tapped bundle list `:128-140`; 7 tests | List omits YouTube Music and Chrome, so the waveform stays flat for those sources | Low | Add their bundle IDs |
| Custom music visualizer (Lottie) | UI | Toggle `.disabled(true)` (`components/Settings/SettingsView.swift:5002-5006`) and "Coming soon" badge (`:5033`); picker and list `:5008-5113` cannot take effect | Dead settings | Low | Hide until finished |
| Per-app volume | PI | Core Audio process taps (`audio/PerAppVolume/AppVolumeTap.swift:65-137`); 16 tests. `PerAppVolumeManager.startTracking()` is called only from the popover (`components/Audio/PerAppVolumePopover.swift:62`); the init observer uses `options: []` (`managers/PerAppVolumeManager.swift:72`) | Saved levels and mutes are **not re-applied after relaunch** until the popover is opened | High | Start tracking at launch when the feature is on and levels exist |

### 2.6 System and productivity

| Feature | State | Evidence (file:line) | User impact | Sev. | Proposed correction |
|---|---|---|---|---|---|
| Calendar / reminders | WI | `Providers/CalendarServiceProviding.swift:45-62` (`requestFullAccessToEvents/Reminders`); `managers/CalendarManager.swift:155-201` | Denied state only `NSLog`s; the notch calendar has no denied UI (Settings has one, `SettingsView.swift:3767-3785`) | Medium | Show a denied state with a deep link |
| Caffeinate (Keep Awake) | WV | `managers/CaffeinateManager.swift:67-88` (`IOPMAssertionCreateWithName`); 7 tests | — | — | — |
| Screen Assistant / AI chat | PI | Providers: Gemini (`managers/ScreenAssistantManager.swift:418-427`, key now in a header), OpenAI `:441`, Groq `:470`, Claude `:497-498`, Ollama `:517`. Only Gemini receives file contents (`:990-1175`); other providers get file names plus "Describe what you see" (`:941-990`). Default Claude model `claude-3-5-sonnet-20241022` (`:497`). Keys in UserDefaults (`Constants.swift:1388-1391`). Audio via `AVAudioRecorder` (`:305`) with no preflight | Non-Gemini answers about screenshots are guesses. API keys are readable by any process running as the user | High | Send images to all vision-capable providers; move keys to Keychain; update model IDs |
| Screenshot snipping | WI | `/usr/sbin/screencapture` (`components/ScreenAssistant/ScreenshotSnippingTool.swift:84-85`); no `CGPreflightScreenCaptureAccess` | First use triggers the system prompt without any explanation | Low | Preflight and explain |
| Onboarding | WI | `components/Onboarding/OnboardingView.swift:27-33, 153-157`; reopen button commented out (`SettingsView.swift:4283-4286`) | Cannot be reopened. The camera result is ignored | Low | Restore "Welcome window" |
| Settings migration from Atoll | WI | `models/TopletProject.swift:42-55`; `DynamicIslandApp.swift:32` | One-shot; skips Sparkle keys. Launch-at-login and TCC grants do not carry over (README says so) | Low | — |
| Sparkle updates | NI | `TopletProject.updatesFeedBase = nil` (`models/TopletProject.swift:33`); updater not started (`DynamicIslandApp.swift:49`); button disabled (`components/Settings/SoftwareUpdater.swift:48`) | No in-app updates (intentional until a feed exists). Auto-check toggles (`SoftwareUpdater.swift:69-78`) and the channel picker (`SettingsView.swift:4232-4260`) are still shown and do nothing | Medium | Hide the updater section while no feed exists |
| Launch at login | CV | `LaunchAtLogin.Toggle` (`components/Settings/SettingsView.swift:1224`), package on branch `main` | Must be re-enabled after the rename | Low | Pin the package version |
| Keyboard shortcuts | WI | `Shortcuts/ShortcutConstants.swift:27-37`; handlers `DynamicIslandApp.swift:1080, 1091, 1454, 1515, 1520, 1525, 1553` | ⌘⇧V, ⌘⇧H, ⌘⇧I, ⌘⇧A and ⌘⇧K are global defaults that shadow common app shortcuts. `decreaseBacklight`/`increaseBacklight` (⌘F1/⌘F2, `:30-31`) are declared but never registered | Medium | Ship with no defaults except toggle-notch; remove the dead keys |
| DDC / Lunar / BetterDisplay integration | CV | `managers/LunarManager.swift:152-154, 402-406`; `BetterDisplayManager.swift:330-334` (displayID−1 used as an index) | Fragile display mapping | Low | Map by display ID |
| About / Donate / GitHub | WI | `strings/constants.swift:21-22`; `SettingsView.swift:4195-4230, 4273` | GitHub opens upstream Atoll; Donate opens the upstream author's page with upstream's text; "Made with love by Ebullioscopic"; release name "Kaafu" (`Constants.swift:~988`) | Low | Re-word as credits; add Toplet links when the repo exists |

**State counts across the 70 rows:**

| State | Rows |
|---|---|
| Working and verified | 4 |
| Working but requires improvement | 48 |
| Partially implemented | 5 |
| UI-only / placeholder | 1 |
| Broken | 1 |
| Not implemented | 1 |
| Cannot currently verify | 10 |

---

## 3. Cross-cutting findings

### 3.1 Incomplete or nonfunctional controls

| Control | Evidence | Problem |
|---|---|---|
| "Use music visualizer spectrogram" toggle | `components/Settings/SettingsView.swift:5002-5006` (`.disabled(true)`) | Key defaults true (`Constants.swift:~1039`), so the Lottie visualizer path (`ContentView.swift:~1811`) cannot be reached |
| Custom visualizer picker, list, "Add new visualizer" | `SettingsView.swift:5008-5113`; "Coming soon" badge `:5033` | UI with no effect |
| "Expanded drag detection" toggle | `SettingsView.swift:4511`; key `Constants.swift:1220` | Nothing outside Settings reads the key |
| Color history size picker | key `colorHistorySize`; `managers/ColorPickerManager.swift:126-127` | Hard-coded limit of 50 |
| Update channel picker and auto-update toggles | `SettingsView.swift:4190, 4232-4260`; `SoftwareUpdater.swift:69-78` | No feed exists, so they do nothing |
| "Welcome window" toolbar button | `SettingsView.swift:4283-4286` (commented out) | Onboarding cannot be reopened |
| Color Picker tab | `ContentView.swift:1304`; absent from `TabSelectionView.swift` | Unreachable |
| Shelf auto-clean | `components/Shelf/DropItem.swift:66` (`TODO`, always false) | Never cleans |
| App attribution for camera/mic | `managers/CameraMonitor.swift:346`, `MicrophoneMonitor.swift:265` ("TODO: investigate") | Shows that a device is on, not which app is using it |
| `UTImportedTypeDeclarations` | `Toplet/Info.plist:20` | Empty stub |
| Material picker below macOS 26 | `SettingsView.swift:~5881` | Disabled on purpose, with a caption (OK) |

Empty `{}` button closures found by grep are all alert Cancel/OK actions (for example `components/Notch/NotchClipboardView.swift:99`), which is benign.

There are no `FIXME`, `HACK` or `XXX` markers. `fatalError` appears only in `CustomOSDWindowManager.swift:175` (a real crash risk) and in standard `init(coder:)` stubs.

### 3.2 Hidden features (no Settings UI, or reachable only another way)
- **Key coverage.** Of 382 keys in `models/Constants.swift`:
  - 331 are used in both Settings and code.
  - 35 are code-only (no UI).
  - 4 are Settings-only (no effect): `releaseName`, `customVisualizers`, `expandedDragDetection`, `colorHistorySize`.
  - 12 are referenced only in `Constants.swift`, all migration or legacy flags (for example `enableGradient` `:1202`, `didMigrateCapsLockTintMode` `:1507`).
- **`showShipCompanion` / `shipAppearance`** (`Constants.swift:1277-1278`). On by default, with no Settings control in `components/Settings/`.
- **Screen Assistant keys and model choice** (`Constants.swift:1386-1392`). Set only in the Screen Assistant panel (`components/ScreenAssistant/ModelSelectionPanel.swift`), not in Settings.
- **Tunables with no UI:**
  - `lockScreenWeatherRefreshInterval` (`Constants.swift:~1095`)
  - `lockScreenWeatherWidgetRowOrder` (`~1158`)
  - `lockScreenMusicFullscreenVideoArtwork` (`~1142`)
  - extension capacity limits (`~1405-1407`)
  - `enableExtensionFileSharing` (`~1408`, read at `services/Extensions/ExtensionRPCService.swift:364`)
- **Main menu only** (visible only while Settings is open): log level and Export Logs, Focus DevTools mode, Accessibility and Full Disk Access requests (`DynamicIslandApp.swift:~1176-1318`).
- **Shortcut only:**
  - Screen Assistant ⌘⇧A (`DynamicIslandApp.swift:1553`)
  - clipboard panel ⌘⇧V (`:1454`)
  - color picker panel ⌘⇧P (`:1515`)
  - sneak peek ⌘⇧H (`:1080`)
  - terminal ⌃` (`:1525`)
  - demo timer (no default since the fix, `Shortcuts/ShortcutConstants.swift:35-36`)
- **Settings placement that hides features.** Usage, Games and Clock are enabled inside the **Stats** page (`SettingsView.swift:8010-8028`, search entries `:441-444`). The `SettingsTab` enum has no Usage, Games or Clock page (`SettingsView.swift:48-70`).
- **Terminal file drop.** `open -a Toplet <file>` adds the file to the Shelf (`DynamicIslandApp.swift:164-184`). Only the README documents it.

### 3.3 Dead code, abandoned experiments, duplicates
- **Unused packages.** Pow and open-meteo are declared (`project.pbxproj:996-999, 1028-1031`) but never linked or imported.
- **Dead code in the app entry file:**
  - `statusItem`/status-menu code (`DynamicIslandApp.swift:107`, never assigned)
  - the unattached `commands` builder (`:84-91`)
  - the commented-out SkyLight delegation for the notch window (`:~450-457`)
- **Unused types:**
  - `MinimalisticMusicView` (`components/MinimalisticMusicView.swift:24`, whole file; the live view is `MinimalisticMusicPlayerView`)
  - `NotchSurfaceGroup` (`components/Notch/NotchSurface.swift:83`)
  - `eventTap`/`runLoopSource` in `managers/NotchSpaceManager.swift:27-28`
- **Dead shortcuts.** `decreaseBacklight`/`increaseBacklight` (`Shortcuts/ShortcutConstants.swift:30-31`); grep shows no other references.
- **Duplicate code.**
  - Agents: `AtollAgents/Core|UI|Hooks` against `Toplet/managers/Agents` and `components/Notch/Agents`, with about 6–8 files diverged.
  - Four near-identical `NSVisualEffectView` wrappers: `components/Settings/EditPanelView.swift:25`, `components/ColorPicker/ColorPickerPanel.swift:665`, `components/ScreenAssistant/ChatPanels.swift:684`, `ModelSelectionPanel.swift:558`.
  - Panel and popover pairs for Clipboard and Color Picker.
- **Unreferenced assets and scripts.**
  - `DynamicIslandSamples/` (screenshots, not referenced by `ReadMe.md`).
  - `scripts/*.rb`: one-off xcodeproj mutators, not used by the build.
  - `Updates/appcast*.xml`: upstream appcasts naming Atoll and Ebullioscopic downloads.
- **Stale identity.**
  - `PRODUCT_MODULE_NAME = Atoll` (`project.pbxproj:833`) is intentional.
  - The product reference `Atoll.app` (`project.pbxproj:126`) is stale.
  - The UI test bundle ID is `com.atoll.*` (`:621`).
- **Leftover upstream strings.** 34 non-comment Swift literals contain "Atoll". The user-visible ones are listed in §2.6 (About) and §2.2 (Extensions marketplace).

### 3.4 Permissions: where they are requested

| Permission | Request site | Usage key |
|---|---|---|
| Accessibility | `helpers/AccessibilityPermissionStore.swift:49`; `managers/MediaKeyInterceptor.swift:470`; checks in `SystemTimerBridge.swift:119`, `MenuBarLayout.swift:135`, `TidalController.swift:155`, `FullscreenMediaDetection.swift:123` | none needed |
| Input / event tap | `CGEvent.tapCreate` `MediaKeyInterceptor.swift:200`; global monitors `ContentView.swift:2244, 2289`, `CapsLockManager.swift:47`, `extensions/PanGesture.swift:211` | none |
| Screen recording | `/usr/sbin/screencapture` `ScreenshotSnippingTool.swift:85` (no preflight) | `Info.plist:14` |
| System audio capture | `audio/AudioTap.swift:256`; `audio/PerAppVolume/AppVolumeTap.swift:71` | `Info.plist:12` |
| Microphone | `AVAudioRecorder` `managers/ScreenAssistantManager.swift:305` (implicit prompt, no preflight) | `project.pbxproj` `INFOPLIST_KEY_NSMicrophoneUsageDescription` |
| Calendars / Reminders | `Providers/CalendarServiceProviding.swift:57, 59` via `CalendarManager.swift:161, 187`; onboarding `OnboardingView.swift:157` | `project.pbxproj:814-815, 824-825`; entitlement `:15` |
| Camera | `managers/WebcamManager.swift:110`; `OnboardingView.swift:153` | `project.pbxproj:816`; entitlement `:7` |
| Bluetooth | `managers/BluetoothAudioManager.swift:2311` | `project.pbxproj:813` |
| Location | `managers/LockScreenWeatherManager.swift:1107`; `managers/Clock/NotchLocation.swift:50` | `project.pbxproj:821-822` |
| Apple Events (Music, Spotify, Notes, Terminal, System Events) | `helpers/AppleScriptHelper.swift:30`; `managers/Agents/TerminalJumper.swift:62` | `project.pbxproj:812`; entitlements `:13-22` |
| Apple Music library | `managers/AnimatedArtworkManager.swift:109` | `Info.plist:10` |
| Full Disk Access (probe) | `helpers/FullDiskAccessPermissionStore.swift:26` (reads TCC.db); DND reads `~/Library/DoNotDisturb/DB` (`DoNotDisturbManager.swift:46`) | n/a |
| Local Network | LocalSend multicast and LAN HTTP (`LocalSendService.swift:60-61, 235-411`) | **missing** `NSLocalNetworkUsageDescription` |
| Notifications, Contacts, Photos | not requested (grep: no `UNUserNotificationCenter`) | — |

### 3.5 Private API use and distribution risk

Combined with sandbox off, this rules out the Mac App Store. Developer ID notarization does not scan for private symbols, so it should pass; this was not tested. The real risk is breakage on each macOS update.

| API | Evidence | What it does | Risk |
|---|---|---|---|
| MediaRemote (in-process) | `MediaControllers/NowPlayingController.swift:60-134`; `AmazonMusicController.swift:44-89` | Send play/pause/seek/shuffle/repeat | High: entitlement-gated since 15.4 |
| MediaRemote via `/usr/bin/perl` | `NowPlayingController.swift:259-276`; `helpers/MediaChecker.swift:53`; bundled `Frameworks/MediaRemoteAdapter.framework` | Reads now-playing data through a platform-binary loophole | High: one OS patch away from breaking |
| CGS Spaces | `private/CGSSpace.swift:26-87` (`@_silgen_name` `CGSSpaceCreate`, `CGSAddWindowsToSpaces`, …); `managers/NotchSpaceManager.swift:32` | Keeps the notch above full-screen apps | High |
| SkyLightWindow package | `SkyLightOperator.shared.delegateWindow` (5 managers, §1.4) | Windows over the lock screen | High |
| Screen-capture watcher | `managers/ScreenRecordingManager.swift:23-30` | Detects recording | High |
| OSDUIHelper SIGSTOP | `managers/SystemOSDManager.swift:530-531`, `:200-201`, `:109` | Freezes the system HUD | High: frozen HUD if Toplet crashes |
| WallpaperAgent SIGSTOP | `FullScreenArtworkWindowManager.swift:452-502` | Freezes the wallpaper agent | High |
| CoreBrightness | `helpers/CoreBrightnessDisplayClient.swift:28-63`; `managers/KeyboardBrightnessSensor.swift:157-171` | Brightness and backlight | High |
| DisplayServices `dlsym` | `helpers/DisplayServicesDynamic.swift:34-44` | Display brightness | Medium-high |
| IOReport `dlopen` | `utils/IOReportBridging.swift:26-39` | Power and GPU stats | Medium |
| AppleSMC | `utils/SMC.swift:166` (write function `:270`); `utils/CPUSensorCollector.swift:58-65` | Temperatures and fans | Medium (the write path exists) |
| Private IOKit keys | `KeyboardBrightnessSensor.swift:88-124`; `utils/AppleHardwareInfo.swift:129, 159` | Backlight, hardware info | Medium |
| BezelServices notification | `managers/SystemMediaControllers.swift:936` | HUD events | Low-medium |
| `NSGlassEffectView` private variant | `helpers/LiquidGlassBackground.swift:179-226` | Glass look | Medium |
| Focus private selectors | `managers/DoNotDisturbManager.swift:1088-1097` | Focus mode names | Medium |
| AirPods listening-mode selectors | `managers/BluetoothAudioManager.swift:2079` | Listening-mode HUD | Medium |
| SwiftUI `Image._internalSystemName` | `extensions/Image+InternalSystemName.swift:21` | Focus glyphs | High (symbol can vanish) |
| `CGSSessionScreenIsLocked` | `managers/LockScreenManager.swift:363` | Lock fallback | Low |

Build note: `CoreBrightness`, `OSD` and `DisplayServices` are referenced in the project (`project.pbxproj:89-91`) and found through `PrivateFrameworks` search paths. They are loaded at runtime rather than linked.

---

## 4. Notch and display handling

**Notch detection.**
- A notch is assumed when `safeAreaInsets.top > 0` (`sizing/matters.swift:423`).
- Closed width = `frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width + 4`, where the +4 is a hard-coded fudge (`:412-415`). It can be overridden (`:417-419`).
- Height modes: real notch (`safeAreaInsets.top`, `:426-427`), menu bar (`frame.maxY − visibleFrame.maxY`, `:428-429`) and custom.
- Defaults (`Constants.swift:1001-1012`): `notchHeightMode = .matchRealNotchSize`, `nonNotchHeight = 32`, `closedNotchWidth = 150`, `openNotchWidth = 640`.
- Open height is fixed at 200 (`matters.swift:74`). Width is clamped to `screen.width − 60`, with floor 400 and fallback 900 (`:79-90`).

**Non-notch displays.**
- `externalDisplayStyle` chooses between a black `NotchShape` and a floating pill. The pill is used only when the style is `.dynamicIsland` and the screen has no notch (`matters.swift:335-352`; `ContentView.swift:421, 575-588`).
- "Hide until hover" moves the shape off-screen (`ContentView.swift:452-458`). It relies on edge polling every 50 ms to 1 s that never stops (`:2136-2215`).
- On non-notch screens, choosing "Match real notch size" just writes 32 (`SettingsView.swift:1329-1336`).
- **Inferred:** `.matchMenuBar` gives height 0 when the menu bar auto-hides (`matters.swift:434-435`).

**External monitors and multi-display.**
- Windows and view models are held per `NSScreen` object (`DynamicIslandApp.swift:108-109`). Matching and preferences are by `localizedName`:
  - preferred screen stored as `@AppStorage("preferred_screen_name")` (`DynamicIslandViewCoordinator.swift:155-162`)
  - name lookups in `matters.swift:82, 342, 388, 406`, `ContentView.swift:436, 2137, 2401, 2414`, `DynamicIslandHeader.swift:107`
  - `FullscreenMediaDetector.fullscreenStatus: [String: Bool]` (`observers/FullscreenMediaDetection.swift:32, 89-90`)
- Identical monitors collide.
- In single-display mode, if the preferred name is missing and auto-switch is off, the window is set to alpha 0 and nothing tells the user (`DynamicIslandApp.swift:1648-1663`).
- In all-displays mode, `calculateRequiredNotchSize` reads only the main view model, which never gets a screen (`DynamicIslandApp.swift:496-507`; `models/DynamicIslandViewModel.swift:45, 352-353`).
- The Settings display picker observes `NSScreen.screens`, which is not observable, so it never refreshes (`SettingsView.swift:1238-1240`).

**Display reconfiguration.**
- `NSApplication.didChangeScreenParametersNotification` is observed (`DynamicIslandApp.swift:1016-1021`). `screenConfigurationDidChange` compares count, names and frames (`:1597-1614`).
- Any change tears down and rebuilds every window, with **no debounce** (`:374-393, 426-457`). There is no `CGDisplayRegisterReconfigurationCallback`.
- The fullscreen detector subscribes to the screen-parameters notification on the **NSWorkspace** notification center (`FullscreenMediaDetection.swift:56-58`). AppKit posts it on `NotificationCenter.default`, so this subscription likely never fires (inferred).
- Lock-screen managers re-align separately on screen parameters and on `screensDidWake` (`LockScreenLiveActivityWindowManager.swift:151-192` and siblings).

**Full-screen awareness.**
- `FullscreenMediaDetector` uses MacroVisionKit `detectFullscreenApps` (`FullscreenMediaDetection.swift:82`), confirmed with AX `AXFullScreen` (`:122-145`). Without Accessibility it trusts the frame only (`:123`).
- The `hideNotchOption` setting (always / now-playing only / never) is applied at `:96-107`.
- Status is recomputed only on Space change; there is no observer for a settings change.
- The CGS Space at max level (`NotchSpaceManager.swift:32`) keeps the window over full-screen Spaces. It is re-asserted on every Space change (`DynamicIslandApp.swift:1023-1032`).

**Sleep, wake and lock.**
- Lock and unlock use the distributed notifications `com.apple.screenIsLocked`/`screenIsUnlocked` (`DynamicIslandApp.swift:1073-1078`).
  - Lock: alpha 0 and `orderOut` (`:330-357`).
  - Unlock: restore after a **fixed 1.0 s delay** (`:335-342, 359-372`).
- There is **no fallback** if the unlock notification is missed. `windowsHiddenForLock` is cleared only at `:361`, and Space re-assert is skipped while it is set (`:416`). `LockScreenManager`, by contrast, has a session-active plus `CGSessionCopyCurrentDictionary` polling fallback (`LockScreenManager.swift:156-166, 352-380`).
- There are no sleep or wake handlers for the notch windows. Wake is handled only by:
  - `SystemOSDManager.swift:49-86`
  - `AlarmManager` catch-up (`managers/Clock/AlarmManager.swift:70-76, 140-148`)
  - `SiriVisibilityMonitor.swift:66-70`
  - the lock-screen re-align observers
- Media state refreshes only when the notch opens (`DynamicIslandViewModel.swift:402`).
- A screen change while locked can recreate and `orderFrontRegardless` a window, which ignores `windowsHiddenForLock` (`DynamicIslandApp.swift:453`).

**Crash points.** `NSScreen.main ?? NSScreen.screens.first!` at `DynamicIslandApp.swift:1079` and `:1149` crashes when no screen is attached (clamshell or headless transitions). The CGS Space is never destroyed on quit; `applicationWillTerminate` does not tear it down (`private/CGSSpace.swift:43`).

**Not handled.** No references to Stage Manager, Mission Control, Dock position, mirroring (`CGDisplayIsInMirrorSet`) or Sidecar. The menu-bar clearance offset from `MenuBarLayout` is one global value applied to every display (`managers/MenuBarLayout.swift:38, 75-90, 133-211`; `ContentView.swift:1035-1049`).

---

## 5. Already fixed on 2026-10-21 (verified in the current tree)

| Fix | Evidence |
|---|---|
| Agents usage archive no longer re-encoded every 10 s. Saves are batched (`saveInterval` 60 s); idle CPU reported 11–66% → about 2% | `managers/Agents/AgentUsageHistory.swift:65-84` |
| Claude token refresh and write-back removed; read-only | `managers/LLMUsage/Quota/ClaudeQuotaClient.swift:192` |
| Upstream Sparkle feed removed from `Info.plist`; updater not started without a Toplet feed | `Toplet/Info.plist` (no `SUFeedURL`); `DynamicIslandApp.swift:49` |
| Extension RPC server off by default, browser `Origin` rejected, file-name traversal fixed | `models/Constants.swift:1399`; `DynamicIslandApp.swift:755-759`; `services/Extensions/ExtensionRPCServer.swift:106-110` |
| ⌘⇧T demo-timer default removed and the saved binding released | `Shortcuts/ShortcutConstants.swift:35-36`; `models/TopletProject.swift:54` |
| Clipboard skips concealed and transient (password-manager) items | `managers/ClipboardManager.swift:582-583` |
| Gemini key sent in a header, not the URL | `managers/ScreenAssistantManager.swift:427` |
| Alarms: silent when the Clock tab is off, catch-up after sleep, visible in minimalistic mode | `managers/Clock/AlarmManager.swift:140-159`; `DynamicIslandViewCoordinator.swift:110` |
| AtollNotch idle files synced into the app so the Xcode project compiles them | `Toplet/AtollNotchIdle/` (8 files) |
| Upstream release, mirror and nightly workflows guarded to the upstream repo | `.github/workflows/release.yml`, `mirror-release.yml`, `nightly-merge.yml` (repository guard) |
| Location usage text mentions the Clock map | `project.pbxproj:821-822` |

---

## 6. Backlog: top 15 open fixes, by impact

| # | Fix | Severity | Effort | Files |
|---|---|---|---|---|
| 1 | Commit the untracked modules and features (Agents, AtollNotch, Clock, Games, Ship, Usage pin, TopletProject, rebrand tool). Make the app consume **one** Agents source and run its tests against the shipped copy | Critical | M | `AtollAgents/`, `Toplet/managers/Agents/`, `Toplet/components/Notch/Agents/`, `local/sync-agents.sh`, `AtollNotch/` |
| 2 | Guarantee OSDUIHelper and WallpaperAgent are resumed after a crash (signal and exit handlers or a launchd watchdog); avoid SIGSTOP where possible | High | M | `managers/SystemOSDManager.swift:109-201, 530-564`; `managers/FullScreenArtworkWindowManager.swift:452-502` |
| 3 | Extension security: prompt the user per extension and verify the caller's code signature instead of auto-authorizing; register or remove the Atoll-named XPC service | High | M | `services/Extensions/ExtensionRPCService.swift:144-152`; `ExtensionXPCServiceHost.swift:25, 55`; `Toplet.entitlements:9-12` |
| 4 | Move Screen Assistant API keys to the Keychain; send images to all vision-capable providers; update default model IDs | High | M | `managers/ScreenAssistantManager.swift:418-517, 941-1175`; `models/Constants.swift:1388-1391`; `components/ScreenAssistant/ModelSelectionPanel.swift` |
| 5 | LocalSend: add `NSLocalNetworkUsageDescription`, pin the peer TLS fingerprint, bind sensibly; implement receive or label it send-only | High | L | `components/Shelf/Services/LocalSendService.swift:86-87, 675-738, 1042-1046`; `project.pbxproj` INFOPLIST keys |
| 6 | Identify displays by UUID or `CGDirectDisplayID`; store the preferred display by UUID; show a fallback instead of alpha 0 | High | M | `DynamicIslandApp.swift:108-109, 1617-1663`; `DynamicIslandViewCoordinator.swift:155-162`; `sizing/matters.swift:82-406`; `observers/FullscreenMediaDetection.swift:32-90` |
| 7 | Unlock restore fallback (session-active or polling, like `LockScreenManager`) and no window ordering while locked | High | S | `DynamicIslandApp.swift:330-372, 416, 453`; `managers/LockScreenManager.swift:156-166` |
| 8 | Camera/mic privacy indicator must not be hidden by music (reorder or make it a secondary slot); same for the agents indicator | High | S | `ContentView.swift:1134-1156, 1531-1560` |
| 9 | Re-apply per-app volume levels and mutes at launch when the feature is on | High | S | `managers/PerAppVolumeManager.swift:72-77, 154-161`; `DynamicIslandApp.swift` (launch sequence) |
| 10 | Debounce screen-parameter rebuilds; fix the fullscreen detector's notification center; remove the `screens.first!` force unwraps | Medium | S | `DynamicIslandApp.swift:1016-1021, 1079, 1149, 1597-1614`; `observers/FullscreenMediaDetection.swift:56-58` |
| 11 | Back alarms with `UNUserNotificationCenter` so they ring when the app is quit; persist snooze | Medium | M | `managers/Clock/AlarmManager.swift:49-159`; Info.plist / entitlements |
| 12 | Settings honesty pass: hide the updater section and channel picker while there is no feed; remove or finish the visualizer, `expandedDragDetection` and `colorHistorySize` controls; restore the onboarding button; add a Ship toggle | Medium | S | `components/Settings/SettingsView.swift:4190-4286, 4511, 5002-5113`; `SoftwareUpdater.swift:55-85`; `managers/ColorPickerManager.swift:126-127`; `models/Constants.swift:1277-1278` |
| 13 | Give Usage, Clock and Games their own Settings pages; host `pricing.json` in Toplet, not upstream Atoll | Medium | S | `components/Settings/SettingsView.swift:48-70, 8010-8060`; `managers/LLMUsage/ModelPricingManager.swift:98` |
| 14 | Global-shortcut defaults: keep only toggle-notch; remove the dead backlight shortcuts | Medium | S | `Shortcuts/ShortcutConstants.swift:27-37`; `DynamicIslandApp.swift:1449-1553` |
| 15 | Replace `fatalError("Unsupported OSD type")` with a logged return; remove dead code (status item, `commands`, `MinimalisticMusicView`, `NotchSurfaceGroup`) and the unused Pow and open-meteo packages | Low | S | `managers/CustomOSDWindowManager.swift:175`; `DynamicIslandApp.swift:84-107`; `components/MinimalisticMusicView.swift`; `project.pbxproj:996-1031` |

Also worth scheduling:
- Rename the upstream-named Keychain services, the XPC service and the `~/.atoll` socket, with a migration (`CiderTokenStore.swift:25`, `SpotifyTokenStore.swift:39`, `NewAPIUsage.swift:38`, `AgentsIntegration.swift:289`).
- Pin the four `branch = main` packages (`project.pbxproj:980-1063`).
- Confirm the licence of the AirPods `.mov` artwork (`Toplet/BluetoothHUDAnimations/`).

---

## 7. Not assessed

- **Runtime behaviour of any kind.** Nothing was built or launched: animations, hover feel, permission prompts, lock-screen windows, multi-display, HUD replacement and SkyLight behaviour.
- **Whether the Xcode project builds** after the AtollNotchIdle sync, and whether Developer ID notarization passes with the private-framework search paths.
- **XCTest results.** The 276 unit tests and 2 UI tests were counted, not run. The AtollAgents `swiftc` suites were not run in this audit.
- **Third-party binaries.** The contents of `Frameworks/MediaRemoteAdapter.framework` and `Contents/Helpers/NowPlayingTestClient` were not inspected.
- **Network services.** Correctness of the provider APIs (Anthropic OAuth usage, ChatGPT `wham`, Cursor, Antigravity local RPC) was not checked.
- **Remaining "Cannot currently verify" rows** in §2: minimalistic mode, Clock map, Clock-app timer mirror, caps lock, backlight/brightness, lock-screen widgets, full-screen artwork, launch at login, DDC integrations, and the new Ship companion, which was added during the audit and was read only far enough to confirm its wiring and default.
