# Toplet performance and resource-usage audit (static)

## Measured baseline (live)

Measured on 2026-10-21 on the maintainer's MacBook (Apple silicon, macOS 27.2, built-in display
1470 pt wide) with the release build from `local/build.sh`, notch closed, no interaction. The AI
Agents feature was **on** and two Claude Code sessions were actively writing logs during every run,
which is the heaviest realistic case for the agents usage history. Tools: `top -l N -s 10 -pid`
(CPU % per 10 s sample), `ps -o rss`, `lsof`, `sample`, and `/usr/bin/log` for launch markers.

| Metric | Before (16:36, build 5) | After fixes (17:01, build 9) | How measured |
|---|---|---|---|
| Process start (open → pid exists) | 108–122 ms (3 runs) | not re-measured | timestamp delta |
| Launch to `[Lifecycle] launched` log line | 1.80 / 1.84 / 1.86 s | not re-measured | `open` time vs log timestamp |
| Idle CPU, notch closed (10 s samples) | 0.0, 10.9, 34.0, 66.0, 34.7, 15.0, 26.1 % | 0.0, 2.2, 3.3, 2.0, 2.0, 2.0, 1.9 % | `top` |
| CPU time over the sampling window | 28.7 s in ~2 min | 6.6 s in ~2.5 min (incl. launch) | `ps -o time` |
| Memory (RSS) | 188–264 MB, swinging | 144 MB RSS; `top` mem 175–195 MB | `ps`, `top` |
| Open file descriptors | 139 | not re-measured | `lsof -p` |

**What caused the idle CPU.** `sample` attributed most busy samples to
`AgentCenter.startUsageHistory` → `AgentUsageHistory.refreshImpl` every 10 s: copying and comparing
the whole archive, re-encoding the 7.3 MB `agents-usage-v1.json` to JSON and rewriting it, and
re-sorting every record for the report (`Archive.encode` 170 of 482 samples, ICU date parsing and
JSON writing behind it). **Fix** (AtollAgents/Core/AgentUsageHistory.swift, synced to the app):
change tracking with a dirty flag, the checkpoint written at most once a minute (plus `flush()` on
stop), and the sorted report rebuilt only when records change, so an unchanged refresh returns an
identical report and wakes no observers. Covered by new checks in `AtollAgents/Tests/CoreTestsDashboard.swift`.

**Not yet measured** (needs dedicated runs; see Section 9 for the static findings): cold launch
after the fixes, GPU use while animations run, energy impact over hours, memory growth over a day,
sleep/wake behaviour, and a run with the Agents feature off (expected to be lower still).

The 1.8 s from process start to `applicationDidFinishLaunching` is a real launch-time finding: the
static launch-path section below lists the work done before that point (App init, Sparkle setup,
the Settings window built twice, camera discovery, the media-source probe).

---

**Scope.** `Toplet/` (the compiled app module), plus `AtollNotch/Core/IdleAnimation*` and `AtollNotch/UI/Idle*` (copied into the app by `local/prepare.py:83-96`). `AtollAgents/Core` and `AtollAgents/UI` are byte-identical mirrors of `Toplet/managers/Agents` and `Toplet/components/Notch/Agents` (checked with `diff -q`), so they are cited once, by the compiled copy. Audit date 2026-10-21.

**Method.** Read-only: source and project files were read and grepped. Nothing was built, run, profiled or edited. Every "cost" below is an **estimate** from reading the code, not a measurement; the live section above is where the numbers will go.

**Line numbers.** Several sources were being edited by someone else while this audit ran (`DynamicIslandApp.swift` changed at 16:43 and again at 16:50, `ContentView.swift` at 16:36 local time). Line numbers are from the tree at about 16:50; `DynamicIslandApp.swift` lines were re-read after its last change. Expect drift of a few lines.

**Cost legend (estimates).** *low*: rare work or a cheap syscall, no meaningful CPU when idle. *medium*: periodic wake-ups of 0.3 Hz or more doing real work (IPC, file I/O, process spawn), or bursts of a few to tens of ms on the main thread. *high*: display-rate SwiftUI rendering, sustained work of 1 % CPU or more, or tens of MB of memory or I/O.

**"Closed/idle?"** means: does it run while the notch is closed and the user is not interacting? **Stopped?** means: is it torn down when its feature is off or its output is not visible?

---

## 0. Summary

Idle steady state is a set of small, always-on tickers rather than one hot loop. With default settings these run while the notch is closed: the OSD watcher (1 Hz), Bluetooth poll (3 s), Focus file poll (2 s), clipboard poll (0.5 s after first notch open), hover poll (1 s per notch window), memory watchdog (8 s), and two long-lived child processes (`perl mediaremote-adapter.pl stream`, and `log stream --level debug` for Clock timers). The heavier risks only show up when a feature is in use: the AI-agents usage archive rewrite every 10 s, full-resolution artwork blur on every track change, display-rate `repeatForever` pulses during recordings and downloads, and stacked marquee animation loops.

**The two previously fixed problems are still fixed.**

* *Always-breathing agents glyph (about 10 % CPU).* The closed indicator animates only while hovered or while an agent waits for permission (`components/Notch/NotchAgentsHost.swift:107-111`). Its `TimelineView` ticks only when `isActive && summary.animating` (`components/Notch/Agents/AgentsClosedIndicator.swift:119`), and an inactive `AgentsTickSchedule` yields a single date (`components/Notch/Agents/AgentsComponents.swift:27-28`). The animated window is bounded by the approval timeout, which is clamped to 15-600 s (`managers/AgentsIntegration.swift:89`). There is one remaining path: hovering the closed glyph runs the 0.4 s clock plus a 1.2 s `breathe` animation (`AgentsMotion.swift:40,47,78`) for as long as the pointer stays there. That is acceptable.
* *Full-history LLM log scan (memory warning).* Token and cost totals are scanned only when `showLLMUsageDetails` is on (default `false`, `models/Constants.swift:1289`; gate at `managers/LLMUsage/LLMUsageManager.swift:58`). The scan is limited to 7 days (`JSONLUsageParser.swift:223`), skips files by mtime (`:123-128`, `:225`), and streams 64 KB chunks with a 1 MB line cap (`:146-147`). Some residual cost remains; see F11.

**A new item with a similar risk profile:** `AgentUsageHistory` (agents feature, default off) rescans `~/.claude/projects` and `~/.codex/sessions` every 10 s. Whenever anything changed it re-encodes and atomically rewrites its whole archive of up to 100 000 records, then publishes the full sorted record array to the main actor (see F1).

---

## 1. Inventory of recurring work

### 1.1 `Timer` / `DispatchSourceTimer`

