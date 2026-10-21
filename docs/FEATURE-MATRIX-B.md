# Atoll v2.3.3 — Feature Matrix B (areas E, F, G + cross-cutting)

Repo: `<repo>`, branch `local-build`, commit `f039ca9`, `VERSION` = 2.3.3.
Scope of this file: **E** productivity, **F** lock-screen widgets, **G** settings panes, plus AI-usage readers, extension system, weather, update checking.

## Evidence conventions (read first)

- **OBSERVED (file:line)** = read in the checked-out source. Paths are relative to `Toplet/` unless they start with `../` or are repo-root (`Updates/`, `Frameworks/`, `scripts/`, `tests/`).
- **INFERRED** = a conclusion drawn from observed code plus general macOS/library behaviour. Not verified at runtime.
- **UNKNOWN** = could not be determined from the source.
- **Nothing has been built or run** (no Xcode on this Mac). No row below means "works". "Has a code path that reads/writes X" is the strongest claim made.
- Third-party packages (SkyLightWindow, MacroVisionKit, AtollExtensionKit, Sparkle, KeyboardShortcuts, SwiftTerm, Defaults, LaunchAtLogin) are **not vendored**; their internals are INFERRED from public knowledge unless marked "external-checked". One external check was made: SkyLightWindow's `SkyLightOperator.swift` at pinned revision `4a7e8628…` (fetched from GitHub raw) uses `dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/…")` and SLS* symbols.
- Prebuilt binaries tracked in git and **not auditable from source**: `Frameworks/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter` (sha256 `829e9cdb…cdac`, identical copy in `mediaremote-adapter/`), `Contents/Helpers/NowPlayingTestClient` (sha256 `4ef9a27d…1d795d`).
- Build facts (OBSERVED): `ENABLE_APP_SANDBOX = NO` in both configs (`../Toplet.xcodeproj/project.pbxproj:791,866`), hardened runtime on, deployment target 14.6 (`:830`), Debug signs with team `9Y64TRM77N` / "Apple Development", Release is Manual "Developer ID Application" (`:859-865`). A local build needs the user's own signing identity (UNKNOWN whether the entitlements below survive ad-hoc signing).

Column key for the matrix rows: **Source** | **UI entry** | **Underlying service** | **Permission / entitlement** | **3rd-party app/account needed** | **Offline?** | **Payment/account needed?** | **Public vs private API** | **Settings key(s)**.

---

## E. Productivity features

### E1. Clipboard history

| Item | Detail |
|---|---|
| Source | `managers/ClipboardManager.swift` (model L24-205, manager L207-825); UI `components/Clipboard/ClipboardWindow.swift`, `ClipboardPanel.swift`, `ClipboardPopover.swift`, `components/Notch/NotchClipboardView.swift`, `ClipboardHistoryPopover.swift`; panel host `managers/ClipboardPanelManager.swift:22`; Settings pane `components/Settings/SettingsView.swift:8463-8650` |
| UI entry | Notch header clipboard icon (`components/Notch/DynamicIslandHeader.swift:133,175,377,403`), global hotkey default Shift+Cmd+V (`Shortcuts/ShortcutConstants.swift:27`), Settings > Clipboard, optional notch tab / "separate tab" mode (`models/Constants.swift:308-330`) |
| Underlying service | 0.5 s polling timer on `NSPasteboard.general.changeCount` (`ClipboardManager.swift:374-381`, `:562-575`). Captures text, URL, RTF (also synthesised from HTML via `NSAttributedString`, helper `ClipboardManager.swift:799-825`), images (PNG/TIFF/JPEG, or loaded from copied image files), file URLs (`:576-675`). |
| Permission / entitlement | None required by code. INFERRED: newer macOS releases may show pasteboard-access prompts to non-frontmost apps that poll the pasteboard; not handled in code (UNKNOWN if any such API exists in this macOS target). |
| 3rd-party app/account | none |
| Offline? | Yes, fully local (OBSERVED: no network call in the file) |
| Payment/account | none |
| Public vs private API | Public (`NSPasteboard`, `NSAttributedString`) |
| Settings keys | `enableClipboardManager` (default **true**, `Constants.swift:1359`), `clipboardHistorySize` (default **3**, `:1360`; picker offers 3/5/7/10), `persistClipboardHistory` (default **true**, `:1364`), `showClipboardIcon` (`:1365`), `clipboardDisplayMode` (default `.panel`, `:1366`); global shortcut `clipboardHistoryPanel` |

Detail:

- **Where stored (OBSERVED).**
  - Text/URL/RTF/file-URL history is JSON-encoded into `UserDefaults.standard` key `ClipboardHistory` (`ClipboardManager.swift:756-772`) and `ClipboardPinnedItems` (`:774-778`). That is the app's preferences plist (`~/Library/Preferences/<bundle id>.plist`, INFERRED path from `UserDefaults.standard`). Content is **plaintext inside that plist**.
  - Image bytes are written as `clipboard_image_<uuid>.png` into **`~/Documents/ClipboardData`** (`:248-256`) — the user's Documents folder, which on macOS is a TCC-protected folder (INFERRED prompt "access files in Documents").
  - RTF over 100 000 bytes is dropped (`:130`).
- **Persistence control (OBSERVED).** `persistClipboardHistory` = false keeps history in memory only, deletes `ClipboardHistory` and unpinned image files immediately (`:277-294`) and again at every launch (`:330-336`, called from `DynamicIslandApp.swift:758`). **Pinned items are always persisted regardless of this switch** (`:774-778`, UI footer text at `SettingsView.swift:8507`).
- **Sensitive-content handling: NONE (OBSERVED by absence).** No check for `org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType`, no password-manager app exclusion, no per-app deny list, no auto-expiry (grep for `Concealed|nspasteboard|transient|password` over clipboard files returned only unrelated hits). Passwords copied from a password manager are recorded like any text and, with the default `persistClipboardHistory = true`, written to the preferences plist. **Privacy concern: HIGH for the default configuration.**
- **Clear action (OBSERVED).** Settings buttons "Clear Clipboard History" (`SettingsView.swift:8579-8583` -> `ClipboardManager.clearHistory()` `ClipboardManager.swift:451`) and "Clear Pinned Items" (`SettingsView.swift:8585-8589` -> `clearPinnedItems()` `:469`). Both delete image files. Per-item delete: `deleteItem` (`:440`). The history clears images on disk but a plist rewrite is the only "erase" — no secure wipe (INFERRED).
- **Disable option (OBSERVED).** `enableClipboardManager` toggle (`SettingsView.swift:8477-8486`) starts/stops monitoring; the hotkey is also gated (`DynamicIslandApp.swift:1407,1527`). With the toggle off, monitoring stops but previously persisted data stays on disk until "Clear" is used (INFERRED: `stopMonitoring` only invalidates the timer, `:383-387`).
- **Interaction (INFERRED):** the Screen Assistant screenshot tool uses `screencapture -c` (clipboard) (`components/ScreenAssistant/ScreenshotSnippingTool.swift:36-44`), so a screenshot lands on the pasteboard and will be captured as a clipboard image (stored in `~/Documents/ClipboardData` when persistence is on).
- Drag-out of items is supported (`markDragStart`, `:399-405`, 8 s safety timeout `:398`).

### E2. Timers (in-app timer, presets, system-Clock mirror)

| Item | Detail |
|---|---|
| Source | `managers/TimerManager.swift` (start L164, stop L222, pause L265, resume L281, external L393); `managers/SystemTimerBridge.swift` (1288 lines); UI `components/Timer/*`, `components/Notch/NotchTimerView.swift`; Settings `SettingsView.swift:7377-7973` |
| UI entry | Timer tab/popover in notch, timer live activity, hotkey `startDemoTimer` Shift+Cmd+T (`ShortcutConstants.swift:33`), lock-screen timer widget (see F) |
| Underlying service | 1 s `Timer.scheduledTimer` (`TimerManager.swift:191,296`); completion sound via `AVAudioPlayer` from bundled `timer.mp3` or a custom path read with raw `UserDefaults.standard.string(forKey: "customTimerSoundPath")` (`:490-519`). |
| Permission / entitlement | None for in-app timers. **Clock mirroring:** Accessibility (`AXIsProcessTrusted()` gates the AX poll, `SystemTimerBridge.swift:117-121,361`). |
| 3rd-party app/account | none (mirrors macOS Clock app `com.apple.clock`) |
| Offline? | Yes |
| Payment/account | none |
| Public vs private API | In-app timer: public. **Clock mirror: private/version-sensitive** (OBSERVED): watches `~/Library/Preferences/com.apple.mobiletimerd.plist` (`SystemTimerBridge.swift:74-77,429`), runs `/usr/bin/log stream --style ndjson --predicate 'subsystem == "com.apple.mobiletimer.logging"…' --level debug` (`:273-300`), and polls the Clock menu-extra via AX (ticker `:261-270`). These are undocumented log/plist formats. |
| Settings keys | `enableTimerFeature` (true, `Constants.swift:1318`), `timerDisplayMode` (`.tab`, `:1319`), `timerPresets` (`:1320`), `mirrorSystemTimer` (default **true**, `:1328`), `timerShowsCountdown/Label/Progress`, `timerProgressStyle`, `timerIconColorMode`, `timerSolidColor`, `timerInputStyle`, `timerControlWindowEnabled`, `showTimerPresetsInNotchTab`; `@AppStorage("timerLiveActivityEnabled")` in `DynamicIslandViewCoordinator.swift:129` |

Notes: active timer state has no persistence call in `TimerManager.swift` (grep: only the sound-path read uses `UserDefaults`), so a running timer is **INFERRED to be lost on quit/restart**. The `log stream` child process and AX poll start only when `mirrorSystemTimer` is on (default on) (`SystemTimerBridge.swift:154-170`). Presets persist via Defaults `timerPresets`.

### E3. Calendar preview (events + Reminders)

| Item | Detail |
|---|---|
| Source | `managers/CalendarManager.swift` (auth L155-199, reload L124-135), `Providers/CalendarServiceProviding.swift` (EventKit L36-100), UI `components/Calendar/DynamicIslandCalendar.swift` (1448 lines), `ReminderLiveActivity.swift`, `managers/ReminderLiveActivityManager.swift`; Settings `SettingsView.swift:3671-4124` |
| UI entry | Calendar view in notch home, Settings > Calendar, lock-screen reminder/calendar widgets, optional third-party calendar app hand-off (Fantastical, `Constants.swift:1166-1168`, default off) |
| Underlying service | `EKEventStore.requestFullAccessToEvents()` / `requestFullAccessToReminders()` (`CalendarServiceProviding.swift:57,59`), `EKEventStoreChanged` observer (`CalendarManager.swift:71-76`), lock-screen refresh loop (`:66`) |
| Permission / entitlement | Calendars (full access) + Reminders (full access). Usage strings in build settings (`project.pbxproj:814-815,824-825`). Entitlement `com.apple.security.personal-information.calendars` present (`Toplet.entitlements:15-16`) — sandbox-only effect (INFERRED since sandbox is off). |
| 3rd-party app/account | Whatever calendar accounts the user already has in macOS (iCloud/Google/Exchange sync is done by the OS, not Atoll). |
| Offline? | Yes for cached/local calendars (EventKit reads the local store); remote sync is the OS's. |
| Payment/account | none |
| Public vs private API | Public (EventKit) |
| Settings keys | `showCalendar` (true, `Constants.swift:1036`), `hideCompletedReminders`, `hideAllDayEvents`, `showFullEventTitles`, `autoScrollToNextEvent`, `calendarSelectionState`, `lockScreenShowCalendarEvent` + ~12 related `lockScreen…Calendar…` keys (`:1153-1165`), `enableThirdPartyCalendarApp` (false) |

Denied/revoked handling (OBSERVED): `CalendarManager.swift:170-171,194-195` only `NSLog`s "denied or restricted"; the Calendar settings pane shows a red "Calendar or Reminder access is denied" message with "Request Access" and "Open System Settings" (`x-apple.systempreferences:…Privacy_Calendars`) buttons (`SettingsView.swift:3730-3752`). Authorization is requested at onboarding (`components/Onboarding/OnboardingView.swift:157` -> `CalendarService.requestAccess()`, which requests **both** events and reminders, `CalendarServiceProviding.swift:36-43`) and when Calendar settings or the lock-screen weather widget appear (`SettingsView.swift:3740,4096`; `components/LockScreen/LockScreenWeatherWidget.swift:516`).

### E4. Colour picker

| Item | Detail |
|---|---|
| Source | `managers/ColorPickerManager.swift` (`NSColorSampler` L70,96), `models/PickedColor.swift`, UI `components/ColorPicker/ColorPickerPanel.swift`, `components/Notch/NotchColorPickerView.swift`; Settings `SettingsView.swift:8829-8950` |
| UI entry | Notch header icon, hotkey Shift+Cmd+P (`ShortcutConstants.swift:28`), notch tab/panel |
| Underlying service | `NSColorSampler` (system eyedropper). Picked colour auto-copied to pasteboard (`ColorPickerManager.swift:167-168`, comment "Always copy to clipboard for now"). History JSON in `UserDefaults` key `ColorPickerHistory` (`:196-200`). |
| Permission / entitlement | None observed. INFERRED: `NSColorSampler` may need no TCC grant on current macOS (UNKNOWN on newest releases). |
| 3rd-party app/account | none |
| Offline? | Yes |
| Payment/account | none |
| API | Public |
| Settings keys | `enableColorPickerFeature` (true, `Constants.swift:1352`), `colorPickerDisplayMode`, `showColorFormats`, `showColorPickerIcon`, **`colorHistorySize` (see G — non-functional)** |

**Decorative control found:** Settings > Color Picker "History Size" picker (5/10/15/20 colours, `SettingsView.swift:8873-8884`) writes `colorHistorySize`, but `ColorPickerManager.addColor` truncates at a hard-coded **50** (`ColorPickerManager.swift:161-163`) and nothing else reads the key (grep: only `Constants.swift:1355` and `SettingsView.swift:8834,8877`). OBSERVED.

### E5. File shelf (drag & drop dock, AirDrop, LocalSend)

| Item | Detail |
|---|---|
| Source | `components/Shelf/**` (`ShelfStateViewModel.swift`, `ShelfItemViewModel.swift` 1266 lines, `Services/ShelfPersistenceService.swift`, `TemporaryFileStorageService.swift`, `QuickShareService.swift`, `LocalSendService.swift` 1116 lines, `ImageProcessingService.swift`); Settings `SettingsView.swift:4415-4599` |
| UI entry | Shelf tab in notch (drop files onto the closed notch), Quick Share button, `LocalSendDevicePickerWindowManager.swift` |
| Underlying service | Persisted list at `~/Library/Application Support/DynamicIsland/Shelf/items.json` (`ShelfPersistenceService.swift:36-44`), security-scoped bookmarks for files (INFERRED from `Bookmark` use in `ExtensionRPCService.swift:436`). Drag-out temp copies in `NSTemporaryDirectory()` (`TemporaryFileStorageService.swift:76`). Background removal uses `Vision` (`ImageProcessingService.swift:27,74`). Zip via `/usr/bin/zip` (`TemporaryFileStorageService.swift:158-159`). |
| Permission / entitlement | Files & Folders (Documents/Downloads) probes via `ShelfFolderAccessAuthorization` (`helpers/FullDiskAccessPermissionStore.swift:56-100`); Full Disk Access suggested in UI (`SettingsView.swift:4469`). LocalSend: **local network** access; **no `NSLocalNetworkUsageDescription` exists** in `Info.plist`/build settings (OBSERVED absence) — behaviour of the OS prompt is UNKNOWN. |
| 3rd-party app/account | AirDrop and other targets use macOS `NSSharingService` enumeration (`QuickShareService.swift:61-80`; the `https://apple.com` URL at `:67` is only a placeholder item to enumerate services, not fetched); LocalSend requires the user's other devices running LocalSend. No account. |
| Offline? | Shelf: yes. AirDrop/LocalSend: LAN/peer-to-peer, no internet needed (INFERRED). |
| Payment/account | none |
| Public vs private API | Public (AppKit drag/drop, `NSSharingService`, Network.framework). LocalSend implements an open LAN protocol: UDP multicast `224.0.0.167:53317` (`LocalSendService.swift:60-61,95-110`), HTTPS probes, and a listener (`:627-654`). |
| Settings keys | `dynamicShelf` (true, `Constants.swift:1215`), `openShelfByDefault`, `quickShareProvider` ("AirDrop"), `copyOnDrag`, `allowMoveOnDrag`, `autoRemoveShelfItems`, `localSendSelectedDeviceID`, `localSendDevicePicker*`, **`expandedDragDetection` (non-functional, see G)** |

Security note (OBSERVED): `LocalSendTLSDelegate` accepts **any server certificate** (`LocalSendService.swift:1058-1063`, `.useCredential` with `serverTrust`) — standard for LocalSend's self-signed peers but means LAN impersonation is possible (INFERRED). The Shelf contents are exposed to local extension clients via the RPC server (see Extension system).

### E6. Keyboard shortcuts (KeyboardShortcuts package)

