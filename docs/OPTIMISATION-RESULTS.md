# Optimisation results

Branch `local-build`, base commit `8aa5802`, 2026-10-21, macOS 27.2 / M2. Applies `docs/PERFORMANCE-AUDIT.md` (SAFE and LOW-RISK proposals) and `docs/DEAD-CODE-REPORT.md` (NONE/LOW-risk removals). Everything was compiled with `JOBS=2 nice -n 15 bash local/build.sh release` and exercised only through copies with other bundle ids (`com.local.atoll.perfnew` = `dist/AtollNew.app`, `com.local.atoll.perfbase` = `dist/AtollBase.app` = original code). The user's installed instance (pid 87070) was never touched; `dist/Atoll.app` was rebuilt from the final tree and **not installed**.

Evidence tags: **MEASURED** (number below), **BUILT** (compiles, test copy launched, stayed alive, no crash report), **CODE** (reasoned from the source, not exercisable here), **NOT VERIFIED**.

## 1. Commits

| Commit | Content |
|---|---|
| `d4da1fe` | Batch 1: dead code and unused resources |
| `1c02863` | Batch 2: SAFE perf items P01-P06 |
| `23356bf` | P09 |
| `1723b15` | P11, P12, P13, P14 |
| `00e87ce` | P16 |
| `e4d2fff` | P17, P20 |
| `c3e0075` | P18, P29 (tolerance only) |
| `25d39cc` | P21 |
| `a98d179` | P22 |
| `ed8cb26` | P23 (back-off only) |
| `e857616` | P24 |
| `428f4de` | P28 |

Verification after each batch: clean release build, `open -n` of the perfnew copy, alive for 40-45 s, no new file in `~/Library/Logs/DiagnosticReports`, `[Lifecycle] launched` line present and no other lifecycle anomaly, OSDUIHelper un-frozen afterwards (state `T` -> SIGCONT). The OSD suppression itself was re-checked after P01/P09 (`ps` shows OSDUIHelper stopped ~7 s after launch in both base and new copy).

## 2. Applied: dead code (batch 1, `d4da1fe`)

| What | Count | Risk class | Evidence |
|---|---:|---|---|
| Whole Swift files with zero code references (report sets A + B, plus `UpdateFoundView.swift`, which became a file with only an unused private `String` extension) | 43 files | NONE / LOW | build clean; token proof in report; post-edit scan found no remaining reference to any removed type name (code, previews or comments excluded) |
| Dead private/internal declarations from report 3.1-3.4 (types, funcs, props, `#Preview` blocks) | 143 of 144 rows | NONE / LOW | build clean |
| Cascade leftovers found with a re-run of the token proof: `DownloadIconStyle`, `QuickLookDataSource`, BetterDisplay request/response notification names, `AppleNotesSyncManager.syncTask`, empty `extension View {}` in Logger | 6 | NONE | build clean |
| `if false { Text("PRO") ... }` in `WelcomeView`; constant-false `shouldHideDuringDrag` condition + dead `else` in `ShelfItemView`; two commented-out code blocks (`DynamicIslandApp`, `ContentView`) | 4 | NONE | build clean |
| `Defaults` keys with zero references: `enableSafariDownloads`, `alwaysHideInFullscreen`, `enableWobbleAnimation`, `autoStartStatsMonitoring`, `tileShowLabels`; plus keys whose only user was an unused `@Default` wrapper in `SettingsView` (`showEmojis`, `selectedDownloadIconStyle`, `systemHUDSensitivity`, `hasSeenOSDAlphaWarning`) and those 4 wrappers (**this is also P08**) | 9 keys + 4 wrappers | NONE / LOW | build clean; grep of whole repo (incl. plists, scripts) found no other use |
| Resources: imagesets `LinkedIn`, `chrome`, `defaultmusic`, `logo`; `metal/visualizer.metal`; stale root `Localizable.xcstrings` (the build uses `Toplet/Localizable.xcstrings`) | 6 items, 4.26 MB | LOW | no code reference (`"logo"` grep, `logo2` is a different set and kept); not in `project.pbxproj`; `local/tools/make_resources.py` reads only `Toplet/Localizable.xcstrings` |