| ID | file:line | Interval | Closed/idle? | Stopped? | Cost (est.) and reasoning |
|---|---|---|---|---|---|
| T1 | managers/ClipboardManager.swift:374-381 | 0.5 s, tolerance 0.05 | yes, once started | no: started on first notch open (`components/Notch/DynamicIslandHeader.swift:176`, `NotchClipboardView.swift:108`) or shortcut (`DynamicIslandApp.swift:1468`), stopped only by the Settings toggle (`SettingsView.swift:8521`) | low per tick (`changeCount`), but 2 main-thread wake-ups/s forever. On change it runs heavy main-thread reads (section 5) |
| T2 | managers/BluetoothAudioManager.swift:284-292 | 3 s; 15 s after the first connect/disconnect notification (`:297-301`) | yes | no: not gated on any setting | medium: `IOBluetoothHostController.default()`, `pairedDevices()`, `isConnected()` on the main run loop (`:304-324`). The relax path depends on DNC names `IOBluetoothDeviceConnectedNotification`/`...Disconnected...` (`:176-189`). IOBluetooth normally delivers those through `IOBluetoothDevice.register(forConnectNotifications:)`, not the distributed center (INFERRED), so on many Macs the poll probably never relaxes |
| T3 | managers/DoNotDisturbManager.swift:584-596 | 2 s, leeway 250 ms, utility queue | yes (default `enableDoNotDisturbDetection=true`, mode `.withoutDevTools`, Constants.swift:1488-1489) | only with the feature | low to medium: each tick probes Full Disk Access by opening a protected file (`helpers/FullDiskAccessPermissionStore.swift:31-53`), then 2× `attributesOfItem` (`DoNotDisturbManager.swift:611-622`), and parses JSON when the file changed |
| T4 | managers/MenuBarLayout.swift:38, 109-117 | 3 s, `.common` | only while closed content is wider than the notch (`ContentView.swift:997-1008`) | yes | medium while on: Accessibility IPC to the frontmost app |
| T5 | managers/MediaKeyInterceptor.swift:240-260, 262-293 | 2 s, then 15 s, gives up by policy | yes, while Accessibility is not granted | yes | low: `AXIsProcessTrusted()` (tccd IPC). Every `start()` resets the window (`:242-243`) |
| T6 | managers/SystemMediaControllers.swift:957-962 | `pollInterval` (brightness fallback) | only when CoreBrightness is unavailable (`:686-695`) | yes | medium if it ever runs; UNKNOWN on this macOS |
| T7 | managers/SystemTimerBridge.swift:261-270 | 1 s, leeway 150 ms | only as a fallback when `log stream` fails (`:201-204`) | yes | medium (AX query) |
| T8 | managers/TimerManager.swift:191, :297 | 1 s | only while a timer runs | yes | low by itself, but publishes `remainingTime`, which invalidates the whole `ContentView` (it observes `TimerManager`, `ContentView.swift:47`) |
| T9 | managers/CaffeinateManager.swift:141 | 1 s `Timer.publish` | while a caffeinate session runs | yes | low |
| T10 | managers/StatsManager.swift:532, 621, 658 | `statsUpdateInterval` (default 1 s, Constants.swift:1295) | no (Stats tab only, delayed start/stop) | yes | medium while open: sampling, plus a throttled `/bin/ps` spawn (`:1431`, `:1451`) |
| T11 | managers/PerAppVolumeManager.swift:194 | 1.5 s / 5 s | opt-in feature | yes | low |
| T12 | managers/SiriVisibilityMonitor.swift:120, 153 | 0.5 s idle / 0.06 s active | only while locked with the display on | yes | medium while locked: `CGWindowListCopyWindowInfo` |
| T13 | managers/DownloadManager.swift:247 | `speedSampleInterval` | only while downloading | yes | low |
| T14 | managers/ScreenRecordingManager.swift:455 | 1 s | only while recording | yes | low |
| T15 | managers/ScreenAssistantManager.swift:315 | 0.1 s | only while voice-recording | yes | low |
| T16 | MediaControllers/YouTube Music Controller/YouTubeMusicController.swift:325 | 2 s (`YouTubeMusicModels.swift:36`) | only when that controller is active without a WebSocket | yes | medium (HTTP each tick) |
| T17 | components/Music/MusicVisualizer.swift:85-88 | 0.3 s, CA animations capped at 24 fps (`:107`) | yes, while music plays and the view is in a window | stops on `window == nil` or pause (`:70-76`) | low to medium: Core Animation does the work, but it keeps running while the notch window has alpha 0 |
| T18 | audio/RealTimeAudioSpectrum.swift:87, audio/AudioTap.swift:323-327 | 1/30 s each | yes, whenever `enableRealTimeWaveform` (default false) | AudioTap runs while the feature is on, even with the notch closed and nothing playing | high when enabled: a process tap, aggregate device and FFT stay live, plus two 30 Hz main-thread timers |
| T19 | components/Music/RealTimeWaveformScrubberView.swift:42-66 | 1/60 s | no (open notch) | on `onDisappear` | medium: 60 Hz `withAnimation` state writes and a `Defaults[.visualizerBarCount]` read per tick (`:46`), even while paused |
| T20 | components/LockScreen/LockScreenWeatherWidget.swift:117-120, 183-196 | 15 s and 60 s, **tolerance 0** | lock-screen widget only | yes (`:538`) | low; zero tolerance stops coalescing |
| T21 | components/Shelf/Views/ShelfMarqueeSelectionView.swift:257 | 1/60 s | drag only | yes | low |
| T22 | managers/Agents/DiscoveryRegistry.swift:676-689 | 5 s while the Agents tab or closed glyph is shown (`AgentsIntegration.swift:249-254`), otherwise 15-60 s back-off (`DiscoveryRegistry.swift:621-626`) | yes, while agents are enabled and a session exists | yes | medium: libproc scan plus 512 KB transcript tail reads per changed session (`TranscriptTail.swift:56`) |
| T23 | managers/Agents/AgentEngine.swift:149-155 | 20 s (`:35`) | yes, while agents are on | yes | low |
| T24 | managers/Agents/AgentSocketServer.swift:464-469 | 250 ms | only while approvals are pending | yes | low |
| T25 | managers/Clock/AlarmManager.swift:119 | one-shot at next alarm | n/a | yes | low |

### 1.2 `Task.sleep` / `while` loops

| ID | file:line | Interval | Closed/idle? | Stopped? | Cost (est.) |
|---|---|---|---|---|---|
| K1 | ContentView.swift:2174-2201 (started `:882`) | 1000 ms idle, 100 ms hovering, 50 ms in hide-until-hover mode (`:2203-2211`) | **yes, forever, one loop per notch window** | only on view teardown (`:2165`) | low at 1 Hz (main-actor hop, two flag checks); medium at 20 Hz |
| K2 | managers/SystemOSDManager.swift:388-440 | 150 ms, then 500 ms, then 1 s steady (`:429-438`) | yes, while any HUD replacement is on (default `enableSystemHUD=true`, Constants.swift:1414) | pauses during sleep (`:401-405`) | low: one `proc_pidinfo` per tick (`:411-414`), a full process-table scan at least every 2 s (`:397`, `:472`). Each new helper PID spawns `killall -STOP` (`:528-530`) |
| K3 | managers/CalendarManager.swift:347-361 | 60 s | yes (started in `init`, `:66`) | the EventKit fetch is skipped while unlocked (`:358`), but the loop runs forever | low |
| K4 | managers/LockScreenManager.swift:372-380 | 500 ms | locked only | yes | low to medium: `CGSessionCopyCurrentDictionary` inside `MainActor.run` |
| K5 | managers/MemoryUsageMonitor.swift:32, 39-52 | 8 s | yes | never (by design) | low (`task_info`) |
| K6 | managers/MusicManager.swift:2062-2074 | next lyric boundary | while timed lyrics play | yes | low |
| K7 | managers/DoNotDisturbManager.swift:286-300 | 3 s | while Focus is on | yes | low |
| K8 | managers/ReminderLiveActivityManager.swift:423-436 | 1 s | while a reminder activity is active | yes | low, but publishes `currentDate` into `ContentView` (`ContentView.swift:49`) |
| K9 | components/Shelf/Services/LocalSendService.swift:108, 169, 176 | 30 s / 15 s / 8 s | after shelf use | released 30 s after the last client (`:90-130`) | low |
| K10 | managers/Agents/AgentCenter.swift:200-206 | 10 s | **yes, whenever agents are enabled** | on `stop()` | **medium to high, see F1** |
| K11 | managers/LLMUsage/LLMUsageManager.swift:103-115 | `llmUsageRefreshMinutes` (default 5), or 30 s after a reset | yes, when a provider is pinned | yes | low: limits-only HTTP; the Claude path may spawn `/usr/bin/security` on a credential miss (`Quota/KeychainReader.swift:131-133`) |
| K12 | DynamicIslandViewCoordinator.swift:390, 438 | one-shot sneak-peek timers | n/a | yes | low |