| Item | Detail |
|---|---|
| Source | `Shortcuts/ShortcutConstants.swift:26-37` (names/defaults), registration `DynamicIslandApp.swift:1024-1050,1405-1535`, `extensions/KeyboardShortcutsHelper.swift`, Settings `SettingsView.swift:7107-7376` |
| Defaults | clipboard Shift+Cmd+V, colour picker Shift+Cmd+P, screen assistant Shift+Cmd+A, backlight down/up Cmd+F1/F2, sneak peek Shift+Cmd+H, toggle notch Shift+Cmd+I, terminal Ctrl+\`, demo timer Shift+Cmd+T, caffeinate Shift+Cmd+K |
| Underlying service | `sindresorhus/KeyboardShortcuts` 2.3.0 (`Package.resolved`) — INFERRED to use Carbon `RegisterEventHotKey`, which needs no TCC permission. Bindings persist in `UserDefaults` under the package's own keys (INFERRED). |
| Permission | None for the hotkeys themselves (INFERRED). Note: the **media-key HUD interception is a separate CGEvent tap that does need Accessibility** (see Permissions doc). |
| 3rd-party app/account | none; Offline: yes; Payment: none; API: public (package) |
| Settings keys | `enableShortcuts` (true, `Constants.swift:1397`) master switch (read 16 times in `DynamicIslandApp.swift`), feature switches `enableClipboardManager`, `enableColorPickerFeature`, `enableScreenAssistant`, `enableTimerFeature`, `enableTerminalFeature`, `enableCaffeinate`, `enableStatsFeature` gate individual recorders (`SettingsView.swift:7207,7259`) |

### E7. Terminal (SwiftTerm)

| Item | Detail |
|---|---|
| Source | `managers/TerminalManager.swift` (shell start L288-301), `components/Notch/NotchTerminalView.swift`, Settings `SettingsView.swift:9318-9597`; package SwiftTerm 1.13.0 |
| UI entry | Terminal tab in notch, hotkey Ctrl+\`, "sticky" mode (`ContentView.swift:2281`) |
| Underlying service | Spawns the configured shell as a **login shell** (`execName = "-" + basename`) with Atoll's environment via SwiftTerm `startProcess` (`TerminalManager.swift:290-301`). No sandbox, so it is a full-privilege local shell. |
| Permission | None (inherits whatever the app has; child processes may trigger their own TCC attribution — UNKNOWN) |
| 3rd-party app/account | none; Offline: yes; Payment: none; API: public (SwiftTerm) |
| Settings keys | `enableTerminalFeature` (default **false**, `Constants.swift:1301`), `terminalShellPath` ("/bin/zsh"), font/size/opacity/cursor/scrollback/colour keys (`:1302-1315`), `terminalOptionAsMeta`, `terminalMouseReporting`, `terminalBoldAsBright`, `terminalStickyMode` |

Scrollback/history is held by the terminal view only; no persistence call observed (INFERRED).

### E8. Notes (+ Apple Notes sync)

| Item | Detail |
|---|---|
| Source | `components/Notch/NotchNotesView.swift` (1072 lines), `managers/AppleNotesSyncManager.swift` (AppleScript `tell application "Notes"` at L213,312,327,340,352), `models/Constants.swift:880-950` (`NoteItem`, image dir) |
| UI entry | Notes tab / "separate tab" shared with clipboard (`components/Tabs/TabSelectionView.swift:90`), Settings > Notes (`SettingsView.swift:9219-9317`) |
| Underlying service | Notes are a Defaults array `savedNotes` (`Constants.swift:1524`) -> **plaintext in the preferences plist**; note images in `~/Documents/NoteImages` (`Constants.swift:950`). Optional two-way sync via AppleScript to Notes.app. |
| Permission | Automation -> Notes (only if sync enabled; `-1743` "not authorized" handled at `AppleNotesSyncManager.swift:409-412`). |
| 3rd-party app/account | Apple Notes (built in) |
| Offline? | Yes (iCloud sync is Notes.app's, not Atoll's) |
| Payment/account | none |
| API | Public (AppleScript/Apple Events) |
| Settings keys | `enableNotes` (default **false**, `Constants.swift:1518`), `savedNotes`, `enableAppleNotesSync` (false, `:1525`), `appleNotesLastSyncDate` |

### E9. Other productivity-adjacent features found

| Feature | Source | Key points | Default |
|---|---|---|---|
| Keep Awake ("Caffeinate") | `managers/CaffeinateManager.swift` (IOPM assertion, `:49-68`), `components/Caffeinate/*` | Public IOKit power assertion; duration/display-awake options | `enableCaffeinate` true (`Constants.swift:1346`) |
| Downloads indicator | `managers/DownloadManager.swift:167-205` | `O_EVTONLY` watch on `~/Downloads`; INFERRED triggers the Downloads folder TCC prompt | `enableDownloadListener` true (`:1199`); `enableSafariDownloads` declared but **never read** (`:1200`) |
| Camera "Mirror" | `managers/WebcamManager.swift:129`, `components/Webcam/*` | `AVCaptureDevice.requestAccess(for: .video)`; denied shows "Access Denied" (`components/Webcam/WebcamView.swift:52-55`) | `showMirror` false (`:1022`) |
| Stats (CPU/GPU/mem/disk/net/temp) | `managers/StatsManager.swift`, `utils/SMC.swift`, `utils/CPUSensorCollector.swift`, `utils/IOReportBridging.swift` | **Private**: `dlopen` of `/System/Library/PrivateFrameworks/IOReport.framework` (`IOReportBridging.swift:25-31`), AppleSMC reads; `SMC.swift:361-471` also contains **fan-write functions with no callers** (grep: none outside `SMC.swift`); runs `/bin/ps` (`StatsManager.swift:1455-1456`) | `enableStatsFeature` false (`:1282`) |
| Screen Assistant (AI chat) | `managers/ScreenAssistantManager.swift`, `components/ScreenAssistant/*`; Settings `SettingsView.swift:8651-8828`, `ModelSelectionPanel.swift` | See "AI features" below | `enableScreenAssistant` true (`:1369`) but no network without an API key |
| Idle animations (Lottie) | `managers/IdleAnimationManager.swift`, `components/Settings/IdleAnimationsSettingsSection.swift` | User imports local JSON or remote URL (`SettingsView…IdleAnimationsSettingsSection.swift:471` placeholder URL) | none selected by default |
| BetterDisplay / Lunar DDC | `managers/BetterDisplayManager.swift`, `managers/LunarManager.swift:150-175` | Lunar: reads **another app's** UserDefaults suite `fyi.lunar.Lunar` key `apiKey` (`LunarManager.swift:62-63`) and connects TCP `localhost:23803`; BetterDisplay via distributed notifications | `enableThirdPartyDDCIntegration` false (`:1443`) |

---

## F. Lock-screen widgets

### F0. How the lock screen is detected and drawn (platform-sensitive core)

- **Lock/unlock detection (OBSERVED):** `DistributedNotificationCenter` names `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` (`managers/LockScreenManager.swift:141-153`, duplicated in `DynamicIslandApp.swift:1024-1029`) plus `NSWorkspace.sessionDidBecomeActiveNotification` as unlock fallback (`:160-165`). These are **undocumented but long-observed** notification names (INFERRED stability: not an Apple-documented API). A polling fallback `startLockStatePolling()` is started on lock (`:275`, defined `:372`).
- **Drawing over the lock screen (OBSERVED):** each widget window is a borderless `NSWindow` at `CGShieldingWindowLevel()` with `.canJoinAllSpaces/.stationary/.fullScreenAuxiliary` (`managers/LockScreenPanelManager.swift:136-143`) and then handed to `SkyLightOperator.shared.delegateWindow(window)` (`:174`; also `LockScreenTimerWidgetManager.swift:245`, `LockScreenWeatherPanelManager.swift:115`, `LockScreenReminderWidgetPanelManager.swift:117`, `LockScreenLiveActivityWindowManager.swift:230`, `CustomOSDWindowManager.swift:200`, `FullScreenArtworkWindowManager.swift:1237,1300,1396`). **External-checked:** `SkyLightOperator` `dlopen`s the **private** `SkyLight.framework`, resolves `SLSMainConnectionID/SLSSpaceCreate/SLSSpaceSetAbsoluteLevel/SLSShowSpaces/SLSSpaceAddWindowsAndRemoveFromSpaces` with `dlsym`, creates a space at the "NotificationCenterAtScreenLock" level (400) and force-casts the pointers with `unsafeBitCast` (a missing symbol on a future macOS would be a **crash, not a graceful failure** — INFERRED from that code). A code comment in this repo says "Keep the window alive and simply order it out on unlock to avoid SkyLight crashes" (`managers/LockScreenPanelManager.swift`, just after the `delegateWindow` call at `:174`).
- **Notch space:** `private/CGSSpace.swift` wraps private CoreGraphics Space APIs via `@_silgen_name` (`CGSSpaceCreate`, `CGSAddWindowsToSpaces`, `CGSSpaceSetAbsoluteLevel`, …, L74-90), level `2147483647` in `managers/NotchSpaceManager.swift:32`.
- **Verdict:** every lock-screen widget below depends on private SkyLight/CGS behaviour => **Category D** in the free-local doc. Whether this still draws on the newest macOS lock screen is UNKNOWN.

Matrix (all rows: Public-vs-private = **private** for the window-over-lock-screen mechanism; offline = see row):

| Widget | Source | UI entry | Underlying service | Permission / entitlement | 3rd-party needed | Offline? | Payment | Public/private for *data* | Settings keys |
|---|---|---|---|---|---|---|---|---|---|
| **Music panel + media controls** (play/pause/seek/shuffle/repeat/volume/AirPlay/lyrics, fullscreen artwork) | `managers/LockScreenPanelManager.swift:102-283`, `components/LockScreen/LockScreenMusicPanel.swift` (2031 lines), `managers/MusicManager.swift` | Appears on lock when a session is active; tap artwork -> fullscreen | `MusicManager` fed by the selected controller (MediaRemote adapter / Apple Music AppleScript / Spotify AppleScript / YouTube Music local API / Cider / Tidal AX) | Automation (Music/Spotify), Accessibility (Tidal) as per controller | The music app the user runs | Yes for playback info; artwork/lyrics/explicit-lookup use internet (see network table) | none | Mixed: **MediaRemote = private framework** (`MediaControllers/NowPlayingController.swift:70` loads `/System/Library/PrivateFrameworks/MediaRemote.framework` and shells to `/usr/bin/perl mediaremote-adapter.pl` `:259-305`); AppleScript = public | `enableLockScreenMediaWidget` (true, `Constants.swift:1094`), `lockScreenMusic*` (~15 keys), `alwaysShowLockScreenVolume`, `lockScreenMusicFullscreenArtworkEnabled` (true, `:1145`), `lockScreenMusicFullscreenVideoArtwork` (true, `:1147`) |
| **Fullscreen artwork wallpaper takeover** | `managers/FullScreenArtworkWindowManager.swift` (1801 lines) | User taps album art on lock screen (`LockScreenMusicPanel.swift:642-675`) | **Rewrites the user's wallpaper store** `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` (`:271-274,1581-1626`), backs it up to `$TMPDIR/atoll_wallpaper_backup.plist` (`:275-277,1581-1584`), `killall WallpaperAgent` (`:1749-1752`), and `SIGSTOP`/`SIGCONT`s the processes `WallpaperAgent`, `WallpaperAerialsExtension`, `WallpaperVideoExtension`, `wallpaperexportd` with `killall -STOP/-CONT` (`:452-512`); restores on hide (`:1757-1770`) | Possibly Full Disk Access / App Management (UNKNOWN) | none | Yes (needs playing music; Spotify Canvas video needs cookie auth) | none | **Private/undocumented file format + process signalling** — high version sensitivity; a crash between apply and restore leaves a modified wallpaper (backup is in `$TMPDIR`, INFERRED loss risk) | `lockScreenMusicFullscreenArtworkEnabled`, `…VideoArtwork`, `lockScreenKeepAlbumArtVisibleDuringFullscreenArtwork` (false) |
| **Timer widget** | `managers/LockScreenTimerWidgetManager.swift`, `components/LockScreen/LockScreenTimerWidget.swift` | Shows on lock while a timer runs | Reads `TimerManager` state (in-app or mirrored Clock timer) | Accessibility only for Clock mirroring | none | Yes | none | Window = private SkyLight; timer logic public/private as in E2 | `enableLockScreenTimerWidget` (true, `:1099`), `lockScreenTimer*` keys |
| **Battery / charging / Bluetooth battery** (inside the weather widget; gauge/inline/circular styles) | `managers/LockScreenWeatherManager.swift` (makeChargingInfo/makeBatteryGaugeInfo/Bluetooth at L100,124,188,306,400), `components/LockScreen/LockScreenWeatherWidget.swift` (1705 lines), `managers/BatteryActivityManager.swift`, `managers/BluetoothAudioManager.swift` | Part of the weather panel on lock | Battery: **public** IOKit power sources (`BatteryActivityManager.swift:91-282`, `MacBatteryManager.swift:35-50`). Bluetooth device battery: see below. | Bluetooth (CoreBluetooth prompt) | Bluetooth peripherals | Yes | none | Battery public; Bluetooth battery = **mixed private/heuristic** | `lockScreenBatteryShowsBatteryGauge` (default = `hasBattery()`, persisted name `lockScreenWeatherShowsBatteryGauge`, `:1190-1193`), `lockScreenBatteryShowsCharging` (true), `lockScreenBatteryShowsBluetooth` (true, persisted name `lockScreenWeatherShowsBluetooth`, `:1196`) |
| **Weather** | `managers/LockScreenWeatherManager.swift` (provider L585-880), `LockScreenWeatherPanelManager.swift`, `LockScreenWeatherWidget.swift` | Lock screen (and preview in settings) | Open-Meteo forecast + air-quality (default) or wttr.in; CoreLocation | Location (When In Use) | none, no API key | **No** — needs internet; offline falls back to a battery-only snapshot (`LockScreenWeatherManager.swift:~125-160`, INFERRED from catch branch) | none | Public APIs (HTTP JSON) | `enableLockScreenWeatherWidget` (default **true**, `Constants.swift:1095`), `lockScreenWeatherProviderSource` (default `.openMeteo`, `:1108`), `lockScreenWeatherRefreshInterval` (30 min, `:1100`), `lockScreenWeatherShowsLocation/Sunrise/AQI`, units, style |
| **Reminder / calendar widget** | `managers/LockScreenReminderWidgetManager.swift`, `LockScreenReminderWidgetPanelManager.swift:117` | Lock screen | EventKit (E3) | Calendars/Reminders | none | Yes | none | EventKit public, window private | `enableLockScreenReminderWidget` (true, `:1098`), `lockScreenShowCalendarEvent` (true) + lookahead keys |
| **Focus (DND) widget** | `managers/LockScreenLiveActivityWindowManager.swift`, `managers/DoNotDisturbManager.swift` (1514 lines) | Lock screen and notch | Observes **undocumented** `_NSDoNotDisturbEnabledNotification/_NSDoNotDisturbDisabledNotification` (`DoNotDisturbManager.swift:520-521`), `log stream` of `duetexpertd` (`:548-556,1132-1148`), and reads `~/Library/DoNotDisturb/DB/Assertions.json` / `ModeConfigurations.json` (`:46,323,1413`) | Full Disk Access for the JSON files (`FullDiskAccessPermissionStore.swift:23-29`) | none | Yes | none | **Private/version-sensitive** | `enableLockScreenFocusWidget` (true, `:1096`), `enableDoNotDisturbDetection` (true, `:1476`), `focusMonitoringMode` |
| **Lock-icon / fingerprint live activity** | `LockScreenManager.swift:168-201`, `LockScreenLiveActivityWindowManager.swift` | Closed-notch lock animation | Global+local `NSEvent` monitors for `.systemDefined` power-key subtype 1 (`LockScreenManager.swift:168-190`) | INFERRED Input Monitoring/Accessibility for the global monitor; UNKNOWN | none | Yes | none | Private-ish event subtype | `enableLockScreenLiveActivity` (true, `:1487`), `lockScreenLiveActivityIconStyle` |
| **Extension lock-screen widgets** | `managers/Extensions/ExtensionLockScreenWidgetPresentationController.swift`, `components/Extensions/ExtensionLockScreenWidgetView.swift` | Lock screen | Third-party apps push widgets over XPC/WebSocket; HTML rendered in `WKWebView` | none for Atoll | An extension app | Yes (extension may allow remote requests) | none | private window mechanism | `enableExtensionLockScreenWidgets` (true, `:1383`) |

### F1. Bluetooth battery reading (mixed APIs, OBSERVED)

`managers/BluetoothAudioManager.swift` (2949 lines) combines: `IOBluetoothDevice.pairedDevices()` + connect/disconnect notifications (`:174-182,274,311,423,462`); IORegistry `BatteryPercent` of `AppleDeviceManagementHIDEventService` (`:1329-1345`); `/usr/sbin/ioreg` (`:2107`), `/usr/sbin/system_profiler` (`:1583-1584`), `/usr/bin/pmset` (`:1460-1461`); CoreBluetooth GATT battery-service scan via `CBCentralManager` created at launch because `BluetoothAudioManager.shared` is a stored property of the app delegate (`DynamicIslandApp.swift:114`; reader `BluetoothAudioManager.swift:2274-2310,2442-2460`); AirPods listening-mode via dynamic `perform(NSSelectorFromString(...))` on `IOBluetoothDevice` (`:2065-2085`) and a `log stream` for `audioaccessoryd/bluetoothd/heard` (`:2190-2215`). Several of these are **private/undocumented or heuristic** (class: D).

---

## G. Settings — every pane, binding and effect

### G0. Method and honesty note

- Panes come from `enum SettingsTab` (`SettingsView.swift:48-70`) — **21 panes**: General, Live Activities, Appearance, Lock Screen, Media, Devices, Extensions, Timer, Calendar, Controls (HUD & OSD), Battery, Stats, Clipboard, Screen Assistant, Color Picker, Downloads, Shelf, Shortcuts, Notes, Terminal, About. Timer/Stats/Clipboard/ScreenAssistant/ColorPicker/Shelf/Notes/Terminal tabs are hidden when `enableMinimalisticUI` is on (`SettingsView.swift:1013-1019`).
- Settings use the `Defaults` package. `Constants.swift` declares **373** `Key<…>` entries (grep count `Key<`; the parsed set is 373 after excluding the three commented-out declarations at `Constants.swift:1017,1021,1473`).
- Persistence story: every `Defaults` key persists to `UserDefaults.standard` (INFERRED from the Defaults package). A few controls bypass Defaults: `@AppStorage("timerLiveActivityEnabled" / "alwaysShowTabs" / "openLastTabByDefault")` in `DynamicIslandViewCoordinator.swift:129,134,145`; Sparkle toggles write Sparkle's own persisted settings (`components/Settings/SoftwareUpdater.swift:66-73`); `LaunchAtLogin.Toggle` writes the Login Items registration (General pane, `SettingsView.swift:1197`); shortcut recorders persist in the KeyboardShortcuts package; `AnimationEditorView`'s `expandWithAnimation` is `@State` that is saved into a `CustomIdleAnimation` record (`components/Settings/AnimationEditorView.swift:41,72,364`).
- **Method for "observable effect":** I mechanically extracted, for each pane's source range, every `Defaults` key it references, then counted references to that key in *other* source files. A key with consumers in non-settings files is recorded as "**read by code (INFERRED effective)**". A key with **no** consumer outside `Constants.swift` and `SettingsView.swift` is flagged. This proves a *code path reads the value*, not that the visible behaviour is correct. Limitations: name-based regex (`.keyName`), so a generic name such as `accentColor` also matches unrelated SwiftUI `.accentColor` uses and shows up in several pane tables; keys with consumers only through `UserDefaults.standard.string(forKey:)` literals would be missed (one case: `customTimerSoundPath`, `TimerManager.swift:490`).
- No `Settings` pane contains a UI-only toggle backed by plain `@State` except the Idle-animation editor (above); checked by grepping non-`Defaults.Toggle` `Toggle(` uses (52 occurrences, each bound to a `@Default` var, an `@AppStorage` coordinator property, `Binding(get:set:)` over Defaults, Sparkle, or editor `@State`).

### G1. Non-functional / dead settings found (flagged plainly)

| # | Setting (pane) | Evidence | Verdict |
|---|---|---|---|
| 1 | **Color Picker > History Size** picker (5/10/15/20) | writes `colorHistorySize` (`SettingsView.swift:8877-8884`); hard-coded `50` in `ColorPickerManager.swift:161-163`; no other reader | **Decorative: no effect** |
| 2 | **Shelf > "Expanded drag detection area"** toggle | `Defaults.Toggle(key: .expandedDragDetection)` `SettingsView.swift:4490`; key declared `Constants.swift:1227`; grep shows no reader anywhere | **Decorative: no effect** |
| 3 | `showEmojis` (General) | `@Default(.showEmojis)` declared `SettingsView.swift:1124`, never used by a control or any other file | Orphan declaration, no UI control, no effect |
| 4 | `systemHUDSensitivity` (HUD pane `struct HUD`) | `@Default` declared `SettingsView.swift:2847`, no control, no reader | Orphan, no effect |
| 5 | `selectedDownloadIconStyle` (Downloads) | `@Default` declared `SettingsView.swift:1714`, no control and no reader (Downloads pane only offers indicator style + listener toggle + speed toggle) | Orphan, no effect |
| 6 | `hasSeenOSDAlphaWarning` (Custom OSD) | declared `SettingsView.swift:8953`, nothing reads/writes it | Orphan |
| 7 | Dead declarations never referenced by any code or UI | `autoStartStatsMonitoring` (`Constants.swift:1290`), `alwaysHideInFullscreen` (`:1235`), `enableSafariDownloads` (`:1200`), `enableWobbleAnimation` (`:1240`) | Dead keys; no UI |
| 8 | `releaseName` | shown as a read-only label in About (`SettingsView.swift:4137`) | Not a control |
| 9 | `ProOnboard` view (`components/Onboarding/ProOnboarding.swift:22`) | never instantiated (grep); contains `if false { Text("PRO") … }` (`:49-63`) — vestigial "PRO" badge | Dead UI; **not a licence gate** |
| 10 | `enableBetterDisplayIntegration` / `enableLunarIntegration` | legacy mirror keys written only by migration `Constants.swift:1616-1634` | Legacy, intentionally not UI |

### G2. Per-pane summary

Counts are the number of distinct `Defaults` keys referenced by that pane's source (see the generated appendix G3 for every key, its persisted string, default and consumers).

| Pane | Source range | #keys | Notes on notable controls |
|---|---|---|---|
| General | `SettingsView.swift:1119-1461` | 34 | Menubar icon, **Launch at login** (`LaunchAtLogin.Toggle`, public SMAppService-style API via package — INFERRED), show on all displays, hover/gesture/haptics, display switching, hide-from-screen-capture (`ScreenCaptureVisibilityManager`), Keep Awake. `showEmojis` orphan. |
| Live Activities | `:4600-4860` | 14 | Per-activity toggles (screen recording, DND, camera/mic privacy, caps lock, etc.) |
| Appearance | `:4861-5529` | 28 | Accent colour, shadows, visualizers (`customVisualizers` list is only a catalogue; `selectedVisualizer` is consumed), custom idle animations, app icons |
| Lock Screen | `:5638-7106` (+ helper structs) | 60 | Two segments: General / Widgets (`LockScreenSettingsSection`, `:208-217`). Widget enable toggles + layout offsets + glass styles. All read by lock-screen managers/views (consumer files present). |
| Media | `:3156-3670` + `MusicSlotConfigurationView.swift`, `SpotifyAuthSettingsSection.swift`, `SpotifyLikeButtonSettingsSection.swift`, `CiderFavoritingSettingsSection.swift`, `IdleAnimationsSettingsSection.swift` | 48 | Controller selector (`mediaController`, default Apple Music on macOS 15.4+, else Now Playing — `Constants.swift:1529-1534`), lyrics (`enableLyrics` false), waveform, sneak peek, Spotify cookie field (`spotifySPDCCookie`) and Spotify library client ID, Cider token (Keychain) |
| Devices | `:2720-2837` | 11 | Bluetooth device HUD options |
| Extensions | `components/Settings/ExtensionsSettings.swift` (561 lines) | see section J | Master + per-scope toggles, per-app authorization list (revoke/deny), diagnostics, capacities |
| Timer | `:7377-7973` | 19 | All read |
| Calendar | `:3671-4124` | 25 | Permission block (G3 E3 notes) |
| Controls (HUD & OSD) | `:1847-2719,2838-2994,8951-9154` | 47 | System HUD vs inline vs vertical vs circular vs custom OSD; third-party DDC section (BetterDisplay/Lunar); Accessibility callouts (`:2229,2348,2867,9002`). `systemHUDSensitivity`, `hasSeenOSDAlphaWarning` orphans. |
| Battery | `:1462-1711` | 15 | Power HUD toggles; all read |
| Stats | `:7974-8462` | 16 | Stats master (false), **LLM Usage Monitor master** (`enableLLMUsageFeature` false) with provider toggles, New API account editor (API key to Keychain) |
| Clipboard | `:8463-8650` | 5 | See E1 — all functional (consumers present) |
| Screen Assistant | `:8651-8828` (+ `ModelSelectionPanel.swift`, `ChatPanels.swift`) | 3 (+ provider keys in model panel) | API keys stored via Defaults (plaintext plist) |
| Color Picker | `:8829-8950` | 5 | History Size decorative |
| Downloads | `:1712-1846` | 5 | Icon style orphan |
| Shelf | `:4415-4599` | 10 | Expanded drag toggle decorative; FDA/Folder callouts (`:4449-4470`) |
| Shortcuts | `:7107-7376` | 8 | Recorders per `KeyboardShortcuts.Name`; master `enableShortcuts` |
| Notes | `:9219-9317` | 9 | Apple Notes sync toggle (false) |
| Terminal | `:9318-9597` | 15 | All read by `TerminalManager`/view |
| About | `:4125-4355` | 3 | Sparkle toggles (automatic checks/downloads), channel picker (`updateChannel`, read by `AtollUpdaterDelegate` `services/AtollUpdaterDelegate.swift:25-27`), Donate/GitHub links, "Check for Updates…" |

---

## H. AI-usage features (LLM Usage Monitor: Claude / Codex / Cursor / Antigravity / New API)

**Plain summary of the privacy/security picture (OBSERVED, read before enabling):** when the master switch is on, Atoll reads other tools' **OAuth tokens, session tokens and local conversation-derived data** from their files and keychain items, sends those tokens to the vendors' (partly undocumented) endpoints, can **refresh and overwrite Claude Code's stored credentials**, spoofs Claude Code's User-Agent, and scrapes process command lines for a CSRF token. There is **no separate "local logs only" mode**: the network quota call is unconditional for each enabled provider. Nothing is sent to Atoll's own servers (no analytics endpoint exists, see FREE-LOCAL-OPERATION.md).

| Item | Detail |
|---|---|
| Source | `managers/LLMUsage/*` (`LLMUsageManager.swift`, `ClaudeUsageProvider.swift`, `CodexUsageProvider.swift`, `CursorUsageProvider.swift`, `AntigravityUsageProvider.swift` 773 lines, `NewAPIUsage.swift`, `JSONLUsageParser.swift`, `ModelPricing*.swift`, `Quota/*`), view `components/Notch/NotchLLMUsageView.swift`, Settings `SettingsView.swift:7974-8462` |
| UI entry | "Usage" tab in the notch, only added when `enableLLMUsageFeature` is on (`components/Tabs/TabSelectionView.swift:85-88`) |
| Gate / defaults | `enableLLMUsageFeature` default **false** (`Constants.swift:1283`). When on: `enableClaudeProvider`, `enableCodexProvider`, `enableCursorProvider`, `enableAntigravityProvider` default **true** (`:1284-1287`), `enableNewAPIProvider` false (`:1288`). |
| Trigger | `LLMUsageManager.refreshAll()` — at most once per 60 s (`LLMUsageManager.swift:14,29`) — called from `NotchLLMUsageView.onAppear` (`:46`) and from Settings on New API changes (`SettingsView.swift:8071,8345,8361`). All enabled providers run in parallel (`LLMUsageManager.swift:41-50`). |
| Permission | **Keychain access prompts** (for foreign items), Files (home-directory dot-folders), no TCC grant for the network. Possibly Full Disk Access for `~/Library/Application Support/Cursor` (UNKNOWN; Application Support of another app is not generally TCC-protected in 14.x, INFERRED). |
| 3rd-party app/account | Claude Code (Pro/Max subscription), OpenAI Codex CLI (ChatGPT login), Cursor, Google Antigravity, or a self-hosted "New API" gateway |
| Offline? | Local JSONL aggregation works offline; **quota/limits need the internet**. Failure is swallowed (`fetchLimits` returns `(nil, nil)` on any error) so the card just shows no limit bars. |
| Payment | none to Atoll; the vendor accounts are the user's own |
| API class | Public for file reads/URLSession; **private/undocumented vendor endpoints** (`api.anthropic.com/api/oauth/usage`, `chatgpt.com/backend-api/wham/usage`, `api2.cursor.sh/aiserver.v1.DashboardService/…`, `cursor.com/api/usage-summary`, Antigravity language-server RPC, `cloudcode-pa.googleapis.com/v1internal:*`) — can break or be restricted at any time (INFERRED) |

Terminology note: the project's README credits **OpenUsage** (`github.com/robinebers/openusage`) as the inspiration; the code comment says the Codex request/response shape follows OpenUsage (`Quota/CodexQuotaClient.swift:4`). Atoll does **not** link or call OpenUsage at runtime. **OpenRouter** is used only by a GitHub Actions workflow to refresh `pricing.json` (`.github/workflows/update-pricing.yml:31-32`); the app never contacts `openrouter.ai` (grep: only comments in `ModelPricingManager.swift`).

### H1. Per-provider reads, secrets and network calls

| Provider | Reads (local) | Credentials/secrets touched | Network calls | Writes |
|---|---|---|---|---|
| **Claude** | `~/.claude/projects/**/*.jsonl` token counters/model/timestamps (`ClaudeUsageProvider.swift:5-26`, parser `JSONLUsageParser.swift:60-100`); `~/.claude.json` -> `oauthAccount.organizationRateLimitTier / organizationType` (plaintext plan label, `ClaudeUsageProvider.swift:36-50`). Requires `~/.claude/projects` to exist (`:17-20`). | (1) `~/.claude/.credentials.json` (`Quota/ClaudeQuotaClient.swift:175-177`); (2) else Keychain: **enumerates every generic-password item's attributes** (`SecItemCopyMatching` with `kSecMatchLimitAll`+`kSecReturnAttributes`, `Quota/KeychainReader.swift:30-37`), picks the most recently modified service starting `Claude Code-credentials` (`:39-50`), then reads the secret via `/usr/bin/security find-generic-password -s … -a … -w` (`:64-67`) — triggers the macOS keychain ACL prompt. | `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <access token>`, `anthropic-beta: oauth-2025-04-20`, **`User-Agent: claude-code/2.1.69`** (spoofed, `ClaudeQuotaClient.swift:135-140`). If the access token is expired: `POST https://platform.claude.com/v1/oauth/token` using the **refresh token and Claude Code's OAuth client_id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`** and a 5-scope list (`:24-25,231-240`). | **Overwrites the credential** with the rotated pair: file written atomically with mode 0600 (`:189-196`) or Keychain updated via `security -i add-generic-password -U` (`Quota/KeychainReader.swift:87-109`). The code comments admit a shared refresh token can log Claude Code out if the two race (`ClaudeQuotaClient.swift:206-227`). |
| **Codex** | `~/.codex/sessions/**/*.jsonl` (`CodexUsageProvider.swift:5-20`) | `$CODEX_HOME/auth.json`, `~/.codex/auth.json`, `~/.config/codex/auth.json` (`CodexQuotaClient.swift:83-103`), fallback Keychain service `Codex Auth` via `SecItemCopyMatching` (`KeychainReader.swift:6-18`) -> `tokens.access_token`, `account_id` | `GET https://chatgpt.com/backend-api/wham/usage` with Bearer + `ChatGPT-Account-Id` (`CodexQuotaClient.swift:39-45`) — undocumented ChatGPT backend endpoint | none |
| **Cursor** | none from logs (quota only) | Keychain service `cursor-access-token` via `SecItemCopyMatching` (`Quota/CursorTokenStore.swift:6`) else **opens Cursor's SQLite DB read-only** `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, key `cursorAuth/accessToken` (`:27-39`); derives cookie `WorkosCursorSessionToken=<sub>%3A%3A<jwt>` from the JWT (`:10-25`) | `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` (Bearer) then fallback `GET https://cursor.com/api/usage-summary` (Cookie) (`Quota/CursorQuotaClient.swift:30-45`) | none |
| **Antigravity** | Runs `/bin/ps -axo pid=,args=` (**all processes' command lines**) to find the Antigravity `language_server`, parsing `--csrf_token` and port flags (`AntigravityUsageProvider.swift:225-327`); `/usr/sbin/lsof -nP -a -p <pid> -iTCP -sTCP:LISTEN -Fn` (`:330-340`) | CSRF token scraped from the process arguments; fallback Keychain item `service=gemini account=antigravity` read via `/usr/bin/security … -w` (`:77-79`), supports `go-keyring-base64:` wrapping (`:114-135`) | Local: `POST http(s)://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/{RetrieveUserQuotaSummary,GetUserStatus,GetCommandModelConfigs,GetAllCascadeTrajectories,GetCascadeTrajectorySteps}` with `x-codeium-csrf-token` (`:356-372,423-470`) — walks **every conversation touched in the last week and pages through its steps** (`:436-490`) but only consumes `metadata.modelUsage` counters; full step payloads still pass through Atoll's memory (INFERRED). Cloud fallback: `POST https://cloudcode-pa.googleapis.com` / `daily-cloudcode-pa.googleapis.com` `/v1internal:retrieveUserQuotaSummary`, `:fetchAvailableModels` with Bearer, UA `antigravity` (`:612-668`). Comment at `:373` says it "allows insecure localhost" but the session is a plain `.ephemeral` one with no delegate (`:9-10`), so HTTPS-with-self-signed likely fails and the HTTP port path is what works (INFERRED). | none |
| **New API** (self-hosted gateway) | `Defaults.newAPIAccounts` (name + base URL, `Constants.swift:1289`) | API key stored in the Keychain under service `com.Ebullioscopic.Atoll.new-api` (`NewAPIUsage.swift:30-32`) — the only provider using Atoll's own keychain item | `GET <user base URL>/api/user/self`, `/api/log/self/stat` with Bearer (`NewAPIUsage.swift:~196-262`); `http://` base URLs are accepted (`normalizedBaseURL` allows http and https, `:162-178`) so the key can travel in cleartext if the user enters an http URL | none |
| **Pricing table** | bundled `managers/LLMUsage/pricing.json` (bundled via the Xcode synchronized folder group — INFERRED from `PBXFileSystemSynchronizedRootGroup` in the pbxproj, the file is not named in the project) | none | `GET https://raw.githubusercontent.com/Ebullioscopic/Atoll/dev/DynamicIsland/managers/LLMUsage/pricing.json` when `ModelPricingManager.shared` is first created (`ModelPricingManager.swift:98-104,132-147`); first created when a cost is computed (`ModelPricing.cost`, called from `JSONLUsageParser.swift:156`, `AntigravityUsageProvider.swift:487`) — INFERRED from the call graph | none |

### H2. Where Atoll itself stores secrets/tokens (OBSERVED, `Constants.swift`)

| Secret | Store | Line |
|---|---|---|
| Gemini/OpenAI/Claude/Groq API keys (Screen Assistant) | `UserDefaults` (plaintext in the prefs plist) | `:1371-1374` |
| Spotify `sp_dc` web-player cookie, derived web access token + expiry | `UserDefaults` (plaintext) | `:1244-1247` (`spotifySPDCCookie`, `spotifyAuthAccessToken…`) |
| Spotify Web API OAuth (library like/unlike) access/refresh | Keychain service `com.Ebullioscopic.Atoll.SpotifyLibrary` (`managers/Spotify/SpotifyTokenStore.swift:39`); legacy Defaults keys retained only for migration (`Constants.swift:1264-1268`) | — |
| Cider external-app API token | Keychain `com.Ebullioscopic.Atoll.Cider` / account `appToken` (`MediaControllers/CiderTokenStore.swift`); legacy plaintext key migrated and cleared | — |
| New API keys | Keychain `com.Ebullioscopic.Atoll.new-api` | — |
| Extension authorization table | Defaults `extensionAuthorizationEntries` | `:1388-1389` |

---

## I. Screen Assistant (AI chat / "ScreenAssistant")

| Item | Detail |
|---|---|
| Source | `managers/ScreenAssistantManager.swift` (1317 lines), `managers/ScreenAssistantPanelManager.swift`, `components/ScreenAssistant/*` (`ChatPanels.swift`, `ModelSelectionPanel.swift`, `ScreenshotSnippingTool.swift`), Settings `SettingsView.swift:8651-8828` |
| UI entry | Hotkey Shift+Cmd+A (`ShortcutConstants.swift:29`), notch panel/button; `enableScreenAssistant` default **true** (`Constants.swift:1369`) but **no network call happens without a user-supplied API key or a local endpoint** (each `sendTo…API` guards on a non-empty key, `ScreenAssistantManager.swift:407,430,453,487`) |
| Endpoints (user-triggered) | Gemini `https://generativelanguage.googleapis.com/v1beta/models/<id>:generateContent?key=<API KEY>` — **API key in the URL query string** (`:418`); OpenAI `https://api.openai.com/v1/chat/completions` (`:441`); Groq `https://api.groq.com/openai/v1/chat/completions` (`:470`); Anthropic `https://api.anthropic.com/v1/messages` (`:498`); local model `<endpoint>/api/chat`, default `http://localhost:11434` (Ollama style; `Constants.swift:1378`, `ScreenAssistantManager.swift:517`) |
| Data sent | User prompt + attached images/PDF/audio/video read with `Data(contentsOf:)` (`:1016-1130`) and screenshots. Attached-file list persisted in `UserDefaults` key `ScreenAssistantFiles` (`:346-355`). Screenshots are saved to `~/Documents/ScreenAssistantScreenshots` (`:141-149`). |
| Screenshots | Shells out to `/usr/sbin/screencapture` with `-c`, `-cw` or `-cs` (clipboard mode) and then reads the pasteboard (`ScreenshotSnippingTool.swift:36-44,100-133`). Overwrites the user's clipboard. TCC attribution of `screencapture` run as a child process is UNKNOWN. |
| Microphone | `Info.plist` generated key says the mic is used "to record voice questions" (`project.pbxproj:823`), but **no recording code exists** (grep for `AVAudioRecorder`, `AVAudioEngine`, `AVAudioApplication`, `requestRecordPermission` in the whole tree: none). Declared-but-unused permission string. |
| Offline | Only with a local Ollama-style server |
| Payment/account | The user's own provider API key (pay-per-use at the vendor) |

---

## J. Extension system (AtollExtensionKit, XPC `com.ebullioscopic.Atoll.xpc`, WebSocket RPC `:9020`)

| Item | Detail |
|---|---|
| Source | `services/Extensions/ExtensionXPCService.swift`, `ExtensionXPCServiceHost.swift`, `ExtensionRPCServer.swift`, `ExtensionRPCService.swift` (734 lines), `ExtensionRPCMessages.swift`, `AtollDistributedNotifications.swift`; `managers/Extensions/*` (authorization, live activities, lock-screen widgets, notch experiences, validator, event bridge); `components/Extensions/*`; Settings `components/Settings/ExtensionsSettings.swift` (561 lines) |
| Package | `AtollExtensionKit` from `github.com/Ebullioscopic/AtollExtensionKit`, pinned revision `e2d30afedbbcc259bec7eeb1bea0757e52f4ca01` (branch-style pin in `Package.resolved`); descriptor/protocol types (`AtollXPCServiceProtocol`, `AtollLiveActivityDescriptor`, …) live there, **not vendored — not audited**. |
| Transports | (1) **XPC mach service** `com.ebullioscopic.Atoll.xpc` (`ExtensionXPCServiceHost.swift:25-26,38-58`; entitlement `com.apple.security.mach-services` `Toplet.entitlements:9-12`). (2) **JSON-RPC 2.0 over WebSocket** on `127.0.0.1:9020` and `[::1]:9020` (`ExtensionRPCServer.swift:50,70-92`; loopback-bound and peer-checked, `:271-281`). Both are **started unconditionally at launch** (`DynamicIslandApp.swift:709-710`; `start()` reads no Defaults flag), so the sockets are open even when `enableThirdPartyExtensions` is off — the flag only makes request handlers reply "disabled" (`ExtensionRPCService.swift:140-146`, `ExtensionXPCService.swift:50-53`). |
| Capabilities offered to extensions | Live activities (`atoll.presentLiveActivity…`), lock-screen widgets, notch experiences/tabs/minimalistic overrides, and **file sharing** methods `getShelfItems`, `getShelfItemData` (returns base64 contents of Shelf files/text, `ExtensionRPCService.swift:422-462`), `showFilePicker`, `shareShelfItems`, `addFilesToShelf`, `subscribeShelfEvents` (`:98-116`) |
| UI entry | Settings > Extensions; `https://getatoll.app/marketplace` link (`ExtensionsSettings.swift:72`, opens browser on click) |
| Permission | none for Atoll itself; Offline: yes (no remote service is required); Payment/account: none |
| API class | Public (NSXPCConnection, Network.framework, WKWebView) |
| Settings keys | `enableThirdPartyExtensions` (default **true**, `Constants.swift:1381`), `enableExtensionLiveActivities/LockScreenWidgets/NotchExperiences/NotchTabs/NotchMinimalisticOverrides/NotchInteractiveWebViews` (all true, `:1382-1387`), `extensionDiagnosticsLoggingEnabled` (true), capacities 4/4/2 (`:1391-1393`), `enableExtensionFileSharing` (**true**, `:1394`) |

**Authorization model — security findings (OBSERVED):**

1. First contact is **auto-approved**. XPC: a `pending` entry is switched to `authorized` immediately (`ExtensionXPCService.swift:57-62`). RPC: `// Auto-authorize for now (user can revoke in settings)` then `authorizationManager.authorize(...)` (`ExtensionRPCService.swift:154-156`). Default scopes are `ExtensionPermissionScope.allCases` (all four, including `fileSharing`) (`ExtensionAuthorizationManager.swift`, `defaultScopes()`).
2. **Client identity is self-asserted.** RPC: the caller's `bundleIdentifier` is whatever `params.bundleIdentifier` says (`ExtensionRPCService.swift:147`). XPC: the identity is `NSRunningApplication(processIdentifier:).bundleIdentifier` (`ExtensionXPCServiceHost.swift:125-136`) and `shouldAcceptNewConnection` imposes **no code-signature/entitlement requirement** (`ExtensionXPCServiceHost.swift:70-98`).
3. The RPC server has **no `Origin`/header validation** (no `setClientRequestHandler`, no Origin check anywhere in `ExtensionRPCServer.swift`); only the peer address is required to be loopback. INFERRED consequence: any local process — and, because browsers permit WebSocket connections to loopback, a web page open in a local browser — can connect, auto-authorize itself under an invented bundle id, and call `getShelfItemData` to read whatever the user has put on the Shelf. Mitigation exists only as the per-app revoke list in Settings and the `enableExtensionFileSharing` toggle.
4. Broadcast side-channel: Atoll posts `DistributedNotificationCenter` `didBecomeActive/didBecomeIdle` with its PID (`DynamicIslandApp.swift:283-290,698-705`) readable by any local process.
5. Extension HTML is rendered in `WKWebView` (`components/Extensions/ExtensionLockScreenWidgetView.swift:297-366`); http(s) navigation/requests are allowed only when the descriptor has `allowRemoteRequests` (or `allowLocalhostRequests` for loopback) (`:340-372`) — i.e. the *extension* decides whether Atoll's WebView may contact the internet, with no user prompt.

---

## K. Weather (Open-Meteo / wttr.in)

| Item | Detail |
|---|---|
| Source | `managers/LockScreenWeatherManager.swift` (provider actor L585-880, location provider L1092-1146), `LockScreenWeatherPanelManager.swift`, `components/LockScreen/LockScreenWeatherWidget.swift` |
| Default behaviour | `enableLockScreenWeatherWidget` default **true** (`Constants.swift:1095`) -> at every launch the app calls `prepareLocationAccess()` (shows the Location prompt) and `refresh(force: true)` (`DynamicIslandApp.swift:1104-1108`; singleton init also refreshes, `LockScreenWeatherManager.swift:35-42`). Refreshed again when the Mac locks (`LockScreenManager.swift:264`) subject to a 30 min interval (`Constants.swift:1100`). |
| Open-Meteo calls | `GET https://api.open-meteo.com/v1/forecast?latitude&longitude&current=temperature_2m,weather_code,is_day,pressure_msl&daily=temperature_2m_max,…,sunrise,sunset&forecast_days=2&timezone=auto[&temperature_unit]` (`:711-738`); AQI `GET https://air-quality-api.open-meteo.com/v1/air-quality…` (`:797-810`). Coordinates are rounded to 4 decimals (`:707-708`). Ephemeral URLSession, 10 s timeouts (`:587-595`). **No API key, no account.** |
| wttr.in | `GET https://wttr.in/<lat,lon>?format=j1&aqi=yes` (`:626`) when the user picks provider "wttr.in" (`enums/generic.swift:233-236`). |
| **Provider-choice leak (OBSERVED)** | With the default provider Open-Meteo, if no location is available (permission denied or not yet granted) the code calls `fetchWttrSnapshot(location: nil)` (`:609-613` -> `https://wttr.in/?format=j1&aqi=yes`, `:626`). That sends the user's IP to wttr.in so the server can geolocate, even though the user selected Open-Meteo. |
| Location | `CLLocationManager.requestWhenInUseAuthorization()` (`:1104-1109`), `kCLLocationAccuracyHundredMeters` (`:1101`), cached 30 min (`:1115`). Info strings `NSLocationUsageDescription`/`…WhenInUse…` (`project.pbxproj:821-822`). No reverse geocoder is used (grep `CLGeocoder`: none), so the displayed place name only comes from wttr.in's response. |
| Offline | Fails -> catch branch shows battery/charging-only snapshot (`:~125-160`, INFERRED). Cached snapshot reused until the interval elapses. |
| Public vs private | Public HTTP APIs + CoreLocation |
| SPM note | `open-meteo/open-meteo` 1.4.16 is listed in `project.pbxproj:994` and `Package.resolved`, but no product of it is linked and nothing in the sources imports it (INFERRED unused; resolving it at build time still downloads the repository). |
| Settings keys | `lockScreenWeatherProviderSource` (`.openMeteo`, `:1108`), `lockScreenWeatherRefreshInterval` (30 min; no Settings control found — `Constants.swift:1100` key is read only by the manager), `lockScreenWeatherShowsLocation/Sunrise/AQI`, unit, style, AQI scale |

---

## L. Update checking (Sparkle, `Updates/` appcasts)

| Item | Detail |
|---|---|
| Source | `DynamicIslandApp.swift:33-47` (updater controller), `services/AtollUpdaterDelegate.swift:24-28`, `models/UpdateChannel.swift`, `components/Settings/SoftwareUpdater.swift`, `components/Settings/CustomUpdaterViews/*` (custom user-driver UI: `AtollUserDriver.swift` etc.), `Info.plist:16-23`, repo `Updates/*.xml` |
| Library | Sparkle 2.7.0 (`Package.resolved`) |
| Feed | Info.plist `SUFeedURL = https://raw.githubusercontent.com/Ebullioscopic/Atoll/main/Updates/appcast.xml`, `SUPublicEDKey = q2YQaJ1u…`, `SUEnableDownloaderService`/`SUEnableInstallerLauncherService` = true (`Info.plist:16-23`). The delegate **overrides** the feed per channel: stable `appcast.xml`, beta/alpha/nightly `appcast-<channel>.xml`, `dev` (Debug builds) -> `appcast-nightly.xml` (`UpdateChannel.swift:51-62`; delegate reads `Defaults[.updateChannel]`, default `.stable`, `Constants.swift:986`). |
| Starts | `SPUStandardUpdaterController(startingUpdater: !AppRuntimeEnvironment.isUITesting, …)` — the updater starts on every normal launch (`DynamicIslandApp.swift:42-45`). `Info.plist` has **no** `SUEnableAutomaticChecks` / `SUScheduledCheckInterval` / `SUAutomaticallyUpdate` keys (OBSERVED absence). INFERRED from Sparkle's documented behaviour: without `SUEnableAutomaticChecks` Sparkle asks the user for permission to check automatically on the second launch; until the user answers it does not poll in the background. Not verified at runtime. |
| Local appcast content | `Updates/appcast.xml`: 10 items, newest **2.3.3** (pubDate 24 Jul 2026, `sparkle:version 20260720004`, min macOS 14.6, DMG from `github.com/Ebullioscopic/Atoll/releases/download/v2.3.3/Atoll-2.3.3.dmg`, EdDSA signature present); `appcast-beta.xml` 2 items, `appcast-alpha.xml` 2, `appcast-nightly.xml` 1. These files are only data; the app fetches the **remote** copy on GitHub, not the local files. |
| Settings | About pane: "Automatically check for updates" and "Automatically download updates" toggles (`SoftwareUpdater.swift:66-73`) bound to Sparkle's own persistence; channel picker (`SettingsView.swift:4209-4240`); "Check for Updates…" (About and menu bar, `DynamicIslandApp.swift:55`) |
| Offline | A check simply fails; no functional dependency |
| Payment/account | none |
| Local-build caveat | An accepted update would **replace the user's self-built app with the upstream Developer-ID-signed DMG** (EdDSA-verified against the upstream key). A self-signed local build should not use Sparkle at all. |


---

### G3. Appendix — generated key tables (every Defaults key per pane)

Columns: Constants.swift declaration line | persisted `UserDefaults` string | Swift type | declared default | consuming files outside `Constants.swift`/`SettingsView.swift` (count) | control label where a `Defaults.Toggle` was matched. **`NONE` in the consumer column = no reader found.**

#### Pane `general` (34 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `automaticallySwitchDisplay` (L990) | `automaticallySwitchDisplay` | `Bool` | `true` | DynamicIslandApp.swift×1 | Toggle: Automatically switch displays |
| `caffeinateDefaultDuration` (L1348) | `caffeinateDefaultDuration` | `CaffeinateDuration` | `.indefinite` | CaffeinateManager.swift×1 |  |
| `caffeinateKeepsDisplayAwake` (L1349) | `caffeinateKeepsDisplayAwake` | `Bool` | `true` | CaffeinateManager.swift×1 | Toggle: Also keep the display awake |
| `closeGestureEnabled` (L1055) | `closeGestureEnabled` | `Bool` | `true` | ContentView.swift×2 | Toggle: Close gesture |
| `closedNotchWidth` (L1015) | `closedNotchWidth` | `CGFloat` | `150` | matters.swift×2 |  |
| `customizePhysicalNotchWidth` (L1016) | `customizePhysicalNotchWidth` | `Bool` | `false` | matters.swift×1 |  |
| `enableCaffeinate` (L1346) | `enableCaffeinate` | `Bool` | `true` | DynamicIslandApp.swift×3, CaffeinateManager.swift×2, DynamicIslandHeader.swift×1 | Toggle: Enable Keep Awake |
| `enableGestures` (L1054) | `enableGestures` | `Bool` | `true` | ContentView.swift×2 | Toggle: Enable gestures |
| `enableHaptics` (L996) | `enableHaptics` | `Bool` | `true` | ContentView.swift×7, ColorPickerManager.swift×1, NotchColorPickerView.swift×1, DynamicIslandCalendar.swift×2 (+4 more) | Toggle: Enable haptics |
| `enableHorizontalMusicGestures` (L1057) | `enableHorizontalMusicGestures` | `Bool` | `true` | ContentView.swift×1, MusicManager.swift×1 | Toggle: Media change with horizontal gestures |
| `enableMinimalisticUI` (L1503) | `enableMinimalisticUI` | `Bool` | `false` | DynamicIslandApp.swift×10, ContentView.swift×5, DynamicIslandViewCoordinator.swift×3, MusicManager.swift×1 (+10 more) | Toggle: Enable Minimalistic UI |
| `extendHoverArea` (L998) | `extendHoverArea` | `Bool` | `false` | ContentView.swift×1 | Toggle: Extend hover area |
| `externalDisplayStyle` (L999) | `externalDisplayStyle` | `ExternalDisplayStyle` | `.notch` | ContentView.swift×1, matters.swift×1, ProfileSelectionView.swift×2 |  |
| `gestureSensitivity` (L1056) | `gestureSensitivity` | `CGFloat` | `200.0` | ContentView.swift×5 |  |
| `hideDynamicIslandFromScreenCapture` (L992) | `hideDynamicIslandFromScreenCapture` | `Bool` | `false` | ScreenCaptureVisibilityManager.swift×2 | Toggle: Hide Dynamic Island during screenshots & recordings |
| `hideNonNotchUntilHover` (L1003) | `hideNonNotchUntilHover` | `Bool` | `false` | ContentView.swift×1 | Toggle: Hide until hovered on non-notch displays |
| `menubarIcon` (L988) | `menubarIcon` | `Bool` | `true` | DynamicIslandApp.swift×1, ProfileSelectionView.swift×1 | Toggle: Menubar icon |
| `minimumHoverDuration` (L995) | `minimumHoverDuration` | `TimeInterval` | `0.3` | ContentView.swift×1 |  |
| `mirrorShape` (L1023) | `mirrorShape` | `MirrorShapeEnum` | `MirrorShapeEnum.rectangle` | WebcamView.swift×2 |  |
| `musicGestureBehavior` (L1058) | `musicGestureBehavior` | `MusicSkipBehavior` | `.track` | MusicManager.swift×1 |  |
| `nonNotchHeight` (L1012) | `nonNotchHeight` | `CGFloat` | `32` | matters.swift×2 |  |
| `nonNotchHeightMode` (L1008) | `nonNotchHeightMode` | `WindowHeightMode` | `WindowHeightMode.matchMenuBar` | matters.swift×1 |  |
| `notchHeight` (L1013) | `notchHeight` | `CGFloat` | `32` | FlyoutWindowPresenter.swift×1, MusicControlWindowManager.swift×1, matters.swift×1 |  |
| `notchHeightMode` (L1004) | `notchHeightMode` | `WindowHeightMode` | `WindowHeightMode.matchRealNotchSize` | matters.swift×2 |  |
| `openNotchOnHover` (L997) | `openNotchOnHover` | `Bool` | `true` | ContentView.swift×5 | Toggle: Open notch on hover |
| `reverseScrollGestures` (L1060) | `reverseScrollGestures` | `Bool` | `false` | ContentView.swift×2 | Toggle: Reverse open/close scroll gestures |
| `reverseSwipeGestures` (L1059) | `reverseSwipeGestures` | `Bool` | `false` | ContentView.swift×1 | Toggle: Reverse swipe gestures |
| `showBatteryIndicator` (L1172) | `showBatteryIndicator` | `Bool` | `BatteryActivityManager.shared.hasBattery()` | DynamicIslandHeader.swift×1 |  |
| `showBatteryPercentInside` (L1174) | `showBatteryPercentInside` | `Bool` | `true` | DynamicIslandHeader.swift×1, DynamicIslandBattery.swift×1 | Toggle: Show battery percentage inside icon |
| `showCaffeinateIcon` (L1347) | `showCaffeinateIcon` | `Bool` | `true` | DynamicIslandHeader.swift×1 | Toggle: Show Keep Awake icon in the notch |
| `showEmojis` (L1020) | `showEmojis` | `Bool` | `false` | **NONE** |  |
| `showMinimalisticBatteryIndicator` (L1175) | `showMinimalisticBatteryIndicator` | `Bool` | `true` | MinimalisticMusicPlayerView.swift×1, DynamicIslandHeader.swift×1 | Toggle: Show battery indicator |
| `showOnAllDisplays` (L989) | `showOnAllDisplays` | `Bool` | `false` | DynamicIslandApp.swift×11, ContentView.swift×3, BatteryStatusViewModel.swift×1 | Toggle: Show on all displays |
| `useModernCloseAnimation` (L1030) | `useModernCloseAnimation` | `Bool` | `true` | ContentView.swift×1 |  |

#### Pane `liveActivities` (14 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `capsLockIndicatorTintMode` (L1494) | `capsLockIndicatorTintMode` | `CapsLockIndicatorTintMode` | `.white` | ContentView.swift×1, InlineHUD.swift×1 |  |
| `enableCameraDetection` (L1483) | `enableCameraDetection` | `Bool` | `true` | ContentView.swift×1, PrivacyIndicatorManager.swift×2 | Toggle: Enable Camera Detection |
| `enableCapsLockIndicator` (L1492) | `enableCapsLockIndicator` | `Bool` | `true` | ContentView.swift×2, CapsLockManager.swift×1 | Toggle: Show Caps Lock Indicator |
| `enableDoNotDisturbDetection` (L1476) | `enableDoNotDisturbDetection` | `Bool` | `true` | DynamicIslandApp.swift×3, ContentView.swift×2, DynamicIslandHeader.swift×1, LockScreenWeatherWidget.swift×1 | Toggle: Enable Focus Detection |
| `enableMicrophoneDetection` (L1484) | `enableMicrophoneDetection` | `Bool` | `true` | ContentView.swift×1, PrivacyIndicatorManager.swift×2 | Toggle: Enable Microphone Detection |
| `enableReminderLiveActivity` (L1333) | `enableReminderLiveActivity` | `Bool` | `true` | ContentView.swift×1, ReminderLiveActivityManager.swift×5, MinimalisticMusicPlayerView.swift×1 | Toggle: Enable reminder live activity |
| `enableScreenRecordingDetection` (L1468) | `enableScreenRecordingDetection` | `Bool` | `true` | DynamicIslandApp.swift×4, ContentView.swift×2, DynamicIslandHeader.swift×1 | Toggle: Enable Screen Recording Detection |
| `focusIndicatorNonPersistent` (L1480) | `focusIndicatorNonPersistent` | `Bool` | `false` | DoNotDisturbManager.swift×1, DoNotDisturbLiveActivity.swift×1 | Toggle: Show Focus as brief toast |
| `recordingControlMode` (L1471) | `recordingControlMode` | `RecordingControlMode` | `.withStopButton` | DynamicIslandApp.swift×1, ContentView.swift×1, RecordingLiveActivity.swift×1 |  |
| `recordingHoverStyle` (L1470) | `recordingHoverStyle` | `RecordingHoverStyle` | `.default` | DynamicIslandApp.swift×1, ContentView.swift×1, RecordingLiveActivity.swift×1 |  |
| `showCapsLockLabel` (L1497) | `showCapsLockLabel` | `Bool` | `false` | ContentView.swift×1, InlineHUD.swift×1 | Toggle: Show Caps Lock label |
| `showDoNotDisturbIndicator` (L1478) | `showDoNotDisturbIndicator` | `Bool` | `true` | ContentView.swift×2, DynamicIslandHeader.swift×1, LockScreenWeatherWidget.swift×1 | Toggle: Show Focus Indicator |
| `showDoNotDisturbLabel` (L1479) | `showDoNotDisturbLabel` | `Bool` | `true` | DoNotDisturbLiveActivity.swift×1 | Toggle: Show Focus Label |
| `showRecordingIndicator` (L1469) | `showRecordingIndicator` | `Bool` | `true` | DynamicIslandApp.swift×1, ContentView.swift×2, DynamicIslandHeader.swift×1 | Toggle: Show Recording Indicator |

#### Pane `appearance` (28 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `accentColor` (L1027) | `accentColor` | `Color` | `Color.blue` | ContentView.swift×4, DynamicIslandViewCoordinator.swift×1, MusicManager.swift×4, LocalSendDevicePickerWindowManager.swift×3 (+32 more) |  |
| `closedNotchWidth` (L1015) | `closedNotchWidth` | `CGFloat` | `150` | matters.swift×2 |  |
| `coloredSpectrogram` (L1063) | `coloredSpectrogram` | `Bool` | `true` | ContentView.swift×4, MusicManager.swift×1, MinimalisticMusicView.swift×2, MinimalisticMusicPlayerView.swift×1 (+2 more) | Toggle: Enable colored spectrograms |
| `cornerRadiusScaling` (L1029) | `cornerRadiusScaling` | `Bool` | `true` | ContentView.swift×4, Button+Bouncing.swift×1, NotchHomeView.swift×1, NotchTerminalView.swift×1 (+1 more) | Toggle: Corner radius scaling |
| `customAppIcons` (L1050) | `customAppIcons` | `[CustomAppIcon]` | `[]` | AppIcons.swift×1 |  |
| `customVisualizers` (L1048) | `customVisualizers` | `[CustomVisualizer]` | `[]` | **NONE** |  |
| `customizePhysicalNotchWidth` (L1016) | `customizePhysicalNotchWidth` | `Bool` | `false` | matters.swift×1 | Toggle: Customize physical notch width |
| `enableMinimalisticUI` (L1503) | `enableMinimalisticUI` | `Bool` | `false` | DynamicIslandApp.swift×10, ContentView.swift×5, DynamicIslandViewCoordinator.swift×3, MusicManager.swift×1 (+10 more) |  |
| `enableShadow` (L1028) | `enableShadow` | `Bool` | `true` | ContentView.swift×1 | Toggle: Enable window shadow |
| `externalDisplayStyle` (L999) | `externalDisplayStyle` | `ExternalDisplayStyle` | `.notch` | ContentView.swift×1, matters.swift×1, ProfileSelectionView.swift×2 |  |
| `lightingEffect` (L1026) | `lightingEffect` | `Bool` | `true` | MinimalisticMusicPlayerView.swift×1, NotchHomeView.swift×1, ProfileSelectionView.swift×1 | Toggle: Enable blur effect behind album art |
| `lockScreenGlassCustomizationMode` (L1120) | `lockScreenGlassCustomizationMode` | `LockScreenGlassCustomizationMode` | `.standard` | LockScreenMusicPanel.swift×1, ProfileSelectionView.swift×1 |  |
| `lockScreenGlassStyle` (L1119) | `lockScreenGlassStyle` | `LockScreenGlassStyle` | `.liquid` | LockScreenMusicPanel.swift×1, ProfileSelectionView.swift×1 |  |
| `lockScreenTimerGlassCustomizationMode` (L1125) | `lockScreenTimerGlassCustomizationMode` | `LockScreenGlassCustomizationMode` | `.standard` | LockScreenTimerWidget.swift×1 |  |
| `lockScreenTimerGlassStyle` (L1124) | `lockScreenTimerGlassStyle` | `LockScreenGlassStyle` | `.frosted` | LockScreenTimerWidget.swift×1 |  |
| `lockScreenTimerWidgetUsesBlur` (L1149) | `lockScreenTimerWidgetUsesBlur` | `Bool` | `false` | LockScreenTimerWidget.swift×1 |  |
| `mirrorShape` (L1023) | `mirrorShape` | `MirrorShapeEnum` | `MirrorShapeEnum.rectangle` | WebcamView.swift×2 |  |
| `openNotchWidth` (L1014) | `openNotchWidth` | `CGFloat` | `640` | DynamicIslandApp.swift×1, DynamicIslandViewModel.swift×1, matters.swift×4 |  |
| `playerColorTinting` (L1043) | `playerColorTinting` | `Bool` | `true` | MinimalisticMusicView.swift×1, MinimalisticMusicPlayerView.swift×2, NotchHomeView.swift×3, PinnedLyricsView.swift×1 (+1 more) | Toggle: Enable colored spectograms |
| `selectedAppIconID` (L1051) | `selectedAppIconID` | `String?` | `nil` | AppIcons.swift×1 |  |
| `selectedCameraID` (L1024) | `selectedCameraID` | `String` | `""` | WebcamManager.swift×1 |  |
| `selectedVisualizer` (L1049) | `selectedVisualizer` | `CustomVisualizer?` | `nil` | LottieAnimationView.swift×1 |  |
| `settingsIconInNotch` (L1025) | `settingsIconInNotch` | `Bool` | `true` | DynamicIslandHeader.swift×2 | Toggle: Settings icon in notch |
| `showMirror` (L1022) | `showMirror` | `Bool` | `false` | DynamicIslandViewCoordinator.swift×1, DynamicIslandViewModel.swift×1, matters.swift×2, DynamicIslandHeader.swift×1 (+3 more) | Toggle: Enable Dynamic mirror |
| `showNotHumanFace` (L1031) | `showNotHumanFace` | `Bool` | `false` | ContentView.swift×2, IdleAnimationsSettingsSection.swift×1 | Toggle: Idle Animation |
| `sliderColor` (L1039) | `sliderUseAlbumArtColor` | `SliderColorEnum` | `SliderColorEnum.white` | NotchHomeView.swift×2, RealTimeWaveformScrubberView.swift×1, LockScreenMusicPanel.swift×1 |  |
| `useModernCloseAnimation` (L1030) | `useModernCloseAnimation` | `Bool` | `true` | ContentView.swift×1 | Toggle: Use simpler close animation |
| `useMusicVisualizer` (L1044) | `useMusicVisualizer` | `Bool` | `true` | ContentView.swift×1, MinimalisticMusicPlayerView.swift×1, LockScreenMusicPanel.swift×1 |  |

#### Pane `lockScreen` (60 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `accentColor` (L1027) | `accentColor` | `Color` | `Color.blue` | ContentView.swift×4, DynamicIslandViewCoordinator.swift×1, MusicManager.swift×4, LocalSendDevicePickerWindowManager.swift×3 (+32 more) |  |
| `enableLockScreenFocusWidget` (L1096) | `enableLockScreenFocusWidget` | `Bool` | `true` | LockScreenWeatherWidget.swift×1 | Toggle: Show focus widget |
| `enableLockScreenLiveActivity` (L1487) | `enableLockScreenLiveActivity` | `Bool` | `true` | LockScreenManager.swift×5, LockScreenLiveActivityWindowManager.swift×1 | Toggle: Enable lock screen live activity |
| `enableLockScreenMediaWidget` (L1094) | `enableLockScreenMediaWidget` | `Bool` | `true` | DynamicIslandApp.swift×4, LockScreenWidgetPreviewManager.swift×3, LockScreenPanelManager.swift×2 | Toggle: Show lock screen media panel |
| `enableLockScreenReminderWidget` (L1098) | `enableLockScreenReminderWidget` | `Bool` | `true` | ReminderLiveActivityManager.swift×1, LockScreenReminderWidgetManager.swift×3 | Toggle: Show lock screen reminder |
| `enableLockScreenTimerWidget` (L1099) | `enableLockScreenTimerWidget` | `Bool` | `true` | LockScreenTimerWidgetManager.swift×2, LockScreenWidgetPreviewManager.swift×4 | Toggle: Show lock screen timer |
| `enableLockScreenWeatherWidget` (L1095) | `enableLockScreenWeatherWidget` | `Bool` | `true` | DynamicIslandApp.swift×1, LockScreenWeatherManager.swift×2, LockScreenWidgetPreviewManager.swift×3 | Toggle: Show lock screen weather |
| `enableLockSounds` (L1489) | `enableLockSounds` | `Bool` | `true` | LockScreenManager.swift×1 | Toggle: Play lock/unlock sounds |
| `enableReminderLiveActivity` (L1333) | `enableReminderLiveActivity` | `Bool` | `true` | ContentView.swift×1, ReminderLiveActivityManager.swift×5, MinimalisticMusicPlayerView.swift×1 |  |
| `lockScreenBatteryShowsBatteryGauge` (L1188) | `lockScreenWeatherShowsBatteryGauge` | `Bool` | `BatteryActivityManager.shared.hasBattery()` | LockScreenWeatherManager.swift×3, LockScreenWidgetPreviewManager.swift×2 | Toggle: Show battery indicator |
| `lockScreenBatteryShowsBluetooth` (L1196) | `lockScreenWeatherShowsBluetooth` | `Bool` | `true` | LockScreenWeatherManager.swift×5, LockScreenWidgetPreviewManager.swift×2 | Toggle: Show Bluetooth battery |
| `lockScreenBatteryShowsCharging` (L1194) | `lockScreenWeatherShowsCharging` | `Bool` | `true` | LockScreenWeatherManager.swift×3, LockScreenWidgetPreviewManager.swift×2 | Toggle: Show charging status |
| `lockScreenBatteryShowsChargingPercentage` (L1195) | `lockScreenWeatherShowsChargingPercentage` | `Bool` | `true` | LockScreenWeatherManager.swift×3, LockScreenWidgetPreviewManager.swift×2 | Toggle: Show charging percentage |
| `lockScreenBatteryUsesLaptopSymbol` (L1193) | `lockScreenWeatherBatteryUsesLaptopSymbol` | `Bool` | `true` | LockScreenWeatherManager.swift×2, LockScreenWidgetPreviewManager.swift×2 | Toggle: Use MacBook icon when on battery |
| `lockScreenCalendarEventLookaheadWindow` (L1154) | `lockScreenCalendarEventLookaheadWindow` | `String` | `"3h"` | CalendarManager.swift×1, LockScreenWeatherWidget.swift×1 |  |
| `lockScreenCalendarSelectionMode` (L1155) | `lockScreenCalendarSelectionMode` | `String` | `"all"` | LockScreenWeatherWidget.swift×1 |  |
| `lockScreenGlassCustomizationMode` (L1120) | `lockScreenGlassCustomizationMode` | `LockScreenGlassCustomizationMode` | `.standard` | LockScreenMusicPanel.swift×1, ProfileSelectionView.swift×1 |  |
| `lockScreenGlassStyle` (L1119) | `lockScreenGlassStyle` | `LockScreenGlassStyle` | `.liquid` | LockScreenMusicPanel.swift×1, ProfileSelectionView.swift×1 |  |
| `lockScreenKeepAlbumArtVisibleDuringFullscreenArtwork` (L1146) | `lockScreenKeepAlbumArtVisibleDuringFullscreenArtwork` | `Bool` | `false` | LockScreenMusicPanel.swift×1 | Toggle: Keep album art visible during fullscreen artwork |
| `lockScreenLiveActivityIconStyle` (L1488) | `lockScreenLiveActivityIconStyle` | `LockScreenLiveActivityIconStyle` | `.lock` | LockScreenManager.swift×3, LockIconAnimationView.swift×2 |  |
| `lockScreenMusicFullscreenArtworkEnabled` (L1145) | `lockScreenMusicFullscreenArtworkEnabled` | `Bool` | `true` | LockScreenMusicPanel.swift×1 | Toggle: Fullscreen artwork on right-click |
| `lockScreenMusicLiquidGlassVariant` (L1129) | `lockScreenMusicLiquidGlassVariant` | `LiquidGlassVariant` | `.defaultVariant` | LockScreenMusicPanel.swift×1, ProfileSelectionView.swift×1 |  |
| `lockScreenMusicMergedAirPlayOutput` (L1144) | `lockScreenMusicMergedAirPlayOutput` | `Bool` | `true` | LockScreenMusicPanel.swift×1 | Toggle: Show merged AirPlay and output devices |
| `lockScreenMusicPanelWidth` (L1111) | `lockScreenMusicPanelWidth` | `Double` | `Double(LockScreenMusicPanel.defaultCollapsedWidth)` | LockScreenPanelManager.swift×1, LockScreenMusicPanel.swift×3 |  |
| `lockScreenMusicUsesEnhancedLiquidBorder` (L1139) | `lockScreenMusicUsesEnhancedLiquidBorder` | `Bool` | `true` | LockScreenMusicPanel.swift×1 | Toggle: Use enhanced liquid border |
| `lockScreenMusicVerticalOffset` (L1110) | `lockScreenMusicVerticalOffset` | `Double` | `0` | LockScreenWidgetPreviewManager.swift×1, LockScreenPanelManager.swift×1 |  |
| `lockScreenPanelShowsBorder` (L1138) | `lockScreenPanelShowsBorder` | `Bool` | `false` | LockScreenMusicPanel.swift×1 | Toggle: Show panel border |
| `lockScreenPanelUsesBlur` (L1143) | `lockScreenPanelUsesBlur` | `Bool` | `true` | LockScreenMusicPanel.swift×1 | Toggle: Enable media panel blur |
| `lockScreenReminderChipStyle` (L1150) | `lockScreenReminderChipStyle` | `LockScreenReminderChipStyle` | `.eventColor` | ReminderLiveActivityManager.swift×1, LockScreenReminderWidgetManager.swift×1, LockScreenWidgetPreviewManager.swift×1, LockScreenWeatherWidget.swift×1 |  |
| `lockScreenReminderWidgetHorizontalAlignment` (L1151) | `lockScreenReminderWidgetHorizontalAlignment` | `String` | `"center"` | LockScreenReminderWidgetManager.swift×1, LockScreenReminderWidgetPanelManager.swift×1 |  |
| `lockScreenReminderWidgetVerticalOffset` (L1152) | `lockScreenReminderWidgetVerticalOffset` | `Double` | `0` | LockScreenReminderWidgetManager.swift×1, LockScreenReminderWidgetPanelManager.swift×1 |  |
| `lockScreenSelectedCalendarIDs` (L1156) | `lockScreenSelectedCalendarIDs` | `Set<String>` | `[]` | LockScreenWeatherWidget.swift×1 |  |
| `lockScreenShowAppIcon` (L1137) | `lockScreenShowAppIcon` | `Bool` | `false` | LockScreenMusicPanel.swift×1 | Toggle: Show media app icon |
| `lockScreenShowCalendarCountdown` (L1157) | `lockScreenShowCalendarCountdown` | `Bool` | `true` | LockScreenWeatherWidget.swift×1 | Toggle: Show countdown |
| `lockScreenShowCalendarEvent` (L1153) | `lockScreenShowCalendarEvent` | `Bool` | `true` | LockScreenWeatherWidget.swift×1 | Toggle: Show next calendar event |
| `lockScreenShowCalendarEventAfterStartEnabled` (L1159) | `lockScreenShowCalendarEventAfterStartEnabled` | `Bool` | `false` | LockScreenWeatherWidget.swift×1 | Toggle: Hide active event and show next upcoming event |
| `lockScreenShowCalendarEventAfterStartWindow` (L1160) | `lockScreenShowCalendarEventAfterStartWindow` | `String` | `"5m"` | LockScreenWeatherWidget.swift×1 |  |
| `lockScreenShowCalendarEventEntireDuration` (L1158) | `lockScreenShowCalendarEventEntireDuration` | `Bool` | `true` | LockScreenWeatherWidget.swift×1 | Toggle: Show event for entire duration |
| `lockScreenShowCalendarStartTimeAfterBegins` (L1162) | `lockScreenShowCalendarStartTimeAfterBegins` | `Bool` | `true` | LockScreenWeatherWidget.swift×1 | Toggle: Show start time after event begins |
| `lockScreenShowCalendarTimeRemaining` (L1161) | `lockScreenShowCalendarTimeRemaining` | `Bool` | `true` | LockScreenWeatherWidget.swift×1 | Toggle: Show time remaining |
| `lockScreenTimerGlassCustomizationMode` (L1125) | `lockScreenTimerGlassCustomizationMode` | `LockScreenGlassCustomizationMode` | `.standard` | LockScreenTimerWidget.swift×1 |  |
| `lockScreenTimerGlassStyle` (L1124) | `lockScreenTimerGlassStyle` | `LockScreenGlassStyle` | `.frosted` | LockScreenTimerWidget.swift×1 |  |
| `lockScreenTimerLiquidGlassVariant` (L1133) | `lockScreenTimerLiquidGlassVariant` | `LiquidGlassVariant` | `.defaultVariant` | LockScreenTimerWidget.swift×1 |  |
| `lockScreenTimerVerticalOffset` (L1116) | `lockScreenTimerVerticalOffset` | `Double` | `0` | LockScreenTimerWidgetManager.swift×2, LockScreenWidgetPreviewManager.swift×1 |  |
| `lockScreenTimerWidgetUsesBlur` (L1149) | `lockScreenTimerWidgetUsesBlur` | `Bool` | `false` | LockScreenTimerWidget.swift×1 |  |
| `lockScreenTimerWidgetWidth` (L1117) | `lockScreenTimerWidgetWidth` | `Double` | `350` | LockScreenTimerWidgetManager.swift×1, LockScreenTimerWidget.swift×2 |  |
| `lockScreenUseArtworkLayoutOverFullscreenCanvas` (L1148) | `lockScreenShowCenteredAlbumArtOverFullscreenCanvas` | `Bool` | `true` | FullScreenArtworkWindowManager.swift×2 | Toggle: Use album art layout over fullscreen canvas |
| `lockScreenWeatherAQIScale` (L1106) | `lockScreenWeatherAQIScale` | `LockScreenWeatherAirQualityScale` | `.us` | LockScreenWeatherManager.swift×3, LockScreenWidgetPreviewManager.swift×2 |  |
| `lockScreenWeatherProviderSource` (L1108) | `lockScreenWeatherProviderSource` | `LockScreenWeatherProviderSource` | `.openMeteo` | LockScreenWeatherManager.swift×7, LockScreenWidgetPreviewManager.swift×2 |  |
| `lockScreenWeatherShowsAQI` (L1105) | `lockScreenWeatherShowsAQI` | `Bool` | `true` | LockScreenWeatherManager.swift×4, LockScreenWidgetPreviewManager.swift×2 | Toggle: Show AQI widget |
| `lockScreenWeatherShowsLocation` (L1101) | `lockScreenWeatherShowsLocation` | `Bool` | `true` | LockScreenWeatherManager.swift×2, LockScreenWidgetPreviewManager.swift×2 | Toggle: Show location label |
| `lockScreenWeatherShowsSunrise` (L1102) | `lockScreenWeatherShowsSunrise` | `Bool` | `true` | LockScreenWeatherManager.swift×3, LockScreenWidgetPreviewManager.swift×2 | Toggle: Show sunrise time |
| `lockScreenWeatherTemperatureUnit` (L1104) | `lockScreenWeatherTemperatureUnit` | `LockScreenWeatherTemperatureUnit` | `.matchingSystemPreference` | LockScreenWeatherManager.swift×4, LockScreenWidgetPreviewManager.swift×2 |  |
| `lockScreenWeatherUsesGaugeTint` (L1107) | `lockScreenWeatherUsesGaugeTint` | `Bool` | `false` | LockScreenWeatherManager.swift×3, LockScreenWidgetPreviewManager.swift×2 | Toggle: Use colored gauges |
| `lockScreenWeatherVerticalOffset` (L1109) | `lockScreenWeatherVerticalOffset` | `Double` | `0` | LockScreenWeatherPanelManager.swift×1, LockScreenWidgetPreviewManager.swift×1 |  |
| `lockScreenWeatherWidgetStyle` (L1103) | `lockScreenWeatherWidgetStyle` | `LockScreenWeatherWidgetStyle` | `.inline` | LockScreenWeatherManager.swift×3, LockScreenWidgetPreviewManager.swift×2, ProfileSelectionView.swift×1 |  |
| `lockScreenWidgetAppearance` (L1118) | `lockScreenWidgetAppearance` | `LockScreenWidgetAppearance` | `.dark` | LockScreenReminderWidget.swift×1, LockScreenMusicPanel.swift×2, LockScreenWeatherWidget.swift×1, LockScreenTimerWidget.swift×1 |  |
| `showMediaOutputControl` (L1072) | `showMediaOutputControl` | `Bool` | `true` | MinimalisticMusicPlayerView.swift×1, NotchHomeView.swift×1, MusicSlotConfigurationView.swift×1, LockScreenMusicPanel.swift×1 |  |
| `showStandardMediaControls` (L1088) | `showStandardMediaControls` | `Bool` | `true` | DynamicIslandApp.swift×2, ContentView.swift×1, DynamicIslandViewCoordinator.swift×1, MusicManager.swift×1 (+4 more) |  |
| `siriResponsivenessMode` (L1097) | `siriResponsivenessMode` | `SiriResponsivenessMode` | `.automatic` | SiriVisibilityMonitor.swift×2 |  |

#### Pane `media` (48 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `accentColor` (L1027) | `accentColor` | `Color` | `Color.blue` | ContentView.swift×4, DynamicIslandViewCoordinator.swift×1, MusicManager.swift×4, LocalSendDevicePickerWindowManager.swift×3 (+32 more) |  |
| `alwaysShowLockScreenVolume` (L1080) | `alwaysShowLockScreenVolume` | `Bool` | `false` | LockScreenMusicPanel.swift×1 | Toggle: Always show volume control |
| `autoHideInactiveNotchMediaPlayer` (L1089) | `autoHideInactiveNotchMediaPlayer` | `Bool` | `true` | DynamicIslandViewModel.swift×1, matters.swift×2, NotchHomeView.swift×1 | Toggle: Auto-hide inactive notch media player |
| `colorExtractionMode` (L1047) | `colorExtractionMode` | `ColorExtractionMode` | `.vibrant` | NSImage+Extensions.swift×2, RealTimeWaveformScrubberView.swift×1 |  |
| `customIdleAnimations` (L1032) | `customIdleAnimations` | `[CustomIdleAnimation]` | `[]` | IdleAnimationManager.swift×11, IdleAnimationsSettingsSection.swift×3 |  |
| `enableFullscreenMediaDetection` (L1068) | `enableFullscreenMediaDetection` | `Bool` | `true` | DynamicIslandViewModel.swift×1, FullscreenMediaDetection.swift×1 |  |
| `enableLockScreenMediaWidget` (L1094) | `enableLockScreenMediaWidget` | `Bool` | `true` | DynamicIslandApp.swift×4, LockScreenWidgetPreviewManager.swift×3, LockScreenPanelManager.swift×2 | Toggle: Show lock screen media panel |
| `enableLyrics` (L1506) | `enableLyrics` | `Bool` | `false` | ContentView.swift×1, FullScreenArtworkWindowManager.swift×2, MusicManager.swift×6, DynamicIslandViewModel.swift×2 (+7 more) | Toggle: Show lyrics |
| `enableMinimalisticUI` (L1503) | `enableMinimalisticUI` | `Bool` | `false` | DynamicIslandApp.swift×10, ContentView.swift×5, DynamicIslandViewCoordinator.swift×3, MusicManager.swift×1 (+10 more) |  |
| `enableRealTimeWaveform` (L1064) | `enableRealTimeWaveform` | `Bool` | `false` | DynamicIslandApp.swift×5, NotchHomeView.swift×1, AudioTap.swift×1, AudioVisualizerView.swift×1 | Toggle |
| `enableSneakPeek` (L1065) | `enableSneakPeek` | `Bool` | `false` | DynamicIslandApp.swift×1, ContentView.swift×6, MusicManager.swift×1 |  |
| `enableWaveformScrubber` (L1046) | `enableWaveformScrubber` | `Bool` | `true` | NotchHomeView.swift×1 |  |
| `hideNotchOption` (L1236) | `hideNotchOption` | `HideNotchOption` | `.nowPlayingOnly` | DynamicIslandApp.swift×1, FullscreenMediaDetection.swift×1 |  |
| `lockScreenGlassCustomizationMode` (L1120) | `lockScreenGlassCustomizationMode` | `LockScreenGlassCustomizationMode` | `.standard` | LockScreenMusicPanel.swift×1, ProfileSelectionView.swift×1 |  |
| `lockScreenGlassStyle` (L1119) | `lockScreenGlassStyle` | `LockScreenGlassStyle` | `.liquid` | LockScreenMusicPanel.swift×1, ProfileSelectionView.swift×1 |  |
| `lockScreenKeepAlbumArtVisibleDuringFullscreenArtwork` (L1146) | `lockScreenKeepAlbumArtVisibleDuringFullscreenArtwork` | `Bool` | `false` | LockScreenMusicPanel.swift×1 | Toggle: Keep album art visible during fullscreen artwork |
| `lockScreenMusicAlbumParallaxEnabled` (L1115) | `lockScreenMusicAlbumParallaxEnabled` | `Bool` | `false` | LockScreenMusicPanel.swift×1 | Toggle: Enable album art parallax |
| `lockScreenMusicFullscreenArtworkEnabled` (L1145) | `lockScreenMusicFullscreenArtworkEnabled` | `Bool` | `true` | LockScreenMusicPanel.swift×1 | Toggle: Fullscreen artwork on right-click |
| `lockScreenMusicMergedAirPlayOutput` (L1144) | `lockScreenMusicMergedAirPlayOutput` | `Bool` | `true` | LockScreenMusicPanel.swift×1 | Toggle: Show merged AirPlay and output devices |
| `lockScreenMusicUsesEnhancedLiquidBorder` (L1139) | `lockScreenMusicUsesEnhancedLiquidBorder` | `Bool` | `true` | LockScreenMusicPanel.swift×1 | Toggle: Use enhanced liquid border |
| `lockScreenPanelShowsBorder` (L1138) | `lockScreenPanelShowsBorder` | `Bool` | `false` | LockScreenMusicPanel.swift×1 | Toggle: Show panel border |
| `lockScreenPanelUsesBlur` (L1143) | `lockScreenPanelUsesBlur` | `Bool` | `true` | LockScreenMusicPanel.swift×1 | Toggle: Enable media panel blur |
| `lockScreenShowAppIcon` (L1137) | `lockScreenShowAppIcon` | `Bool` | `false` | LockScreenMusicPanel.swift×1 | Toggle: Show media app icon |
| `lockScreenUseArtworkLayoutOverFullscreenCanvas` (L1148) | `lockScreenShowCenteredAlbumArtOverFullscreenCanvas` | `Bool` | `true` | FullScreenArtworkWindowManager.swift×2 | Toggle: Use album art layout over fullscreen canvas |
| `lyricHighlightStyle` (L1509) | `lyricHighlightStyle` | `LyricHighlightStyle` | `.sweep` | LyricSweep.swift×1 |  |
| `lyricsPanelOffset` (L1514) | `lyricsPanelOffset` | `CGFloat` | `0` | DynamicIslandViewModel.swift×1, matters.swift×1, NotchHomeView.swift×1 |  |
| `lyricsPanelWidth` (L1513) | `lyricsPanelWidth` | `CGFloat` | `280` | DynamicIslandViewModel.swift×1, matters.swift×1, NotchHomeView.swift×1 |  |
| `mediaController` (L1243) | `mediaController` | `MediaControllerType` | `defaultMediaController` | MusicManager.swift×2, MusicControllerSelectionView.swift×3 |  |
| `musicControlSlots` (L1084) | `musicControlSlots` | `[MusicControlButton]` | `MusicControlButton.defaultLayout` | MinimalisticMusicPlayerView.swift×1, NotchHomeView.swift×1, MusicSlotConfigurationView.swift×1, LockScreenMusicPanel.swift×1 |  |
| `musicControlWindowEnabled` (L1087) | `musicControlWindowEnabled` | `Bool` | `false` | DynamicIslandApp.swift×4, ContentView.swift×1 | Toggle: Show floating media controls |
| `musicSkipBehavior` (L1086) | `musicSkipBehavior` | `MusicSkipBehavior` | `.track` | ContentView.swift×1, MinimalisticMusicPlayerView.swift×1, NotchHomeView.swift×1, MusicControlOverlay.swift×1 (+1 more) |  |
| `parallaxEffectIntensity` (L1069) | `parallaxEffectIntensity` | `Double` | `6.0` | View+Parallax3D.swift×1 |  |
| `pinLyricsWhenClosed` (L1512) | `pinLyricsWhenClosed` | `Bool` | `false` | ContentView.swift×1, NotchHomeView.swift×1 | Toggle: Keep lyrics under the closed notch |
| `pinnedLyricContext` (L1511) | `pinnedLyricContext` | `PinnedLyricContext` | `.current` | ContentView.swift×1, PinnedLyricsView.swift×1 |  |
| `selectedIdleAnimation` (L1033) | `selectedIdleAnimation` | `CustomIdleAnimation?` | `nil` | IdleAnimationManager.swift×7, IdleAnimationView.swift×1, IdleAnimationsSettingsSection.swift×2, AnimationEditorView.swift×4 |  |
| `showCalendar` (L1036) | `showCalendar` | `Bool` | `true` | DynamicIslandViewCoordinator.swift×1, DynamicIslandViewModel.swift×1, matters.swift×3, NotchHomeView.swift×2 (+2 more) |  |
| `showLiveCanvasInDynamicIsland` (L1515) | `showLiveCanvasInDynamicIsland` | `Bool` | `false` | MinimalisticMusicPlayerView.swift×1, NotchHomeView.swift×2 | Toggle: Show live canvas in Dynamic Island |
| `showMediaOutputControl` (L1072) | `showMediaOutputControl` | `Bool` | `true` | MinimalisticMusicPlayerView.swift×1, NotchHomeView.swift×1, MusicSlotConfigurationView.swift×1, LockScreenMusicPanel.swift×1 | Toggle: Show \ |
| `showNotHumanFace` (L1031) | `showNotHumanFace` | `Bool` | `false` | ContentView.swift×2, IdleAnimationsSettingsSection.swift×1 |  |
| `showShuffleAndRepeat` (L1071) | `showShuffleAndRepeat` | `Bool` | `true` | MinimalisticMusicPlayerView.swift×1, NotchHomeView.swift×1, LockScreenMusicPanel.swift×1 | Toggle |
| `showSneakPeekOnTrackChange` (L1067) | `showSneakPeekOnTrackChange` | `Bool` | `true` | MusicManager.swift×1 |  |
| `showSongMetadataInClosedNotch` (L1644) | `showSongMetadataInClosedNotch` | `Bool` | `false` | ContentView.swift×1 | Toggle: Show song title and artist on non-notch displays |
| `showStandardMediaControls` (L1088) | `showStandardMediaControls` | `Bool` | `true` | DynamicIslandApp.swift×2, ContentView.swift×1, DynamicIslandViewCoordinator.swift×1, MusicManager.swift×1 (+4 more) | Toggle: Show media controls in Dynamic Island |
| `sneakPeekStyles` (L1066) | `sneakPeekStyles` | `SneakPeekStyle` | `.standard` | DynamicIslandApp.swift×1, ContentView.swift×7, MusicManager.swift×1 |  |
| `spotifyLibraryClientID` (L1248) | `spotifyLibraryClientID` | `String` | `""` | SpotifyLibraryManager.swift×1, SpotifyOAuthService.swift×1, SpotifyLikeButtonSettingsSection.swift×1 |  |
| `spotifySPDCCookie` (L1244) | `spotifySPDCCookie` | `String` | `""` | SpotifyAuthManager.swift×5, SpotifyAuthSettingsSection.swift×1 |  |
| `visualizerBarCount` (L1045) | `visualizerBarCount` | `Int` | `4` | ContentView.swift×1, MinimalisticMusicView.swift×1, MinimalisticMusicPlayerView.swift×1, MusicVisualizer.swift×1 (+4 more) |  |
| `waitInterval` (L1070) | `waitInterval` | `Double` | `3` | MusicManager.swift×1 |  |

#### Pane `devices` (11 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `enablePerAppVolume` (L1341) | `enablePerAppVolume` | `Bool` | `false` | PerAppVolumeManager.swift×3, DynamicIslandHeader.swift×1 | Toggle: Enable per-app volume |
| `progressBarStyle` (L1207) | `progressBarStyle` | `ProgressBarStyle` | `.hierarchical` | SystemEventIndicatorModifier.swift×2, InlineHUD.swift×1 |  |
| `showAirPodsListeningModeChanges` (L1279) | `showAirPodsListeningModeChanges` | `Bool` | `true` | BluetoothAudioManager.swift×8 | Toggle: Show AirPods listening mode changes |
| `showBluetoothBatteryPercentageText` (L1276) | `showBluetoothBatteryPercentageText` | `Bool` | `false` | InlineHUD.swift×1 | Toggle: Show battery percentage text in HUD |
| `showBluetoothDeviceConnections` (L1271) | `showBluetoothDeviceConnections` | `Bool` | `true` | BluetoothAudioManager.swift×2 | Toggle: Show Bluetooth device connections |
| `showBluetoothDeviceNameMarquee` (L1277) | `showBluetoothDeviceNameMarquee` | `Bool` | `false` | InlineHUD.swift×1 | Toggle: Scroll device name in HUD |
| `showPerAppVolumeIcon` (L1342) | `showPerAppVolumeIcon` | `Bool` | `true` | DynamicIslandHeader.swift×1 | Toggle: Show app volume icon in the notch |
| `useBluetoothHUD3DIcon` (L1278) | `useBluetoothHUD3DIcon` | `Bool` | `true` | InlineHUD.swift×1 |  |
| `useCircularBluetoothBatteryIndicator` (L1275) | `useCircularBluetoothBatteryIndicator` | `Bool` | `true` | InlineHUD.swift×1 | Toggle: Use circular battery indicator |
| `useColorCodedBatteryDisplay` (L1272) | `useColorCodedBatteryDisplay` | `Bool` | `true` | SystemEventIndicatorModifier.swift×1, InlineHUD.swift×1 | Toggle: Color-coded battery display |
| `useSmoothColorGradient` (L1274) | `useSmoothColorGradient` | `Bool` | `true` | CircularHUDView.swift×1, VerticalHUDView.swift×1, SystemEventIndicatorModifier.swift×1, InlineHUD.swift×1 |  |

#### Pane `timer` (19 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `accentColor` (L1027) | `accentColor` | `Color` | `Color.blue` | ContentView.swift×4, DynamicIslandViewCoordinator.swift×1, MusicManager.swift×4, LocalSendDevicePickerWindowManager.swift×3 (+32 more) |  |
| `enableLockScreenTimerWidget` (L1099) | `enableLockScreenTimerWidget` | `Bool` | `true` | LockScreenTimerWidgetManager.swift×2, LockScreenWidgetPreviewManager.swift×4 | Toggle: Show lock screen timer widget |
| `enableTimerFeature` (L1318) | `enableTimerFeature` | `Bool` | `true` | DynamicIslandApp.swift×3, ContentView.swift×1, DynamicIslandViewCoordinator.swift×3, matters.swift×1 (+4 more) | Toggle: Enable timer feature |
| `lockScreenTimerGlassCustomizationMode` (L1125) | `lockScreenTimerGlassCustomizationMode` | `LockScreenGlassCustomizationMode` | `.standard` | LockScreenTimerWidget.swift×1 |  |
| `lockScreenTimerGlassStyle` (L1124) | `lockScreenTimerGlassStyle` | `LockScreenGlassStyle` | `.frosted` | LockScreenTimerWidget.swift×1 |  |
| `lockScreenTimerLiquidGlassVariant` (L1133) | `lockScreenTimerLiquidGlassVariant` | `LiquidGlassVariant` | `.defaultVariant` | LockScreenTimerWidget.swift×1 |  |
| `lockScreenTimerWidgetUsesBlur` (L1149) | `lockScreenTimerWidgetUsesBlur` | `Bool` | `false` | LockScreenTimerWidget.swift×1 |  |
| `mirrorSystemTimer` (L1328) | `mirrorSystemTimer` | `Bool` | `true` | SystemTimerBridge.swift×10 | Toggle |
| `showTimerPresetsInNotchTab` (L1321) | `showTimerPresetsInNotchTab` | `Bool` | `true` | NotchTimerView.swift×1 |  |
| `timerControlWindowEnabled` (L1338) | `timerControlWindowEnabled` | `Bool` | `true` | TimerLiveActivity.swift×1 |  |
| `timerDisplayMode` (L1319) | `timerDisplayMode` | `TimerDisplayMode` | `.tab` | ContentView.swift×1, DynamicIslandViewCoordinator.swift×3, matters.swift×1, DynamicIslandHeader.swift×1 (+1 more) |  |
| `timerIconColorMode` (L1322) | `timerIconColorMode` | `TimerIconColorMode` | `.adaptive` | ContentView.swift×1, NotchTimerView.swift×1, TimerIconAnimation.swift×1, TimerPopover.swift×2 (+1 more) |  |
| `timerInputStyle` (L1329) | `timerInputStyle` | `TimerInputStyle` | `.manual` | NotchTimerView.swift×1 |  |
| `timerPresets` (L1320) | `timerPresets` | `[TimerPreset]` | `TimerPreset.defaultPresets` | ContentView.swift×1, TimerManager.swift×1, MinimalisticMusicPlayerView.swift×1, NotchTimerView.swift×1 (+4 more) |  |
| `timerProgressStyle` (L1327) | `timerProgressStyle` | `TimerProgressStyle` | `.bar` | ContentView.swift×1, NotchTimerView.swift×1, TimerPopover.swift×2, TimerLiveActivity.swift×1 |  |
| `timerShowsCountdown` (L1324) | `timerShowsCountdown` | `Bool` | `true` | ContentView.swift×1, TimerPopover.swift×1, TimerLiveActivity.swift×1 |  |
| `timerShowsLabel` (L1325) | `timerShowsLabel` | `Bool` | `false` | TimerLiveActivity.swift×1 |  |
| `timerShowsProgress` (L1326) | `timerShowsProgress` | `Bool` | `true` | ContentView.swift×1, NotchTimerView.swift×1, TimerPopover.swift×2, TimerLiveActivity.swift×1 |  |
| `timerSolidColor` (L1323) | `timerSolidColor` | `Color` | `.blue` | ContentView.swift×1, NotchTimerView.swift×1, TimerIconAnimation.swift×1, TimerPopover.swift×2 (+1 more) |  |

#### Pane `calendar` (25 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `autoScrollToNextEvent` (L1232) | `autoScrollToNextEvent` | `Bool` | `true` | DynamicIslandCalendar.swift×2 |  |
| `enableLockScreenReminderWidget` (L1098) | `enableLockScreenReminderWidget` | `Bool` | `true` | ReminderLiveActivityManager.swift×1, LockScreenReminderWidgetManager.swift×3 | Toggle: Show lock screen reminder |
| `enableLyrics` (L1506) | `enableLyrics` | `Bool` | `false` | ContentView.swift×1, FullScreenArtworkWindowManager.swift×2, MusicManager.swift×6, DynamicIslandViewModel.swift×2 (+7 more) |  |
| `enableReminderLiveActivity` (L1333) | `enableReminderLiveActivity` | `Bool` | `true` | ContentView.swift×1, ReminderLiveActivityManager.swift×5, MinimalisticMusicPlayerView.swift×1 | Toggle: Enable reminder live activity |
| `enableThirdPartyCalendarApp` (L1166) | `enableThirdPartyCalendarApp` | `Bool` | `false` | EventModel.swift×1 | Toggle |
| `fantasticalDefaultView` (L1168) | `fantasticalDefaultView` | `FantasticalViewStyle` | `.mini` | EventModel.swift×2 |  |
| `hideAllDayEvents` (L1038) | `hideAllDayEvents` | `Bool` | `false` | ReminderLiveActivityManager.swift×3, DynamicIslandCalendar.swift×3 |  |
| `hideCompletedReminders` (L1037) | `hideCompletedReminders` | `Bool` | `true` | ReminderLiveActivityManager.swift×3, DynamicIslandCalendar.swift×3 |  |
| `lockScreenCalendarEventLookaheadWindow` (L1154) | `lockScreenCalendarEventLookaheadWindow` | `String` | `"3h"` | CalendarManager.swift×1, LockScreenWeatherWidget.swift×1 |  |
| `lockScreenCalendarSelectionMode` (L1155) | `lockScreenCalendarSelectionMode` | `String` | `"all"` | LockScreenWeatherWidget.swift×1 |  |
| `lockScreenReminderChipStyle` (L1150) | `lockScreenReminderChipStyle` | `LockScreenReminderChipStyle` | `.eventColor` | ReminderLiveActivityManager.swift×1, LockScreenReminderWidgetManager.swift×1, LockScreenWidgetPreviewManager.swift×1, LockScreenWeatherWidget.swift×1 |  |
| `lockScreenSelectedCalendarIDs` (L1156) | `lockScreenSelectedCalendarIDs` | `Set<String>` | `[]` | LockScreenWeatherWidget.swift×1 |  |
| `lockScreenShowCalendarCountdown` (L1157) | `lockScreenShowCalendarCountdown` | `Bool` | `true` | LockScreenWeatherWidget.swift×1 | Toggle: Show countdown |
| `lockScreenShowCalendarEvent` (L1153) | `lockScreenShowCalendarEvent` | `Bool` | `true` | LockScreenWeatherWidget.swift×1 | Toggle: Show next calendar event |
| `lockScreenShowCalendarEventAfterStartEnabled` (L1159) | `lockScreenShowCalendarEventAfterStartEnabled` | `Bool` | `false` | LockScreenWeatherWidget.swift×1 | Toggle: Hide active event and show next upcoming event |
| `lockScreenShowCalendarEventAfterStartWindow` (L1160) | `lockScreenShowCalendarEventAfterStartWindow` | `String` | `"5m"` | LockScreenWeatherWidget.swift×1 |  |
| `lockScreenShowCalendarEventEntireDuration` (L1158) | `lockScreenShowCalendarEventEntireDuration` | `Bool` | `true` | LockScreenWeatherWidget.swift×1 | Toggle: Show event for entire duration |
| `lockScreenShowCalendarStartTimeAfterBegins` (L1162) | `lockScreenShowCalendarStartTimeAfterBegins` | `Bool` | `true` | LockScreenWeatherWidget.swift×1 | Toggle: Show start time after event begins |
| `lockScreenShowCalendarTimeRemaining` (L1161) | `lockScreenShowCalendarTimeRemaining` | `Bool` | `true` | LockScreenWeatherWidget.swift×1 | Toggle: Show time remaining |
| `reminderLeadTime` (L1335) | `reminderLeadTime` | `Int` | `5` | ReminderLiveActivityManager.swift×3 |  |
| `reminderPresentationStyle` (L1334) | `reminderPresentationStyle` | `ReminderPresentationStyle` | `.ringCountdown` | ContentView.swift×1, ReminderLiveActivityManager.swift×1, ReminderLiveActivity.swift×1 |  |
| `reminderSneakPeekDuration` (L1336) | `reminderSneakPeekDuration` | `Double` | `5` | ContentView.swift×2, DynamicIslandViewCoordinator.swift×1, ReminderLiveActivityManager.swift×3, ReminderLiveActivity.swift×1 (+1 more) |  |
| `selectedCalendarApp` (L1167) | `selectedCalendarApp` | `ThirdPartyCalendarApp` | `.fantastical` | EventModel.swift×1 |  |
| `showCalendar` (L1036) | `showCalendar` | `Bool` | `true` | DynamicIslandViewCoordinator.swift×1, DynamicIslandViewModel.swift×1, matters.swift×3, NotchHomeView.swift×2 (+2 more) | Toggle: Show calendar |
| `showFullEventTitles` (L1231) | `showFullEventTitles` | `Bool` | `false` | DynamicIslandCalendar.swift×2 |  |

#### Pane `hudAndOSD` (47 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `accentColor` (L1027) | `accentColor` | `Color` | `Color.blue` | ContentView.swift×4, DynamicIslandViewCoordinator.swift×1, MusicManager.swift×4, LocalSendDevicePickerWindowManager.swift×3 (+32 more) |  |
| `brightnessFineStepPercent` (L1411) | `brightnessFineStepPercent` | `Int` | `2` | SystemChangesObserver.swift×1 |  |
| `brightnessStepPercent` (L1410) | `brightnessStepPercent` | `Int` | `6` | SystemChangesObserver.swift×1 |  |
| `circularHUDShowValue` (L1437) | `circularHUDShowValue` | `Bool` | `true` | CircularHUDView.swift×1 |  |
| `circularHUDSize` (L1438) | `circularHUDSize` | `CGFloat` | `65` | CircularHUDWindowManager.swift×3, CircularHUDView.swift×1 |  |
| `circularHUDStrokeWidth` (L1439) | `circularHUDStrokeWidth` | `CGFloat` | `4` | CircularHUDView.swift×1 |  |
| `circularHUDUseAccentColor` (L1440) | `circularHUDUseAccentColor` | `Bool` | `true` | CircularHUDView.swift×1 |  |
| `enableBrightnessHUD` (L1402) | `enableBrightnessHUD` | `Bool` | `true` | SystemChangesObserver.swift×3, SystemHUDManager.swift×3, MinimalisticMusicPlayerView.swift×1, NotchHomeView.swift×1 |  |
| `enableCircularHUD` (L1416) | `enableCircularHUD` | `Bool` | `false` | BetterDisplayManager.swift×4, SystemChangesObserver.swift×6, LunarManager.swift×4, CircularHUDWindowManager.swift×1 (+3 more) |  |
| `enableCustomOSD` (L1414) | `enableCustomOSD` | `Bool` | `false` | BetterDisplayManager.swift×4, SystemChangesObserver.swift×6, CustomOSDWindowManager.swift×4, LunarManager.swift×4 (+3 more) |  |
| `enableExternalVolumeControlListener` (L1445) | `enableExternalVolumeControlListener` | `Bool` | `false` | BetterDisplayManager.swift×1, LunarManager.swift×1, SystemHUDManager.swift×3 |  |
| `enableKeyboardBacklightHUD` (L1403) | `enableKeyboardBacklightHUD` | `Bool` | `true` | SystemChangesObserver.swift×3, SystemHUDManager.swift×3, MinimalisticMusicPlayerView.swift×1, NotchHomeView.swift×1 |  |
| `enableOSDBrightness` (L1454) | `enableOSDBrightness` | `Bool` | `true` | BetterDisplayManager.swift×1, SystemChangesObserver.swift×1, CustomOSDWindowManager.swift×1, LunarManager.swift×1 (+1 more) |  |
| `enableOSDKeyboardBacklight` (L1455) | `enableOSDKeyboardBacklight` | `Bool` | `true` | SystemChangesObserver.swift×1, CustomOSDWindowManager.swift×1, SystemHUDManager.swift×2 |  |
| `enableOSDVolume` (L1453) | `enableOSDVolume` | `Bool` | `true` | BetterDisplayManager.swift×1, SystemChangesObserver.swift×1, CustomOSDWindowManager.swift×1, LunarManager.swift×1 (+1 more) |  |
| `enableSystemHUD` (L1400) | `enableSystemHUD` | `Bool` | `true` | DynamicIslandViewCoordinator.swift×1, BetterDisplayManager.swift×2, SystemChangesObserver.swift×3, LunarManager.swift×2 (+4 more) |  |
| `enableThirdPartyDDCIntegration` (L1443) | `enableThirdPartyDDCIntegration` | `Bool` | `false` | DynamicIslandApp.swift×1, BetterDisplayManager.swift×2, LunarManager.swift×2, SystemHUDManager.swift×4 |  |
| `enableVerticalHUD` (L1415) | `enableVerticalHUD` | `Bool` | `false` | BetterDisplayManager.swift×4, SystemChangesObserver.swift×8, LunarManager.swift×4, VerticalHUDWindowManager.swift×4 (+3 more) |  |
| `enableVolumeHUD` (L1401) | `enableVolumeHUD` | `Bool` | `true` | SystemChangesObserver.swift×3, SystemHUDManager.swift×3, MinimalisticMusicPlayerView.swift×1, NotchHomeView.swift×1 |  |
| `hasSeenOSDAlphaWarning` (L1451) | `hasSeenOSDAlphaWarning` | `Bool` | `false` | **NONE** |  |
| `inlineHUD` (L1206) | `inlineHUD` | `Bool` | `true` | ContentView.swift×2, SystemEventIndicatorModifier.swift×1, ProfileSelectionView.swift×2 |  |
| `osdIconColorStyle` (L1465) | `osdIconColorStyle` | `OSDIconColorStyle` | `.white` | CustomOSDView.swift×1 |  |
| `osdLiquidGlassCustomizationMode` (L1457) | `osdLiquidGlassCustomizationMode` | `LockScreenGlassCustomizationMode` | `.standard` | CustomOSDView.swift×1 |  |
| `osdLiquidGlassVariant` (L1461) | `osdLiquidGlassVariant` | `LiquidGlassVariant` | `.defaultVariant` | CustomOSDView.swift×1 |  |
| `osdMaterial` (L1456) | `osdMaterial` | `OSDMaterial` | `.frosted` | CustomOSDView.swift×1 |  |
| `playVolumeChangeFeedback` (L1405) | `playVolumeChangeFeedback` | `Bool` | `false` | SystemChangesObserver.swift×1 | Toggle: Play feedback when volume is changed |
| `progressBarStyle` (L1207) | `progressBarStyle` | `ProgressBarStyle` | `.hierarchical` | SystemEventIndicatorModifier.swift×2, InlineHUD.swift×1 |  |
| `showProgressPercentages` (L1212) | `showProgressPercentages` | `Bool` | `true` | SystemEventIndicatorModifier.swift×1, InlineHUD.swift×1 | Toggle: Show percentages beside progress bars |
| `systemEventIndicatorShadow` (L1210) | `systemEventIndicatorShadow` | `Bool` | `false` | SystemEventIndicatorModifier.swift×3 | Toggle: Enable glowing effect |
| `systemEventIndicatorUseAccent` (L1211) | `systemEventIndicatorUseAccent` | `Bool` | `false` | SystemEventIndicatorModifier.swift×4 | Toggle: Use accent color |
| `systemHUDSensitivity` (L1404) | `systemHUDSensitivity` | `Int` | `5` | **NONE** |  |
| `thirdPartyDDCProvider` (L1444) | `thirdPartyDDCProvider` | `ThirdPartyDDCProvider` | `.betterDisplay` | DynamicIslandApp.swift×1, BetterDisplayManager.swift×2, LunarManager.swift×2, SystemHUDManager.swift×3 |  |
| `useColorCodedBatteryDisplay` (L1272) | `useColorCodedBatteryDisplay` | `Bool` | `true` | SystemEventIndicatorModifier.swift×1, InlineHUD.swift×1 |  |
| `useColorCodedVolumeDisplay` (L1273) | `useColorCodedVolumeDisplay` | `Bool` | `true` | CircularHUDView.swift×1, VerticalHUDView.swift×1, SystemEventIndicatorModifier.swift×1, InlineHUD.swift×1 | Toggle: Color-coded Volume |
| `useSmoothColorGradient` (L1274) | `useSmoothColorGradient` | `Bool` | `true` | CircularHUDView.swift×1, VerticalHUDView.swift×1, SystemEventIndicatorModifier.swift×1, InlineHUD.swift×1 | Toggle: Smooth color transitions |
| `verticalHUDHeight` (L1422) | `verticalHUDHeight` | `CGFloat` | `160` | VerticalHUDWindowManager.swift×3, VerticalHUDView.swift×1 |  |
| `verticalHUDInteractive` (L1421) | `verticalHUDInteractive` | `Bool` | `true` | VerticalHUDWindowManager.swift×2, VerticalHUDView.swift×1 |  |
| `verticalHUDLiquidGlassCustomizationMode` (L1427) | `verticalHUDLiquidGlassCustomizationMode` | `LockScreenGlassCustomizationMode` | `.standard` | VerticalHUDView.swift×1 |  |
| `verticalHUDLiquidGlassVariant` (L1431) | `verticalHUDLiquidGlassVariant` | `LiquidGlassVariant` | `.defaultVariant` | VerticalHUDView.swift×1 |  |
| `verticalHUDMaterial` (L1426) | `verticalHUDMaterial` | `OSDMaterial` | `.frosted` | VerticalHUDView.swift×1 |  |
| `verticalHUDPadding` (L1424) | `verticalHUDPadding` | `CGFloat` | `24` | VerticalHUDWindowManager.swift×3 |  |
| `verticalHUDPosition` (L1417) | `verticalHUDPosition` | `String` | `"right"` | VerticalHUDWindowManager.swift×3 |  |
| `verticalHUDShowValue` (L1420) | `verticalHUDShowValue` | `Bool` | `true` | VerticalHUDView.swift×1 |  |
| `verticalHUDUseAccentColor` (L1425) | `verticalHUDUseAccentColor` | `Bool` | `false` | VerticalHUDView.swift×1 |  |
| `verticalHUDWidth` (L1423) | `verticalHUDWidth` | `CGFloat` | `36` | VerticalHUDWindowManager.swift×3, VerticalHUDView.swift×1 |  |
| `volumeFineStepPercent` (L1409) | `volumeFineStepPercent` | `Int` | `2` | SystemChangesObserver.swift×1 |  |
| `volumeStepPercent` (L1408) | `volumeStepPercent` | `Int` | `6` | SystemChangesObserver.swift×1 |  |

#### Pane `battery` (15 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `chargingBatteryHUDDuration` (L1181) | `chargingBatteryHUDDuration` | `Int` | `3` | BatteryStatusViewModel.swift×1 |  |
| `fullBatteryHUDDuration` (L1183) | `fullBatteryHUDDuration` | `Int` | `3` | BatteryStatusViewModel.swift×1 |  |
| `fullBatteryHUDStyle` (L1187) | `fullBatteryHUDStyle` | `BatteryNotificationStyle` | `.standard` | DynamicIslandApp.swift×1, ContentView.swift×2, DynamicIslandBattery.swift×1 |  |
| `fullBatteryHUDThreshold` (L1185) | `fullBatteryHUDThreshold` | `Int` | `100` | BatteryStatusViewModel.swift×1 |  |
| `lowBatteryHUDDuration` (L1182) | `lowBatteryHUDDuration` | `Int` | `3` | BatteryStatusViewModel.swift×1 |  |
| `lowBatteryHUDStyle` (L1186) | `lowBatteryHUDStyle` | `BatteryNotificationStyle` | `.standard` | DynamicIslandApp.swift×1, ContentView.swift×2, DynamicIslandBattery.swift×1 |  |
| `lowBatteryHUDThreshold` (L1184) | `lowBatteryHUDThreshold` | `Int` | `20` | BatteryStatusViewModel.swift×2 |  |
| `playLowBatteryAlertSound` (L1177) | `playLowBatteryAlertSound` | `Bool` | `true` | BatteryStatusViewModel.swift×1 | Toggle: Play low battery alert sound |
| `showBatteryIndicator` (L1172) | `showBatteryIndicator` | `Bool` | `BatteryActivityManager.shared.hasBattery()` | DynamicIslandHeader.swift×1 | Toggle: Show battery indicator |
| `showBatteryPercentage` (L1173) | `showBatteryPercentage` | `Bool` | `true` | DynamicIslandBattery.swift×1 | Toggle: Show battery percentage |
| `showChargingBatteryHUD` (L1178) | `showChargingBatteryHUD` | `Bool` | `true` | ContentView.swift×1, BatteryStatusViewModel.swift×1 | Toggle: Charging HUD |
| `showFullBatteryHUD` (L1180) | `showFullBatteryHUD` | `Bool` | `true` | ContentView.swift×1, BatteryStatusViewModel.swift×1 | Toggle: Fully charged HUD |
| `showLowBatteryHUD` (L1179) | `showLowBatteryHUD` | `Bool` | `true` | ContentView.swift×1, BatteryStatusViewModel.swift×1 | Toggle: Low battery HUD |
| `showPowerStatusIcons` (L1176) | `showPowerStatusIcons` | `Bool` | `true` | DynamicIslandBattery.swift×2 | Toggle: Show power status icons |
| `showPowerStatusNotifications` (L1171) | `showPowerStatusNotifications` | `Bool` | `true` | DynamicIslandApp.swift×1, ContentView.swift×2, BatteryStatusViewModel.swift×1 | Toggle: Show power status notifications |

#### Pane `stats` (16 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `cpuTemperatureUnit` (L1298) | `cpuTemperatureUnit` | `LockScreenWeatherTemperatureUnit` | `.matchingSystemPreference` | CPUStatsSharedViews.swift×1 |  |
| `enableAntigravityProvider` (L1287) | `enableAntigravityProvider` | `Bool` | `true` | UsageProvider.swift×1 | Toggle: Antigravity |
| `enableClaudeProvider` (L1284) | `enableClaudeProvider` | `Bool` | `true` | UsageProvider.swift×1 | Toggle: Claude |
| `enableCodexProvider` (L1285) | `enableCodexProvider` | `Bool` | `true` | UsageProvider.swift×1 | Toggle: Codex |
| `enableCursorProvider` (L1286) | `enableCursorProvider` | `Bool` | `true` | UsageProvider.swift×1 | Toggle: Cursor |
| `enableLLMUsageFeature` (L1283) | `enableLLMUsageFeature` | `Bool` | `false` | TabSelectionView.swift×1 | Toggle: Enable LLM Usage Monitor |
| `enableNewAPIProvider` (L1288) | `enableNewAPIProvider` | `Bool` | `false` | UsageProvider.swift×1 | Toggle: New API |
| `enableStatsFeature` (L1282) | `enableStatsFeature` | `Bool` | `false` | DynamicIslandApp.swift×1, ContentView.swift×1, DynamicIslandViewCoordinator.swift×2, matters.swift×2 (+3 more) | Toggle: Enable system stats monitoring |
| `newAPIAccounts` (L1289) | `newAPIAccounts` | `[NewAPIAccount]` | `[]` | NewAPIUsage.swift×7, NotchLLMUsageView.swift×2 |  |
| `showCpuGraph` (L1293) | `showCpuGraph` | `Bool` | `true` | DynamicIslandApp.swift×1, ContentView.swift×1, matters.swift×1, NotchStatsView.swift×1 | Toggle: CPU Usage |
| `showDiskGraph` (L1297) | `showDiskGraph` | `Bool` | `false` | DynamicIslandApp.swift×1, ContentView.swift×1, matters.swift×1, NotchStatsView.swift×1 | Toggle: Disk I/O |
| `showGpuGraph` (L1295) | `showGpuGraph` | `Bool` | `true` | DynamicIslandApp.swift×1, ContentView.swift×1, matters.swift×1, NotchStatsView.swift×1 | Toggle: GPU Usage |
| `showMemoryGraph` (L1294) | `showMemoryGraph` | `Bool` | `true` | DynamicIslandApp.swift×1, ContentView.swift×1, matters.swift×1, NotchStatsView.swift×1 | Toggle: Memory Usage |
| `showNetworkGraph` (L1296) | `showNetworkGraph` | `Bool` | `false` | DynamicIslandApp.swift×1, ContentView.swift×1, matters.swift×1, NotchStatsView.swift×1 | Toggle: Network Activity |
| `statsStopWhenNotchCloses` (L1291) | `statsStopWhenNotchCloses` | `Bool` | `true` | StatsManager.swift×2 | Toggle: Stop monitoring after closing the notch |
| `statsUpdateInterval` (L1292) | `statsUpdateInterval` | `Double` | `1.0` | StatsManager.swift×4 |  |

#### Pane `clipboard` (5 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `clipboardDisplayMode` (L1366) | `clipboardDisplayMode` | `ClipboardDisplayMode` | `.panel` | DynamicIslandApp.swift×1, DynamicIslandViewCoordinator.swift×1, DynamicIslandViewModel.swift×1, matters.swift×1 (+3 more) |  |
| `clipboardHistorySize` (L1360) | `clipboardHistorySize` | `Int` | `3` | ClipboardManager.swift×1 |  |
| `enableClipboardManager` (L1359) | `enableClipboardManager` | `Bool` | `true` | DynamicIslandApp.swift×3, DynamicIslandViewCoordinator.swift×1, DynamicIslandViewModel.swift×1, matters.swift×1 (+5 more) | Toggle: Enable Clipboard Manager |
| `persistClipboardHistory` (L1364) | `persistClipboardHistory` | `Bool` | `true` | ClipboardManager.swift×5 | Toggle: Save History Across Restarts |
| `showClipboardIcon` (L1365) | `showClipboardIcon` | `Bool` | `true` | DynamicIslandHeader.swift×2 | Toggle: Show Clipboard Icon |

#### Pane `screenAssistant` (3 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `enableScreenAssistant` (L1369) | `enableScreenAssistant` | `Bool` | `true` | DynamicIslandApp.swift×3, ProfileSelectionView.swift×4 | Toggle: Enable Screen Assistant |
| `geminiApiKey` (L1371) | `geminiApiKey` | `String` | `""` | ScreenAssistantManager.swift×1, ChatPanels.swift×1, ScreenAssistantPanel.swift×1, ModelSelectionPanel.swift×3 |  |
| `screenAssistantDisplayMode` (L1370) | `screenAssistantDisplayMode` | `ScreenAssistantDisplayMode` | `.panel` | DynamicIslandApp.swift×1 |  |

#### Pane `colorPicker` (5 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `colorHistorySize` (L1355) | `colorHistorySize` | `Int` | `10` | **NONE** |  |
| `colorPickerDisplayMode` (L1354) | `colorPickerDisplayMode` | `ColorPickerDisplayMode` | `.panel` | DynamicIslandHeader.swift×1 |  |
| `enableColorPickerFeature` (L1352) | `enableColorPickerFeature` | `Bool` | `true` | DynamicIslandApp.swift×3, DynamicIslandHeader.swift×1, NotchColorPickerView.swift×1, TabSelectionView.swift×1 (+1 more) | Toggle: Enable Color Picker |
| `showColorFormats` (L1353) | `showColorFormats` | `Bool` | `true` | NotchColorPickerView.swift×1, ColorPickerPanel.swift×1 | Toggle: Show All Color Formats |
| `showColorPickerIcon` (L1356) | `showColorPickerIcon` | `Bool` | `true` | DynamicIslandHeader.swift×2 | Toggle: Show Color Picker Icon |

#### Pane `downloads` (5 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `accentColor` (L1027) | `accentColor` | `Color` | `Color.blue` | ContentView.swift×4, DynamicIslandViewCoordinator.swift×1, MusicManager.swift×4, LocalSendDevicePickerWindowManager.swift×3 (+32 more) |  |
| `enableDownloadListener` (L1199) | `enableDownloadListener` | `Bool` | `true` | ContentView.swift×1, DownloadManager.swift×2 | Toggle: Enable download detection |
| `selectedDownloadIconStyle` (L1203) | `selectedDownloadIconStyle` | `DownloadIconStyle` | `DownloadIconStyle.onlyAppIcon` | **NONE** |  |
| `selectedDownloadIndicatorStyle` (L1201) | `selectedDownloadIndicatorStyle` | `DownloadIndicatorStyle` | `DownloadIndicatorStyle.progress` | DownloadLiveActivity.swift×1 |  |
| `showDownloadSpeed` (L1202) | `showDownloadSpeed` | `Bool` | `false` | DownloadLiveActivity.swift×1 | Toggle: Show download speed |

#### Pane `shelf` (10 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `accentColor` (L1027) | `accentColor` | `Color` | `Color.blue` | ContentView.swift×4, DynamicIslandViewCoordinator.swift×1, MusicManager.swift×4, LocalSendDevicePickerWindowManager.swift×3 (+32 more) |  |
| `allowMoveOnDrag` (L1225) | `allowMoveOnDrag` | `Bool` | `false` | ShelfItemView.swift×1 | Toggle: Allow moving files when dragging out |
| `autoRemoveShelfItems` (L1226) | `autoRemoveShelfItems` | `Bool` | `false` | ShelfItemView.swift×1 | Toggle: Remove from shelf after dragging |
| `copyOnDrag` (L1221) | `copyOnDrag` | `Bool` | `false` | ShelfItemView.swift×2 | Toggle: Copy items on drag |
| `dynamicShelf` (L1215) | `dynamicShelf` | `Bool` | `true` | ContentView.swift×1, DynamicIslandViewCoordinator.swift×1, matters.swift×1, TabSelectionView.swift×1 | Toggle: Enable shelf |
| `expandedDragDetection` (L1227) | `expandedDragDetection` | `Bool` | `true` | **NONE** | Toggle: Expanded drag detection area |
| `localSendDevicePickerGlassMode` (L1219) | `localSendDevicePickerGlassMode` | `LockScreenGlassCustomizationMode` | `.standard` | LocalSendDevicePickerWindowManager.swift×1 |  |
| `localSendDevicePickerLiquidGlassVariant` (L1220) | `localSendDevicePickerLiquidGlassVariant` | `LiquidGlassVariant` | `.v11` | LocalSendDevicePickerWindowManager.swift×1 |  |
| `openShelfByDefault` (L1216) | `openShelfByDefault` | `Bool` | `true` | DynamicIslandViewCoordinator.swift×1, DynamicIslandViewModel.swift×1 | Toggle: Open shelf tab by default if items added |
| `quickShareProvider` (L1217) | `quickShareProvider` | `String` | `"AirDrop"` | TabSelectionView.swift×1, AirDropView.swift×1, FileShareView.swift×1 |  |

#### Pane `shortcuts` (8 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `enableCaffeinate` (L1346) | `enableCaffeinate` | `Bool` | `true` | DynamicIslandApp.swift×3, CaffeinateManager.swift×2, DynamicIslandHeader.swift×1 |  |
| `enableClipboardManager` (L1359) | `enableClipboardManager` | `Bool` | `true` | DynamicIslandApp.swift×3, DynamicIslandViewCoordinator.swift×1, DynamicIslandViewModel.swift×1, matters.swift×1 (+5 more) |  |
| `enableColorPickerFeature` (L1352) | `enableColorPickerFeature` | `Bool` | `true` | DynamicIslandApp.swift×3, DynamicIslandHeader.swift×1, NotchColorPickerView.swift×1, TabSelectionView.swift×1 (+1 more) |  |
| `enableScreenAssistant` (L1369) | `enableScreenAssistant` | `Bool` | `true` | DynamicIslandApp.swift×3, ProfileSelectionView.swift×4 |  |
| `enableShortcuts` (L1397) | `enableShortcuts` | `Bool` | `true` | DynamicIslandApp.swift×16 | Toggle: Enable global keyboard shortcuts |
| `enableStatsFeature` (L1282) | `enableStatsFeature` | `Bool` | `false` | DynamicIslandApp.swift×1, ContentView.swift×1, DynamicIslandViewCoordinator.swift×2, matters.swift×2 (+3 more) |  |
| `enableTerminalFeature` (L1301) | `enableTerminalFeature` | `Bool` | `false` | DynamicIslandApp.swift×3, DynamicIslandViewCoordinator.swift×1, matters.swift×1, NotchTerminalView.swift×1 (+2 more) |  |
| `enableTimerFeature` (L1318) | `enableTimerFeature` | `Bool` | `true` | DynamicIslandApp.swift×3, ContentView.swift×1, DynamicIslandViewCoordinator.swift×3, matters.swift×1 (+4 more) |  |

#### Pane `notes` (9 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `appleNotesLastSyncDate` (L1526) | `appleNotesLastSyncDate` | `Date?` | `nil` | AppleNotesSyncManager.swift×1 |  |
| `enableAppleNotesSync` (L1525) | `enableAppleNotesSync` | `Bool` | `false` | AppleNotesSyncManager.swift×4, NotchNotesView.swift×2 | Toggle: Sync with Apple Notes |
| `enableCreateFromClipboard` (L1522) | `enableCreateFromClipboard` | `Bool` | `true` | NotchNotesView.swift×1 | Toggle: Enable Create from Clipboard |
| `enableNoteCharCount` (L1523) | `enableNoteCharCount` | `Bool` | `true` | NotchNotesView.swift×1 | Toggle: Show Character Count |
| `enableNoteColorFiltering` (L1521) | `enableNoteColorFiltering` | `Bool` | `false` | NotchNotesView.swift×1 | Toggle: Enable Color Filtering |
| `enableNotePinning` (L1519) | `enableNotePinning` | `Bool` | `true` | NotchNotesView.swift×1 | Toggle: Enable Note Pinning |
| `enableNoteSearch` (L1520) | `enableNoteSearch` | `Bool` | `false` | NotchNotesView.swift×1 | Toggle: Enable Note Search |
| `enableNotes` (L1518) | `enableNotes` | `Bool` | `false` | DynamicIslandViewCoordinator.swift×1, matters.swift×1, NotchNotesView.swift×1, TabSelectionView.swift×3 | Toggle: Enable Notes |
| `savedNotes` (L1524) | `savedNotes` | `[NoteItem]` | `[]` | NotchNotesView.swift×1 |  |

#### Pane `terminal` (15 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `enableTerminalFeature` (L1301) | `enableTerminalFeature` | `Bool` | `false` | DynamicIslandApp.swift×3, DynamicIslandViewCoordinator.swift×1, matters.swift×1, NotchTerminalView.swift×1 (+2 more) | Toggle: Enable terminal |
| `terminalBackgroundColor` (L1312) | `terminalBackgroundColor` | `Color` | `.black` | TerminalManager.swift×1 |  |
| `terminalBoldAsBright` (L1311) | `terminalBoldAsBright` | `Bool` | `true` | TerminalManager.swift×1 |  |
| `terminalCursorColor` (L1314) | `terminalCursorColor` | `Color` | `Color(.selectedControlColor)` | TerminalManager.swift×1 |  |
| `terminalCursorStyle` (L1307) | `terminalCursorStyle` | `String` | `"blinkBlock"` | TerminalManager.swift×1 |  |
| `terminalFontFamily` (L1303) | `terminalFontFamily` | `String` | `""` | TerminalManager.swift×2 |  |
| `terminalFontSize` (L1304) | `terminalFontSize` | `Double` | `12.0` | TerminalManager.swift×2 |  |
| `terminalForegroundColor` (L1313) | `terminalForegroundColor` | `Color` | `.white` | TerminalManager.swift×1, NotchTerminalView.swift×1 |  |
| `terminalMaxHeightFraction` (L1306) | `terminalMaxHeightFraction` | `Double` | `0.4` | DynamicIslandApp.swift×2, ContentView.swift×1 |  |
| `terminalMouseReporting` (L1310) | `terminalMouseReporting` | `Bool` | `true` | TerminalManager.swift×1 |  |
| `terminalOpacity` (L1305) | `terminalOpacity` | `Double` | `1.0` | TerminalManager.swift×1 |  |
| `terminalOptionAsMeta` (L1309) | `terminalOptionAsMeta` | `Bool` | `true` | TerminalManager.swift×1 |  |
| `terminalScrollbackLines` (L1308) | `terminalScrollbackLines` | `Int` | `1000` | TerminalManager.swift×1 |  |
| `terminalShellPath` (L1302) | `terminalShellPath` | `String` | `"/bin/zsh"` | TerminalManager.swift×1 |  |
| `terminalStickyMode` (L1315) | `terminalStickyMode` | `Bool` | `false` | ContentView.swift×3 | Toggle |

#### Pane `about` (3 Defaults keys referenced)

| Key (Constants.swift line) | Persisted string | Type | Default | Read outside Settings UI (files) | Control |
|---|---|---|---|---|---|
| `accentColor` (L1027) | `accentColor` | `Color` | `Color.blue` | ContentView.swift×4, DynamicIslandViewCoordinator.swift×1, MusicManager.swift×4, LocalSendDevicePickerWindowManager.swift×3 (+32 more) |  |
| `releaseName` (L991) | `releaseName` | `String` | `"Kaafu"` | **NONE** |  |
| `updateChannel` (L986) | `updateChannel` | `UpdateChannel` | `.stable` | UpdateFoundView.swift×1, UpdateProgressView.swift×1, UpdateNotFoundView.swift×1, AtollUpdaterDelegate.swift×1 |  |

Footnote on the table above: `accentColor` rows that appear in unrelated panes are a regex artefact (the `.accentColor` pattern also matches `Color.accentColor`/`.foregroundStyle(.accentColor)` style uses). The `Extensions` pane (`ExtensionsSettings.swift`) is covered in section J rather than as a key table because its toggles are bound through `ExtensionAuthorizationManager.updateFeatureToggles` (`ExtensionsSettings.swift:368-398`) onto the keys listed in J.