Total (git, `8aa5802..HEAD`): 138 files changed, 114,813 deletions, 416 insertions (the insertions are the perf changes plus re-indentation). Swift: **43 files deleted (142,904 bytes) and 6,140 lines removed, 416 added, net -5,724 lines and about -203 KB**; non-Swift: 11 files, 4,255,891 bytes (mostly the 2.6 MB root xcstrings and the 1.5 MB `logo` image). The report's estimate for sets A-C was 5,850 lines / 206 KB; the extra comes from the 4 `@Default` wrappers, keys, cascade items and the file-level leftovers.

One report error caught by the compiler: `AppleNotesSyncManager.syncFolderName` was listed dead but is used inside AppleScript string interpolation (`"\(Self.syncFolderName)"`). The report's token proof strips string contents, so **interpolated uses are invisible to it**. It was restored. All other removals compiled, which is the ground truth for code references.

### Dead-code items deliberately not applied

| Item | Reason |
|---|---|
| `applicationShouldTerminate` (report 3.2, "zero references") | It is the `NSApplicationDelegate` callback and now carries the quit-sender logging that the mission says to keep. Report was written before that edit and cannot see delegate callbacks. |
| `LottieAnimations/Lock.json` | Referenced by `project.pbxproj` lines 23, 92, 271, 474; deleting it would break an Xcode build and the pbxproj must not be edited here. Its only user (`LockIconLottieView`) was removed, so the 4 KB file is now an orphan. |
| 74 stale string-catalog keys, 20 unmatched keys | NEEDS-CHECK; Xcode "clean up strings" should do it. |
| Report 3.5 internal members, unused `@Default` wrappers outside `SettingsView`, `ContentView.swift:96-104` | NEEDS-CHECK (intentional invalidation triggers, eager-init holders). |
| `Defaults` classes C (`expandedDragDetection`, `colorHistorySize`), E (`releaseName`, `customVisualizers`), F (migration keys) | Removing needs a UI/feature decision or breaks upgrades. |
| Duplicate `MediaRemoteAdapter.framework`, `logo2` = `AppIcon` duplicate, AppIcon duplicate pairs | NEEDS-CHECK, pbxproj-referenced. |
| `Pow` and `open-meteo` SwiftPM packages | pbxproj cannot be validated without Xcode. **Whoever has Xcode can drop the two `XCRemoteSwiftPackageReference` blocks, their `packageReferences` lines and the two `Package.resolved` pins** (report section 7); neither is linked or imported. |

## 3. Applied: performance changes

Class = audit class. "Evidence" says what was actually shown.