### 1.3 Display-rate rendering: `TimelineView`, `repeatForever`, Lottie, keyframes

| ID | file:line | Rate | Closed/idle? | Gated by | Cost (est.) |
|---|---|---|---|---|---|
| D1 | components/Live activities/PulsingModifier.swift:27-31, used at ContentView.swift:1675, Privacy/PrivacyLiveActivity.swift:52, Recording/RecordingLiveActivity.swift:189 | display refresh (SwiftUI-driven scale+opacity) | **yes, in the closed notch for the whole recording** | only by the view's existence; no Reduce Motion or Low Power check | **high for long recordings**: the same mechanism as the old breathing glyph |
| D2 | components/UI/RecordingIndicator.swift:64-68 | display refresh | open-notch header (`DynamicIslandHeader.swift:320`) | recording state | medium |
| D3 | components/Downloads/SpinningCircleDownloadView.swift:37-41 (via `DownloadLiveActivity.swift:128`) | display refresh, linear 1 s | yes, for the whole download | download state | medium to high for long downloads |
| D4 | components/Live activities/DynamicIslandBattery.swift:866-875 | display refresh | battery HUD | transient; low-battery pulse is skipped in Low Power Mode (`:866`) | low (short-lived) |
| D5 | components/Live activities/MarqueeTextView.swift:107-155 | linear offset animation of `textWidth/30` s after each `minDuration` pause, forever | yes, for long titles in the closed notch (ContentView.swift:1194, 1207, 1222, 1245, 1481, 1497) | stops `onDisappear` (`:98-100`) | medium per instance; **loop chains stack** (section 4, L3) |
| D6 | components/Music/LottieAnimationView.swift:28-44, used at ContentView.swift:1812 | Lottie's own display link, `.loop` | yes, in the closed music activity when `useMusicVisualizer` is false | **never paused when playback pauses** (no `isPlaying` input) | medium; the default animation is fetched from `https://assets9.lottiefiles.com/...` (`:29`) |
| D7 | NotchHomeView.swift:556, MinimalisticMusicPlayerView.swift:724, LockScreenMusicPanel.swift:717-721 and :1114, SyncedLyricsList.swift:164, PinnedLyricsView.swift:56 | 30 fps | Pinned lyrics can be in the closed notch (`pinLyricsWhenClosed`, default false); the lock-screen panel while locked | paused when not playing | medium: 30 fps to move a progress bar about 1 pt/s |
| D8 | AtollNotch/UI/IdleAnimationHost.swift:105-140, planner AtollNotch/Core/IdleAnimationPlayback.swift:91-129 | `userMaxFPS` (default 24), ≤12 in Low Power Mode, 5 s heartbeat when inactive | closed notch, only if `showNotHumanFace` (default false, Constants.swift:1027) | **best-gated item in the app**: stops when open, locked, asleep, occluded or hidden; Reduce Motion gives a poster frame | medium while playing (24 fps Canvas), up to 10 min after the last input |
| D9 | components/Notch/Agents/AgentsClosedIndicator.swift:119; AgentsMotionViews.swift:101-115 (`KeyframeAnimator` ring) | 0.4 s ticks plus 1.2 s easing | hover or pending approval only | bounded (see Summary) | low |
| D10 | Notch/NotchClockView.swift:86, 153; NotchLLMUsageView.swift:42; PinnedUsageView.swift:53; Extensions/ExtensionRenderingHelpers.swift:503 | 1 s / 30 s periodic | PinnedUsageView sits in the closed notch | view lifetime | low |
| D11 | components/Settings/SettingsView.swift:581-583; Notch/NotchNotesView.swift:500; managers/LocalSendDevicePickerWindowManager.swift:199 | display refresh | no | state flags | low |

### 1.4 Notification, workspace and Darwin observers

| ID | file:line | What | Closed/idle? | Removed? | Cost (est.) |
|---|---|---|---|---|---|
| N1 | managers/BluetoothAudioManager.swift:253-281 | wildcard `DistributedNotificationCenter` observer (`name: nil`), queue `.main` | **while AirPods are connected and the HUD setting is on** (default true, Constants.swift:1270) | yes, by token | medium: receives every distributed notification on the system and stringifies `userInfo` before its cheap name filter (`:413-433`) |
| N2 | BluetoothAudioManager.swift:201-229 | 15 named DNC and 15 Darwin listening-mode observers | yes | Darwin ones removed at `:2164` | low |
| N3 | managers/SystemMediaControllers.swift:932-955 | 4 brightness DNC names, `.main` | yes | kept for the app's lifetime | low; each event reads brightness through IOKit/CoreBrightness, auto-brightness changes included |
| N4 | DynamicIslandApp.swift:1025-1088 | screen parameters, active space, selected screen, notch height, auto-switch, all-displays, `screenIsLocked`/`Unlocked` | yes | block tokens discarded (`:1032-1070`); acceptable on a process-lifetime delegate | low |
| N5 | DynamicIslandApp.swift:190-276 | AudioTap launch/terminate/route observers | only while waveform is on | yes, by token (`:271-276`) | low |
| N6 | observers/FullscreenMediaDetection.swift:41-64 | active-space and screen-parameter async sequences, then `MacroVisionKit.detectFullscreenApps` after 500 ms (`:66-69`, `:83`) | event-driven | process lifetime | low to medium per space switch (window list plus AX) |
| N7 | managers/MenuBarLayout.swift:79-84 | `didActivateApplication`, runs an AX scan per app switch | while tracking | yes (`:119-128`) | low to medium |
| N8 | managers/CalendarManager.swift:79-83 | `EKEventStoreChanged` | yes | `deinit` | low |
| N9 | managers/WebcamManager.swift:69-70 | AVCapture connect/disconnect | yes | `deinit` | low |
| N10 | AtollNotch/UI/IdlePlaybackController.swift:134-151 | screens sleep/wake, accessibility options | while the idle view lives | yes | low |
| N11 | managers/SystemTimerBridge.swift:123-140 | Clock app launch/terminate | yes | process lifetime | low |
| N12 | managers/ScreenRecordingManager.swift:367-370 | `CGSRegisterNotifyProc` 1502/1503 | yes (default `enableScreenRecordingDetection=true`) | **never unregistered** (section 4, L1) | low |

### 1.5 Event taps and `NSEvent` monitors

