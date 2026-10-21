# Atoll performance and wake-up audit

Audit of `Toplet/` on branch `local-build` (363 Swift files), 2026-10-21, macOS 27.2 / M2. **Read-only:** no source was edited, the app was not run, nothing was built. Companion: `docs/DEAD-CODE-REPORT.md`. Context read: `PERFORMANCE-REPORT.md` (idle baseline 0.0-0.7 % CPU), `LOCAL-ARCHITECTURE-AUDIT.md`, `FEATURE-MATRIX-A.md` section "C. Polling intervals".

Evidence tags: **OBSERVED** (file:line read, or command result), **INFERRED** (reasoned, not measured), **UNKNOWN**. Line numbers are from the tree at audit time. The line numbers in the user's `sample` output differ from the source by 1-21 lines (e.g. `osduiHelperPID` is at SystemOSDManager.swift:450, not :471), so the sampled binary was built from a slightly different revision (INFERRED); function names match. `DynamicIslandApp.swift` was being edited by another process during the audit, so its line numbers are approximate (`~`).

---

## 0. Summary

**Why the app is ~0.5 % idle and bursts to 8-20 % for ~10 s.** Idle is the sum of many small always-on tickers (section 2). The bursts are not one bug; four mechanisms line up (INFERRED, the sample cannot separate them):

1. **Restart storms re-arm fast schedules.** Every `startSystemObserver()` (SystemHUDManager.swift:301-330) is triggered by ten `Defaults.publisher` sinks (:41-207), by BetterDisplay/Lunar `isRunning` changes (:233-243), and indirectly by lock/unlock (`updateNativeHUDSuppressionForLockState`, :342-363 calls `disableSystemHUD()`) and by wake (SystemOSDManager.swift:76-86). Each call restarts the OSDUIHelper watcher with `stableChecks = 0` (SystemOSDManager.swift:384-418): 5 scans at 150 ms, then 15 at 500 ms = **8.25 s of elevated polling**, which matches the "~10 s" burst length. Restart also resets the media-key retry window to 30 retries at 2 s (MediaKeyInterceptor.swift:241-262, `stop()` -> `cancelTapRetry()` at :295).
2. **Bluetooth/AirPods notification handling runs on the main thread for every distributed notification on the system** (a wildcard `name: nil` observer, BluetoothAudioManager.swift:205-210), builds a string from `userInfo` each time (:369-385), and the listening-mode handlers re-parse it (:2041, :2612, :2637, :2706). Notification rates rise exactly when AirPods/audio are active, which is when bursts were sampled. If `readListeningModeViaDynamicSelectors` returns nil the fallback is `ioreg -r -l -w 0` (full IORegistry dump) read and `lowercased()`-filtered line by line **inside `MainActor.run`** (:1963-1976, :2106-2145). Whether that path was hit: UNKNOWN.
3. **ContentView re-evaluates its whole body** (3,321-line file, 18 `@ObservedObject`, 46 `@Default`, 71 `Defaults[...]` reads) on any publish from any observed object, including ones its body never reads (`statsManager`, `localSendService.sendProgress`, `timerManager.remainingTime` at 1 Hz, `reminderManager.currentDate` at ~1 Hz). Each evaluation re-runs the 15-branch `NotchLayout()` chain and reads Defaults (UserDefaults + bridge decode) dozens of times.
4. **Four `panGesture` modifiers install 8 scroll-wheel monitors (4 global)** (ContentView.swift:731-745, PanGesture.swift:95-101): every scroll event anywhere on the system wakes the main thread 4 times and does window/view coordinate conversion before rejecting it.

**The OSD watcher is a steady contributor, not the burst driver.** Measured here (OBSERVED, ctypes calling the same `proc_listpids` + `proc_name` loop, 703 processes): **1.2 ms per full scan**, `proc_name` 1.67 us/call; a UID-only listing (542 pids) 0.75 ms. At 150 ms cadence that is ~0.8 % of a core, at 1 s cadence ~0.12 %. It explains the `__proc_info` frames and part of the 0.5 % idle but not 8-20 %. OSDUIHelper is currently in state `T` (stopped), so suppression works (OBSERVED, `ps` just now).

### Top wake-up offenders, ranked by frequency x cost x always-on

| Rank | Source | Frequency | Per-tick cost | Always-on? | Proposals |
|---:|---|---|---|---|---|
| 1 | Bluetooth/AirPods: wildcard DNC observer + 15 named DNC + 15 Darwin observers + 3 s `IOBluetoothDevice.pairedDevices()` poll + `ioreg` fallback | event-driven (rate unbounded) + 0.33 Hz | string build + 20-branch parse on main; IOBluetooth XPC; ioreg dump on main actor | yes (created at launch, `DynamicIslandApp` `let bluetoothAudioManager`) | P11-P14, P35 |
| 2 | `SystemOSDManager` watcher | 1-6.7 Hz, re-armed by every restart | full process-table scan (~700 `proc_name` syscalls, 1.2 ms) | yes while any HUD replacement on | P01, P09, P10, P36 |
| 3 | `PanGesture` x4 (8 NSEvent monitors) | every scroll event system-wide (60-120/s while scrolling) x4 | coordinate conversion on main | yes while `enableGestures` (default true) | P16 |
| 4 | Periodic trio: `MenuBarLayout` 3 s AX scan, hidden-edge hover 1 s, clipboard 0.5 s | 0.33 + 1 + 2 Hz | AX IPC to frontmost app; main-actor hop; pasteboard `changeCount` | yes (closed notch / after first notch open) | P17, P19, P20, P02 |
| 5 | `MediaKeyInterceptor` retry | 0.5 Hz x30 then 0.07 Hz, up to 1 h per restart | `AXIsProcessTrusted()` (tccd IPC) | while Accessibility not granted | P18 |

SwiftUI invalidation (section 4) is the multiplier on all of these.

### Proposal counts (section 7)

**8 SAFE, 22 LOW-RISK, 7 RISKY** (37 total).

---

## 1. The measured frames, one by one