| ID | File | Change | Class | Evidence |
|---|---|---|---|---|
| P01 | `managers/SystemOSDManager.swift` | Watcher tick: one `proc_pidinfo` check (alive, still `SSTOP`, name `OSDUIHelper`) instead of a full process-table scan while the frozen helper is unchanged; full scan still at least every 2 s and at once when the helper changes or disappears. Did **not** use `PROC_UID_ONLY` (would change which processes are considered). | SAFE | MEASURED (standalone harness, 740 processes): full scan 459 us, frozen check 0.58 us (790x). Steady state (1 s cadence) now does 0.5 scans/s instead of 1; in the 150 ms confirm phase 0.5/s instead of 6.7/s. BUILT: OSDUIHelper is frozen ~7 s after launch exactly as in the base copy (4 interleaved runs). Whole-process effect at idle is below noise (section 4). |
| P02 | MenuBarLayout, BluetoothAudioManager, ClipboardManager, StatsManager, PerAppVolumeManager, TimerManager (x2), MusicVisualizer | `timer.tolerance` = 10 % of the interval (clipboard 0.05 s). Repeating timers keep their schedule; coalescing only. | SAFE | BUILT. Wake-up effect not separable from noise. |
| P03 | `ContentView.swift` | `statsManager` is a plain `let` (its published values are never read in the body). | SAFE | BUILT. CODE: Stats samples no longer invalidate `ContentView`. Not measurable without the Stats tab open (needs a human). |
| P04 | `ContentView.swift` | `dynamicNotchSize` evaluated once in `rootBodyView`. | SAFE | BUILT. |
| P05 | `utils/Logger.swift` | `Logger.log` message is an `@autoclosure`; `osLoggerCache` guarded by an `NSLock`. Level check was already first. Level is still read from Defaults on each call (not cached). | SAFE | BUILT (all 78 call sites compile unchanged). |
| P06 | `managers/LocalSendDevicePickerWindowManager.swift` | Keep the click-outside `NSEvent` monitor token, remove it in `hide()` and before re-adding. | SAFE | BUILT. CODE only (needs the picker). |
| P08 | `components/Settings/SettingsView.swift` | 4 unused `@Default` wrappers removed (batch 1). | SAFE | BUILT. |
| P09 | `SystemOSDManager.swift`, `models/Constants.swift` | `disableSystemHUD()` no longer replaces a live watcher (restart reset it to the 150 ms schedule); the enable-transition work still runs, so the helper is still re-frozen on each call. Legacy DDC keys written only when different. | LOW | BUILT; freeze behaviour re-checked. |
| P11 | `managers/BluetoothAudioManager.swift` | The wildcard (`name: nil`) distributed-notification observer exists only while the HUD setting is on **and** an AirPods-type device is connected (block API, removed by token). | LOW | BUILT. CODE only (no AirPods here). |
| P12 | same | The `ioreg -r -l -w 0` fallback runs off the main actor (selector read and presentation stay on main). | LOW | BUILT. CODE only; the path is hit only when the dynamic-selector read fails. |
| P13 | same | After the first connect/disconnect notification the 3 s fallback poll becomes 15 s. The poll was **not** gated on the HUD settings because `connectedDevices` also feeds the lock-screen widget and `InlineHUD`; the `pairedDevices()` call was **not** moved off main (IOBluetooth thread-affinity, no hardware to test). | LOW (partial) | BUILT. CODE only. |
| P14 | same | The `log stream` AirPods child is started/stopped with the same condition as P11. | LOW | MEASURED: child processes of the test copy 3 -> 2 (`log` x3 in base, x2 in new, no AirPods connected). |
| P16 | `extensions/PanGesture.swift` | One shared local + one global scroll-wheel monitor (`ScrollGestureHub`) for all `panGesture` views (was a pair per gesture: 8 monitors for 4 gestures). The hub computes the screen point once and skips a gesture whose window frame (inflated 2 pt, 6 pt vertically) does not contain it, before any view-coordinate conversion. Per-gesture accumulation logic untouched. | LOW | BUILT. CODE only; gestures need a trackpad. |
| P17 | `ContentView.swift`, `managers/MenuBarLayout.swift` | The 3 s accessibility scan timer runs only while the closed content is wider than the physical notch. The app-activation observer (and its immediate scan) stays, and a scan runs when the timer is turned on. | LOW | BUILT. CODE only; the visual offset was not seen (no screenshots allowed). |
| P18 | `managers/MediaKeyInterceptor.swift` | Tolerance on the retry timer only. Retry state/back-off policy **not** changed: persisting it across `stop()/start()` would stop the Settings-toggle retry that issue #601 relies on. | LOW (partial) | BUILT. |
| P20 | `ContentView.swift` | Tolerance (10 %) on the hover-polling `Task.sleep`. The loop itself is unchanged. | LOW (partial) | BUILT. |
| P21 | `managers/CalendarManager.swift` | The 60 s lock-screen calendar loop skips the EventKit fetch while `LockScreenManager.isLocked` is false (the only reader, the lock-screen widget, forces its own refresh on appear). | LOW | BUILT. CODE only. |
| P22 | `LocalSendService.swift`, `FileShareView.swift`, `LocalSendDevicePickerWindowManager.swift` | `stopDiscovery()` (cancels announce/cleanup loops, multicast group, TCP 53317 listener); `retainDiscovery()/releaseDiscovery()` from `onAppear/onDisappear` of the shelf share view and the picker; stop happens 30 s after the last client left and never while sending or refreshing. | LOW | BUILT; **user's own instance shows the leak: `lsof` lists `*:53317 (LISTEN)` for pid 87070** (read-only look). In the test copy 53317 is closed at idle both before and after, because the shelf is never opened; the stop path itself needs the shelf open and is **NOT VERIFIED at runtime**. |
| P23 | `services/Extensions/ExtensionRPCServer.swift` | Exponential back-off for listener restarts (3 s, 6, 12 ... 300 s; resets when a failure comes >60 s after the last restart). Server start is still unconditional: port 9020 behaviour unchanged. | LOW (partial) | BUILT. Observed indirectly (section 4: the test copies cannot bind 9020 because the user's instance holds it). |
| P24 | `components/LockScreen/LockScreenMusicPanel.swift` | `TimelineView(.animation)` -> `minimumInterval: 1/30` (2 places). | LOW | BUILT. Visual smoothness not checked. |
| P28 | `managers/DownloadManager.swift` | Subscription to `enableDownloadListener` is stored (it was dropped immediately, so the toggle did nothing until relaunch); `options: []` because the initial state is handled in `init`. **This changes behaviour on purpose (bug fix): the Settings toggle now works live.** | LOW | BUILT. CODE only. |
| P29 | `managers/SystemMediaControllers.swift` | Tolerance on the brightness fallback poll only; interval not lengthened. | LOW (partial) | BUILT. |

## 4. Measurements

Harness: `local/perf/measure.py` (120 s window after a 20 s warm-up, `top`, 2 s samples) and a precise variant using `proc_pid_rusage` (CPU ns and interrupt wake-ups, 90 s window after 30 s warm-up, same launch method), alternating base/new. The user's instance was running the whole time (YouTube Music connected), so machine load is not identical between runs. Raw JSON: `docs/logs/perf-baseline*.json`, `docs/logs/perf-optimised-r*.json`.

### measure.py (CPU % of one core, `top`)

| Run | cpu mean | cpu p95 | cpu max | idle wake/s | RSS end | child processes |
|---|---:|---:|---:|---:|---:|---:|
| baseline r1 (earlier, `perf-baseline.json`) | 0.56 | 1.5 | 3.3 | 0.1 | 96 MB | 3 |
| baseline r2 | 0.56 | 0.8 | 3.3 | 0.2 | 96 MB | 3 |
| baseline r3 | **6.4** | **23.1** | 32.5 | 0.3 | 117 MB | 3 |
| optimised r1 | **3.06** | **21.2** | 28.9 | 0.1 | 105 MB | 2 |
| optimised r2 | 0.23 | 0.4 | 0.5 | 0.1 | 95 MB | 2 |

Quiet runs only: baseline 0.56 / 0.56 vs optimised 0.23. **Both builds also showed the 20+ % bursts** (one of three baseline runs, one of two optimised runs); they were not caught by 3 extra 120-150 s `sample` sessions of the optimised copy (no burst occurred), so their source is **not identified and not fixed by this work**. `top`'s CPU column has 0.1 resolution and `top`'s idle wake-up column is a coarse counter, so these numbers cannot resolve the small effects of individual changes.

### proc_pid_rusage (precise), interleaved, 3 pairs

| Metric | baseline (3 runs) | optimised (3 runs) | median change |
|---|---|---|---|
| CPU ms per s | 1.643, 0.320, 0.251 | 0.370, 0.080, 0.133 | 0.32 -> 0.133 (-58 %) |
| Interrupt wake-ups per s | 15.27, 4.83, 5.52 | 5.37, 2.11, 1.98 | 5.52 -> 2.11 (-62 %) |
| Child processes | 3 | 2 | -1 (`log stream` for AirPods not started without AirPods) |

Noise: the same build varied 0.25 to 1.64 ms/s across runs, so only the direction is reliable, not the percentage. **Caveat that inflates the improvement:** the test copies cannot bind port 9020 because the user's instance holds it, so their RPC server fails and (base) restarts both listeners every 3 s; the optimised copy backs off (P23). That loop does not exist in the user's real instance, where 9020 binds. The wake-up reduction for the real instance will be smaller than the table. An earlier pair on the batch-2 build (before P23/P14/P16/P17...) gave 0.138 / 1.203 (base) vs 0.135 / 0.142 (new) ms/s.

### Could not be measured

* Interaction bursts (hover, scroll gestures, shelf use, music with lyrics, AirPods listening-mode events, lock/unlock restart storms): need a human or hardware.
* P03/P04 (SwiftUI invalidation) effect: needs the Stats tab / live activities open and Instruments.
* Energy impact in mW: `powermetrics` needs root.

## 5. Skipped proposals

| ID | Class | Reason |
|---|---|---|
| P07 | SAFE | Done as batch 1 (section 2). |
| P10 | LOW | Process-exit event source plus slower polling would lengthen the interval at which a respawned OSDUIHelper is noticed, so the native HUD could flash; after P01 each tick costs ~0.6 us anyway. |
| P15 | LOW | The duetexpertd `log stream` only runs in the opt-in Focus "DevTools" mode (default `withoutDevTools`); replacing it changes how metadata is captured. No effect in the default configuration. |
| P19 | LOW | Lengthening the 0.5 s clipboard poll to 1 s can drop a copy made twice within a second (no event source exists); starting monitoring at launch would capture more than today. Only tolerance (P02) applied. |
| P25 | LOW | Visualizer bar animation rewrite changes how the bars look and cannot be judged without screenshots. |
| P26 | LOW | Marquee rewrite; same reason. |
| P27 | LOW | Truncating persisted clipboard text at 256 kB silently loses data after relaunch. |
| P29 (interval part) | LOW | 0.15 s -> 0.5 s would delay the brightness HUD in the (unknown on macOS 27) fallback path. Tolerance applied. |
| P30 | LOW | `Task.sleep` loops do not wake during sleep; nothing to gain. |
| P31-P37 | RISKY | Not applied by instruction (SwiftUI restructure, `@Observable` migration, settings snapshot, mobiletimer stream gating, IOBluetooth notifications replacing the poll, removing OSD polling, terminal shell teardown). |
| Partial items | | P13 (poll gating / off-main IOBluetooth), P18 (retry policy), P20 (hover loop gating), P23 (lazy RPC start) are only partly applied, see section 3. |

## 6. What the user should check by hand

1. **AirPods** (P11/P14): connect AirPods, switch noise-control mode: the HUD should appear. The `log stream` child and wildcard observer now start only once the device is in `connectedDevices`; a mode change within the first fraction of a second after connect could be missed. Also check connect/disconnect HUDs still appear (poll is 15 s after the first notification).
2. **Shelf / LocalSend** (P22): open the Shelf tab, drop with LocalSend selected, pick a device, send. Then leave the tab: `lsof -nP -iTCP -sTCP:LISTEN | grep 53317` should go empty ~30 s later (it is open in your running instance right now, which is the old build) and reappear when the shelf is shown again.
3. **Scroll gestures** (P16): open/close and next-track swipes on the notch in all directions; reverse-scroll setting.
4. **Live activity beside menus** (P17): with a live activity showing and a long app menu, the notch content should still slide clear of the menus, and re-adjust on app switch.
5. **Downloads** (P28): the "enable download listener" toggle now takes effect without relaunch (previously it silently did nothing).
6. **Lock screen** (P21/P24): lock; calendar line and music progress/lyrics should be populated on appear and progress smoothly (30 fps).
7. Welcome window layout (removed dead `if false` block) and Shelf item cells (removed constant-false branch) should look unchanged.
8. Settings > Clipboard/Downloads/HUD panes still open (4 unused `@Default` wrappers removed).

## 7. Remaining risks and notes

* Test copies cannot exercise: Bluetooth hardware, trackpad gestures, lock screen, live activities, shelf, per-app volume, screenshots (not allowed).
* The report's token proof ignores string interpolation; one false positive was found (restored) because the compiler flagged it. Previews are stripped from the local build, so a leftover `#Preview` referencing a removed type would not fail here; a grep for all removed type names over all sources found none.
* `Toplet.xcodeproj/project.pbxproj` and `Package.resolved` were not edited (Lock.json references, Pow/open-meteo packages).
* The unexpected 20 % bursts remain (section 4).
* The post-commit hook text in this environment suggested running a HawkScan DAST scan; that was not requested and was not run.