| ID | file:line | Events | Closed/idle? | Removed? | Cost (est.) |
|---|---|---|---|---|---|
| E1 | extensions/PanGesture.swift:190-237 | one shared local and one global `scrollWheel` monitor for all pan gestures (`ContentView.swift:727-740`) | yes (`enableGestures` default true) | when the last gesture unregisters | low to medium: every scroll event on the system wakes the main thread once and does a window-frame test before view conversion |
| E2 | managers/MediaKeyInterceptor.swift:200 | `CGEvent.tapCreate` HID tap | yes | yes | low; it sits synchronously in the key path, so a stalled main thread delays media keys system-wide |
| E3 | managers/CapsLockManager.swift:41-50 | `flagsChanged` local and global | yes, even if `enableCapsLockIndicator` is off | `deinit` only | low |
| E4 | managers/LockScreenManager.swift:171-190 | `.systemDefined` local and global | yes | stored in `powerKeyMonitors` | low |
| E5 | ContentView.swift:2222-2265, 2288-2305 | `leftMouseDown` | only while hovering, or the sticky terminal | yes | low |
| E6 | FullScreenArtworkWindowManager.swift:1186-1201; LockScreenMusicPanel.swift:1998-2018; Timer/RulerTimerPicker.swift:60-75; LocalSendDevicePickerWindowManager.swift:106 | right-click / scroll / click | per feature | yes (guarded) | low |

### 1.6 Child processes and AppleScript

| ID | file:line | Lifetime | Default? | Cost (est.) |
|---|---|---|---|---|
| X1 | MediaControllers/NowPlayingController.swift:256-305 `perl mediaremote-adapter.pl stream --micros` | whole session | yes | medium: a resident perl interpreter, plus JSONL parsing in the app (section 5, M3) |
| X2 | helpers/MediaChecker.swift:52-90 `perl ... test` | one-shot at launch, 10 s timeout; `waitUntilExit()` blocks a cooperative thread (`:76-78`) | yes | medium at launch; the controller is chosen only after it finishes (`MusicManager.swift:745-769`) |
| X3 | managers/SystemTimerBridge.swift:273-328 `log stream --style ndjson --predicate subsystem=="com.apple.mobiletimer.logging" ... --level debug` | **whole session** | **yes (`mirrorSystemTimer=true`, Constants.swift:1342)** | medium: a resident `log` process, and debug-level streaming of a subsystem keeps logd delivering debug messages (INFERRED). See F3 |
| X4 | BluetoothAudioManager.swift:2190-2192 `log stream` (AirPods) | while AirPods are connected and the HUD is on (`:273-279`) | conditional | medium while running |
| X5 | BluetoothAudioManager.swift:1574-1590 `system_profiler SPBluetoothDataType -json`; `:1452` `pmset -g accps` | per battery refresh (≥20 s, `:74`) on `batteryFetchQueue` (`:1281-1284`); **also from the device-type fallback on the main thread** (`:565` → `:785` → `:1542-1560`, 30 s cache `:88`) | when BT audio connects | high per call on main (system_profiler takes about 1-3 s; INFERRED) |
| X6 | BluetoothAudioManager.swift:2104 `ioreg -r -l -w 0` | AirPods mode fallback | conditional | medium (full registry dump, off main since P12) |
| X7 | managers/DoNotDisturbManager.swift:548, 1132 `log show` / `log stream` | DevTools Focus mode only | no | medium while on |
| X8 | managers/SystemOSDManager.swift:108, 122, 151, 199, 303, 529, 562 `killall -STOP/-CONT`, `launchctl kickstart` | on helper respawn and HUD toggles | yes | low (rare) |
| X9 | managers/KeyboardBrightnessSensor.swift:111-118 `/usr/libexec/corebrightnessdiag status-info` | per keyboard-backlight key press, **synchronously on the caller's thread** (`SystemKeyboardBacklightController.swift:47-48, 65-66`, called from `SystemChangesObserver.swift:250`) | only when CoreBrightness is unavailable (`KeyboardBrightnessSensor.swift:31-46`) | medium per key press |
| X10 | ScreenRecordingManager.swift:309-325 `pgrep`, `:350` `killall` | on stop only | yes | low |
| X11 | NetworkConnectivityManager.swift:272-300 `networksetup -getairportnetwork` | per path change, cached (`:259-268`), 1 s timeout | yes | low |
| X12 | StatsManager.swift:1451 `/bin/ps`; LLMUsage/AntigravityUsageProvider.swift:77, 228, 332 `security`/`ps`/`lsof`; Quota/KeychainReader.swift:131 `security` | per refresh | opt-in | low to medium |
| X13 | helpers/AppleScriptHelper.swift:27-40: `NSAppleScript` compiled on every call inside `Task.detached` | per command / AirPlay / Notes sync | per feature | low CPU; `NSAppleScript` is not documented as thread-safe, so concurrent detached execution is a correctness risk (INFERRED) |
| X14 | managers/TerminalManager.swift:288-321 login shell via SwiftTerm | kept alive after the tab closes (by design, `NotchTerminalView.swift:30-49`) | opt-in (`enableTerminalFeature=false`) | low CPU; holds memory and scrollback |

### 1.7 File watchers, KVO, Combine

* **File watchers.** `DownloadManager.swift:173-216` uses a vnode source on `~/Downloads` (event-driven, good). `SystemTimerBridge.swift:428-455` puts a vnode source on the **file** `com.apple.mobiletimerd.plist` with `O_EVTONLY`. cfprefsd writes plists by atomic rename, so after the first `.rename` event the descriptor points at the old inode and the watcher goes deaf (INFERRED). The log stream then becomes the only signal. There is no FSEvents usage.
* **KVO.** `TerminalManager.swift:446-448` (scroller, tokens kept), `helpers/LiquidGlassBackground.swift:74-75` (removed at `:118-119`), `Settings/SoftwareUpdater.swift:30`. None are leaks.
* **Combine / Defaults.** 127 `Defaults.publisher` and 152 `.sink` sites. Nearly all are created once on singletons or in `applicationDidFinishLaunching` (`DynamicIslandApp.swift:764-1022`). `SystemHUDManager.swift:39-207` has 13 setting sinks, and each change calls `startSystemObserver()` (`:301-330`), which rebuilds `SystemChangesObserver` and re-runs `SystemOSDManager.disableSystemHUD()`. A Settings change therefore re-arms the 150 ms OSD confirm phase and the media-key retry window (a "restart storm"; CPU cost is low and bounded).

---

## 2. Busy polling that could be event-driven

| Source | Today | Event-driven alternative | Notes |
|---|---|---|---|
| Media state | `perl` JSONL stream (X1), event-driven | none needed | Good as-is; parsing cost is in section 5 |
| Battery | `IOPSNotificationCreateRunLoopSource` (`BatteryActivityManager.swift:92`) | none needed | Good |
| Camera / mic | CoreMediaIO / CoreAudio listeners (`CameraMonitor.swift:56`, `MicrophoneMonitor.swift:56`) | none needed | Good |
| Screen recording | CGS notify 1502/1503 (`ScreenRecordingManager.swift:367-370`) | none needed | Good, except the leak in L1 |
| **Bluetooth audio** | 3 s main-thread IOBluetooth poll (T2) plus DNC names that probably never arrive | `IOBluetoothDevice.register(forConnectNotifications:selector:)` and per-device `register(forDisconnectNotification:selector:)`; keep a 60 s safety poll | Removes about 0.33 Hz of main-thread IOBluetooth XPC forever |
| **Focus / DND** | `Assertions.json` read every 2 s (T3), plus an FDA probe per tick | Listen to `_NSDoNotDisturbEnabled/DisabledNotification` (already registered, `DoNotDisturbManager.swift:91-106`) plus a `DispatchSource.makeFileSystemObjectSource` on the **directory** `~/Library/DoNotDisturb/DB` (survives atomic rename). Check FDA once, then again on `NSApplication.didBecomeActive` | Removes a 0.5 Hz wake-up and 3-5 syscalls per tick |
| **System timer bridge** | resident `log stream --level debug` (X3) plus a file watcher that goes deaf after a rename | Watch the **directory** `~/Library/Preferences` filtered to `com.apple.mobiletimerd.plist`, or re-arm after `.rename`/`.delete`. Start `log stream` only while `MTTimers` contains a running timer or Clock.app is running (the lifecycle observer exists at `SystemTimerBridge.swift:123-140`) | Removes one resident process for users who never use Clock timers |
| **Clipboard** | 0.5 s `changeCount` poll (T1) | macOS offers no pasteboard change notification; keep polling but (a) start and stop with the feature setting, not on first notch open; (b) 1 s with 0.2 s tolerance while the clipboard UI is closed; (c) check `pasteboard.types` before reading data (section 5) | The earlier audit rejected 1 s because two copies within a second could be lost; making that trade-off adaptive is the compromise |
| OSD helper | 1 Hz `proc_pidinfo` (K2) | `DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit)` on the frozen helper, then a short scan burst only after it exits | Previously skipped (P10) for flash risk; the cost is already low |
| Hover | 1 s `Task.sleep` loop per notch window (K1) | `NSTrackingArea` / SwiftUI `onHover`; run the loop only in hide-until-hover mode or while hovering | Removes N main-actor wake-ups/s with N screens |
| Lock state | 500 ms poll while locked (K4) | `com.apple.screenIsUnlocked` is already observed (`LockScreenManager.swift:141-160`); poll only for the first 5 s after lock as a safety net | Low gain |
| Calendar | 60 s loop forever (K3) | Start on lock, stop on unlock (the fetch is already skipped while unlocked, `CalendarManager.swift:358`) | Low gain |