| Frame in the busy sample | Source (OBSERVED) | Trigger | Why it shows up |
|---|---|---|---|
| `startSuppressionWatcher()` closure -> `osduiHelperPID()` -> `__proc_info` | SystemOSDManager.swift:383-419, :450-487 | detached task loop, intervals 150 ms / 500 ms / 1 s / 1 s-when-no-helper | each iteration enumerates every PID and calls `proc_name` on each (:455-473) |
| `BluetoothAudioManager.startPollingForChanges()` -> `checkForDeviceChanges()` | :253-259, :262-297 | `Timer` 3.0 s, no tolerance, main run loop | `IOBluetoothHostController.default()`, `IOBluetoothDevice.pairedDevices()`, per device `isConnected()` + `isAudioDevice` (3 SDP `getServiceRecord` calls + class-of-device, :543-566) |
| `ClipboardManager.startMonitoring()` timer -> `checkClipboard()` | ClipboardManager.swift:374-379, :562 | `Timer` 0.5 s, started on first notch open (`DynamicIslandHeader.swift:~176`, `NotchClipboardView.swift:~108`), never stopped | cheap (`changeCount`), but 2 main-thread wakeups/s forever |
| `MediaKeyInterceptor.installRetryTimer` -> `performTapRetry()` | MediaKeyInterceptor.swift:249-259, :262-293 | `Timer` 2 s (30 attempts) then 15 s; gives up after 3600 s | `AXIsProcessTrusted()` each tick; `scheduleTapRetry()` resets `retryStartDate`/`retryAttempts` (:241-247) every time `start()` is called, and `start()` is called on every observer restart (SystemChangesObserver.swift:130), so it effectively never gives up |
| AirPods handlers at :362, 2033, 2637, 2706 | BluetoothAudioManager.swift:360-366, :2041, :2612-2637, :2706 | `handleAirPodsListeningModeNotification` (15 named DNC names) and the wildcard `handlePotentialAirPodsListeningModeNotification` (:369-391), plus 15 Darwin names (:212-226) | `userInfo.map{...}.joined()` and `AirPodsListeningMode.from(String)` with ~20 `contains` on a lowercased string; the wildcard filter tests `payload.contains("anc")`, which matches innocuous words ("balance", "distance", "instance") |
| `Defaults` subscript getter | `local/.work/vendor/Defaults/.../UserDefaults.swift:21-26` (`_get(key.name) ?? default`) | ~897 `Defaults[...]` reads in sources, 71 in ContentView, 78 `Logger.log` calls each read `Defaults[.logLevel]` (Logger.swift:~80) | UserDefaults `object(forKey:)` + `Serializable` bridge; Codable-backed keys JSON-decode on every read |
| `ContentView.body`, `rootBodyView` (:860), `mainLayoutBase` (:656), `configuredMainLayout` (:692/:712), `NotchLayout` (:1057/:1079), `resolveMusicSecondaryLiveActivity` (:1538) | ContentView.swift | any `objectWillChange` of 18 observed objects, any of 46 `@Default` keys, `@State` hover/gesture flips | whole-tree re-evaluation; `dynamicNotchSize` is evaluated at :864 and :865 (3 textual uses) and reads ~10 Defaults each time |

---

## 2. Inventory of recurring wake-up sources

Legend for "Runs only when enabled AND needed?": **Y** = gated by feature and visibility, **F** = gated by feature but runs while hidden, **N** = always on. Cost column is INFERRED unless a number is given. "Fix" refers to section 7.

### 2.1 `Timer` / `DispatchSourceTimer`

| ID | file:line | Interval | Owner | Gated? | Cost per tick | Fix |
|---|---|---|---|---|---|---|
| T01 | managers/MenuBarLayout.swift:86 (`pollInterval` :38) | 3 s, `.common` | closed-notch left wing clearance | **N**: `startTracking()` runs at ContentView.swift:1010 whenever notch is closed, not only when a live activity is showing | `AXIsProcessTrusted`, then detached AX scan of frontmost app's menu bar (up to 1 s deadline, 0.25 s per-element timeout, :134-190) | P17 |
| T02 | managers/BluetoothAudioManager.swift:256 | 3 s | Bluetooth connect/disconnect HUD | **N** (created in `init`, gated by nothing, even if `showBluetoothDeviceConnections` is off) | IOBluetooth XPC + ObjC allocations on main | P13, P02 |
| T03 | managers/ClipboardManager.swift:378 | 0.5 s | clipboard history | F (starts on first notch open if `enableClipboardManager`, never stopped) | `NSPasteboard.changeCount` | P19, P02 |
| T04 | managers/MediaKeyInterceptor.swift:251 | 2 s x30, 15 s after | HUD replacement | N while Accessibility not granted | `AXIsProcessTrusted` | P18 |
| T05 | managers/SystemMediaControllers.swift:961 | 0.15 s | brightness HUD fallback | only when `CoreBrightnessDisplayClient` is unavailable (:695-698); UNKNOWN on macOS 27 | `currentBrightness` (IOKit/CoreBrightness) | P29 |
| T06 | managers/SystemMediaControllers.swift:803 | ~10 steps over <=0.3 s | brightness key animation | Y | writes brightness | none |
| T07 | components/Music/MusicVisualizer.swift:85 | 0.3 s | closed/open notch music bars | Y (view in window and playing) | `bars x CABasicAnimation` allocated and added each tick | P25 |
| T08 | audio/RealTimeAudioSpectrum.swift:87 | 1/30 s | real-time waveform (`enableRealTimeWaveform`, default false) | Y | reads magnitudes, 4+ CATransactions | none |
| T09 | audio/AudioTap.swift:325 | 1/30 s | same | Y | `updateSmoothedMagnitudes` | none |
| T10 | components/Music/RealTimeWaveformScrubberView.swift:44 | 1/60 s | scrubber | Y (while shown) | SwiftUI state update | none |
| T11 | managers/TimerManager.swift:191, :296 | 1 s | notch timer | Y | publishes `remainingTime` -> ContentView body (section 4) | B4 |
| T12 | managers/CaffeinateManager.swift:141 | 1 s (`Timer.publish`) | caffeinate session | Y | publishes `remainingTime` | none |
| T13 | managers/StatsManager.swift:621 | `statsUpdateInterval` (default 1 s) | Stats tab | Y (starts 0.5 s after tab open, stops 3 s after close; :510-560) | CPU/mem/GPU/net/disk reads + `/bin/ps` spawn every sample (:1455, FEATURE-MATRIX-A) | none |
| T14 | managers/PerAppVolumeManager.swift:194 | 1.5 s (popover) / 5 s (taps exist) | per-app volume (default off) | Y | `refreshApps` | none |
| T15 | managers/SiriVisibilityMonitor.swift:153 | 0.5 s idle / 0.06 s active (powerSaver 2 s / 0.25 s) | Siri window detection | Y (locked and display on only, :135-141) | `CGWindowListCopyWindowInfo` | none |
| T16 | managers/DownloadManager.swift:241 | `speedSampleInterval` | download speed | Y (while downloading) | directory stat | none |
| T17 | managers/ScreenRecordingManager.swift:463 | 1 s | recording duration | Y | publish | none |
| T18 | managers/ScreenAssistantManager.swift:315 | 0.1 s | voice recording meter | Y | publish | none |
| T19 | MediaControllers/YouTube Music Controller/YouTubeMusicController.swift:325 | `configuration.updateInterval` | YT Music fallback | Y (only when WebSocket absent and app active) | HTTP | none |
| T20 | components/LockScreen/LockScreenWeatherWidget.swift:117 / :183-188 | 15 s (tolerance 0) / minute-aligned 60 s (tolerance 0) | lock-screen weather widget | Y (locked only, `updateMinuteAlignedTimer` :~170) | `now = Date()` | none |
| T21 | components/Shelf/Views/ShelfMarqueeSelectionView.swift:257 | 1/60 s | marquee drag | Y | | none |
| T22 | managers/DoNotDisturbManager.swift:588 (`DispatchSourceTimer`) | 2 s, leeway 250 ms | Focus (mode `withoutDevTools`) | F (needs FDA; each tick `FullDiskAccessAuthorization.hasPermission()` opens 1-2 protected files, :31-53, then 1-2 `attributesOfItem`) | 3-5 syscalls + JSON parse on change | P15 note |
| T23 | managers/SystemTimerBridge.swift:262 (`DispatchSourceTimer`) | 1 s | AX fallback when `log stream` cannot start | Y (fallback only) | AX query | none |

