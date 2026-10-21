# Notch notifications and idle animation engine: Phase 1 audit

Repo `Atoll-Local/Atoll`, branch `local-build` (HEAD `6294efa`), GPL-3.0, sources in `Toplet/`. Date 2026-10-21. Host: macOS 27.2, Command Line Tools only (no Xcode), Swift 6.4.

Scope: read-only audit of what exists, what is missing, how the closed notch arbitrates today, and the smallest change set that delivers (a) notch notification experiences and (b) an idle animation engine without a second pipeline. Nothing in `Toplet/` was edited; this file is the only artifact.

User constraints carried through the whole document:
1. REUSE the existing architecture. No duplicate controllers, pipelines or state managers.
2. No claim of system-wide notification access unless a supported public API exists. (There is none; section 5.)
3. Never bypass macOS permissions.

## Evidence legend

| Tag | Meaning |
|---|---|
| `[OBSERVED path:line]` | Read directly in a file at the current tree, or measured by a command run for this audit. Line numbers are from THIS tree. |
| `[INFERRED]` | Reasoned from observed facts, not executed. |
| `[UNKNOWN]` | Could not be established from disk or the web. Needs a live test. |
| `[WEB Wn]` | Taken from a web source listed in section 9. `[SDK]` = read from the macOS 27.0 SDK headers on this Mac. |

Stale-document warning (the user asked to trust code over docs). Differences found while auditing:
- `docs/LOCAL-ARCHITECTURE-AUDIT.md` and `docs/PERFORMANCE-AUDIT.md` quote `ContentView.swift` as 3,321 lines and cite old line numbers; the file is 3,287 lines now. All line numbers below were re-read.
- `docs/DEAD-CODE-REPORT.md:186-187` lists `loadStoredUserAnimations` and `updateAnimation` in `IdleAnimationManager.swift`; neither exists any more (the file is 268 lines). `[OBSERVED managers/IdleAnimationManager.swift]`
- `docs/FEATURE-MATRIX-A.md` A18 says the closed notch is "one if/else chain"; true, but the chain is duplicated in two size functions (section 2.3), and its guards depend on expansion types that nothing sets any more (section 2.6, B7).
- `AtollAgents/` (15,611 Swift lines incl. tests) is UNTRACKED in git (`git status`: `?? AtollAgents/`), has 0 references in `Toplet.xcodeproj/project.pbxproj`, and no file under `Toplet/` references it. It is a finished-looking but unintegrated module. `[OBSERVED git status; grep -c AtollAgents project.pbxproj = 0]`

---

## 0. Summary in ten lines