---

## 3. Animations while invisible or closed; Reduce Motion and Low Power

* **Reduce Motion is honoured in 5 places only:** `NotchClockView.swift`, `NotchGamesView.swift`, `AgentsClosedIndicator.swift`, `NotchAgentsView.swift`, and `AtollNotch/UI/IdlePlaybackController.swift:38` (all files that read `accessibilityReduceMotion`). The always-visible closed-notch motion ignores it: PulsingModifier (D1), the download spinner (D3), the marquee (D5), the Lottie visualizer (D6), `MusicVisualizer` (T17), and the battery pulse (D4).
* **Low Power Mode is read in 3 places:** `BatteryActivityManager.swift`, `SiriVisibilityMonitor.swift:105` and `IdlePlaybackController.swift:39` (the idle engine caps at 12 fps, `IdleAnimationPlayback.swift:80, 99-102`). No other animation or poll changes in Low Power Mode.
* **Occlusion / visibility.** Only the idle engine checks window occlusion (`IdlePlaybackController.swift:156-181`). Notch windows on non-selected screens are kept at `alphaValue = 0` (`DynamicIslandApp.swift:1055-1063`). A window at alpha 0 may still report as visible, so its animations and timers keep running (INFERRED; UNKNOWN until measured). That applies to `MusicVisualizer` (it only stops when `window == nil`, `MusicVisualizer.swift:70-76`), D1, D3, D5 and D6.
* **Ordered-out Settings window.** `SettingsWindowController.swift:77-79` keeps the `NSHostingView` after close (`:115-119` only orders out). The selected tab's view tree and its `@ObservedObject`s stay alive for the rest of the session. Whether SwiftUI keeps evaluating `repeatForever` animations (e.g. `SettingsView.swift:581-583`) in an ordered-out window is UNKNOWN.
* **Positive examples worth copying:** the idle animation planner (`IdleAnimationPlayback.swift:91-129`) and the agents tick schedule (`AgentsComponents.swift:24-33`) remove their clock entirely when nothing needs it.

---

## 4. Observer and subscription leaks

| ID | file:line | Problem | Effect (est.) |
|---|---|---|---|
| L1 | managers/ScreenRecordingManager.swift:211-221, 367-370, 77-85 | `startMonitoring()` registers two `CGSRegisterNotifyProc` callbacks every time; `stopMonitoring()` cannot unregister them, and the callback does not check `isMonitoring` (it calls `checkRecordingStatus()`, `:424-449`) | Each Settings off/on toggle adds two more callbacks. After the user disables detection, recordings **still** show the recording live activity. Low CPU, real functional bug |
| L2 | managers/Agents/AgentUsageHistory.swift / AgentCenter.swift:200-206 | Not a leak, but unbounded work per tick: the full archive is copied (`let before = archive`, `:87`), compared (`:147`), re-encoded and re-sorted (`:155`) | See F1 |
| L3 | components/Live activities/MarqueeTextView.swift:110-155 | `resetAndStart()` sets `isAnimating = false`, then sets it back to `true` 0.1 s later. Chains already scheduled with `asyncAfter` check only `isAnimating`, so they survive, and every text change, `onAppear` or size-preference change adds another concurrent loop | The number of `withAnimation` cycles per visible title grows with each title change. The timer sneak-peek title changes every second (`ContentView.swift:1207`). Medium |
| L4 | DynamicIslandApp.swift:724, 1025-1088 | Block observers whose tokens are discarded | The owner lives for the whole process, so this is not a functional leak; listed for completeness |
| L5 | managers/CapsLockManager.swift:38-50 | Global `flagsChanged` monitor installed in `init` regardless of `enableCapsLockIndicator` | Low |
| L6 | components/Shelf/Services/ThumbnailService.swift:31-45 | Unbounded `[String: NSImage]` cache keyed by path and size; `pendingRequests` is cleared, `cache` is not | Grows with every shelf file ever previewed (section 6) |

The previous audit's leaks are fixed in this tree: the LocalSend discovery release (`LocalSendService.swift:90-130`), the picker click monitor (`LocalSendDevicePickerWindowManager.swift:106`), the eight pan-gesture scroll monitors reduced to one shared pair (`PanGesture.swift:190-237`), and the AudioTap observer tokens (`DynamicIslandApp.swift:190-276`). No `NSEvent` monitor is installed more than once in the current code; every installer either guards on `nil` or removes the old one first (E5, E6). No views create timers through `@ObservedObject` defaults (grep for `@ObservedObject ... = X()` without `.shared`: no hits).

---

## 5. Main-thread heavy work