### 2.2 `Task` / `Task.sleep` / `while` loops

| ID | file:line | Interval | Owner | Gated? | Cost | Fix |
|---|---|---|---|---|---|---|
| K01 | ContentView.swift:2167-2194 `startHiddenEdgeHoverPolling` (called at :895 from `.onAppear`) | 1000 ms idle / 100 ms hovering / **50 ms** when `shouldHideUntilHover` (non-notch screen with hide-until-hover) | hover handling | **N**: loop never ends while the view lives; idle iterations only check two flags | `@MainActor` hop per tick; at 50 ms: `NSEvent.mouseLocation` + rect tests, 20 Hz | P20 |
| K02 | managers/SystemOSDManager.swift:383-419 | 150 / 500 / 1000 ms (1000 when no helper) | native OSD suppression | N while HUD replacement on | 1.2 ms scan (measured) | P01, P09, P10 |
| K03 | managers/CalendarManager.swift:351-358 `startLockScreenRefreshLoop` (called from `init`, :66) | 60 s | lock-screen calendar widget | **N** (only `hasCalendarAccess` gate); `updateLockScreenEvents` runs an EventKit fetch (up to 365 days when "all time") at most every 15 s (:57, :270-274) | EventKit query on all calendars | P21 |
| K04 | managers/LockScreenManager.swift:375 | 500 ms | lock-state poll | Y (only while locked) | `CGSessionCopyCurrentDictionary` | none |
| K05 | managers/MemoryUsageMonitor.swift:43 | 8 s | self-memory watchdog (restart prompt at 1 GiB release) | N | `task_info` | none |
| K06 | managers/MusicManager.swift:2056-2078 lyric sync | 50-250 ms | lyrics (`enableLyrics` default false) | Y (timed lyrics and playing) | main-actor hop, publishes `currentLyricIndex`/`currentLyrics` | none |
| K07 | managers/DoNotDisturbManager.swift:292-300 | 3 s | Focus state verification | Y (focus active) | reads Assertions.json | none |
| K08 | managers/ReminderLiveActivityManager.swift:426-436 | 1 s | reminder activity | Y | publishes `currentDate` (~1 Hz) | B4 |
| K09 | components/Shelf/Services/LocalSendService.swift:118-130 | 15 s cleanup, 8 s multicast announce | LocalSend discovery | **N after first shelf open**: `startDiscovery()` has no stop (isStarted never reset; no `stopDiscovery` anywhere) | UDP multicast send + dictionary sweep | P22 |
| K10 | MediaControllers/NowPlayingController.swift:582 | event | JSONL read of perl child | N | decode per line | none |
| K11 | MediaControllers/YouTube Music Controller/YouTubeMusicNetworking.swift:181 | event | WebSocket receive | Y | | none |
| K12 | managers/DoNotDisturbManager.swift:1132-1190 `FocusLogStream` | event | Focus (DevTools mode) | F | `log stream` child | P15 |

### 2.3 Display-rate, animation and run-loop-driven work

| ID | file:line | Rate | Owner | Gated? | Cost | Fix |
|---|---|---|---|---|---|---|
| D01 | components/LockScreen/LockScreenMusicPanel.swift:717 and :1113 `TimelineView(.animation(...))` **without `minimumInterval`** | display refresh (up to 120 Hz) | lock-screen progress bar and lyric sweep | Y (paused when not playing; visible only when locked) | full body of the slider/lyrics each frame | P24 |
| D02 | NotchHomeView.swift:556, MinimalisticMusicPlayerView.swift:781, SyncedLyricsList.swift:164, PinnedLyricsView.swift:56 | 30 Hz, `paused:` when not playing | progress / lyrics | Y; PinnedLyricsView can be mounted in the **closed** notch (`pinLyricsWhenClosed`, default false) | `currentLyricSweepProgress` per frame | none |
| D03 | components/Live activities/MarqueeTextView.swift:107-136 | recursive `asyncAfter` chain: pause `minDuration` (0.4-3 s) then a linear offset animation of `textWidth/30` s, repeated forever | long titles in closed/open notch | Y (stops on `onDisappear`) | per-frame SwiftUI layout on main for the animation duration; a 300 pt title animates 10 s out of every ~13 s, which also resembles a "10 s burst" (INFERRED) | P26 |
| D04 | `.repeatForever` (13 sites): RecordingIndicator.swift:66,146,174; PrivacyIndicatorIcon.swift:119; DynamicIslandBattery.swift:869,874; PulsingModifier.swift:29; SpinningCircleDownloadView.swift:39; NotchNotesView.swift:504; LocalSendDevicePickerWindowManager.swift:188; SettingsView.swift:565; UpdateProgressView.swift:87; UpdateFoundView.swift:62 | 60 Hz while visible | status pulses | Y (only while their activity is on screen); camera/mic indicator runs as long as the camera/mic is in use | | none |
| D05 | extensions: ExtensionRenderingHelpers.swift:503 `TimelineView(.periodic(by:1))` | 1 Hz | extension countdown | Y | | none |