1. EXISTS: a single closed-notch compositor (`ContentView.NotchLayout`), a single transient-message slot (`coordinator.sneakPeek`), a single takeover slot (`coordinator.expandingView`), ~17 producers, an extension API (live activities with priority, app icon, Lottie, sneak-peek config), Focus detection, EventKit reminders, a Lottie idle-animation importer with transform editor.
2. BIGGEST GAPS: no notification model at all (no queue, dedupe, click action, privacy redaction, Focus gating, per-source duration/priority); no explicit priority system; no idle presets, no sprite sheets, no real validation, no Reduce Motion handling anywhere in `Toplet/`, no energy controls; settings have no Notifications section.
3. PRIORITY TODAY, in three lines: (1) a hard-coded 17-branch `if/else if` chain in `ContentView.swift:1046-1164` picks ONE primary closed surface (connectivity > hello > battery HUD > inline HUD > caps lock > music(+badge) > timer > reminder > recording > download > LocalSend > Focus > privacy > extension > shelf > idle); (2) on top of that, `sneakPeek` (last writer wins, no priority, one shared duration field) is drawn inline or below the notch, and `expandingView` (one slot, last writer wins) silently suppresses most of those branches through guards that mention expansion types nobody sets; (3) window width/height precedence is re-encoded in two other places in a DIFFERENT order (`ContentView.swift:112-243`, `DynamicIslandApp.swift:491-610`).
4. Real bugs found (section 2.6): recording-size precedence can clip the battery HUD by 48 pt; duration clobber can leave a HUD that never hides; hide-by-type ignores the type; Bluetooth HUD cut short by a 1.5 s suppression window; camera/mic privacy indicator is never drawn while music plays (default settings); a long download hides timer, reminder, music, Focus and privacy.
5. Idle pipeline bugs (section 3): editing an existing animation drops name and speed; a NEW import drops all transform settings; live-preview speed/loop sliders do nothing (LottieUI only reads its state at creation); built-in animations are stored as absolute bundle URLs (this Mac's defaults already point into `dist/Atoll.app` while the app runs from `~/Applications`); `expandWithAnimation` is stored but never read; `print` calls run inside view bodies.
6. SOURCES: there is NO public macOS API to observe other apps' notifications. Supportable sources are Atoll's own `UNUserNotificationCenter`, the extension API, a local `atoll-notify` socket/CLI, AI-agent hooks, EventKit, Focus status. Notification-center database reading (Full Disk Access) and Accessibility scraping are classified "not implemented / experimental, not recommended".
7. RECOMMENDED DESIGN: refine, do not replace. Extract the chain into ONE pure resolver (`NotchEventArbiter`, characterization-tested against the old chain), make `toggleSneakPeek` priority- and token-aware inside the existing coordinator, add a pure `NotificationQueue` feeding that single entry point, extend `IdleAnimationManager` with presets/validation/sprites instead of adding a manager.
8. Fewest existing files: 6 core edits (`Constants.swift`, `DynamicIslandViewCoordinator.swift`, `ContentView.swift`, `DynamicIslandApp.swift`, `SettingsView.swift`, `IdleAnimationManager.swift` + its 3 UI siblings); everything else is new files that the synchronized Xcode group and `local/prepare.py` pick up with no project edits.
9. Test plan runs without Xcode: pure-Swift logic tests with `swiftc` (same pattern as `tests/test_timer_lifecycle.py` and `AtollAgents/Tests/run_core.sh`), offscreen SwiftUI snapshots (pattern of `AtollAgents/UI/Snapshot`), and live launch checks (pattern of `local/smoke.sh`, `local/perf/measure.py`).
10. Biggest unknowns: `UNUserNotificationCenter` and `INFocusStatusCenter` behaviour for an ad-hoc-signed accessory app on macOS 27; whether the extension XPC service works at all in the local build (its entitlement is removed); LottieUI preview behaviour (needs a live check).

---

## 1. CAPABILITY MATRIX

Legend: EXISTS = present and doing the job; PARTIAL = something is there, gap stated; MISSING = nothing.

### 1.A Notification experiences

| # | Requested capability | Status | Evidence and gap |
|---|---|---|---|
| A1 | Compact presentation around the notch | PARTIAL | Closed-notch "wing" compositions exist for music, timer, reminder, recording, Focus, privacy, extension, shelf (`ContentView.swift:1123-1157`), with a shared wing-width system (`ContentView.swift:1381-1506`, `1542-1624`) and automatic menu-bar clearance (`ContentView.swift:1256-1269`). Text-bearing transient content exists only as a one-line marquee under the notch (`ContentView.swift:1166-1249`). No notification-specific compact view. |
| A2 | Expand / collapse | PARTIAL | Expansion patterns exist: battery "standard" style grows the notch downward (`ContentView.swift:157-188`, `components/Live activities/DynamicIslandBattery.swift:543`), inline sneak peek widens to 460 (`ContentView.swift:124-148`), recording hover-expand (`helpers/RecordingHUDLayout.swift:36-82`). All are system-driven; none can be expanded or collapsed by the user per item. Hover-open is blocked while any sneak peek shows (`ContentView.swift:2321-2338`). |
| A3 | Source app icon + title + preview | PARTIAL | `AtollLiveActivityDescriptor` carries `title`, `subtitle`, `sneakPeekTitle/Subtitle`, `accentColor`, and `AtollIconDescriptor.appIcon(bundleIdentifier:)`/`.image`/`.lottie` `[WEB W11: AtollIconDescriptor.swift, AtollLiveActivityDescriptor.swift]`. But the extension sneak-peek view draws only an accent bar plus one marquee line, no icon (`ContentView.swift:1221-1248`). `coordinator.sneakPeek.icon` is an SF-Symbol name string (`DynamicIslandViewCoordinator.swift:82`). Nothing for locally originated notifications. |
| A4 | Configurable duration | PARTIAL | Per call `toggleSneakPeek(duration:)` (`DynamicIslandViewCoordinator.swift:322-345`, default 1.5 s `:325`); extension default 2.5 s (`managers/Extensions/ExtensionLiveActivityManager.swift:191`) overridable by the poster via `AtollSneakPeekConfig.duration`; reminder `reminderSneakPeekDuration` (5 s, `models/Constants.swift:1326`); battery durations (3 s each, `Constants.swift:1176-1178`). No user setting for notifications. |
| A5 | Priority | PARTIAL | Extension descriptors have `low/normal/high/critical` `[WEB W11: AtollLiveActivityPriority.swift]`, used only to sort extension activities (`ExtensionLiveActivityManager.swift:164-169`). `sneakPeek` has no priority; last writer wins (`DynamicIslandViewCoordinator.swift:359-376`). |
| A6 | Queue | MISSING | `sneakPeek` and `expandingView` are single slots (`DynamicIslandViewCoordinator.swift:402`, `430`). Extension activities queue up to capacity 4 (`Constants.swift:1381`) but only the first is drawn (`ContentView.swift:1898-1985`). |
| A7 | Dedupe | PARTIAL | Extension activities replace by `(descriptor.id, bundleIdentifier)` (`ExtensionLiveActivityManager.swift:62`). Sneak peek: same-type write just restarts the timer (`DynamicIslandViewCoordinator.swift:402-409`). No content/time-window dedupe. |
| A8 | Dismissal | PARTIAL | Timer auto-hide (`DynamicIslandViewCoordinator.swift:383-400`); lock clears everything (`managers/LockScreenManager.swift:250-257`); extensions can `dismiss` (`ExtensionLiveActivityManager.swift:123-152`) and are told via XPC/RPC. No user dismissal (no swipe or click-to-dismiss on a transient). |
| A9 | Click actions | MISSING | The closed notch has one tap handler that opens the notch (`ContentView.swift:705-715`). `AtollExtensionKit` has no tap callback (no tap/click/action member in `AtollLiveActivityDescriptor`; RPC method list `services/Extensions/ExtensionRPCService.swift:59-113` has none). |
| A10 | Do-Not-Disturb / Focus awareness | PARTIAL | Focus is DETECTED (`managers/DoNotDisturbManager.swift:25-30` `isDoNotDisturbActive`, mode name/id) and shown as a live activity, but no presentation is gated on it. Detection rests on private distributed notification names `_NSDoNotDisturbEnabledNotification` (`DoNotDisturbManager.swift:520-521`), `~/Library/DoNotDisturb/DB/*.json` read under Full Disk Access (`:45`, `:317`, `:604`) and a `log stream` child. Monitoring starts only if `enableDoNotDisturbDetection` (`DynamicIslandApp.swift:783-786`, re-started on toggle at `:977`). Zero uses of public `INFocusStatusCenter` (grep). |
| A11 | Privacy mode (hide sensitive content) | MISSING | Only whole-window `hideDynamicIslandFromScreenCapture` (`components/Notch/DynamicIslandWindow.swift:60`, `helpers/ScreenCaptureVisibilityManager.swift`). Nothing redacts content. Worse: extension payloads (text, icon bytes up to 5 MB) are written in plaintext to `~/Library/Application Support/AtollExtensions/live_activities.json` and broadcast with the full payload over `DistributedNotificationCenter` (`managers/Extensions/ExtensionEventBridge.swift:78-94`, `:105-124`), so routing notification text through that path would leak it. |

### 1.B Idle animation engine

| # | Requested capability | Status | Evidence and gap |
|---|---|---|---|
| B1 | Built-in breathing / pulse / animated-eye presets | MISSING | The only built-ins are 4 bundled Lottie files (`managers/IdleAnimationManager.swift:107`). A legacy procedural "face" was removed and is only cleaned up (`IdleAnimationManager.swift:54-60`, `82-93`; the dead sentinel `builtin://face` survives at `components/Settings/IdleAnimationsSettingsSection.swift:162`). A `PulsingModifier` exists for the recording dot (`ContentView.swift:1652`). A native breathing orb exists only in the unintegrated `AtollAgents/UI/AgentsClosedIndicator.swift`. |
| B2 | Import Lottie JSON | EXISTS (weak) | File picker restricted to `UTType.json` (`IdleAnimationsSettingsSection.swift:135-141`), copy to app storage (`IdleAnimationManager.swift:152-192`), or remote URL stored without download (`:195-213`). |
| B3 | Import sprite sheets | MISSING | No code path, no model case (`AnimationSource` has only `.lottieFile`, `.lottieURL`, `models/Constants.swift:126-136`). |
| B4 | Local asset storage | EXISTS | `~/Library/Application Support/DynamicIsland/IdleAnimations/<UUID>.json` (`IdleAnimationManager.swift:27-35`, `165-170`); metadata in `Defaults`. Built-ins are persisted as absolute bundle URLs (section 3.2). |
| B5 | Validation | PARTIAL (weak) | Extension must be `.json`; content must parse as JSON (`IdleAnimationManager.swift:155-163`). `{}` and `[]` pass. No size cap, no schema (`v/fr/ip/op/w/h/layers`), no asset-reference check, remote URL unchecked, `NSAllowsArbitraryLoads=true` (`Toplet/Info.plist:6-8`). |
| B6 | Live preview | PARTIAL | Preview canvas with notch-bounds overlay (`components/Settings/AnimationEditorView.swift:157-188`) and per-card previews (`IdleAnimationsSettingsSection.swift:365-387`). Speed and loop-mode changes do not reach a running preview (section 3.4). Preview is not rendered in the real notch context. |
| B7 | Loop / speed / scale / position | PARTIAL | `AnimationTransformConfig` has scale, offsetX/Y, crop W/H, rotation, opacity, paddingBottom, loopMode (`Constants.swift:97-110`); speed lives on `CustomIdleAnimation` (`:74`). Gaps: new imports discard the transform config (`AnimationEditorView.swift:463-516`); editing an existing animation saves transforms only and drops name and speed (`:477-498`); `expandWithAnimation` is never read (only `Constants.swift:106` and the editor). |
| B8 | Automatic suspension during higher-priority activity | PARTIAL (implicit) | Achieved only because the idle branch is last in the chain (`ContentView.swift:1157`): the view is destroyed and recreated, restarting playback; no pause/resume and no condition besides music idle, no expansion, no hideOnClosed. |
| B9 | Reduce Motion | MISSING | `grep accessibilityReduceMotion|accessibilityDisplayShouldReduceMotion` over `Toplet/` returns 0 hits. Only the untracked `AtollAgents/UI/*` reads `@Environment(\.accessibilityReduceMotion)`. Lottie's own handling only plays a marker named "reduced motion" if the file has one `[WEB W4]`, so it cannot be relied upon. |
| B10 | Energy-efficient rendering | MISSING | Default Lottie rendering engine (no `LottieConfiguration` outside the lock icon, `components/LockScreen/LockIconAnimationView.swift:153`), loops forever, no fps cap, no pause on display sleep / low-power / user inactivity, `print` and a `Defaults` JSON decode on every body evaluation (`components/IdleAnimationView.swift:46-50`, `Constants.swift:86-94`). Good: view is not mounted when `hideOnClosed` (fullscreen) or while the notch is open. |

### 1.C Wiring to existing modules and the priority system

| # | Module / requirement | Status | Evidence |
|---|---|---|---|
| C1 | Closed notch | EXISTS | `ContentView.swift:1043-1313`. |
| C2 | Expanded notch | PARTIAL | Tab views (`ContentView.swift:1273-1306`); no notification history/tab; idle animation not shown when open. |
| C3 | Music / media | EXISTS | Music wings with secondary badge slot (`ContentView.swift:1123-1126`, `1508-1540`); idle only when `!isPlaying && isPlayerIdle` (`:1157`, `MusicManager.swift:1433-1441`, `waitInterval` 3 s `Constants.swift:1065`). |
| C4 | Battery / charging | EXISTS | `expandingView(.battery)` + `BatteryStatusViewModel.activeTemporaryHUDKind` (`models/BatteryStatusViewModel.swift:186-217`); highest non-structural priority in the chain (`ContentView.swift:1097`). |
| C5 | Timers / reminders | EXISTS | `TimerLiveActivity` (`ContentView.swift:1127`); reminders via EventKit (`Providers/CalendarServiceProviding.swift:35-115`, `managers/ReminderLiveActivityManager.swift:456-542`) with a sneak peek at lead time and a "critical" one before start. |
| C6 | Downloads | EXISTS | `DownloadManager` + `expandingView(.download)` (`managers/DownloadManager.swift:545-620`). |
| C7 | Screen recording / camera / mic indicators | PARTIAL | Recording: `expandingView(.recording)` for 3 s then branch (`managers/ScreenRecordingManager.swift:432`, `ContentView.swift:1131`). Camera/mic: `PrivacyLiveActivity` (`ContentView.swift:1141`) but masked by music (B8 in 2.6). |
| C8 | Third-party extension live activities | EXISTS | `ContentView.swift:1143-1153`, `1819-1985`; sneak peek `:1221-1248`. |
| C9 | DETERMINISTIC priority system | MISSING | Section 2. |
| C10 | Settings: Notifications | MISSING | `SettingsTab` has no such case (`components/Settings/SettingsView.swift:48-69`). |
| C11 | Settings: Idle Animations | PARTIAL | Lives inside the Appearance tab: toggle `SettingsView.swift:5171-5175`, section `:5182` (`IdleAnimationsSettingsSection`). Search entry `:373`. No own tab. |
| C12 | Settings: Integrations | PARTIAL | The "Integrations" sidebar group exists (`SettingsView.swift:28`, `42`, `83`) and holds one tab, `Extensions` (`components/Settings/ExtensionsSettings.swift:23-216`: marketplace, global toggles, authorized apps). No sources/CLI/agents section. |
| C13 | Gallery: Import / Preview / Apply / Reset / Delete | PARTIAL | Import file/URL EXISTS, Preview EXISTS (card + editor), Apply EXISTS (tap selects, `IdleAnimationsSettingsSection.swift:63-67`), Delete EXISTS for non-built-in with confirm alert (`:197-208`, `IdleAnimationManager.swift:218-248`), Edit via context menu (`:348-360`). Reset MISSING (the editor's "Reset All" only resets editor state `AnimationEditorView.swift:421-435`; nothing restores defaults or the built-in set). |

---

## 2. THE EXISTING PRIORITY MODEL

There is no priority engine. Priority is the order of an `if / else if` chain, plus three single-slot state holders and several per-feature suppression hacks.

### 2.1 Every state variable that participates

Coordinator (global, shared by all displays) `DynamicIslandViewCoordinator.swift`:

| Variable | Line | Notes |
|---|---|---|
| `sneakPeek: sneakPeek` {show, type, value, icon, title, subtitle, accentColor, styleOverride, targetScreenName} | 78-88, 402-410 | `@Published`; one slot; `didSet` schedules hide |
| `sneakPeekDuration: TimeInterval` | 379 | plain `private var`, written synchronously in `toggleSneakPeek` (`:345`), read later inside `didSet` (`:405`) |
| `sneakPeekTask: Task` | 380 | hide timer; cancelled by `didSet` |
| `expandingView: ExpandedItem` {show, type, value, autoHideDuration} | 90-95, 430-447 | `@Published`; one slot; `didSet` auto-hides after `autoHideDuration ?? 3` except `.download` |
| `expandingViewTask` | 428 | |
| `currentView`, `firstLaunch`, `musicLiveActivityEnabled`, `timerLiveActivityEnabled` | 107, 126, 128-129 | `@AppStorage` for the last three |

Per display `models/DynamicIslandViewModel.swift`: `notchState` (32), `hideOnClosed` (45; default `true`, set by fullscreen detection `:355-372`), `closedNotchSize`, `effectiveClosedNotchHeight` (376).

Producer state read by the chain (`ContentView.swift:1043-1164`): `networkConnectivityManager.hudState`; `coordinator.firstLaunch`; `batteryModel.activeTemporaryHUDKind/Token/TargetScreenName`; `Defaults[.inlineHUD]` (default true, `Constants.swift:1199`), `Defaults[.showPowerStatusNotifications]`; `capsLockManager.isCapsLockActive`; `musicManager.isPlaying/isPlayerIdle/songTitle/artistName`; `timerManager.isTimerActive`; `reminderManager.isActive/activeReminder`; `recordingManager.isRecording`; `downloadManager.isDownloading`; `localSendService.isSending/transferState`; `doNotDisturbManager.isDoNotDisturbActive/isFocusToastDismissing`; `privacyManager.hasAnyIndicator`; `extensionLiveActivityManager.activeActivities`; `shelfState.isEmpty`; `lockScreenManager.isLocked/shouldDelayPostUnlockMusicHUD`; `Defaults[.showNotHumanFace]`, `enableMinimalisticUI`, `showStandardMediaControls` (default true, `Constants.swift:1083`), and about 15 `enable*` toggles. All are read inside one `ViewBuilder`; ContentView observes 18 objects, so any publish re-runs the whole chain (`docs/PERFORMANCE-AUDIT.md` section 0, item 3).

### 2.2 The closed-notch decision chain, in order

`ContentView.NotchLayout()` `[OBSERVED ContentView.swift:1043-1164]`. First true branch wins. "Exp-guard" = the branch is skipped when any expansion is visible on this screen (`isCurrentScreenExpansionVisible`, `ContentView.swift:503-509`) unless the expansion type equals the one named.

| Pri | Line | Surface | Extra guards |
|---:|---:|---|---|
| 1 | 1046 | Network connectivity HUD (replaces everything, own shape/size) | `NetworkConnectivityHUDMetrics.isPresented` |
| 2 | 1052 | First-launch hello | `coordinator.firstLaunch` |
| 3 | 1097 | Battery temporary HUD (charging/low/full) | `expandingView.type == .battery`, kind non-nil, closed, setting on |
| 4 | 1113 | Inline HUD: sneak peek of any type except music, battery, timer, reminder, extension; volume/brightness/backlight only when closed; requires `inlineHUD` (default on) or the AirPods-listening-mode sentinel | `isSneakPeekVisibleOnCurrentScreen` |
| 5 | 1120 | Caps-lock persistent indicator | `isCapsLockActive`, enabled, `!hideOnClosed`, `!isLocked` |
| 6 | 1123 | Music live activity with a secondary badge slot | `canShowMusicDuringExpansion` (no expansion, or music, or expansion equals the secondary) and `musicPairingEligible` |
| 7 | 1127 | Timer live activity | exp-guard `.timer`, `timerLiveActivityEnabled` |
| 8 | 1129 | Reminder live activity | exp-guard `.reminder` |
| 9 | 1131 | Recording live activity | exp-guard `.recording`, `!musicPairingEligible` |
| 10 | 1133 | Download live activity | exp-guard `.download` |
| 11 | 1136 | LocalSend live activity | `!isCurrentScreenExpansionVisible` |
| 12 | 1139 | Focus / DND live activity | exp-guard `.doNotDisturb`, `!isLocked` |
| 13 | 1141 | Camera/mic privacy live activity | exp-guard `.privacy` |
| 14 | 1143 | Extension standalone live activity (sorted by priority desc, then `receivedAt` asc, `ExtensionLiveActivityManager.swift:164-169`) | `resolvedExtensionStandalonePayload`, `:1898-1985`, also `!isCurrentScreenExpansionVisible` |
| 15 | 1154 | Shelf inline | `!expandingView.show`, not minimalistic |
| 16 | 1157 | IDLE ANIMATION | `!isCurrentScreenExpansionVisible`, `!isPlaying && isPlayerIdle`, `showNotHumanFace`, `!hideOnClosed` |
| 17 | 1159 | Header (notch open) | |
| 18 | 1162 | Empty spacer | |

Music secondary badge priority (`ContentView.swift:1508-1540`): timer > reminder > recording > Focus > caps lock > extension (music-coexistence only) > shelf. This is a second, DIFFERENT ordering of the same concepts (Focus ranks above caps lock here, below here relative to download; privacy, download and LocalSend are not badge-capable at all).

Additive overlay, not exclusive (`ContentView.swift:1166-1249`): when `sneakPeek.show`, a second block draws UNDER the primary surface: `SystemEventIndicatorModifier` (when `inlineHUD` is off), or a one-line marquee for music / timer / reminder / extension in `.standard` style. So a reminder or extension sneak peek is drawn below whatever primary surface won.

Hover: while a sneak peek shows, hover-open is blocked (`ContentView.swift:2321-2338`) and when it ends and the cursor is still there the notch opens 0.2 s later (`:808-817`).

### 2.3 The same priority re-encoded for geometry (two more copies, different order)

| Copy | Where | Order (first match returns) |
|---|---|---|
| View max-size | `ContentView.swift:112-243` `dynamicNotchSize` | connectivity (115) > inline sneak (music/timer expansion or AirPods sentinel, width 460) (124-148) > recording HUD (150-155) > battery HUD (157-188) > tab-specific sizes |
| Window size | `DynamicIslandApp.swift:491-610` `calculateRequiredNotchSize` | connectivity (492) > inline sneak (509-530) > recording (532-537) > battery (540-574) > tab sizes |
| Clip shape | `ContentView.swift:612-636` `resolvedClipShape` | connectivity > recording surface > battery surface > pill/notch |

Order differences versus the chain: the chain puts battery above inline HUD and recording near the bottom; the size functions put recording above battery and decide on `isRecording` alone, not on which branch actually won. Default (no special case) the window is `openNotchSize` (640 wide, observed `w=640 h=222` in `docs/TEST-RESULTS.md`), so anything wider than 640 or taller than ~200 needs a size-function edit and anything narrower is safe.

The AirPods-listening-mode state is encoded by a magic value: `type == .bluetoothAudio && value < 0 && AirPodsListeningMode.fromHUDSymbol(icon) != nil`, copied at `ContentView.swift:126-130`, `:1093-1095`, `DynamicIslandApp.swift:510-514`. Any new sneak-peek type will need this kind of copy-paste unless the rule moves into one function.

### 2.4 Timeouts that exist

| Surface | Duration | Source |
|---|---|---|
| Sneak peek default | 1.5 s | `DynamicIslandViewCoordinator.swift:325` |
| Sneak peek timer type | 10 s (no producer exists) | `:336-337` |
| Reminder sneak peek | `reminderSneakPeekDuration`, default 5 s; critical one `min(window, timeRemaining-2)` | `Constants.swift:1326`, `ReminderLiveActivityManager.swift:512-527` |
| Extension sneak peek | `config.duration ?? 2.5` | `ExtensionLiveActivityManager.swift:191` |
| Bluetooth connect / AirPods mode | 2.5 s | `managers/BluetoothAudioManager.swift:1947-1951`, `2011-2015` |
| Caps lock | infinite until released | `CapsLockManager.swift:81-86`; `scheduleSneakPeekHide` returns for non-finite (`DynamicIslandViewCoordinator.swift:387`) |
| Music sneak peek | 1.5 s default; shortcut uses 3 s | `MusicManager.swift:1538`, `DynamicIslandApp.swift:1053-1057` |
| `expandingView` | `autoHideDuration ?? 3` s, never for `.download` | `DynamicIslandViewCoordinator.swift:430-446` |
| Battery HUD | 3 s each (settings) | `Constants.swift:1176-1178`, `BatteryStatusViewModel.swift:210-217` |
| Download completion | 2.0 s then close | `DownloadManager.swift:578` |
| Focus-off toast | 2.5 s | `DoNotDisturbManager.swift:353-365` |
| Volume-HUD suppression after Bluetooth event | 1.5 s | `managers/SystemMediaControllers.swift:31-58`, `BluetoothAudioManager.swift:1942`, `2006` |
| Hello | 3.5 s | `models/DynamicIslandViewModel.swift:460-468` |

### 2.5 Effective order when an expansion is visible

Because `expandingView` takes one of five types from five callers (`music` MusicManager:1540, `battery` BatteryStatusViewModel:216, `recording` ScreenRecordingManager:432, `download` DownloadManager:564, `lockScreen` LockScreenManager:270) and nothing ever sets `.timer`, `.reminder`, `.doNotDisturb`, `.privacy` (grep over every `toggleExpandingView(` call), the guards `(!isCurrentScreenExpansionVisible || type == .timer/.reminder/.doNotDisturb/.privacy)` collapse to `!isCurrentScreenExpansionVisible`. Effective behaviour:

| Visible expansion | Hides |
|---|---|
| `.download` (stays for the whole download) | timer, reminder, recording (unless it is the badge), Focus, privacy, LocalSend, extension standalone, music (unless the music wings are the expansion), shelf, idle |
| `.battery` (3 s) | everything except connectivity/hello |
| `.recording` (3 s) | music (unless recording is its badge), timer, reminder, Focus, privacy, extension, idle |
| `.music` inline (3 s) | timer, reminder, Focus, privacy, extension, idle (music itself stays) |
| `.lockScreen` (until unlock sequence ends) | all of the above (blank notch; separate lock windows draw the real UI) |

So the written order (music > timer > reminder > recording > download) is NOT what the user sees while a download runs (download > all of them).

### 2.6 Races, overlaps and bugs, with concrete scenarios

Confidence: all are `[OBSERVED]` code facts; the runtime consequence is `[INFERRED]` unless stated. None were reproduced live (no UI automation in this audit).

| ID | Scenario | Mechanism and evidence |
|---|---|---|
| B1 | Screen recording is on, no music pairing, then the charging HUD fires. The battery HUD needs `+180` width but the window and max-size are computed for the recording HUD (`+132`, compact), so its sides overflow the window by 24 pt each and are clipped. | `dynamicNotchSize` checks recording at `ContentView.swift:150-155` before battery `:157-188`; `calculateRequiredNotchSize` does the same `DynamicIslandApp.swift:532-537` before `:540-574`; widths `ContentView.swift:176-177` vs `helpers/RecordingHUDLayout.swift:26-35`. Recording layout is "visible" whenever `isRecording && !musicPairing`, regardless of which branch drew. Same hazard for timer countdown wings, reminder digital wing and wide inline HUDs. |
| B2 | Volume key and Caps Lock pressed in the same main-queue turn: volume HUD never auto-hides (until Caps Lock is released or another sneak peek replaces it). | `toggleSneakPeek` assigns the shared `sneakPeekDuration` synchronously (`DynamicIslandViewCoordinator.swift:345`), but each write lands later via `DispatchQueue.main.async` and `didSet` reads whatever the field holds then (`:359-376`, `:405`). Last assignment (`.infinity` for Caps Lock, `CapsLockManager.swift:84`) wins for both. Low probability, bad failure (wedged `show == true`). |
| B3 | A Bluetooth HUD is showing; the user toggles Caps Lock OFF; the Bluetooth HUD vanishes. | Hide requests carry a type but the write never compares it with the current type (`DynamicIslandViewCoordinator.swift:359-376`); `CapsLockManager.swift:90-97` hides unconditionally. Only `MusicManager.dismissTransientMusicPreview` guards (`MusicManager.swift:1547`). |
| B4 | Settings: "System HUD" is turned off while a HUD is up: the scheduled hide is dropped and the HUD stays. | Early return for non-bypassed types when `!enableSystemHUD` applies to hide as well as show (`DynamicIslandViewCoordinator.swift:356-358`); the auto-hide calls `toggleSneakPeek(status:false, ...)` (`:395`). Edge case. |
| B5 | Hide task wakes at the exact moment a new sneak peek is applied: the new one is hidden immediately (flash). | The hide path passes `Task.isCancelled` then hops twice (`MainActor.run` then `DispatchQueue.main.async`, `:389-399`, `:359`); it carries no generation token, unlike the battery HUD's `activeTemporaryHUDToken` (`BatteryStatusViewModel.swift:53`). Very narrow window. |
| B6 | AirPods connect (HUD 2.5 s); user presses volume at t=1.6 s: the Bluetooth HUD is replaced 0.9 s early by the volume HUD. | `HUDSuppressionCoordinator.suppressVolumeHUD(for: 1.5)` (`BluetoothAudioManager.swift:1942`, `2006`) is a private, volume-only arbitration hack shorter than the HUD it protects (`:1947`: 2.5 s). Brightness, backlight, Caps Lock and extensions are not covered. |
| B7 | Long browser download running; Zoom starts the camera; a timer is running; music plays. The notch shows the download only. The camera indicator, timer, reminder and music are all hidden for the download's whole duration. | Section 2.5: `.download` expansion has no auto-hide (`DynamicIslandViewCoordinator.swift:435`) and the guards at `ContentView.swift:1090`, `1127`, `1129`, `1131`, `1139`, `1141` skip those branches. The written order has timer and reminder ABOVE download; behaviour inverts it. |
| B8 | With default settings (`showStandardMediaControls` true, `musicLiveActivityEnabled` true) and music playing, the camera/mic privacy indicator is never drawn. | Music branch `ContentView.swift:1123` precedes privacy `:1141`; the badge resolver has no privacy case (`:1508-1540`); privacy has no expansion type. Privacy is also not a music secondary for download or LocalSend. A privacy indicator losing to media is the one ordering that is a correctness problem rather than taste. |
| B9 | Shelf has any item (non-minimalistic): idle animation never shows. Each time a higher branch comes and goes the Lottie view is rebuilt and restarts from frame 0. | Shelf branch `ContentView.swift:1154` precedes idle `:1157`; `IdleAnimationView` is re-created (`.id(animation.id)`, `components/IdleAnimationView.swift:59`) with no pause/resume. |
| B10 | Extension activity (any priority) posted while a `critical` reminder sneak peek is up: the reminder is overwritten after 2.5 s default or immediately by the new write. Extension `priority` only sorts extensions. | `ExtensionLiveActivityManager.swift:189-221` calls `toggleSneakPeek` with no priority concept; sorting at `:164-169`. |
| B11 | `showOnAllDisplays` with an external monitor: every sneak peek appears on every display. | `targetScreenName` is only set when a caller passes `onScreen:`; only `BetterDisplayManager`/`Lunar` HUD helpers do for their own windows, no sneak-peek producer does (grep `onScreen:`); `isSneakPeekVisibleOnCurrentScreen` returns true when it is nil (`ContentView.swift:434-439`). Battery resolves a target screen (`BatteryStatusViewModel.swift:223-244`); sneak peeks do not. |
| B12 | Extension live activities never expire unless the poster dismisses them, and are reloaded from disk at launch. A "notification" posted this way persists across restarts. | `ExtensionLiveActivityManager.swift:37-39` loads the persisted snapshot; no TTL, `estimatedDuration` is never read (grep). |
| B13 | The RPC server auto-authorizes any first caller for any self-declared bundle id, and live-activity `present` trusts `descriptor.bundleIdentifier`; the rate-limit records are written but `ExtensionValidationError.rateLimited` is never thrown. Any local process can post as "com.apple.mail" with that app's icon. | `services/Extensions/ExtensionRPCService.swift:144-156`, `:182`; `ExtensionAuthorizationManager.swift:89-110`, `:181-192`; grep `rateLimited`: only the enum case and its mapping (`ExtensionActivityModels.swift:62`, `ExtensionRPCService.swift:344`). The XPC path derives the bundle id from the peer pid (`ExtensionXPCServiceHost.swift:125-134`) but `ExtensionLiveActivityManager.present` does not compare it with the descriptor's (the notch-experience manager does, `ExtensionNotchExperienceManager.swift:58-61`). |

### 2.7 Proposed deterministic priority table (a refinement, not a second engine)

Principle: encode TODAY's effective order explicitly in one pure function, fix the clear bugs, and add the new surfaces as new rows. Rows marked DECISION are places where today's behaviour is arguable; the default below preserves it and a test locks it so changing it is a one-line, visible edit.

Rank class meanings: STRUCTURAL (screen state, never preempted), SAFETY (privacy/critical, preempts media), TRANSIENT (timed, preempts and resumes), STICKY (lives while its condition holds), AMBIENT (decorative).

| Rank | Surface | Class | Today | Change |
|---:|---|---|---|---|
| 1 | Connectivity-lost HUD | STRUCTURAL | chain 1 | none |
| 2 | First-launch hello | STRUCTURAL | chain 2 | none |
| 3 | Camera / mic privacy indicator | SAFETY | chain 13, masked by music (B8) | LIFT above music/timer/download; stays visible until camera/mic stop |
| 4 | Battery temporary HUD | TRANSIENT | chain 3 | none |
| 5 | Critical notification, critical reminder | TRANSIENT | reminder critical is a plain sneak peek | NEW rank; never dropped, may not be preempted by lower ranks |
| 6 | System HUDs: volume, brightness, backlight, Bluetooth, AirPods mode, Caps Lock toggle | TRANSIENT | chain 4 | coalesce per type; Bluetooth not preempted by volume inside its own TTL (fixes B6); replaces the volume-only suppression hack |
| 7 | App notification (normal and high) | TRANSIENT | none | NEW; a user-initiated HUD (rank 6) preempts it and it RESUMES with its remaining TTL |
| 8 | Caps-lock persistent indicator | STICKY | chain 5 | none |
| 9 | Music live activity (+ badge) | STICKY | chain 6 | none |
| 10 | Timer | STICKY | chain 7 | none (but see DECISION D1) |
| 11 | Reminder | STICKY | chain 8 | none |
| 12 | Recording | STICKY | chain 9 | exempt from B1 size precedence |
| 13 | Download | STICKY | chain 10 (effective: above 9-12, B7) | DECISION D1: keep "download takes over while it runs" (today's behaviour) but make it explicit rank 8.5 instead of an accident of dead expansion guards; or demote below 9-12 to match the written order |
| 14 | LocalSend | STICKY | chain 11 | none |
| 15 | Focus / DND live activity | STICKY | chain 12 | none |
| 16 | Extension standalone (own sort by priority, arrival) | STICKY | chain 14 | `critical` extension may use rank 5 via the same API |
| 17 | Shelf inline | AMBIENT | chain 15 | none |
| 18 | Idle animation | AMBIENT | chain 16 | none; additionally governed by the playback planner (section 7.4) |

Determinism rules (all testable with a fake clock):
1. Total order key: `(rank, subrank, arrivalSeq)`. `arrivalSeq` is a counter incremented on the main actor when an event is accepted. Wall-clock time and dispatch-hop order never break ties.
2. All writes enter through one `@MainActor` function (today `toggleSneakPeek` and `toggleExpandingView`); the `DispatchQueue.main.async` hop and the shared `sneakPeekDuration` field are removed, so FIFO of the main actor is the only ordering.
3. Every transient carries `(token, ttl, remaining)`. Hide requests must present the token; a hide for a non-current token is a no-op (fixes B3, B4, B5).
4. TRANSIENT preemption: higher rank preempts lower; the preempted item keeps `remaining` and resumes unless expired; equal rank: same dedupe key replaces, otherwise FIFO in a queue capped (default 5) with oldest-lowest-rank evicted.
5. STICKY items are not queued; the winner is the best `(rank, subrank, arrivalSeq)` among those whose condition holds. Priority never changes a sticky item's own timer.
6. SAFETY and STRUCTURAL are never preempted by TRANSIENT or below.
7. One pure function `resolve(snapshot) -> surface` owns the answer; ContentView's chain, `dynamicNotchSize`, `calculateRequiredNotchSize` and `resolvedClipShape` all consume its result (kills the three-copy problem).

---

## 3. THE EXISTING IDLE ANIMATION PIPELINE

### 3.1 Data model `[OBSERVED models/Constants.swift:70-136]`

- `CustomIdleAnimation` {id: UUID, name, source: AnimationSource, speed: CGFloat = 1, isBuiltIn}, `Codable, Hashable, Defaults.Serializable`.
- `AnimationSource`: `.lottieFile(URL)` (local file or bundle file), `.lottieURL(URL)` (remote).
- `AnimationTransformConfig` {scale 1, offsetX 0, offsetY 0, cropWidth 30, cropHeight 20, rotation 0, opacity 1, paddingBottom 0, expandWithAnimation false, loopMode loop}; `AnimationLoopMode` {loop, playOnce, autoReverse}.
- Three Defaults keys: `customIdleAnimations: [CustomIdleAnimation]` (`:1028`), `selectedIdleAnimation: CustomIdleAnimation?` (`:1029`), `animationTransformOverrides: [String: AnimationTransformConfig]` keyed by UUID string (`:1030`); plus the enable toggle `showNotHumanFace` default false (`:1027`).
- Two sources of truth: the selection is a COPY of the list element (not an id), so edits and deletes must patch both (`IdleAnimationManager.swift:241-244`, `AnimationEditorView.swift:486-494`).

### 3.2 Storage

- Files: `~/Library/Application Support/DynamicIsland/IdleAnimations/<UUID>.json`, created in `IdleAnimationManager.init` (`:27-35`). Note the folder name is `DynamicIsland`, not `Atoll`; other Atoll data is under `AtollExtensions/`, `Atoll/`.
- Metadata: `UserDefaults.standard` via Defaults (URLs and numbers only; animation data never goes into defaults).
- Built-ins: 4 JSONs from the app bundle, `Dog waiting`, `Moody Dog`, `Orange Cat Peeping`, `Reindeer` (`:107-123`), 24-30 fps, canvases 1080-2560 px, 1-11 layers (measured from `LottieAnimations/*.json`). They are stored with ABSOLUTE bundle URLs.
- FINDING (observed on this Mac): `defaults read com.ebullioscopic.Atoll selectedIdleAnimation` returns `source.lottieFile._0 = file://<repo>/dist/Atoll.app/Contents/Resources/Orange%20Cat%20Peeping.json`, `showNotHumanFace = 1`, while `local/install.sh` runs the app from `~/Applications/Atoll.app`. `initializeDefaultAnimations()` only adds built-ins whose NAME is missing (`IdleAnimationManager.swift:69-77`), so a stale path is never repaired. The installed app currently reads its idle animation from the build folder; rebuilding/deleting `dist/` or moving the app silently blanks the animation. `LottieUI` reports a load failure only through an unobserved Combine subject (`onDownloaded`), so the UI shows nothing.
- Imported-by-user directory on this Mac is empty; no overrides stored.

### 3.3 Accepted formats and validation

| Input | Accepted today | Check performed |
|---|---|---|
| Local `.json` | yes (`UTType.json` file importer, `IdleAnimationsSettingsSection.swift:135-141`) | extension is `json` (`IdleAnimationManager.swift:155-157`); `JSONSerialization.jsonObject` succeeds (`:160-163`) |
| Remote `http`/`https` URL | yes; stored as `.lottieURL`, never downloaded or cached to disk | none; plain `http` allowed because `NSAllowsArbitraryLoads` is true (`Info.plist:6-8`); loads at every notch render; fails silently offline |
| `.lottie` (dotLottie zip), GIF, APNG, PNG sheet, video | no | n/a |
| Size / dimensions / frame count / fps / layers / external assets | not checked | n/a (so a 50 MB or `{}` or `[]` file imports "successfully") |

### 3.4 Playback: loop, speed, scale, position, and what actually applies

Render path `components/IdleAnimationView.swift:24-88`: `LottieView(state: LUStateData(type: .loadedFrom(url), speed:, loopMode:))` then `.frame(cropWidth*scale, cropHeight*scale)`, `.offset`, `.rotationEffect`, `.opacity`, `.padding(.bottom)`, `.clipped()`. It sits in the right wing of the closed notch inside a `sideSize = effectiveClosedNotchHeight - 12` square (`ContentView.swift:1363-1378`), so default 30x20 is clipped by the wing.

Verified in the pinned LottieUI source (`jasudev/LottieUI@0cd5b54`, `[WEB W11]`):
- `LUContent.makeNSView` builds the Lottie view once from the state (speed, loop mode, URL). `updateNSView` only applies `value`/`isControlEnabled` and `setSize`. Therefore changing speed or loop mode on a live `LottieView` does nothing unless the view is re-created. `IdleAnimationView` re-creates through `.id(...)` (works). `AnimationEditorView`'s preview does NOT (`:172-185`), so the Playback Speed slider and Loop picker do not affect the live preview. `[INFERRED from source; needs one live check]`
- URL load errors are only published on `state.onDownloaded`, which Atoll never subscribes to.
- No stop on disappear, no pause API exposed.

Editor save logic `AnimationEditorView.swift:457-517`:
- Existing animation: only `animationTransformOverrides[id]` is written; `name` and `speed` are edited in the UI but discarded (`:477-498`). The `.onChange(of: editedAnimation)` branch for existing items in `IdleAnimationsSettingsSection.swift:168-195` is therefore dead.
- New import: the whole `AnimationTransformConfig` is built (`:463-474`) then thrown away; only `speed` reaches the manager (`:501-505`). Scale/offset/crop/rotation/opacity/loop mode set during import are lost.
- `expandWithAnimation` has no reader anywhere in the app (the help text promises the notch widens).

When it plays and stops: the view exists only while the idle branch wins (section 2.2, row 16): closed notch, nothing above it in the chain, `!isPlaying && isPlayerIdle` (idle becomes true 3 s after pause), toggle on, not fullscreen-hidden. It starts at frame 0 every time, loops forever by default, and is destroyed on notch open/hover-open, on any higher surface, and on lock (window hidden).

### 3.5 Energy cost

- Rendering: Lottie 4.5.2 default `.automatic` engine; the Core Animation engine renders in the render server without app main-thread work but supports only a subset, otherwise Lottie falls back to the main-thread engine `[WEB W8]`. Atoll sets no `LottieConfiguration` for idle. UNKNOWN which engine each bundled file gets.
- Timers: none of its own. Continuous compositing of the notch window for as long as the animation loops at 24-30 fps.
- Main-thread work in `IdleAnimationView`/`AnimationContentView` bodies: two `print` calls per evaluation (`IdleAnimationView.swift:49-50`), `getTransformConfig()` prints and decodes `Defaults[.animationTransformOverrides]` from UserDefaults JSON each time (`Constants.swift:86-94`). ContentView re-evaluates on any publish from 18 observed objects, including 1 Hz timer and reminder ticks (`docs/PERFORMANCE-AUDIT.md` section 0 item 3, B4). `print` is not stripped in release builds.
- Settings gallery: every card runs its own looping Lottie for as long as the Appearance tab is visible (`IdleAnimationsSettingsSection.swift:365-387`).
- Measured here, not isolating: with the idle toggle ON in the user's defaults, `top` on the running installed app (pid 78050), five 4-second samples: CPU 0.4-0.5 %, idle wake-ups steady at 42-43, power 0.4-0.5. Whether the animation was on screen at the time is UNKNOWN, so this is a ceiling for "app idle with feature enabled", not the animation's own cost. A proper A/B needs `local/perf/measure.py` with the toggle on vs off.
- No pause on: display sleep (`screensDidSleep` is only observed by `SiriVisibilityMonitor.swift:66`), Low Power Mode (observed elsewhere: `BatteryActivityManager.swift:80`, `SiriVisibilityMonitor.swift:76`, but not by idle), screen lock (window hidden but view not paused), user inactivity, battery power.

### 3.6 Reduce Motion

Zero handling in `Toplet/`. Public API exists: `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (macOS 10.12+) with `accessibilityDisplayOptionsDidChangeNotification` `[WEB W3]`. Lottie only honours a marker literally named "reduced motion" `[WEB W4]`.

### 3.7 What `AnimationEditorView` does

A 860x620 sheet (`AnimationEditorView.swift:93-95`): header (name), live preview canvas at 1-10x zoom with a dashed 30x20 notch-bounds rectangle (`:157-188`, `:190-236`), controls for name, speed (0.1-3x), loop mode, scale (0.1-5x), crop width/height (5-100), offsets (-50..50), bottom padding, rotation, opacity, the unused expand toggle, quick presets (Fit, Fill, Scale up 2x, Scale down, Reset All). Footer button "Import" or "Save Changes". Bugs listed in 3.4.

---

## 4. EXISTING NOTIFICATION-LIKE SURFACES

### 4.1 Producers of transient content in the notch today

| Producer | Entry point | Slot and fields | Text/icon source |
|---|---|---|---|
| Volume, brightness, keyboard backlight | `managers/SystemChangesObserver.swift:299`, `:348`, `:388`; Lunar `managers/LunarManager.swift:354`, `:377`; BetterDisplay `managers/BetterDisplayManager.swift:281`, `:305` | `sneakPeek` with `value`, 1.5 s | no text; icon string optional |
| Bluetooth connect, AirPods listening mode | `managers/BluetoothAudioManager.swift:1945`, `:2009` | `sneakPeek(.bluetoothAudio)`, 2.5 s; value is battery 0-1, or `-1` as the "AirPods mode" sentinel | SF Symbol only |
| Caps Lock | `managers/CapsLockManager.swift:81-97` | `sneakPeek(.capsLock)` infinite plus a chain fallback branch | none |
| Music track change/play | `managers/MusicManager.swift:1530-1543` | `sneakPeek(.music)` (standard) or `expandingView(.music)` (inline); default off (`Constants.swift:1060`) | read live from `MusicManager` |
| Reminder / calendar event | `managers/ReminderLiveActivityManager.swift:502`, `:519` | `sneakPeek(.reminder)` with icon names | text built in ContentView from `reminderManager` (`ContentView.swift:1322-1341`) |
| Extension live activity | `managers/Extensions/ExtensionLiveActivityManager.swift:208` | `sneakPeek(.extensionLiveActivity(bundleID,activityID))` with title, subtitle, accent | descriptor fields; standard style only (`:193-202`) |
| Battery HUD | `models/BatteryStatusViewModel.swift:216` | `expandingView(.battery)` + view-model state | `BatteryTemporaryActivityView` |
| Download | `managers/DownloadManager.swift:564`, `:593`, `:614` | `expandingView(.download)` + `@Observable` state | `DownloadLiveActivity` |
| Recording | `managers/ScreenRecordingManager.swift:432`, `:443` | `expandingView(.recording)` | `RecordingLiveActivity` |
| Lock | `managers/LockScreenManager.swift:270`, `:342` | `expandingView(.lockScreen)` | separate lock-screen windows |
| Focus on/off | `DoNotDisturbManager.swift` published state (`isFocusToastDismissing`) | no coordinator slot | `DoNotDisturbLiveActivity` |
| LocalSend, connectivity, privacy, shelf, timer | own `@Published` state, no coordinator slot | | their own views |
| Shortcut | `DynamicIslandApp.swift:1049-1058` toggles a music sneak peek for 3 s | | |

Unused enum cases (`SneakContentType`: `mic`, `download`, `timer`, `recording`, `doNotDisturb`, `privacy`, `lockScreen` have no `toggleSneakPeek` caller; `expandingView` types `timer`, `reminder`, `doNotDisturb`, `privacy` have no caller): `DynamicIslandViewCoordinator.swift:23-40`.

### 4.2 How an app-originated notification can ride the same pipeline

Needed rendering fields (source icon, title, preview, accent) already exist in the `sneakPeek` struct except the app icon, which can travel in the existing `icon` string with a reserved prefix (for example `app:<bundleID>`) and be resolved with `NSWorkspace` at draw time, so the struct needs no new stored field.

Option A (recommended): one new `SneakContentType` case, `.notification(id:)`, produced by a new `NotificationQueue` through the existing `toggleSneakPeek`. Costs: add the case to `==` (`DynamicIslandViewCoordinator.swift:43-66`), exclude it from the two copy-pasted type lists (`ContentView.swift:1113`, `:1167`), add one rendering branch, and one tap hook (`ContentView.swift:705-715`). Content stays in memory only.

Option B (rejected): post as `.extensionLiveActivity` with a synthetic bundle id. It reuses rendering but (1) persists plaintext to `live_activities.json` and broadcasts it system-wide (B12, A11), (2) never expires, (3) cannot draw an app icon in the sneak peek, (4) pushes Atoll's own notifications through the authorization/RPC trust path.

Option C (rejected): a new window or panel for notifications. It would duplicate window/space/level management that `DynamicIslandWindow` and `NotchSpaceManager` already solve, and break the "notch is the surface" model.

---

## 5. SUPPORTED NOTIFICATION SOURCES: FEASIBILITY

STATEMENT: macOS provides NO public API for one app to observe or read other apps' notifications. `UNUserNotificationCenter` is documented as the object "for managing notification-related activities for your app or app extension" and every method is scoped to the calling app's own notifications `[WEB W1]`. Confirmed in the macOS 27.0 SDK header on this Mac: `UNUserNotificationCenter.h` exposes `getDeliveredNotifications`, `getPendingNotificationRequests`, `add`, remove, categories, settings, badge, delegate; no observer, no cross-app query `[SDK UserNotifications.framework/Headers/UNUserNotificationCenter.h:42-103]`. Community consensus is the same: "It is not possible. You can't observe user notifications sent by applications unless an application provides a specific API" `[WEB W5]`, and "UNUserNotificationCenter appears to be restricted to notifications generated by the current application" `[WEB W7]`. Atoll today uses none of these APIs (grep for `UserNotifications`, `UNUserNotificationCenter`, `INFocusStatus`, `import Intents`: 0 hits).

Product copy must therefore say: "Atoll shows notifications from Atoll itself, apps that integrate with it, the `atoll-notify` command, calendar and reminders, and AI agents you enable. It does not read other apps' macOS notifications."

| Source | Class | How | Permission | Notes and risks |
|---|---|---|---|---|
| Atoll's own `UNUserNotificationCenter` | SUPPORTED, public | Atoll posts or receives its own notifications; `willPresent` lets Atoll route its own banner into the notch instead | `requestAuthorization` prompt | Only for Atoll features that would otherwise post; a duplicate of the timer/reminder surfaces unless used for click actions or history. Works for an ad-hoc-signed accessory app: UNKNOWN, must test. Obeys Focus automatically. |
| AtollExtensionKit XPC and RPC | SUPPORTED (Atoll's own API) | Third-party apps present live activities (title, subtitle, app icon, priority, sneak-peek config) `[WEB W11]` | `ExtensionAuthorizationManager` entry | Gaps found: no click callback; payload persisted and broadcast in plaintext (B12/A11); RPC auto-authorizes any caller and trusts self-declared bundle id (B13); rate limit never enforced; XPC needs the `mach-services` entitlement that `local/assemble.py` removes for ad-hoc signing (`docs/BUILD-ISSUES-AND-FIXES.md` item 13), so in this local build only the loopback WebSocket path (9020) can work `[INFERRED]`. Good for apps that opt in; not the transport for a CLI. |
| Local CLI / socket `atoll-notify` | SUPPORTED if built (new) | Same-user process writes a short JSON line to a UNIX socket; a tiny shell wrapper around `/usr/bin/nc -U` | none beyond same-uid peer check | Use the transport design already written in `AtollAgents/Core/AgentSocketServer.swift` (0700 directory, 0600 socket, `LOCAL_PEERCRED`, 1 MiB cap, 2 s read deadline, 64 connections, fail-open) and documented as preferred over the WebSocket in `docs/AI-AGENTS-RESEARCH.md` section 0 item 7. That server is untracked and unintegrated and its framing validates `agent` as `claude|codex`, so either add a `notify` message kind there (preferred, one socket, one parser) or wait for the Agents integration. Trust model: any process of the same user can post; show provenance ("via CLI") and rate-limit. |
| AI-agent hooks (`AtollAgents/`) | SUPPORTED (opt-in hooks, public agent hook APIs) | `AgentEventPayload.notification(NotificationKind, message, title)` already models Claude/Codex notification events (`AtollAgents/Core/AgentEvent.swift:58-68`, `:68-100`); hooks install is a `NoopHookInstaller` today (`Core/HookInstalling.swift`) | agent config edits are explicit and previewed | Producer for the queue (approval needed, finished, failed). It brings its own closed indicator (`AgentsClosedIndicator.swift`), which must get a rank in section 2.7 when integrated. Not integrated yet. |
| EventKit (Calendar, Reminders) | SUPPORTED, public, already integrated | `CalendarServiceProviding` (`requestFullAccessToEvents/Reminders`, `Providers/CalendarServiceProviding.swift:57-59`), `.EKEventStoreChanged` observer (`CalendarManager.swift:82`), `ReminderLiveActivityManager` | already granted by users of the feature | Keep as is: it already produces the right surface; feed the same queue only for dedupe/Focus/privacy policy, do not rebuild. |
| Focus status | PARTIAL public + current private | Public: `INFocusStatusCenter.default.focusStatus.isFocused` (macOS 12+, `requestAuthorization`, `[SDK Intents.framework/Headers/INFocusStatusCenter.h:12-28]`, `[WEB W2]`) returns only an optional Bool ("the user's preference for receiving communication notifications"), no mode name, no change callback in the header | user authorization; Info.plist usage string name `NSFocusStatusUsageDescription` is recalled, not verified in this SDK: UNKNOWN | Current code uses private names and Full Disk Access JSON (section 1.A, A10). Recommendation: keep `DoNotDisturbManager` as the single Focus source for gating, optionally add `INFocusStatusCenter` as a fallback when FDA is absent; whether it returns data for a non-communication app: UNKNOWN. |
| Mail | UNSUPPORTED natively; user-assembled possible | No public new-mail event API. Users may attach a Mail rule that runs a script which calls `atoll-notify` (Mail rules can run AppleScript `[WEB W9]`) | Mail Automation | Atoll never reads Mail. Rule-script reliability on current macOS is anecdotal: UNKNOWN. |
| Messages | UNSUPPORTED | No public hook; the `chat.db` store needs Full Disk Access `[WEB W10, third-party]` | FDA | Not implemented. Do not build. AppleScript event handlers for Messages on macOS 26/27: UNKNOWN, do not rely. |
| Notification Center database (`usernoted`) | UNSUPPORTED / private, NOT IMPLEMENTED | `~/Library/Group Containers/group.com.apple.usernoted/db2/db` since macOS 15; TCC-protected, undocumented schema (binary plist blobs) `[WEB W6]` | Full Disk Access | Undocumented, schema can change any release, reads every app's private message text, and Apple moved it specifically to protect it. Classified: not implemented. Atoll already asks for FDA for Focus only; do not widen that use. |
| Accessibility scraping of Notification Center banners | EXPERIMENTAL, NOT RECOMMENDED | AX observer on `com.apple.notificationcenterui` (`AXNotificationCenterBanner` subrole) `[WEB W5, W7]` | Accessibility (`AXIsProcessTrusted`, already requested for `MenuBarLayout`) | Described by its own users as unreliable ("sometimes stops working, without explanation", `AXLayoutChanged` fires on hover; Late Night forum shows view-hierarchy paths that vary by OS version) `[WEB W5, W7]`. It would also create banners twice (Apple's and Atoll's) because banners cannot be suppressed. Not recommended; if ever offered it must be behind a clearly labelled experimental toggle, off by default, with no claim of completeness. |
| Distributed notification wildcard | UNSUPPORTED | `nil`-name observers are not supported since macOS 10.15 and other apps do not post notifications there `[WEB W5 comment]` | n/a | Atoll already has an expensive wildcard observer for Bluetooth (`docs/PERFORMANCE-AUDIT.md`); do not add more. |

---

## 6. INTEGRATION POINTS (ordered, fewest existing files)

Convention: NEW = new file under `Toplet/` (picked up by the synchronized Xcode group `PBXFileSystemSynchronizedRootGroup` and by `local/prepare.py`, which copies every `Toplet/**/*.swift`; no project edit). EDIT = existing file. Risk H/M/L.

### 6.1 New pure logic (no UI, no risk to running code)

| Step | File | Content |
|---:|---|---|
| N1 | NEW `helpers/NotchEventArbiter.swift` | `NotchSurfaceRank`, `ClosedNotchSurface`, `ClosedNotchSnapshot`, `resolveClosedNotchSurface(_:)`, `SneakPeekScheduler` (value type: offer/resume/expire/finish(token)), fake-clock friendly. Precedent: `helpers/ClosedMusicPairingVisibility.swift`, `helpers/RecordingHUDLayout.swift`. |
| N2 | NEW `helpers/NotificationQueue.swift` | `NotchNotification`, dedupe, TTL, rate limit, privacy redaction, Focus policy; no AppKit. |
| N3 | NEW `helpers/IdleAnimationModels.swift` | Defaults-free Codable model (see section 7.3) so tests can compile it with plain `swiftc`; `Defaults.Serializable` conformance stays in `Constants.swift`. |
| N4 | NEW `helpers/IdleAnimationValidation.swift` | Lottie and sprite-sheet validators. |
| N5 | NEW `helpers/IdleAnimationPlayback.swift` | pure `PlaybackPlanner`. |

### 6.2 Existing files, in the order to touch them

| Step | File and lines | Change | Risk |
|---:|---|---|---|
| E1 | `models/Constants.swift` after `:1030` and `:1061`; model block `:70-136` | New Defaults keys (7.2); extend `CustomIdleAnimation` with OPTIONAL fields only. Non-optional fields with defaults break decoding of existing stored blobs because synthesized `Codable` does not use defaults for missing keys, and `Defaults` then falls back to `[]`, losing every user animation. Use optionals or a custom `init(from:)`. Add a migration function beside `migrateClipboardShortcutToV` (`:1536-1630`) | M |
| E2 | `DynamicIslandViewCoordinator.swift:23-88`, `:322-410` | Add `.notification(id:)` to `SneakContentType` and `==`; add `priority`/`token` to `sneakPeek`; replace the shared duration field and the `DispatchQueue.main.async` hop with a single `@MainActor` path calling `SneakPeekScheduler`; hide by token; default priority derived from `type` so the 12 existing call sites compile unchanged | H (one choke point, 12 callers) |
| E3 | `ContentView.swift`: (a) `:1097-1164` replace chain by `switch resolve(snapshot)`; (b) `:112-243` and `:612-636` consume the same resolved surface; (c) `:1113`, `:1167` replace the two long type lists with `type.rendersAsInlineHUD`; (d) new branch for notification compact view; (e) `:705-715` tap handler asks the notification layer first; (f) `:808-817` pause TTL while hovering | H for (a)-(b); L for (c)-(f) | H/L |
| E4 | `DynamicIslandApp.swift:491-610` | Consume the same resolved surface; only needed if a surface can exceed the default 640x200 window | M |
| E5 | `DynamicIslandApp.swift` near `:753`, `:785-790` | Start the ingestion facade and set the `UNUserNotificationCenter` delegate | L |
| E6 | `components/Settings/SettingsView.swift` | Lowest touch: call `NotificationsSettingsSection()` from `LiveActivitiesSettings` (`:4593`), keep Idle in Appearance (`:5182`), call `IntegrationsSettingsSection()` from `ExtensionsSettingsView` (`ExtensionsSettings.swift:44-49`), add search entries beside `:373` and `:411`. Dedicated tabs would require 5 exhaustive `switch` edits (`:74-138`, `:1023-1116`) plus search index | L (sections) / M (tabs) |
| E7 | `managers/IdleAnimationManager.swift` | Add `validate(...)`, `importSpriteSheet(...)`, `resolveBuiltIn(...)` (resolve by name, never persist bundle URLs), `reset()` and preset registry. Do NOT add a second manager. | M |
| E8 | `components/IdleAnimationView.swift` | Remove `print`s, cache `AnimationTransformConfig` lookup, ask `PlaybackPlanner`, render preset/sprite/Lottie, add `scenePhase`/`occlusion` pause | M |
| E9 | `components/Settings/AnimationEditorView.swift:457-517`, `IdleAnimationsSettingsSection.swift` | Fix existing-edit save (name, speed), persist transform on first import, re-create the preview on speed/loop change (`.id`), add Reset, accept sprite PNG | M |
| E10 | `Info.plist` / pbxproj `INFOPLIST_KEY_*` and `local/assemble.py` Info.plist writer | Only if `INFocusStatusCenter` is adopted (usage string) | L but touches build config |
| E11 | `local/tools/make_resources.py` | Only if bundled preset assets are added. Avoid: ship presets procedurally | n/a |

Minimum viable notification path (touches only E1, E2, E3c-f, E5, E6): about 120 changed lines in existing files plus N2 and the new views.

---

## 7. DESIGN PROPOSAL

### 7.1 Components mapped onto existing types

| Proposed | Is | Reuses | Does not become |
|---|---|---|---|
| `NotchEventArbiter` (N1) | A pure namespace: `resolveClosedNotchSurface`, `SneakPeekScheduler` | state stays in `DynamicIslandViewCoordinator` (`sneakPeek`, `expandingView`) and the managers | a second engine or a second state store |
| `NotificationQueue` (N2) | Pure value type: accept, dedupe, privacy-redact, Focus-gate, order, expire | feeds `coordinator.toggleSneakPeek(type: .notification(id:))` | a presenter |
| `NotchNotificationCenter` (thin, `managers/`) | `@MainActor` ingestion facade: Atoll `UNUserNotificationCenterDelegate`, socket reader, extension and agent adapters; owns one `NotificationQueue` | `DoNotDisturbManager.shared.isDoNotDisturbActive` for Focus, `ExtensionAuthorizationManager` for third-party trust | an `ObservableObject` ContentView observes (avoids one more of the 18 invalidation sources) |
| `NotificationSneakPeekView` (NEW view) | Compact (icon + title) and expanded (icon, title, 2-line preview, actions) | wing sizing helpers in `ContentView`, `MarqueeText`, icon resolution like `ExtensionIconView` | a new window |
| `IdleAnimationLibrary` | Not a type: extra functions on the existing `IdleAnimationManager` | its storage dir, `customIdleAnimations`, `selectedIdleAnimation` | a second manager |
| `PlaybackPlanner` (N5) | Pure decision: play / pause / static frame / fps cap | existing signals (`hideOnClosed`, `isLocked`, `notchState`, resolved surface) | a timer |

### 7.2 Persistence keys (Defaults, all additive)

Notifications (all default off or conservative):
`notchNotificationsEnabled` Bool false; `notchNotificationDuration` Double 4; `notchNotificationMaxQueue` Int 5; `notchNotificationDedupeWindow` Double 10; `notchNotificationPrivacyMode` enum {off, hidePreview, hideAll} default hidePreview; `notchNotificationFocusPolicy` enum {show, silence, silenceExceptCritical} default silenceExceptCritical; `notchNotificationSourcesEnabled` [String: Bool] (atollSelf, extensions, cli, agents, calendar); `notchNotificationCLIEnabled` Bool false; `notchNotificationRatePerMinute` Int 30; `notchNotificationClickAction` enum.

Idle animation (existing four keys kept): add `idleAnimationLibraryVersion` Int (migration), `idleAnimationRespectReduceMotion` Bool true (locked on, shown for transparency), `idleAnimationPauseOnLowPower` Bool true, `idleAnimationInactivityMinutes` Int 10 (0 = never), `idleAnimationMaxFPS` Int 24, `idleAnimationAllowRemoteURL` Bool false.

Persistence rules: no animation bytes in Defaults; files under the existing `~/Library/Application Support/DynamicIsland/IdleAnimations/` (`<UUID>.json`, `<UUID>.png`); built-ins identified by stable `presetID`/bundle name and resolved at launch, never by absolute URL; a one-time migration rewrites stale absolute built-in URLs (the live defect in 3.2).

Extended model (all NEW fields optional so old blobs still decode):
`CustomIdleAnimation { id, name, source, speed, isBuiltIn, kind: String?, presetID: String?, sprite: SpriteSheetSpec?, schemaVersion: Int? }`, `SpriteSheetSpec { columns, rows, frameCount, fps, frameWidth, frameHeight, loop }`, presets: `breathing`, `pulse`, `eyes` drawn procedurally with `TimelineView(.animation(minimumInterval:, paused:))` and a frozen-time hook for tests (the technique in `AtollAgents/UI/AgentsMotion.swift`).

### 7.3 Validation rules (pure, tested)

Lottie JSON: top-level object; `v` string, `fr` in 1...120, `op > ip`, `w`,`h` in 1...4096, `layers` array 1...200, file <= 2 MiB, no `assets[].u` http(s) or absolute `p` paths (no external fetch), asset data URIs total <= 1 MiB, reject unknown huge expression strings (`x` fields > 4 KiB), duration `(op-ip)/fr` <= 60 s. Sprite sheet: PNG/JPEG via ImageIO (no decode of pixels beyond size), pixels <= 16 MP, `columns*rows >= frameCount`, frame dimensions integral, `fps` 1...30, `frameCount` 2...240, image decode validated at import by cropping frame 0 and last. Remote URL: off by default; when allowed https only, download once into storage and validate like a local file, never stream at render.

### 7.4 Playback planner (energy and Reduce Motion)

Inputs: resolved surface, `notchState`, `hideOnClosed`, `isLocked`, screens asleep, `ProcessInfo.isLowPowerModeEnabled`, `accessibilityDisplayShouldReduceMotion`, seconds since last user event (`CGEventSource.secondsSinceLastEventType`, no permission required), hover. Output: `.play(fps)`, `.pauseAtFrame(0)` (static), `.unmounted`. Rules: Reduce Motion -> static first frame always; lock/display asleep/fullscreen/open -> unmounted; low-power or inactivity timeout -> static; higher surface -> unmounted but remember "was playing" so that returning does not restart in the middle of a transition. Sprite and preset renderers use `TimelineView(.animation(minimumInterval: 1/fps, paused: !plan.isPlaying))`. Lottie keeps its engine; `LottieAnimationView.pause()/play()` via a small custom `NSViewRepresentable` in place of `LottieUI` for the idle path so speed/loop/pause are real (this also fixes the preview bug in 3.4); LottieUI stays for other uses.

### 7.5 Notification behaviour contract

Compact: closed-notch wings, icon left, title right wing marquee (reusing wing geometry); expanded: card below the notch (the battery "standard" pattern: +height, rounded bottom shape) on hover or click; hover pauses TTL; tap performs the item's action (open URL, activate bundle id, or open notch) and dismisses; swipe-up dismisses; dedupe key `(sourceID, threadID or title hash)` inside the window; Focus: with `silenceExceptCritical` items are held in an in-memory history (not shown) and critical are shown; privacy mode `hidePreview` shows app icon and name only, `hideAll` shows a dot; privacy applies before any logging or persistence; notification text is never written to disk or distributed notifications.

### 7.6 Test plan (no Xcode required)

All runnable with Command Line Tools; no XCTest (it is absent here, `docs/TEST-RESULTS.md`). Wire into `local/tests/run.sh`.

| ID | What | How | Pattern to copy |
|---|---|---|---|
| T1 | Arbiter equivalence: new resolver equals the old chain for all snapshots, except an allow-listed set of intentional changes (B8 privacy lift, B1) | Transcribe the old chain (`ContentView.swift:1097-1164` + badge resolver `:1508-1540`) as a reference oracle in the test; enumerate pruned boolean combinations plus seeded random; diff | `tests/test_timer_lifecycle.py` compiling real sources with `swiftc` |
| T2 | Scheduler scenarios B2-B6, B10 as regression tests with a fake clock; invariants: one active item, hide requires matching token, no state with `show == true` and no pending expiry, preempt-and-resume remaining TTL, deterministic under permuted arrival hops | seeded fuzz of 10^5 event sequences | `AtollAgents/Tests/run_core.sh` + `CoreTestSupport.swift` |
| T3 | Queue: dedupe window, rate limit, cap eviction order, Focus policies, privacy modes (assert no preview substring reaches the output under `hidePreview` and `hideAll`), expiry on dequeue | pure Swift | same |
| T4 | Lottie validator: the 6 bundled JSONs must pass; negative fixtures `{}`, `[]`, NaN fps, `op<=ip`, 100k layers, external `u`/`p`, oversize, deeply nested JSON; sprite validator with PNGs generated by CoreGraphics at test time | pure Swift + ImageIO | `tests/test_cursor_quota_payload.swift` |
| T5 | Playback planner truth table (Reduce Motion, low power, lock, sleep, inactivity, surface, hover) | pure Swift | same |
| T6 | Migration: decode the real legacy blob (shape captured from this Mac's `selectedIdleAnimation`) and an old `AnimationTransformConfig` without the new fields; stale absolute built-in URL rewritten; unknown fields ignored; empty storage dir | pure Swift on `IdleAnimationModels.swift` | same |
| T7 | Offscreen SwiftUI snapshots: notification compact and expanded (long title, long preview, no icon, privacy modes, Reduce Transparency), idle presets at frozen times (strip of frames), Reduce Motion equals frame 0, sprite renderer frame stepping, all inside a notch-height frame with clipping assertions | `NSHostingView` + `bitmapImageRepForCachingDisplay` or `ImageRenderer`, injectable time and Reduce Motion environment | `AtollAgents/Tests/run_ui.sh`, `AtollAgents/UI/Snapshot/FilmStrips.swift`. Constraint: files compiled standalone must avoid `@State` and `#Preview` (SDK 27 macros need Xcode plugins; the local build rewrites them in `local/prepare.py`/`swiftxform.py`, bare `swiftc` does not). Real `LottieView` is excluded from this harness (binary xcframework); cover it in T9. |
| T8 | Socket security: peer uid rejection, path perms 0700/0600, oversize, slow-loris deadline, malformed JSON, rate limit | reuse the server tests | `AtollAgents/Tests/CoreTestsServer.swift` |
| T9 | Live launch checks: launch `dist/Atoll.app`, post notifications via `atoll-notify`, assert notch window frame via `CGWindowList` (no permission needed, as in `docs/TEST-RESULTS.md`), assert state through an env-gated `ATOLL_TRACE_NOTCH=1` log of the resolved surface (no screen-capture permission), then check idle Lottie playback by importing a fixture and reading the trace; energy A/B (idle toggle off/on, each preset, sprite 12 fps) with `local/perf/measure.py` | scripted | `local/smoke.sh`, `local/perf/measure.py` |
| T10 | UNUserNotificationCenter and Focus probes: log `requestAuthorization` result and `INFocusStatusCenter.authorizationStatus` on the ad-hoc build (answers two UNKNOWNs) | tiny probe app under `local/tests` | `local/tests/asset_lookup.swift` style |

---

## 8. RISKS AND UNKNOWNS

| ID | Risk or unknown | Tag | Mitigation |
|---|---|---|---|
| R1 | Refactoring the chain (E3a) changes behaviour invisibly | high | T1 differential oracle; ship behind a compile-time flag first |
| R2 | `toggleSneakPeek` is the single choke point for 12 callers; changing its semantics (token, no async hop) can alter animation timing (`withAnimation` is applied inside the async block today) | medium | keep `withAnimation(.smooth(duration: 0.3))`, preserve default priorities per type, T2 |
| R3 | Adding fields to `CustomIdleAnimation` or `AnimationTransformConfig` can wipe the user's gallery on next launch | high | optional fields only, T6 against the real blob |
| R4 | One more observed object in ContentView increases whole-body re-evaluations (18 observed today) | medium | facade not observed; publish through the existing `sneakPeek` only |
| R5 | Extension path leaks content (plaintext on disk and in a system-wide distributed notification), auto-authorizes, spoofable identity, no rate limit | high | never route notification text through it; separately fix `rateLimited` and bundle-id check before advertising "apps can post notifications" |
| R6 | `UNUserNotificationCenter` behaviour for ad-hoc signed accessory app on macOS 27 | UNKNOWN | T10 |
| R7 | `INFocusStatusCenter` returns data for a non-communication app? usage-string key name? | UNKNOWN | T10, read Apple's current docs |
| R8 | Extension XPC may not function in the local build (entitlement removed) | INFERRED | test RPC only; do not depend on XPC |
| R9 | LottieUI preview/speed bug and which Lottie engine bundled files use | INFERRED / UNKNOWN | live check; replace with a small `NSViewRepresentable` for idle |
| R10 | Reduce Motion: Lottie reduced-motion marker semantics differ per file | WEB W4 | enforce Atoll's own rule, ignore Lottie's |
| R11 | Behaviour when the notch is opened while a standard sneak peek is visible (what is drawn, who dismisses) | UNKNOWN | read `ContentView.swift:1166-1249` against `vm.notchState` during T9 |
| R12 | Multi-display: screens are keyed by `localizedName` (docs A15); sneak peeks have no target screen (B11) | OBSERVED | pass a target screen from the facade; test with two displays (not possible here, BLOCKED) |
| R13 | AtollAgents integration changes the socket path and adds a closed indicator; two ingestion sockets would violate "no duplicate pipelines" | OBSERVED | decide ONE socket before building `atoll-notify` |
| R14 | Bundled Lottie assets come from LottieFiles under the Lottie Simple License (`NOTICE:10-12`); new presets must be original | OBSERVED | procedural presets; no downloaded art |
| R15 | `NSAllowsArbitraryLoads=true` and remote Lottie URLs conflict with the local-first goal (`docs/FREE-LOCAL-OPERATION.md`) | OBSERVED | remote import off by default, https only, download-once |
| R16 | Debug `print`s in release bodies (idle, `getTransformConfig`) add stdout and CPU on every invalidation | OBSERVED | remove in E8 |
| R17 | Privacy: notification text must not enter logs. `Logger.log` and `print` are used everywhere; Focus manager already prints state | OBSERVED | redact at queue level; lint test greps new files for `print(` |
| R18 | Idle animation shown on a Mac whose user enabled Reduce Motion today violates the system preference | OBSERVED | B9 in matrix; fix in planner |
| R19 | `hideOnClosed` defaults to `true` until fullscreen detection runs (`DynamicIslandViewModel.swift:45`): a notification posted at launch may be hidden | OBSERVED | queue holds until the first non-hidden state |
| R20 | Hover-open after a sneak peek ends can open the notch under the cursor (B-adjacent, `ContentView.swift:808-817`) | OBSERVED | pause TTL on hover; suppress hover-open for 0.4 s after a notification dismisses (`suppressHoverOpen` exists, `DynamicIslandViewCoordinator.swift:249-251`) |

Not verified in this audit (needs a person or Xcode): all UI behaviour at runtime, multi-display, Instruments energy numbers, TopletTests (XCTest unavailable).

---

## 9. Sources (web) and commands

Web (read 2026-10-21):
- W1 Apple, UNUserNotificationCenter: https://developer.apple.com/documentation/usernotifications/unusernotificationcenter
- W2 Apple, INFocusStatus / INFocusStatusCenter: https://developer.apple.com/documentation/intents/infocusstatus and https://developer.apple.com/documentation/intents/infocusstatuscenter
- W3 Apple, `NSWorkspace.accessibilityDisplayShouldReduceMotion`: https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion
- W4 lottie-ios `ReducedMotionOption`: https://github.com/airbnb/lottie-ios/blob/master/Sources/Public/Configuration/ReducedMotionOption.swift and https://swiftpackageindex.com/airbnb/lottie-ios/master/documentation/lottie/reducedmotionoption/reducedmotion
- W5 Stack Overflow, "Observe for new System Notifications OSX": https://stackoverflow.com/questions/45593529/observe-for-new-system-notifications-osx
- W6 9to5Mac, notification database moved in macOS Sequoia (Group Containers, TCC-protected): https://9to5mac.com/2024/09/01/security-bite-apple-addresses-privacy-concerns-around-notification-center-database-in-macos-sequoia/
- W7 Late Night Software forum, "Parsing Notifications in macOS Sequoia": https://forum.latenightsw.com/t/parsing-notifications-in-macos-sequoia/5001
- W8 Airbnb, Lottie 4.0 for iOS (Core Animation engine): https://medium.com/airbnb-engineering/announcing-lottie-4-0-for-ios-d4d226862a54
- W9 MacScripter, Mail rule triggering AppleScript: https://www.macscripter.net/t/no-applescript-triggered-by-mail-rule/75453
- W10 third-party article on Full Disk Access and the Messages database: https://blakecrosley.com/blog/macos-full-disk-access-ai-agents
- W11 Package sources at the pinned revisions: `Ebullioscopic/AtollExtensionKit@e2d30af` (`AtollLiveActivityDescriptor.swift`, `AtollLiveActivityPriority.swift`, `AtollIconDescriptor.swift`) and `jasudev/LottieUI@0cd5b54` (`LottieView.swift`, `View/LUView.swift`, `View/LUContent.swift`, `Model/LUStateData.swift`), fetched from raw.githubusercontent.com.

Local commands that produced evidence: `git status`, `grep -c AtollAgents project.pbxproj`; grep sweeps for `toggleSneakPeek(`, `toggleExpandingView(`, `accessibilityReduceMotion`, `UNUserNotificationCenter`, `INFocusStatus`, `rateLimited`, `expandWithAnimation`, `onScreen:`; SDK headers under `/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk`; read-only `defaults read com.ebullioscopic.Atoll selectedIdleAnimation|showNotHumanFace|customIdleAnimations|animationTransformOverrides|enableSneakPeek` (the app's own preferences, nothing modified); five `top` samples of the already-running app; `python3 -I` JSON read of `LottieAnimations/*.json` for fps, canvas and layer counts.