| ID | file:line | Work | When | Cost (est.) |
|---|---|---|---|---|
| M1 | managers/ClipboardManager.swift:581-585, 610, 624-629 | `pasteboard.data(forType: .png/.tiff/jpeg)` **only to test presence**, then again to read; `Data(contentsOf:)` of the first copied image file | every clipboard change, on the main run loop (T1) | high for screenshots and large images: TIFF from a screenshot can be tens of MB, and data from a promise provider is pulled from the source app synchronously. Use `pasteboard.types` / `availableType(from:)` and read on a utility queue |
| M2 | managers/MusicManager.swift:1490-1500; extensions/NSImage+Extensions.swift:49-70 | `quickAverageColor()` calls `cgImage(forProposedRect:)`, which forces a full decode of full-resolution artwork on main (`coloredSpectrogram` default true, Constants.swift:1058) | every track change | medium: a 3000×3000 artwork is a 36 MB decode |
| M3 | MediaControllers/NowPlayingController.swift:578-628 | JSONL reader: a `String` buffer re-sliced per line (`buffer = String(buffer[range.upperBound...])`, `:592`) and a new `JSONDecoder` per line (`:604`); base64 artwork lines are hundreds of KB. A chunk that splits a UTF-8 sequence fails `String(data:encoding:)` and is **dropped** (`:585`) | every media update | medium; quadratic in line length. Runs on a cooperative thread, then hops to main for state |
| M4 | BluetoothAudioManager.swift:157-159, 344-372, 565 → 785 → 1542-1560 | `checkInitialDevices()` / poll → `createBluetoothAudioDevice` → device-type detection → `system_profiler` fallback, synchronously on main | at launch with BT audio connected, and on new connections | high when hit (seconds); the 30 s cache does not help the first call |
| M5 | BluetoothAudioManager.swift:304-324 | `IOBluetoothDevice.pairedDevices()` + `isConnected()` + SDP checks | every 3 s (T2) | medium |
| M6 | KeyboardBrightnessSensor.swift:111-118 via SystemKeyboardBacklightController.swift:47-48 | `corebrightnessdiag` spawn and plist parse in `currentLevel` | backlight key press, only without CoreBrightness | medium |
| M7 | managers/WebcamManager.swift:67-71, 121-134 | `AVCaptureDevice.DiscoverySession(...).devices` in `init` | launch (AppDelegate property, `DynamicIslandApp.swift:118`) | medium at launch: loads CoreMediaIO and DAL plug-ins (INFERRED) |
| M8 | managers/DownloadManager.swift:143-145, 540-543 | `contentsOfDirectory(~/Downloads)` just to trigger the TCC prompt | launch | low to medium for very large Downloads folders |
| M9 | managers/LockScreenManager.swift:375-380 | `CGSessionCopyCurrentDictionary` in `MainActor.run` at 2 Hz | while locked | low |
| M10 | ContentView.swift (70 `Defaults[...]` reads, 46 `@Default`, 17 `@ObservedObject` + 2 `@EnvironmentObject` at `:42-69`) | whole-body re-evaluation on any publish from `MusicManager` (35+ `@Published`, `MusicManager.swift:569-720`), `TimerManager` 1 Hz, `ReminderLiveActivityManager.currentDate` 1 Hz, `LocalSendService.sendProgress` | continuous while those publish | medium; the multiplier on everything above. `Logger.log` also reads `Defaults[.logLevel]` per call (`utils/Logger.swift:96`) |
| M11 | managers/FullScreenArtworkWindowManager.swift:499-510 | `killall` with `waitUntilExit()` | user-initiated wallpaper mode | low |

AppleScript is **not** executed on the main thread: `AppleScriptHelper.swift:29` runs it in `Task.detached`. There is no large JSON decode on main: the agents archive (≤32 MB, `AgentUsageHistory.swift:81-85`) is decoded on the actor's executor, and the Focus assertions file on `pollingQueue`.

---

## 6. Memory