### 2.4 Notification observers (NotificationCenter, Distributed, Darwin, NSWorkspace)

| ID | file:line | Trigger | Gated? | Cost | Fix |
|---|---|---|---|---|---|
| N01 | BluetoothAudioManager.swift:205-210 `dnc.addObserver(..., name: nil, object: nil)` | **every distributed notification system-wide** | **N** (registered in `init`; guard on `showAirPodsListeningModeChanges` is inside the handler :369-371) | main-thread delivery + `userInfo` stringification | P11 |
| N02 | :197-203, :171-183 | 15 named DNC + 2 IOBluetooth connect/disconnect names | N | parse + `scheduleEventDrivenListeningModeRefresh` (180 ms debounce, then selectors or `ioreg`) | P11, P12 |
| N03 | :212-226 | 15 Darwin names | N | | none |
| N04 | SystemMediaControllers.swift:932-945 | 4 brightness DNC names, `queue: .main` | N after `start()` | each calls `currentBrightness` (CoreBrightness/IOKit) even for auto-brightness changes | P29 |
| N05 | DoNotDisturbManager.swift:91-106; LockScreenManager.swift:141-160; DynamicIslandApp.swift ~1035-1041; LockScreenWeatherWidget.swift:135-155 | focus on/off, `com.apple.screenIsLocked/Unlocked` | N | low rate | none |
| N06 | BetterDisplayManager.swift:505-565; LunarManager.swift:479-510; DynamicIslandApp.swift:~215-240 | NSWorkspace launch/terminate (every app) | N (registered even if integration disabled) | one comparison per app event | none |
| N07 | MenuBarLayout.swift:78 | `didActivateApplication` | while tracking | triggers an AX scan per app switch | P17 |
| N08 | CalendarManager.swift:81 | `EKEventStoreChanged` | N | EventKit reload, throttled | none |
| N09 | FullscreenMediaDetection.swift:42-65 | active-space / screen-parameter changes, +500 ms | N | `MacroVisionKit.detectFullscreenApps` + AX | none |

### 2.5 Event taps and NSEvent monitors

| ID | file:line | Events | Gated? | Cost | Fix |
|---|---|---|---|---|---|
| E01 | extensions/PanGesture.swift:95-101, installed by ContentView.swift:731, 734, 737, 744 | `scrollWheel` local **and global**, one pair per `panGesture` (4 gestures -> 8 monitors) | `enableGestures` (default true) | `handleScroll` -> `isCursorNearObservedView` window/view conversion on main for every scroll event system-wide | P16 |
| E02 | managers/MediaKeyInterceptor.swift:200-232 | `CGEvent.tapCreate` HID head-insert tap on `NX_SYSDEFINED` | while HUD replacement on and Accessibility granted | synchronous callback in the event path; creates `NSEvent(cgEvent:)` per system-defined event | none (note: a stalled main thread delays all media keys system-wide) |
| E03 | CapsLockManager.swift:41-50 | `flagsChanged` local + global | N | every modifier key change system-wide | none |
| E04 | LockScreenManager.swift:171-190 | `.systemDefined` local + global | N | | none |
| E05 | ContentView.swift:2236-2247, 2281 | `leftMouseDown` global/local | only while hovering / terminal open | | none |
| E06 | managers/LocalSendDevicePickerWindowManager.swift:103 | `leftMouseDown` local, **return value discarded** | per picker show | monitor never removed (leak) | P06 |

### 2.6 Event-driven system listeners (no polling; listed for completeness)

CoreAudio property listeners (SystemMediaControllers.swift:301, 351; PerAppVolumeManager.swift:345, 362; MicrophoneMonitor.swift:213; AppVolumeTap.swift:179), CoreMediaIO camera listener (CameraMonitor.swift:67), IOPS run-loop source (BatteryActivityManager.swift:92), private CGS notifications 1502/1503 (ScreenRecordingManager.swift:377-378), `NWPathMonitor` (NetworkConnectivityManager.swift:43), EventKit. All OBSERVED, all event-driven.

### 2.7 Child processes

| ID | file:line | Lifetime | Feature | Notes |
|---|---|---|---|---|
| X01 | NowPlayingController.swift:259-273 `/usr/bin/perl mediaremote-adapter.pl ... stream --micros` | whole session | now-playing (all sources except where AppleScript controllers are chosen) | OBSERVED live: pid present in `pgrep` |
| X02 | helpers/MediaChecker.swift:52; MusicManager.swift:749 | one-shot at launch, 10 s timeout | deprecation probe | spawns perl once |
| X03 | BluetoothAudioManager.swift:2190 `log stream --predicate (audioaccessoryd OR bluetoothd OR heard) AND (LsnM ...)` | whole session when `showAirPodsListeningModeChanges` (default true) | AirPods mode HUD | `readabilityHandler` + line parse on a utility queue |
| X04 | SystemTimerBridge.swift:278 `log stream --level debug` subsystem `com.apple.mobiletimer.logging` + file monitor (:436) | whole session when `mirrorSystemTimer` (default true) | mirror Clock timers | `--level debug` of a chatty subsystem, NDJSON parse, 1 MB buffer cap |
| X05 | DoNotDisturbManager.swift:1132 `log stream` duetexpertd | whole session in Focus "DevTools" mode | Focus name/identifier | plus up to three one-shot `log show --last 5m/1h/24h` at start (:548) |
| X06 | SystemOSDManager.swift:108-125, :297, :493, :526 `killall -STOP/-CONT/-9`, `launchctl kickstart` | on new OSDUIHelper pid, on enable/disable | HUD replacement | one fork+exec per respawn |
| X07 | BluetoothAudioManager.swift:2107 `ioreg -r -l -w 0` | per qualifying notification | AirPods mode fallback | full registry dump, **inside `MainActor.run`**, `waitUntilExit()` on main |
| X08 | :1461 `pmset`, :1584 `system_profiler SPBluetoothDataType` | on connect / refresh, cached, `batteryFetchQueue` | BT battery | background queue (OK) |
| X09 | StatsManager.swift:1455 `/bin/ps` | every Stats sample | Stats tab | |
| X10 | NetworkConnectivityManager.swift:273 `networksetup` | fallback when CoreWLAN gives no SSID, cached 1.5 s | Wi-Fi HUD | |
| X11 | ScreenRecordingManager.swift:319 `pgrep`, :360 `killall` | on recording events | | |
| X12 | TerminalManager.swift:288-300 `LocalProcessTerminalView.startProcess(shell, execName: "-zsh")` | from first mount of the Terminal tab (NotchTerminalView.swift:36-39) until quit | Terminal | already lazy; never torn down |
| X13 | LLMUsage/AntigravityUsageProvider.swift:77/228/332 (`security`, `ps`, `lsof`), Quota/KeychainReader.swift:132 | on demand | LLM usage (default off) | |
| X14 | KeyboardBrightnessSensor.swift:112 `corebrightnessdiag` | on demand (macOS M1 path) | keyboard backlight | `SystemDisplayManager.swift:62` has the same call but is dead code |

### 2.8 File watchers and network

| ID | file:line | Notes |
|---|---|---|
| F01 | DownloadManager.swift:183 `DispatchSource` vnode on `~/Downloads` (`.write .rename .delete .attrib`) | each event re-lists the directory and stats every file (:396-422) |
| F02 | SystemTimerBridge.swift:436 vnode on `com.apple.mobiletimerd.plist` | event |
| F03 | **Servers:** ExtensionRPCServer.swift `NWListener` WebSocket on 127.0.0.1 and ::1 port 9020 (started unconditionally at `applicationDidFinishLaunching` ~:720-721); `NSXPCListener` mach service (ExtensionXPCServiceHost.swift:55); LocalSend TCP `NWListener` on **port 53317, all interfaces** and UDP multicast group 224.0.0.167 (LocalSendService.swift:99-113, :619-650) after first shelf open | idle servers cost no wakeups except: RPC `scheduleListenerRestart()` re-binds every 3 s with no back-off if a listener fails (:155-160, :256-264) |
| F04 | Sparkle `SPUStandardUpdaterController(startingUpdater: true)` (DynamicIslandApp.swift:43) | scheduled update checks to `raw.githubusercontent.com/.../appcast.xml` (Info.plist `SUFeedURL`); UNKNOWN whether the local build disables it |
| F05 | Network clients: lyrics providers per track, `ImageService` artwork (50 MB memory URLCache, ImageService.swift:40-45), `SpotifyAuthManager` secrets fetch from raw.githubusercontent, `ModelPricingManager` remote pricing (LLM feature), `LockScreenWeatherManager` | on demand |

---

## 3. Ranking detail

Score = frequency x per-tick cost x always-on (INFERRED weights: always-on 1.0, feature-gated 0.3, visible-only 0.1).

| Rank | ID | Reason |
|---:|---|---|
| 1 | N01/N02/X07/T02 | unbounded event rate, main-thread parsing, full ioreg fallback on main |
| 2 | K02 | 700-syscall scan up to 6.7 Hz, re-armed by lock/unlock/wake/settings/DDC changes |
| 3 | E01 | 8 monitors, every scroll event, main thread |
| 4 | T01 + K01 + T03 | three always-on periodic wakers (3 s AX IPC, 1 s main-actor, 0.5 s) |
| 5 | T04 | tccd IPC every 2 s for 60 s after each restart |
| 6 | D03 | continuous SwiftUI animation work for long titles |
| 7 | K03 | EventKit fetch every 60 s even when never locked |
| 8 | K09 | multicast every 8 s and an open all-interface TCP port after first shelf use |
| 9 | X03/X04/X05 | three permanent `log stream` children (their CPU is outside Atoll but costs energy) |
| 10 | D01 | unbounded frame rate on lock screen while playing |

---

## 4. SwiftUI invalidation hot spots