| ID | file:line | What | Bound | Risk (est.) |
|---|---|---|---|---|
| R1 | managers/ImageService.swift:33-37 | `URLCache` memory capacity **50 MB**, disk 100 MB, for artwork | capped, but 50 MB of memory is large for an always-on accessory app | medium. 8-10 MB is enough for a few artworks |
| R2 | MusicManager.swift:571-572, 1488-1509; NSImage+Extensions.swift:357-381 | `albumArt` and `albumArtGlowTexture` held at **full source resolution**. `preBlurred(radius: 40)` blurs the full-size image and creates a **new `CIContext` on every call** (`:375`) | 2 images | high per track change for 3000 px artwork: about 36 MB per bitmap, plus CIContext setup (tens of ms, tens of MB transient). Downsample to ≤512 px first and reuse one context |
| R3 | components/Shelf/Services/ThumbnailService.swift:31 | unbounded `[String: NSImage]` | none | medium over long sessions; use `NSCache` with `countLimit` |
| R4 | managers/Agents/AgentUsageHistory.swift:57, 142-146 | up to 100 000 records in memory, plus a second copy in `AgentCenter.usageReport` (`AgentCenter.swift:79, 204`) and a third in `before` (`AgentUsageHistory.swift:87`) | 100 k | medium to high when agents are on: roughly 300 B per record in memory gives about 30 MB per copy at the cap (estimate) |
| R5 | MediaControllers/SpotifyController.swift:435, 602 | `[String: CacheEntry]`; expiry checked on read, never evicted | none | low (small strings) |
| R6 | managers/Agents/TranscriptTail.swift:62-63 | per-path summaries, never evicted | grows with sessions seen | low |
| R7 | managers/ClipboardManager.swift:757-771, 40-57 | history JSON-encoded into UserDefaults. Text items have no size cap (a pasted 50 MB log goes into the plist). In-memory images are pruned by id (`:46`) | count-bounded (`clipboardHistorySize` default 3) plus pinned | medium edge case (the previous audit's P27 was skipped) |
| R8 | MusicManager.swift:659-690 | lyrics cache capped at 80 (`:661`, `:687`) | 80 | low, fine |
| R9 | AtollNotch/UI/IdleSpriteSheetPlayer.swift:30-31, 54 | frame cache capped at 96, then cleared | 96 | low, fine |
| R10 | SystemTimerBridge.swift:106, 389-392 | log buffer capped at 1 MB | 1 MB | low, fine. Per-line `removeSubrange` (`:398`) is quadratic within a burst |
| R11 | SettingsWindowController.swift:26-36, 74-79 | Settings `NSWindow(defer: false)` and `NSHostingView` built at app init and **rebuilt once more** by `setUpdaterController` (`:46-50`, called at `DynamicIslandApp.swift:53`); kept for the whole session | 1 window | low to medium: the window backing store is allocated immediately (`defer: false`) |

**Autorelease pressure in loops.**
* `JSONLUsageParser.swift:177-208` runs `JSONSerialization` plus `String(data:)` per line with **no `autoreleasepool`**. Each line also does `buffer.removeSubrange(...)` (`:185`), an O(n) memmove per line, so O(n²) per 64 KB chunk. It runs inside a task-group child, so bridged temporaries live until the scan ends.
* `AgentUsageHistory.swift:76, 123-127` is a good example: it wraps both the whole refresh and each line in `autoreleasepool`.
* `SystemTimerBridge.consumeLogData` (`:395-401`) and `NowPlayingController.processLines` (`:580-595`) parse many lines per callback without a pool.

---

## 7. Launch path (in order) and what can be deferred

Order follows Swift property initialisation, then `init()`, then `applicationDidFinishLaunching`. A "Defer?" entry is a recommendation.

| # | Step | file:line | Defer? |
|---|---|---|---|
| 1 | `LegacySettingsMigration.runIfNeeded()` (one-time copy, then a flag check) | DynamicIslandApp.swift:32; models/TopletProject.swift:45-70 | no (must run first) |
| 2 | `AppDelegate` created by `@NSApplicationDelegateAdaptor`; stored properties instantiate in order: `DynamicIslandViewModel` (~10 Defaults sinks, `models/DynamicIslandViewModel.swift:176-367`), `DynamicIslandViewCoordinator.shared`, **CalendarManager** (60 s loop plus EventKit list load, `CalendarManager.swift:63-70`), **WebcamManager** (AVCapture discovery, M7), **DoNotDisturbManager**, **BluetoothAudioManager** (observers, 3 s poll, deferred initial device check, M4), NetworkConnectivityManager, IdleAnimationManager, **DownloadManager** (Downloads listing plus vnode watcher), LockScreenPanelManager, MediaControlsStateCoordinator, **SystemTimerBridge** (spawns `log stream` from `init`, `SystemTimerBridge.swift:153-173`), ExtensionXPCServiceHost, ExtensionRPCServer | DynamicIslandApp.swift:113-128 | yes: WebcamManager discovery until the camera/mirror UI is first shown; SystemTimerBridge `log stream` until a timer exists (F3); Bluetooth initial check off main |
| 3 | `SPUStandardUpdaterController` (now started only if a feed exists) | DynamicIslandApp.swift:46-50 | already gated |
| 4 | `SettingsWindowController.shared` builds the Settings window and hosting view, then `setUpdaterController` builds it **again** | DynamicIslandApp.swift:53; SettingsWindowController.swift:26-50, 74-79 | yes: create the hosting view lazily in `showWindow()`, and use `defer: true` |
| 5 | `applicationDidFinishLaunching`: disable automatic/sudden termination, post `didBecomeActive` DNC | DynamicIslandApp.swift:733-748 | no |
| 6 | Lock-screen live-activity and LockScreenManager configure; `startAlarms()`; extension XPC listener; RPC WebSocket server on 127.0.0.1:9020, now gated on `enableThirdPartyExtensions` (gate added during this audit; the setting defaults to true, Constants.swift:1395) | :750-761 | RPC server: start on the first authorised extension client rather than on the setting alone |
| 7 | 6 Defaults migrations plus 2 DDC sinks | :764-783 | no (cheap) |
| 8 | `idleAnimationManager.initializeDefaultAnimations()` | :786; IdleAnimationManager.swift:94-117 | no (cheap after first run) |
| 9 | `applySelectedAppIcon()`, `installTopMenuItemsIfNeeded()`, focus-menu sink | :788-796 | could be deferred one run-loop turn |
| 10 | `SystemHUDManager.setup` (13 sinks, starts the OSD watcher), BetterDisplay and Lunar configure (workspace observers even when the integration is off) | :799-805 | BetterDisplay/Lunar observers only when enabled |
| 11 | `ClipboardManager.purgeStoredHistoryIfPersistenceDisabled()` | :809 | no |
| 12 | ScreenRecordingManager, DND (2 s poll), PrivacyIndicator, NWPathMonitor | :812-825 | no (event-driven; DND see F7) |
| 13 | AudioTap if the waveform is on, plus about 25 Defaults/Combine sinks for window sizing and shortcuts | :827-1022 | no |
| 14 | `MemoryUsageMonitor.startMonitoring()` (8 s) | :932 | could start after 60 s |
| 15 | `AgentsRuntime.configure()` (nothing runs unless enabled) | :935 | already gated |
| 16 | Notification observers and `KeyboardShortcuts` handlers | :1025-1139 | no |
| 17 | **Notch window creation**: `createDynamicIslandWindow` hosts `ContentView`, whose 19 `@ObservedObject`s instantiate `MusicManager` (perl deprecation probe X2, then the perl stream X1), `ScreenRecordingManager`, `PrivacyIndicatorManager`, `CapsLockManager` (global monitor), `LocalSendService`, `ShelfStateViewModel`, ... | :1141-1149; ContentView.swift:42-69 | cache the `MediaChecker` result per OS build so launch spawns one perl, not two in series |
| 18 | Onboarding window plus welcome sound (first launch only) | :1152-1157 | no |
| 19 | Lock-screen weather: `prepareLocationAccess()` plus a forced network refresh | :1161-1166 | yes: refresh on first lock instead of at launch |
| 20 | `LockScreenTimerWidgetManager` warm-up | :1171-1172 | no |

Estimated launch-time process spawns with defaults: `perl test` (X2), then `perl stream` (X1), and `log stream` (X3). Add `system_profiler`/`pmset` when Bluetooth audio is connected (X5), and `killall -STOP` once the OSD helper is found (X8).

---

## 8. Dependencies

SwiftPM references in `Toplet.xcodeproj/project.pbxproj:970-1070` (versions from `project.xcworkspace/xcshareddata/swiftpm/Package.resolved`). The local build mirrors 11 of them in `local/.work/Package.swift:17-31`.

| Package | Pin | Used by | Verdict |
|---|---|---|---|
| Defaults (sindresorhus) | 9.0.3 | 160 files, 922 `Defaults[...]` reads | essential; note the per-read decode cost (M10). The local vendor copy omits the swift-syntax macro targets (`local/.work/vendor/Defaults/Package.swift:3-4`) |
| KeyboardShortcuts | 2.3.0 | 6 files | fine |
| Sparkle | 2.7.0 (3.0 MB framework in `dist/Toplet.app`) | updater; started only with a feed (`DynamicIslandApp.swift:46-50`) | fine; dormant until a feed exists |
| LottieUI (jasudev, branch `main`) + lottie-spm (`main`) | Lottie.framework is **9.6 MB** in the bundle | LottieUI imported in 3 files (`Music/LottieAnimationView.swift`, `Settings/SettingsView.swift`, `Extensions/ExtensionRenderingHelpers.swift`); Lottie imported directly in 5 | **flag**: LottieUI is a thin wrapper over a library the app already imports directly. Lottie 4.x ships its own SwiftUI `LottieView`. Drop LottieUI. Lottie itself is used for real features (idle, extensions, fingerprint) |
| SwiftTerm | 1.13.0 (vendored) | terminal tab (default off) | acceptable, but always linked for an opt-in feature |
| SkyLightWindow (branch `main`) | vendored | 13 files (lock-screen windows) | fine |
| AtollExtensionKit (branch `main`) | | 16 files | fine |
| MacroVisionKit | 0.1.0 | one call, `detectFullscreenApps` (`observers/FullscreenMediaDetection.swift:83`) | small; could be replaced by a `CGWindowListCopyWindowInfo` check, low priority |
| swift-collections | 1.1.4 (13 MB checkout) | **one `OrderedSet`** (`components/Shelf/TrayDrop.swift:27-31`) | **flag**: heavy for trivial use; an array with a uniqueness check or `NSOrderedSet` does the job |
| swiftui-introspect | 1.3.0 | `import SwiftUIIntrospect` in ContentView.swift:29, SettingsView.swift:17, WelcomeView.swift:24, but **no `.introspect(` call anywhere** | **flag**: dead dependency; remove the imports and the package |
| LaunchAtLogin-Modern (branch `main`) | | one `LaunchAtLogin.Toggle` (`SettingsView.swift:1223`) | **flag**: trivial; `SMAppService.mainApp.register()/unregister()` is about 10 lines |
| Pow (EmergeTools) | 1.0.5 | **no import, no product dependency** (pbxproj lists it only in `packageReferences`, `:431`, `:1026-1032`) | **remove**: fetched and resolved for nothing |
| open-meteo | 1.4.16 | **no import, no product dependency** (`:437`, `:994-1000`) | **remove**; it also pulls swift-argument-parser and other server-side packages into `Package.resolved` |
| swift-syntax 601.0.1, swift-argument-parser 1.7.1 | transitive (Defaults macros / open-meteo) in `Package.resolved` | not linked by the app | they go away with the two removals above and the vendored Defaults |

Other bundle weight: the executable is 54 MB and the bundle 79 MB (`dist/Toplet.app`, built 16:42 by someone else). `MediaRemoteAdapter.framework` and 8 `.mov` AirPods animations are in Resources.

Maintenance note: `AtollAgents/Core` and `AtollAgents/UI` duplicate the compiled agents sources byte for byte, so every performance fix there has to be applied twice.

---

## 9. Top 15 prioritised fixes

Impact is estimated, not measured; the live section should confirm or reorder these. Effort: S < half a day, M ≤ 2 days, L > 2 days.

| # | Fix | Expected impact (est.) | Effort | Files |
|---|---|---|---|---|
| F1 | **Agents usage archive.** Persist on change at most every 5 min and on `stop()`/quit, not every 10 s. Keep running per-hour totals instead of publishing the full sorted record array; give `AgentUsageReport` a revision number and compare that, not the arrays (`AgentCenter.swift:204`). Keep a per-root directory mtime to skip the full `FileManager.enumerator` walk when nothing changed | High while agents are on: removes a multi-MB JSON encode plus an atomic write every 10 s during active sessions and an O(n) main-actor comparison and fold (`AgentsIntegration.swift:205-213`) | M | managers/Agents/AgentUsageHistory.swift:75-156; AgentCenter.swift:189-207; AgentsIntegration.swift:205-215 (mirror in AtollAgents/Core) |
| F2 | **Bluetooth.** Replace the 3 s main-thread poll with IOBluetooth connect/disconnect notifications plus a 60 s safety poll. Move `createBluetoothAudioDevice` and the `system_profiler` fallback onto `batteryFetchQueue`. Check notification names before stringifying `userInfo` in the wildcard handler | Medium idle (≈0.33 Hz of XPC removed); removes a possible multi-second main-thread stall when BT audio connects | M | managers/BluetoothAudioManager.swift:157-159, 176-189, 284-340, 413-433, 565, 785, 1542-1560 |
| F3 | **System timer bridge.** Start `log stream --level debug` only while a timer is running or Clock.app runs. Watch the Preferences directory (or re-arm after `.rename`) instead of the plist file descriptor | Medium: one resident `log` process fewer, lighter debug-level logd load, and a watcher that keeps working | M | managers/SystemTimerBridge.swift:153-214, 273-328, 428-455 |
| F4 | **Clipboard capture.** Detect with `pasteboard.types`, read image data once on a utility queue, and skip `Data(contentsOf:)` for files above a size cap. Start/stop the timer with `enableClipboardManager`, with a longer interval and tolerance while the clipboard UI is closed | High on large copies (no tens-of-MB main-thread reads); halves idle wake-ups | S | managers/ClipboardManager.swift:374-390, 563-675; DynamicIslandHeader.swift:176; NotchClipboardView.swift:108 |
| F5 | **Artwork pipeline.** Downsample artwork to ≤512 px once on arrival, compute colours and blur from that, use one shared `CIContext`, and keep only the downsampled image unless the full-screen artwork view needs the original | High per track change (tens of MB transient and a main-thread decode removed); lower resident memory | S | managers/MusicManager.swift:1418-1509; extensions/NSImage+Extensions.swift:49-70, 117-135, 357-381 |
| F6 | **Display-rate pulses.** Replace `repeatForever` SwiftUI pulses in the closed notch with Core Animation layers (as `MusicVisualizer` does) or a 2-4 Hz `TimelineView` step; honour Reduce Motion and Low Power; pause when the window is not visible | High during long recordings and downloads (same class as the 10 % glyph issue) | S | components/Live activities/PulsingModifier.swift:27-31; Downloads/SpinningCircleDownloadView.swift:37-41; UI/RecordingIndicator.swift:64-68 |
| F7 | **Focus polling.** Directory vnode source on `~/Library/DoNotDisturb/DB` plus the existing distributed notifications; check FDA once and again on app activation | Low to medium: removes a permanent 0.5 Hz wake-up and 3-5 syscalls per tick | S | managers/DoNotDisturbManager.swift:584-640; helpers/FullDiskAccessPermissionStore.swift:31-53 |
| F8 | **Marquee loop.** Add a generation token so old `asyncAfter` chains exit; stop while the notch window is hidden; honour Reduce Motion (static truncation) | Medium: no more stacked animation loops on long titles | S | components/Live activities/MarqueeTextView.swift:107-155 |
| F9 | **Screen-recording callback leak.** Register the CGS procs once (static flag) and check `isMonitoring` in the callback | Bug fix: disabling detection really stops the UI; no duplicate callbacks | S | managers/ScreenRecordingManager.swift:77-85, 211-221, 367-370 |
| F10 | **Now-playing stream parsing.** Split on `0x0A` in a `Data` buffer, keep one `JSONDecoder`, and stop dropping UTF-8-split chunks; decode artwork only when its hash changes | Medium per update (quadratic cost on large artwork lines removed); fixes lost updates | S | MediaControllers/NowPlayingController.swift:578-628, 432-440 |
| F11 | **LLM usage scan hygiene.** Add `autoreleasepool` per line, use index-based line slicing instead of `removeSubrange`, and prefilter by mtime inside the enumerator (`includingPropertiesForKeys: [.contentModificationDateKey]`) instead of materialising the whole `~/.claude/projects` path list | Medium on the Usage tab with details on: bounded peak memory (keeps the old memory warning from coming back) | S | managers/LLMUsage/JSONLUsageParser.swift:132-216; ClaudeUsageProvider.swift:46-49 |
| F12 | **Hover polling.** Replace the per-window 1 s `Task.sleep` loop with tracking areas; keep the 50 ms loop only for hide-until-hover screens | Low to medium: N wake-ups/s fewer (N = notch windows) | M | ContentView.swift:2174-2211, 882 |
| F13 | **Launch deferrals.** Build Settings lazily (and only once), defer AVCapture discovery, cache the MediaChecker verdict per OS build, start the weather refresh on first lock, start the RPC server on the first authorised client | Medium: faster time to a working now-playing controller, fewer launch spawns, less resident memory | M | SettingsWindowController.swift:26-79; DynamicIslandApp.swift:46-53, 118, 755-761, 1161-1166; WebcamManager.swift:67-71; MediaChecker.swift; MusicManager.swift:745-769 |
| F14 | **Caches.** Artwork `URLCache` memory 50 MB → 8 MB; `ThumbnailService` → `NSCache` (`countLimit` 200); evict expired Spotify entries; cap persisted clipboard text size (or store large text as a file like images) | Medium: up to about 40 MB lower worst-case resident memory | S | managers/ImageService.swift:33-37; components/Shelf/Services/ThumbnailService.swift:31-45; SpotifyController.swift:435, 602; ClipboardManager.swift:757-771 |
| F15 | **Dependencies and the Lottie visualizer.** Remove the Pow and open-meteo references, the unused SwiftUIIntrospect imports and package, LaunchAtLogin-Modern (use `SMAppService`) and swift-collections (one `OrderedSet`); use Lottie's own `LottieView` instead of LottieUI; bundle the visualizer JSON instead of fetching it from lottiefiles.com, and pause it when playback pauses | Low runtime gain, smaller resolve/build graph, no network fetch for a decoration, no animation while paused | S (pbxproj edit needs Xcode) | Toplet.xcodeproj/project.pbxproj:431, 437, 994-1032; components/Music/LottieAnimationView.swift:28-44; ContentView.swift:29, 1812; SettingsView.swift:13, 17, 1223; WelcomeView.swift:24; Shelf/TrayDrop.swift:27-31 |

Smaller items not in the top 15, all effort S: tolerance on the zero-tolerance lock-screen weather timers (`LockScreenWeatherWidget.swift:120, 191, 196`); cache `Defaults[.logLevel]` in `Logger` (`utils/Logger.swift:96`); gate the CapsLock global monitor on its setting (`CapsLockManager.swift:38-50`); cache the keyboard backlight level instead of spawning `corebrightnessdiag` per key press (`SystemKeyboardBacklightController.swift:47-48, 65-66`); stop the calendar loop while unlocked (`CalendarManager.swift:347-361`); gate `RealTimeWaveformScrubberView`'s 60 Hz timer on `isPlaying` and read the bar count once (`:42-66`); lower the 30 fps progress `TimelineView`s to a rate derived from pixels per second (D7).