| ID | Finding (OBSERVED unless noted) | Fix |
|---|---|---|
| B1 | `ContentView` holds 18 `@ObservedObject` (ContentView.swift:44-66) plus `@EnvironmentObject vm` (25 `@Published` popover/hover flags, DynamicIslandViewModel.swift:31-141) and `webcamManager`, 46 `@Default` wrappers and 71 `Defaults[...]` reads in a 3,321-line file. Any publish re-evaluates `rootBodyView`, `NotchLayout()`, `resolveMusicSecondaryLiveActivity`. | P31 (RISKY) |
| B2 | `statsManager` is observed (:55) but ContentView only calls `statsManager.updateMonitoringState(...)` (:768, :834); it never reads a published property. Every stats sample while Stats is open invalidates ContentView. | **P03 (SAFE)** make it a plain `let`/`StatsManager.shared` |
| B3 | `localSendService` observed (:64); body reads `isSending`/`transferState` but `sendProgress` (`@Published`, LocalSendService.swift:53, updated per upload chunk :540-543) republishes the whole object. `reminderManager.currentDate` (~1 Hz while active, ReminderLiveActivityManager.swift:548) and `timerManager.remainingTime` (1 Hz) do the same. | P31, or split into per-activity subviews that own their observation |
| B4 | `TimerLiveActivity`/`ReminderLiveActivity` countdown text is rendered from ContentView state (ContentView.swift:1479, 3054, 3098). A per-second `TimelineView(.periodic)` inside the activity view would stop invalidating the root. | P31 |
| B5 | `dynamicNotchSize` (:110-217, reads ~10 Defaults, `openNotchSize` -> `maxAllowedNotchWidth` -> screens) is used at :864 and :865 inside one `body`, i.e. computed repeatedly per evaluation. | **P04 (SAFE)** `let size = dynamicNotchSize` |
| B6 | `NotchLayout()` (:1054-~1390) is a `@ViewBuilder` function with a 15-branch `if/else if` chain re-evaluating `closedMusicPairingEligible`, `resolveMusicSecondaryLiveActivity`, `extensionStandalonePayload` and `Defaults[...]` on each pass. | P31, P33 |
| B7 | `conditionalModifier(Defaults[.enableGestures])` (:729) and `.conditionalModifier((closeGestureEnabled \|\| reverseScrollGestures) && enableGestures && interactionsEnabled)` (:741) change the view's structural type when the flag flips, discarding state and re-creating `ScrollMonitor` NSViews and their monitors. | use a stable view with `.allowsHitTesting`/internal flag (inside P16) |
| B8 | `MusicManager` (35 `@Published`: title, artist, art, glow texture, colors, `elapsedTime`, `timestampDate`, `playbackRate`, `currentLyricIndex`, `currentLyrics`, flip angle, ...) is observed by ContentView and every music view. A track change publishes ~15 properties; each lyric line change republishes the root. | P32 (RISKY, `@Observable`; `DownloadManager` already uses `@Observable`, deployment target 14/15 allows it) |
| B9 | `coordinator.sneakPeek` / `expandingView` are structs published as a whole (DynamicIslandViewCoordinator.swift:402, 430); every field change republishes all observers (InlineHUD, ContentView, ...). | P31 |
| B10 | `TimelineView(.animation)` at display rate on the lock screen (D01) and 30 Hz bodies for slider/lyrics (D02) re-run `MusicSliderView` and lyric rows with fresh `musicManager` reads each frame. | P24 |
| B11 | Animations while closed: music bars (T07, timer-driven CABasicAnimation), Marquee (D03), privacy/recording pulses (D04) run while their activity is visible; no animation was found that runs while the notch is closed and idle (OBSERVED). | P25, P26 |
| B12 | 13 `@Default` wrappers are never used in their file (list in DEAD-CODE-REPORT 3.5). Each subscribes its view to UserDefaults KVO. Four are in `SettingsView`, which is a 9.7 k-line view; the ContentView ones are labelled "Battery settings reactivity" and may be intentional triggers. | **P08 (SAFE)** for the Settings ones |
| B13 | `Defaults` does not de-duplicate writes (UserDefaults.swift:12-19), so `syncLegacyThirdPartyDDCKeys()` (Constants.swift:1630-1635) republishes two keys on every call; `enforceMinimumNotchWidth` is correctly guarded (sizing/matters.swift:~150). | write only if changed (inside P09) |
| B14 | `Logger.log(_ message: String, ...)` takes an eager `String` (utils/Logger.swift:~80); 78 call sites build interpolated strings (e.g. ReminderLiveActivityManager ticker at 1 Hz) before the level check, and each call reads `Defaults[.logLevel]`. | **P05 (SAFE)** `@autoclosure`, cache level |

---

## 5. Memory and lifetime risks over long uptime

| ID | Finding | Evidence | Severity | Fix |
|---|---|---|---|---|
| M1 | **Leaked NSEvent monitor** per `LocalSendDevicePickerWindowManager.show()`; the token is discarded so it can never be removed. Closure is `[weak self]` so memory is small, but each monitor stays installed and runs on every click. | LocalSendDevicePickerWindowManager.swift:103-115 | LOW-MEDIUM | P06 |
| M2 | **Dropped Combine subscription**: `Defaults.publisher(.enableDownloadListener).sink {...}` is not stored, so it is cancelled immediately and toggling the download listener never takes effect until relaunch. | DownloadManager.swift:145-151 (only unstored `.sink` found by script across 363 files) | functional bug | P28 |
| M3 | **LocalSend never stops**: `connectionGroup`, `registerListener` (TCP 53317, all interfaces), `cleanupTask`, `announceTask` live forever after first discovery. | LocalSendService.swift:62-65, :87-130, :619-650; no `stopDiscovery` anywhere | MEDIUM (wakeups + exposed port) | P22 |
| M4 | **RPC restart loop without back-off**: failed listener restarts both families every 3 s indefinitely. | ExtensionRPCServer.swift:155-160, :256-264 | LOW (INFERRED trigger: port already bound) | P23 |
| M5 | Clipboard persistence encodes every history item's full `stringData` into UserDefaults on each mutation (`saveHistoryToDefaults`, ClipboardManager.swift:756-772); default history size 3, but there is no per-item size cap, so a large paste is re-encoded and written on every later change. Images are file-backed (OK). RTF is capped at 100 kB (:~130). | | MEDIUM when large text is copied | P27 |
| M6 | Spotify artist/canvas caches keep entries past their TTL and are never pruned (SpotifyController.swift:437-459, :596-612). ~100 B per unique track. | | LOW | none needed |
| M7 | Bounded structures (OBSERVED, fine): lyrics cache 80 (MusicManager.swift:661), explicitness caches 300 (:192, :352), Stats history 30 points, color history 50, `ImageService` URLCache 50 MB memory, clipboard history by setting, in-memory clipboard images pruned (ClipboardManager.swift:40-60). | | | |
| M8 | `Logger.osLoggerCache` is a static mutable dictionary read and written from any thread without a lock (Logger.swift:72-80): data race. | | LOW (crash-class if two first-time categories race) | inside P05 |
| M9 | Long-lived closures: 55/66 `addObserver` sites use `[weak self]`; singletons make cycles harmless. The only strong long-lived captures found are `Timer` targets on singletons (`AudioTap.swift:325`). | script + reading | none | |
| M10 | `Task`s never cancelled: `MemoryUsageMonitor` (intentional), `CalendarManager.lockScreenRefreshTask` (cancelled only in `deinit` of a singleton), `hiddenEdgeHoverPollingTask` (cancelled in `performViewTeardown`, :2154-2163, OK). | | LOW | |
| M11 | Terminal: the pty and `-zsh` child live until quit once the Terminal tab was mounted; scrollback is a user setting. | TerminalManager.swift:288-300 | by design | P37 |

---

## 6. Always-on processes and servers that could start lazily

| Process / server | Started at | Needed when | What is lost if lazy | Proposal |
|---|---|---|---|---|
| `log stream` AirPods (X03) | `BluetoothAudioManager.init` via `AppDelegate` stored property, if `showAirPodsListeningModeChanges` (default true) | only while an AirPods-class device is connected | nothing, except the first mode change within ~100-300 ms of connect (process start) | P14 |
| `log stream` mobiletimer (X04) | `SystemTimerBridge.init` if `mirrorSystemTimer` (default true) | only while the system timer is running or Clock is open | precise remaining time when the timer is started by Siri/Control Center unless the plist file monitor (F02) triggers the start | P34 (RISKY) |
| `log stream` duetexpertd (X05) | when Focus mode is "DevTools" | only around focus changes | metadata logged just before the enable notification could be missed; mitigated by one-shot `log show --last 10s` (code already does `log show` at start, :548) | P15 |
| zsh pty (X12) | first mount of Terminal tab | while Terminal tab/sticky | shell state, history of a long-running command | P37 (RISKY) |
| WebSocket :9020 + XPC mach service (F03) | every launch (~:720) | only when a third-party extension app connects | extensions cannot connect until the server is up; with `enableThirdPartyExtensions` default true the user would need to opt in or the server be started on a first-run toggle | P23 |
| perl adapter (X01) | with `NowPlayingController` creation | whenever any media may play | can't be lazy: it is the event source for playback started elsewhere. Alternatives: none without private MediaRemote access | keep |
| LocalSend listener/multicast (F03/K09) | first shelf open | only while the share picker is visible | nothing | P22 |

---

## 7. Proposals

Classes: **SAFE** = behaviour identical, mechanical. **LOW-RISK** = small behaviour/timing change. **RISKY** = needs interactive testing. "Code shape" is illustrative, not applied.

| ID | Class | Change | Location | Code shape |
|---|---|---|---|---|
| P01 | SAFE | Before scanning the process table, check the already-frozen helper in O(1); scan only if gone or different. Use `PROC_UID_ONLY` for the scan | SystemOSDManager.swift:395, :450 | `if lastPID > 0, proc_pidinfo(lastPID, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status == 4 /*SSTOP*/, info.pbi_start_tvsec == lastStart { sleep; continue }` else `proc_listpids(UInt32(PROC_UID_ONLY), getuid(), ...)`. Measured: 1.2 ms -> ~2 us per tick in steady state |
| P02 | SAFE | `tolerance = 0.1 * interval` on every repeating `Timer` that has none (MenuBarLayout, Bluetooth, Clipboard, StatsManager, PerAppVolume, TimerManager, MusicVisualizer) | the T-rows | `timer.tolerance = interval * 0.1` |
| P03 | SAFE | Stop observing `statsManager` in ContentView | ContentView.swift:55 | `private let statsManager = StatsManager.shared` |
| P04 | SAFE | Evaluate `dynamicNotchSize` once per body | ContentView.swift:864-865 | `let size = dynamicNotchSize` in `rootBodyView` |
| P05 | SAFE | `Logger.log(_ message: @autoclosure () -> String, ...)`, read level first, lock `osLoggerCache` | utils/Logger.swift | check `configuredLevel` before evaluating the message |
| P06 | SAFE | Keep and remove the monitor token | LocalSendDevicePickerWindowManager.swift:103, `hide()` :121 | `clickMonitor = NSEvent.addLocalMonitorForEvents...; hide(){ if let m = clickMonitor { NSEvent.removeMonitor(m) }; clickMonitor = nil }` |
| P07 | SAFE | Delete set A files and private dead declarations | DEAD-CODE-REPORT sections 2.A, 3 | `rm` / line ranges |
| P08 | SAFE | Delete the 4 unused `@Default` wrappers in SettingsView | SettingsView.swift:1124, 1714, 2847, 8953 | delete lines |
| P09 | LOW | Make `disableSystemHUD()` idempotent: do not restart the watcher or reset `stableChecks` if already active; write legacy DDC keys only if changed | SystemOSDManager.swift:214-226; Constants.swift:1630 | `let wasWatching = s.active && s.task != nil; ... if !wasWatching { startSuppressionWatcher() }` |
| P10 | LOW | Park the poll while the frozen helper is alive: `DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit)` wakes the loop; keep `suppressNativeOSDNow()` as the fast path; poll no faster than 2 s when no helper | SystemOSDManager.swift:382-441 | `let src = DispatchSource.makeProcessSource(identifier: lastPID, eventMask: .exit, queue: q); src.setEventHandler { rescan() }` |
| P11 | LOW | Delete or gate the wildcard DNC observer (`name: nil`); the 15 named names already cover the known notifications. If kept, install with the block API only while an AirPods device is connected and remove by token | BluetoothAudioManager.swift:205-210 | `wildcardToken = dnc.addObserver(forName: nil, object: nil, queue: nil) {...}` / `dnc.removeObserver(wildcardToken)` |
| P12 | LOW | Never block main on `ioreg`: run the fallback in `Task.detached`, and read the registry in-process like `collectRegistryBatteryLevels()` (:1327) instead of `ioreg -r -l -w 0` | BluetoothAudioManager.swift:1963-1976, :2106-2145 | `let mode = await Task.detached { Self.readListeningModeFromIORegistry() }.value` |
| P13 | LOW | Poll only if `showBluetoothDeviceConnections` or AirPods HUD enabled; 3 s -> 15 s with tolerance once a connect/disconnect notification has been seen; move `pairedDevices()` off main | :253-297 | `queue.async { let current = ...; DispatchQueue.main.async { diff } }` |
| P14 | LOW | Start `AirPodsListeningModeLogObserver` only while an AirPods device is connected | :230-250, :2187-2222 | call `start()/stop()` from `connectedDevices` didSet |
| P15 | LOW | Replace the permanent duetexpertd stream by an on-demand `log show --last 15s` (or a stream that stops N s after focus ends) triggered by `_NSDoNotDisturbEnabledNotification` | DoNotDisturbManager.swift:524-540, :1127-1190 | reuse `checkInitialFocusStateViaLog` with window `["15s"]` |
| P16 | LOW | One shared scroll-wheel monitor pair for all pan gestures; reject early using `NSEvent.mouseLocation` against a cached notch rect before any window math; install only while `enableGestures` and the notch window is visible | PanGesture.swift:95-101; ContentView.swift:729-745 | `ScrollGestureHub.shared.register(rect:handler:)` with a single `addGlobalMonitorForEvents(.scrollWheel)` |
| P17 | LOW | Run `MenuBarLayout` only while a left-wing live activity is visible (as its own comment says), refresh on app activation and on width change; drop the 3 s timer or use 10 s | ContentView.swift:1010-1018, MenuBarLayout.swift:72-90 | `if closedContentWidth > vm.closedNotchSize.width { startTracking() } else { stopTracking() }` |
| P18 | LOW | Keep retry state across `stop()/start()`; back off 2 s -> 30 s -> 120 s; re-arm on `NSApplication.didBecomeActive`; optionally listen for `com.apple.accessibility.api` (UNKNOWN whether posted on macOS 27, verify) | MediaKeyInterceptor.swift:241-262, :295 | persist `retryStartDate` in the singleton, only `cancelTapRetry()` after a successful `installTap()` |
| P19 | LOW | Clipboard timer 1 s + 0.3 s tolerance; start only if enabled at launch; stop when the feature is disabled | ClipboardManager.swift:374-384 | `Timer.scheduledTimer(withTimeInterval: 1, ...)` |
| P20 | LOW | Do not run the hover loop when it has nothing to poll; for hide-until-hover use a global `.mouseMoved` monitor instead of 50 ms polling | ContentView.swift:2167-2203 | `guard shouldUseHiddenEdgeHoverPolling \|\| isHovering else { wait on continuation }` |
| P21 | LOW | Gate the 60 s lock-screen calendar loop on the lock-screen calendar widget being enabled; fetch on lock instead | CalendarManager.swift:66, :346-358 | `if Defaults[.enableLockScreenCalendar...]` / start on lock |
| P22 | LOW | Add `stopDiscovery()` (cancel tasks, `registerListener?.cancel()`, `connectionGroup?.cancel()`, `isStarted = false`) and call it when the share picker/shelf disappears | LocalSendService.swift:87-130 | |
| P23 | LOW | Start RPC/XPC lazily or default `enableThirdPartyExtensions` to false in the local build; exponential back-off in `scheduleListenerRestart` | DynamicIslandApp.swift ~720; ExtensionRPCServer.swift:155 | `delay = min(3 * 2^n, 300)` |
| P24 | LOW | Add `minimumInterval: 1/30` to the two lock-screen `TimelineView(.animation)` | LockScreenMusicPanel.swift:717, :1113 | `.animation(minimumInterval: 1.0/30.0, paused: ...)` |
| P25 | LOW | Visualizer bars: one repeating, auto-reversing `CABasicAnimation` per bar with randomised duration/amplitude instead of a 0.3 s Timer that re-adds animations | MusicVisualizer.swift:84-112 | `anim.repeatCount = .infinity; anim.duration = .random(in: 0.25...0.5)` |
| P26 | LOW | Marquee: replace the `asyncAfter` recursion by one `withAnimation(.linear(duration:).delay(pause).repeatForever(autoreverses: false))` started on appear and cancelled on disappear | MarqueeTextView.swift:104-140 | |
| P27 | LOW | Cap persisted `stringData` (e.g. 256 kB) and skip re-encoding unchanged items | ClipboardManager.swift:756-772 | `String(stringData.prefix(262_144))` for the persisted copy |
| P28 | LOW | Store the `Defaults.publisher` sink so the download listener toggle works | DownloadManager.swift:145 | `.sink {...}.store(in: &cancellables)` |
| P29 | LOW | Brightness fallback poll 0.15 s -> 0.5 s with tolerance; skip the DNC handler's `currentBrightness` read when not user-initiated | SystemMediaControllers.swift:665, :932-945 | |
| P30 | LOW | Pause `MemoryUsageMonitor`/Calendar loops while the Mac is asleep (they currently rely on `Task.sleep` only) and set `ProcessInfo.beginActivity` hints to `.background` for utility tasks | MemoryUsageMonitor.swift:43; CalendarManager.swift:351 | |
| P31 | RISKY | Extract the closed-notch content (`NotchLayout`'s live-activity chain) into a subview that owns only the observations it reads; make activity views own their 1 Hz clocks; keeps the `Namespace` for `matchedGeometryEffect` in the parent | ContentView.swift:1054-1390 | |
| P32 | RISKY | Migrate `MusicManager`/`TimerManager`/`DynamicIslandViewCoordinator` to `@Observable` so views depend only on the properties they read | managers/ | |
| P33 | RISKY | Replace `Defaults[...]` reads inside `body` with one observed `NotchSettingsSnapshot` struct updated by a single `Defaults.publisher(keys...)` merge | ContentView.swift | |
| P34 | RISKY | Gate the mobiletimer `log stream` on the plist file monitor / Clock activity | SystemTimerBridge.swift:150-175, :262-290 | |
| P35 | RISKY | Replace the 3 s poll with `IOBluetoothDevice.register(forConnectNotifications:selector:)` and per-device disconnect notifications | BluetoothAudioManager.swift:253-297 | needs hardware testing |
| P36 | RISKY | Remove OSDUIHelper polling entirely and rely on key/volume/brightness event paths (`suppressNativeOSDNow`) plus the exit-event source | SystemOSDManager.swift | native HUD flash on missed races |
| P37 | RISKY | Terminate the terminal shell after N minutes closed (opt-in) | TerminalManager.swift:288-320 | loses session |

Counts (matching the table): SAFE P01-P08 = **8**, LOW-RISK P09-P30 = **22**, RISKY P31-P37 = **7**.

---

## 8. UNKNOWN / how to confirm (nothing here was run)

* Which of the four burst mechanisms dominates in the user's sample: add `Self._printChanges()` (DEBUG) in `ContentView.body`, an `os_signpost` around `handleAirPodsListeningModeNotification` and `startSuppressionWatcher` restarts, and record `sample`/Instruments Time Profiler with Bluetooth audio playing.
* Whether `readListeningModeViaDynamicSelectors` returns nil on macOS 27 (decides whether the `ioreg` path runs).
* Whether `CoreBrightnessDisplayClient.isAvailable` is true on macOS 27 (decides whether the 0.15 s brightness poll runs).
* Whether `com.apple.accessibility.api` is posted on macOS 27.
* Sparkle behaviour in the local build; process count on other machines (watcher cost scales with it).
* Settings window teardown on close (are its 9.7 k-line views released?): not examined.
