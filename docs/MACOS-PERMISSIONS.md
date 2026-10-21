# Atoll v2.3.3 — macOS permissions, entitlements and usage strings

Repo: `<repo>`, branch `local-build`, commit `f039ca9`. Paths relative to `Toplet/` unless noted.
**Nothing was built or run.** Tags: **OBSERVED (file:line)**, **INFERRED**, **UNKNOWN**. "Requested in code" means a call that *should* make macOS show a prompt; it is not proof that a prompt appears on a given macOS release.
**Safety rule for this document:** every grant below is made by the user through the macOS prompt or System Settings UI. Do **not** edit the TCC database or use scripts to grant permissions. (For information: Atoll itself opens `~/Library/Application Support/com.apple.TCC/TCC.db` *read-only and closes it unread* as a Full Disk Access probe, `helpers/FullDiskAccessPermissionStore.swift:23-47`.)

## 1. Build/identity facts that drive TCC

| Fact | Evidence |
|---|---|
| App is **not sandboxed** (`ENABLE_APP_SANDBOX = NO`), hardened runtime ON | `../Toplet.xcodeproj/project.pbxproj:791,792,866,867` |
| Bundle IDs: Debug `com.Ebullioscopic.Atoll.dev`, Release `com.Ebullioscopic.Atoll` | `project.pbxproj:832,907` |
| `LSUIElement = YES` (menu-bar accessory app; no Dock icon) | `project.pbxproj:810` |
| Deployment target macOS 14.6 | `project.pbxproj:830` |
| Signing: Debug "Apple Development" automatic with team `9Y64TRM77N`; Release manual "Developer ID Application" | `project.pbxproj:783-790,859-865` — a local build needs the user's own identity |
| TCC grants are tied to bundle ID + code identity (INFERRED, standard macOS behaviour): a rebuild signed with a different identity, or an ad-hoc build, will be treated as a new app and re-prompt | — |
| **Local-build crash risk:** the code itself warns that if the `mach-services` entitlement is stripped (ad-hoc signing), "starting the listener without the entitlement crashes the app" and it skips the XPC listener only under UI testing | `services/Extensions/ExtensionXPCServiceHost.swift:45-60`; listener started at launch `DynamicIslandApp.swift:709` (UNKNOWN whether a self-signed build keeps the entitlement) |

## 2. Info.plist usage strings (all of them)

Two sources: the hand-written `Info.plist` and `INFOPLIST_KEY_*` build settings (Debug `project.pbxproj:812-825`; the Release configuration carries the same block).

| Key | Text | Source | Backed by code? |
|---|---|---|---|
| `NSAppleMusicUsageDescription` | "Atoll uses Apple Music to fetch animated artwork for the lock screen wallpaper." | `Info.plist:10-11` | Yes — `managers/AnimatedArtworkManager.swift:105-111` (`MusicAuthorization.request()`) |
| `NSAudioCaptureUsageDescription` | "…real-time music waveform and to set the volume of individual apps…" | `Info.plist:12-13` | Yes — Core Audio process taps `audio/AudioTap.swift:248-303`, `audio/PerAppVolume/AppVolumeTap.swift:65-93` |
| `NSScreenCaptureUsageDescription` | "…screen recording permission to capture screenshots for the AI assistant feature." | `Info.plist:14-15` | Indirect — Atoll does **not** call any capture API (no `CGPreflightScreenCaptureAccess`, `CGRequestScreenCaptureAccess`, ScreenCaptureKit, `CGWindowListCreateImage`; grep); it launches `/usr/sbin/screencapture` (`components/ScreenAssistant/ScreenshotSnippingTool.swift:100-103`). Whether macOS attributes that child's capture to Atoll is UNKNOWN. |
| `NSAppleEventsUsageDescription` | "Atoll uses AppleScripts to control Spotify, Apple Music, and Notes." | `project.pbxproj:812` | Yes, but also used for **System Events** (not mentioned): `components/DynamicIslandSystemTiles.swift:68`, `managers/ScreenRecordingManager.swift:133` |
| `NSBluetoothAlwaysUsageDescription` | "…detect when audio devices connect and display their battery status in the HUD." | `:813` | Yes — `managers/BluetoothAudioManager.swift:44,2310` |
| `NSCalendarsFullAccessUsageDescription` / `NSCalendarsUsageDescription` | "Show calender events inside the notch" / "Need for Calendar Mode" | `:814-815` | Yes — `Providers/CalendarServiceProviding.swift:57` |
| `NSRemindersFullAccessUsageDescription` / `NSRemindersUsageDescription` | "Atoll needs Reminders access to show your reminders" | `:824-825` | Yes — `CalendarServiceProviding.swift:59` |
| `NSCameraUsageDescription` | "We need your camera for Mirror mode" | `:816` | Yes — `managers/WebcamManager.swift:129` |
| `NSLocationUsageDescription` / `NSLocationWhenInUseUsageDescription` | "…display accurate lock screen weather." | `:821-822` | Yes — `managers/LockScreenWeatherManager.swift:1107` |
| `NSMicrophoneUsageDescription` | "…record voice questions for the AI assistant feature." | `:823` | **No** — no recording code exists (grep for `AVAudioRecorder`, `AVAudioEngine`, `AVAudioApplication`, `requestRecordPermission`, `AVCaptureDevice … .audio`: none). `MicrophoneMonitor` only listens to CoreAudio "device running" flags (`managers/MicrophoneMonitor.swift:68,188-205`). Declared but unused string. |
| `NSDocumentsFolderUsageDescription` | "…save and read shelf dragged files." | `:818` | Yes — clipboard images, note images, screenshots in `~/Documents` |
| `NSDownloadsFolderUsageDescription` | "…read files in the downloads folder." | `:819` | Yes — `managers/DownloadManager.swift:167-205` |
| `NSDesktopFolderUsageDescription` | "…save screenshots to your desktop." | `:817` | **No** — grep finds no code writing to the Desktop (only "Desktop" dictionary keys inside the wallpaper plist, `FullScreenArtworkWindowManager.swift:1608,1692`). Stale string. |
| `NSHumanReadableCopyright`, `CFBundleDisplayName=Atoll`, `LSApplicationCategoryType=utilities`, `MetalCaptureEnabled` | — | `:808-820` | n/a |
| `NSAppTransportSecurity > NSAllowsArbitraryLoads = true` | — | `Info.plist:5-9` | not a permission; disables ATS (see FREE-LOCAL-OPERATION.md P7) |
| `SUFeedURL`, `SUPublicEDKey`, `SUEnableDownloaderService`, `SUEnableInstallerLauncherService` | Sparkle | `Info.plist:16-23` | updates |
| **Missing keys (OBSERVED absence)** | `NSLocalNetworkUsageDescription` / `NSBonjourServices` (LocalSend multicast and listener, `components/Shelf/Services/LocalSendService.swift:60-61,95-110,627`), `NSLocationAlwaysUsageDescription` (not needed), any `CFBundleURLTypes` (Spotify OAuth uses a callback scheme `atoll-spotify`, `managers/Spotify/SpotifyOAuthService.swift:35-37`; the grep found no URL-type declaration, so the callback relies on the web-auth session — INFERRED) | — | — |
| `UTImportedTypeDeclarations` contains one empty `<dict/>` | — | `Info.plist:24-28` | empty declaration (effect UNKNOWN) |

## 3. Entitlements (`Toplet.entitlements`, OBSERVED lines 5-27)

| Entitlement | Meaning | Status in this non-sandboxed app |
|---|---|---|
| `com.apple.security.cs.disable-library-validation` = true (`:5-6`) | allows loading libraries not signed by the same team (the prebuilt `MediaRemoteAdapter.framework`, Sparkle XPC helpers) | **active** under hardened runtime; weakens code-injection protection |
| `com.apple.security.device.camera` = true (`:7-8`) | camera access under hardened runtime | **needed** for Mirror |
| `com.apple.security.mach-services` = [`com.ebullioscopic.Atoll.xpc`] (`:9-12`) | lets the extension XPC listener register that name | needed or the listener crashes (see section 1) |
| `com.apple.security.automation.apple-events` = true (`:13-14`) | send Apple Events under hardened runtime | **needed** for Music/Spotify/Notes/System Events |
| `com.apple.security.personal-information.calendars` = true (`:15-16`) | calendar/reminder data | sandbox entitlement; harmless/inert without sandbox (INFERRED) |
| `com.apple.security.temporary-exception.apple-events` = [`com.spotify.client`, `com.apple.Music`, `com.apple.Notes`] (`:17-22`) | sandbox exception list | **inert** without sandbox (INFERRED); also note it omits `com.apple.systemevents`, which the code targets |
| `com.apple.security.temporary-exception.mach-lookup.global-name` = [`$(PRODUCT_BUNDLE_IDENTIFIER)-spks`, `-spki`] (`:23-27`) | Sparkle sandbox XPC services | inert without sandbox (INFERRED) |
| **Absent**: `com.apple.security.device.audio-input` (build setting `ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = NO`, `project.pbxproj:794,869`), `com.apple.security.personal-information.location`, `com.apple.security.device.bluetooth`, `com.apple.developer.musickit`-style capability | not present; location/Bluetooth work without them when unsandboxed; the **MusicKit developer-token capability for a locally signed build is UNKNOWN** (code backs off on token failures, `AnimatedArtworkManager.swift:62-66`) | — |

## 4. Permission-by-permission

Columns: **Triggering feature(s)** | **Requested in code** | **Denied / revoked handling observed** | **Exact manual user action** | **Prompted at first launch with default settings?**

### 4.1 Accessibility

| | |
|---|---|
| Triggers | System HUD replacement via media-key event tap (`managers/MediaKeyInterceptor.swift`); Mirror-system-Clock-timer AX polling (`managers/SystemTimerBridge.swift:117-121,197,361-375,1180`); Tidal controller (`MediaControllers/TidalController.swift:168`); menu-bar layout probing (`managers/MenuBarLayout.swift:111`); fullscreen-media detection (`observers/FullscreenMediaDetection.swift:123`); screen-recording "stop" shortcut injected through System Events (`ScreenRecordingManager.swift:133-148`); global `NSEvent` monitors (see 4.14) |
| Requested | `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` at `MediaKeyInterceptor.swift:464-470` (called by `start()` `:173`, which `SystemHUDManager` runs at launch because `enableSystemHUD` defaults true, `models/Constants.swift:1400`). Also `helpers/AccessibilityPermissionStore.swift:45-50` from Settings callouts (`components/Settings/SettingsView.swift:2229,2348,2867,9002`) and the menu-bar "Permissions/Accessibility" items (`DynamicIslandApp.swift:1152-1210,1273-1280`). |
| Denied/revoked | Event tap creation fails -> logs "Accessibility permission missing…", `isInterceptionAvailable = false`, schedules a **retry timer** (fast then slower, `MediaKeyInterceptor.swift:241-290`, policy `MediaKeyTapRetryPolicy`) so granting later works without relaunch (comment `:157-164`). A running tap that is disabled by the OS is re-enabled/logged (`:327-336`). `AccessibilityPermissionStore` polls 30x500 ms after a prompt and re-polls when status flips to false (`:55-69,82-87`). `SettingsPermissionCallout` (`SettingsView.swift:9155`) shows status + "Request" + "Open System Settings" buttons. `SystemTimerBridge` warns once (`didWarnAboutAccessibility`) and continues without AX. Without the tap, volume/brightness keys are not intercepted and Apple's HUD may stay hidden/suspended depending on state (INFERRED). |
| Manual action | System Settings > **Privacy & Security > Accessibility** > enable **Atoll** (use "+" and pick the app if it is not listed). Code opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` (`AccessibilityPermissionStore.swift:52-55`). Relaunch only if features stay inactive (INFERRED, the code retries on its own). |
| First launch (defaults) | **Yes** (HUD replacement default on) |

### 4.2 Screen & System Audio Recording

| | |
|---|---|
| Triggers | (a) Real-time waveform: `AudioTap` creates a Core Audio process tap + aggregate device (`audio/AudioTap.swift:248-303`; default **off**, `enableRealTimeWaveform`, `Constants.swift:1064`). (b) Per-app volume: `AppVolumeTap` (`audio/PerAppVolume/AppVolumeTap.swift:65-121`; default **off**, `Constants.swift:1341`). (c) Screen Assistant screenshot via `/usr/sbin/screencapture -c/-cw/-cs` (`ScreenshotSnippingTool.swift:100-133`; user-initiated). |
| Requested | No explicit TCC API call. Taps use `AudioHardwareCreateProcessTap` (macOS 14.2+) whose first use is expected to trigger the **system-audio recording** consent (usage string `NSAudioCaptureUsageDescription`) — INFERRED. `screencapture` consent attribution: UNKNOWN. |
| Denied/revoked | Tap creation errors are printed/stored as text only ("AudioHardwareCreateProcessTap failed (status)", `AppVolumeTap.swift:274-276`; `AudioTap.swift:256-259` just logs and returns). `ScreenshotSnippingTool` treats a non-zero exit as "failed" and ends snipping (`:111-118`). No in-app permission UI for this category (OBSERVED absence). |
| Manual action | System Settings > Privacy & Security > **Screen & System Audio Recording** (or "System Audio Recording Only" where macOS provides it) > enable Atoll. |
| First launch | No |

### 4.3 Camera

| | |
|---|---|
| Triggers | Mirror (`showMirror` default false, `Constants.swift:1022`), onboarding step "Enable Camera Access" (`components/Onboarding/OnboardingView.swift:56-77,152-154`) |
| Requested | `AVCaptureDevice.requestAccess(for: .video)` (`managers/WebcamManager.swift:129`; onboarding `:153`) |
| Denied/revoked | `WebcamManager.authorizationStatus` observed; denied shows an "Access Denied" state with a warning icon (`components/Webcam/WebcamView.swift:52-55,77-`; `models/DynamicIslandViewModel.swift:490-`). The camera-in-use privacy indicator uses CoreMediaIO property listeners (`managers/CameraMonitor.swift:25-110,226-300`) which do not need the permission (INFERRED). |
| Manual action | System Settings > Privacy & Security > **Camera** > enable Atoll. Entitlement `com.apple.security.device.camera` is present. |
| First launch | Only via the onboarding "Allow" button (shown when `coordinator.firstLaunch`, `DynamicIslandApp.swift:1094-1099`) |

### 4.4 Microphone

No capture code exists (see section 2). `NSMicrophoneUsageDescription` is present but **no prompt is expected** (INFERRED). `enableMicrophoneDetection` (default true, `Constants.swift:1484`) uses the CoreAudio `DeviceIsRunningSomewhere` property only (`MicrophoneMonitor.swift:68,188-205`). The hardened-runtime audio-input entitlement is absent, so capture would be blocked even if added.

### 4.5 Calendars and Reminders

| | |
|---|---|
| Triggers | Calendar preview, lock-screen reminder/calendar widget, reminder live activity |
| Requested | `EKEventStore.requestFullAccessToEvents()` and `…ToReminders()` (`Providers/CalendarServiceProviding.swift:57,59`) from: onboarding (`OnboardingView.swift:157` -> `requestAccess()` requests **both**, `CalendarServiceProviding.swift:36-43`), Settings > Calendar (`SettingsView.swift:3740-3741,4096-4097`), lock-screen weather widget (`components/LockScreen/LockScreenWeatherWidget.swift:516-517`). `CalendarManager.init` itself only reloads lists (`managers/CalendarManager.swift:63-71`). |
| Denied/revoked | `checkCalendarAuthorization/checkReminderAuthorization` only `NSLog` for denied/restricted/writeOnly (`CalendarManager.swift:170-171,177,194-195,201`). Settings > Calendar shows a red "Calendar or Reminder access is denied" message with **Request Access** and **Open System Settings** (`x-apple.systempreferences:…Privacy_Calendars`, `SettingsView.swift:3730-3752`). Calendar services return only calendars where `authorizationStatus == .fullAccess` (`CalendarServiceProviding.swift:66-70`), so "write-only" grants are treated as no access. |
| Manual action | System Settings > Privacy & Security > **Calendars** (Full Access) and > **Reminders** (Full Access) > enable Atoll. |
| First launch | Only via the onboarding step |

### 4.6 Bluetooth

| | |
|---|---|
| Triggers | Bluetooth device connect HUD, device battery levels, AirPods mode (`managers/BluetoothAudioManager.swift`), lock-screen Bluetooth gauge |
| Requested | `CBCentralManager(delegate:queue:)` constructed in `BluetoothLEBatteryReader.init` (`BluetoothAudioManager.swift:2309-2311`) — instantiated at app launch because `BluetoothAudioManager.shared` is a stored property of the app delegate (`DynamicIslandApp.swift:114`; `:44`). `IOBluetoothDevice.pairedDevices()` and IORegistry reads need no consent. |
| Denied/revoked | `centralManagerDidUpdateState`: `.unauthorized/.unsupported/.poweredOff` -> completes with empty results (`:2344-2355`); other battery sources (IORegistry/defaults/`system_profiler`) still run (`:584-607,1329-1345,1583`). No UI explanation (OBSERVED absence). |
| Manual action | System Settings > Privacy & Security > **Bluetooth** > enable Atoll. |
| First launch | **Yes** (INFERRED: constructing `CBCentralManager` triggers the prompt) |

### 4.7 Location Services

| | |
|---|---|
| Triggers | Lock-screen weather widget (default on) |
| Requested | `CLLocationManager.requestWhenInUseAuthorization()` (`managers/LockScreenWeatherManager.swift:1104-1109`) from `prepareLocationAccess()` at launch (`DynamicIslandApp.swift:1104-1107`), from the singleton's init (`LockScreenWeatherManager.swift:40`) and on lock (`:55`) |
| Denied/revoked | `currentLocation()` returns nil unless authorized (`:1111-1125`). With the provider "Open Meteo" a nil location triggers the **wttr.in IP-geolocation fallback** (`:609-613`) — i.e. denying Location does not stop the network request. No in-app "denied" message found (OBSERVED absence). |
| Manual action | System Settings > Privacy & Security > **Location Services** > turn Location Services on, then enable **Atoll**. |
| First launch | **Yes** |

### 4.8 Automation (Apple Events)

| Target | Feature | Where | Notes |
|---|---|---|---|
| **Music** (`com.apple.Music`) | Apple Music controller (default controller on macOS >= 15.4, `Constants.swift:1529-1534`), AirPlay device list (`managers/AppleMusicAirPlayManager.swift:98`), favourites | `MediaControllers/AppleMusicController.swift:337,400-443`; `helpers/AppleScriptHelper.swift:27-41` | prompt on first script |
| **Spotify** (`com.spotify.client`) | Spotify controller | `MediaControllers/SpotifyController.swift:344,380` | only if Spotify is the selected controller |
| **Notes** (`com.apple.Notes`) | Apple Notes sync (default off) | `managers/AppleNotesSyncManager.swift:213,312-352,404` | `-1743` handled `:409-412` |
| **System Events** (`com.apple.systemevents`) | "Log out" tile, stop screen recording via Cmd-Ctrl-Esc | `components/DynamicIslandSystemTiles.swift:55-75`, `managers/ScreenRecordingManager.swift:130-148` | **not** listed in the usage string or the temporary-exception list |
| (no target) `get volume settings` scripts | system volume/mute read | `managers/SystemVolumeManager.swift:26,35` via `helpers/AppleScriptRunner.swift:30` | StandardAdditions only; no Automation prompt expected (INFERRED) |

Requested: implicitly when `NSAppleScript.executeAndReturnError` first addresses an app. Denied/revoked: `AppleScriptHelper.execute` throws `AppleScriptError`; callers use `try?` and carry on (`AppleMusicController.swift:337`, `SpotifyController.swift:344`), so a denial looks like a silent "nothing happens"; only the Notes sync surfaces a message. Manual action: System Settings > Privacy & Security > **Automation** > expand **Atoll** > enable Music / Spotify / Notes / System Events as needed. First launch: Music prompt on macOS >= 15.4 as soon as the controller polls (INFERRED).

### 4.9 Full Disk Access

| | |
|---|---|
| Triggers | Focus/DND detail via `~/Library/DoNotDisturb/DB/{Assertions,ModeConfigurations}.json` (`managers/DoNotDisturbManager.swift:46,323,1413`); "power the Shelf" per the alert text; Settings callouts `SettingsView.swift:4469,4694`; possibly the wallpaper plist rewrite (UNKNOWN) |
| Requested | There is **no system request API for FDA**. `FullDiskAccessPermissionStore.requestAccessPrompt()` shows an `NSAlert` ("Full Disk Access Required … Dynamic Island needs…") then opens `Privacy_AllFiles` and reveals the app bundle in Finder (`helpers/FullDiskAccessPermissionStore.swift:121-137`), then polls 40x500 ms (`:153-172`). Detection = attempting to open `TCC.db` and `ModeConfigurations.json` for reading (`:23-47`). Menu: Permissions > Request Full Disk Access (`DynamicIslandApp.swift:1281-1288`). |
| Denied/revoked | `isAuthorized` stays false; Focus falls back to the notification/`log stream` path ("Use without DevTools"/"Use DevTools", `Constants.swift:728-742,1477`). The alert still uses the legacy app name "Dynamic Island" (`:126-127`). |
| Manual action | System Settings > Privacy & Security > **Full Disk Access** > "+" > select **Atoll.app** > enable; quit and reopen Atoll afterwards (INFERRED — macOS applies FDA to new launches). |
| First launch | No |

### 4.10 Files & Folders

| Folder | Why | Code |
|---|---|---|
| Documents | `~/Documents/ClipboardData`, `~/Documents/NoteImages` (`Constants.swift:950`), `~/Documents/ScreenAssistantScreenshots` (`ScreenAssistantManager.swift:141-149`) | implicit prompt on first write |
| Downloads | downloads indicator (`DownloadManager.swift:167-205`, default on) and Shelf probe | implicit; `ShelfFolderAccessPermissionStore.requestAccessPrompt()` lists both directories to provoke the prompts, polls 40x (`helpers/FullDiskAccessPermissionStore.swift:56-100,200-240`) |
| Desktop | usage string only (stale) | — |
| `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` | read+write on lock-screen artwork takeover (user tap) | `FullScreenArtworkWindowManager.swift:271-277,1581-1626`; TCC category UNKNOWN |
| `~/.claude`, `~/.codex`, `~/.config/codex`, `~/Library/Application Support/Cursor/…/state.vscdb` | LLM usage readers (off by default) | see FEATURE-MATRIX-B.md H; home dot-directories are not TCC-protected (INFERRED) |

Denied/revoked handling: `ShelfFolderAccessPermissionStore` publishes `hasDocumentsAccess/hasDownloadsAccess` and `SettingsPermissionCallout`s appear in Settings > Shelf (`SettingsView.swift:4449-4470`). Elsewhere failures are swallowed by `try?`. Manual action: Privacy & Security > **Files & Folders** > Atoll > Documents Folder / Downloads Folder (URL used by code: `Privacy_FilesAndFolders`, `FullDiskAccessPermissionStore.swift:211-225`).

### 4.11 Media & Apple Music (MusicKit)

| | |
|---|---|
| Triggers | Animated artwork when Apple Music plays and `lockScreenMusicFullscreenVideoArtwork` (default true) is on |
| Requested | `MusicAuthorization.request()` (`managers/AnimatedArtworkManager.swift:105-111`) via `MusicManager.fetchVideoArtwork()` (`managers/MusicManager.swift:1025,2209-2227`) — **at the first track change**, not at launch |
| Denied/revoked | returns nil -> no video artwork; a token failure back-off exists (`:62-66`, `recordTokenFailureIfNeeded`) |
| Manual action | Privacy & Security > **Media & Apple Music** > enable Atoll (needs an Apple Music-capable Apple ID; whether MusicKit works for a self-signed bundle ID is UNKNOWN) |

### 4.12 Notifications

**Not used.** No `UserNotifications`/`UNUserNotificationCenter`/`NSUserNotification` reference exists in the sources (grep), so there is nothing to grant and no notification permission is requested. All "HUD"-style alerts are in-app windows.

### 4.13 Login Items

| | |
|---|---|
| Trigger | Settings > General > "Launch at login" (`SettingsView.swift:1197`, `LaunchAtLogin.Toggle` from the `LaunchAtLogin-Modern` package, revision `a04ec1c3…`) |
| Requested | package-managed (INFERRED: `SMAppService.mainApp.register()`); macOS may post a "Background Items Added" notice; no entitlement needed |
| Denied/revoked | handled inside the package (UNKNOWN); no Atoll code observed |
| Manual action | Toggle in Atoll Settings, or System Settings > **General > Login Items & Extensions** > "Open at Login" / "Allow in the Background" > Atoll |
| First launch | No |

### 4.14 Input Monitoring (and global event monitors)

There is **no explicit Input Monitoring API call** (no `CGPreflightListenEventAccess`/`CGRequestListenEventAccess`/`IOHIDRequestAccess`; grep). However the app installs:

- an **active** (`.defaultTap`, `.headInsertEventTap`) `CGEvent` tap for system-defined (media-key) events, tried at several tap locations (`MediaKeyInterceptor.swift:199-212`, locations `[.cghidEventTap, .cgSessionEventTap]` at `:148`);
- global `NSEvent` monitors for `.flagsChanged` (Caps Lock indicator, `managers/CapsLockManager.swift:41-47`), `.leftMouseDown` (hover/click-outside, `ContentView.swift:2236,2281`) and `.systemDefined` (lock-screen power/Touch ID key, `managers/LockScreenManager.swift:168-190`).

INFERRED: macOS gates keyboard-class global monitors/taps behind **Accessibility** and/or **Input Monitoring**; the exact requirement per event class on the user's macOS version is UNKNOWN from the source. The code comments only mention Accessibility (`MediaKeyInterceptor.swift:157-164,215-218`). If a feature (Caps Lock indicator, lock-screen fingerprint animation) does not react, check **Privacy & Security > Input Monitoring** for Atoll (manual toggle) — this is a *possibility to verify at runtime*, not a documented requirement.

### 4.15 Developer Tools (Privacy_DevTools) — Focus "Use DevTools" mode

The menu has "Permissions > Open Developer Tools Settings" which opens `Privacy_DevTools` (`DynamicIslandApp.swift:1194-1204,1290-1300`) and the onboarding asks to choose Focus detection mode "Use DevTools" / "Use without DevTools" (`OnboardingView.swift:129-146`; default `withoutDevTools`, `Constants.swift:1477`). In DevTools mode Atoll runs `/usr/bin/log stream/show` filtered to `duetexpertd` (`DoNotDisturbManager.swift:525-556,1132-1148`). The rationale for the Developer-Tools grant is not stated in code (UNKNOWN; INFERRED that reading unredacted private log fields works only with that grant). Manual action: Privacy & Security > **Developer Tools** > enable Atoll.

### 4.16 Local Network

LocalSend discovery uses UDP multicast `224.0.0.167:53317`, an `NWListener` and HTTPS probes (`LocalSendService.swift:60-61,95-110,362-367,627-654`). **No `NSLocalNetworkUsageDescription`** is present (OBSERVED absence). macOS may prompt "Atoll would like to find and connect to devices on your local network" without Atoll's explanation, or silently block; UNKNOWN. Manual action: Privacy & Security > **Local Network** > enable Atoll. Triggered only when the LocalSend picker/share UI is opened (`FileShareView.swift:56`, `LocalSendDevicePickerWindowManager.swift:231`).

### 4.17 Keychain access (not TCC, but user-visible prompts)

| Reader | Items touched | Prompt behaviour |
|---|---|---|
| LLM Usage (off by default) | enumerates attributes of **all** generic-password items (`managers/LLMUsage/Quota/KeychainReader.swift:30-37`); reads `Claude Code-credentials*` via `/usr/bin/security … -w` (`:64-67`); reads `Codex Auth`, `cursor-access-token` via `SecItemCopyMatching` (`:6-18`, `CursorTokenStore.swift:6`); Antigravity item `gemini`/`antigravity` via `security` (`AntigravityUsageProvider.swift:77-79`) | macOS keychain "wants to use … in your keychain" dialogs naming `security` or Atoll; choosing "Always Allow" grants a persistent ACL |
| Writes to another app's item | `security -i add-generic-password -U` on Claude Code's credential item (`KeychainReader.swift:87-109`) | can alter Claude Code's keychain ACL partition (the code tries to preserve it, comment `:55-58`) |
| Atoll's own items | `com.Ebullioscopic.Atoll.new-api`, `…SpotifyLibrary`, `…Cider` | normal prompts only on rebuilt/re-signed binaries |

Manual action: respond in the dialog, or manage in **Keychain Access.app**. Never run `scripts/test_claude_keychain.sh` / `tests/test_claude_keychain.swift` (they read the Keychain).

### 4.18 Other privileges and behaviours that are not TCC prompts

| Item | Evidence | Note |
|---|---|---|
| Process signalling of system daemons: `killall -STOP/-CONT/-9 OSDUIHelper`, `launchctl kickstart gui/<uid>/com.apple.OSDUIHelper`, `launchctl load -w …com.apple.OSDUIHelper.plist` | `managers/SystemOSDManager.swift:100-160,214-260,493-530`; `helpers/SystemHUDDebugger.swift:66-80` | same-user processes; works because the app is unsandboxed |
| `SIGSTOP/SIGCONT` of `WallpaperAgent`, `WallpaperAerialsExtension`, `WallpaperVideoExtension`, `wallpaperexportd` + `killall WallpaperAgent` | `managers/FullScreenArtworkWindowManager.swift:452-512,1749-1752` | only after user taps lock-screen artwork |
| Private frameworks loaded: SkyLight (via SkyLightWindow), `CGS*` Spaces, MediaRemote, IOReport, CoreBrightness, DisplayServices | see FEATURE-MATRIX-B.md F0 | no TCC; can break on macOS updates |
| Reading other apps' preferences: `fyi.lunar.Lunar` API key (`managers/LunarManager.swift:62-63`), `com.apple.mobiletimerd.plist`, Cursor `state.vscdb` | | no TCC for same-user preference files |
| Subprocesses used: `/usr/bin/perl` (MediaRemote adapter), `/usr/bin/log`, `/usr/bin/security`, `/bin/ps`, `/usr/sbin/lsof`, `/usr/sbin/ioreg`, `/usr/sbin/system_profiler`, `/usr/bin/pmset`, `/usr/sbin/networksetup`, `/usr/bin/pgrep`, `/usr/bin/killall`, `/bin/launchctl`, `/usr/sbin/arp`, `/usr/sbin/screencapture`, `/usr/bin/zip`, `/usr/libexec/corebrightnessdiag` | e.g. `LocalSendService.swift:389-390`, `StatsManager.swift:1455`, `SystemDisplayManager.swift:62-63` | helper tools may carry their own TCC/entitlement requirements (UNKNOWN) |

## 5. Quick map: what a default first launch will ask for (INFERRED from defaults + code, not run)

1. Onboarding (shown once, `DynamicIslandApp.swift:1094-1099`): **Camera**, **Calendars + Reminders**; then music-controller choice and profile choice.
2. At launch regardless of onboarding: **Bluetooth** (CBCentralManager), **Location** (weather), **Accessibility** prompt (media-key tap), possible **Downloads Folder** prompt (downloads watcher), and — on macOS >= 15.4 with Apple Music as the controller — **Automation > Music** and later **Media & Apple Music**.
3. Optional/on use: Full Disk Access (Focus details), Automation > Spotify/Notes/System Events, Screen & System Audio Recording (waveform, per-app volume, screenshots), Local Network (LocalSend), Developer Tools (Focus DevTools mode), Keychain prompts (LLM usage), Login Items (launch at login).

## 6. Revocation behaviour summary

| Permission | What the code does when it disappears at runtime |
|---|---|
| Accessibility | event tap disabled -> retry loop and status polling; features degrade silently; Settings callouts show state |
| Camera | status becomes denied -> Mirror view shows "Access Denied" |
| Calendar/Reminders | lists/events come back empty (service filters on `.fullAccess`); Settings shows the red banner |
| Bluetooth | LE battery reads return empty; other battery sources continue |
| Location | weather uses wttr.in IP fallback (see 4.7) |
| Automation | AppleScript errors swallowed (`try?`); controllers appear idle; Notes sync reports `-1743` |
| Full Disk Access | `isAuthorized` false; Focus detection uses the non-FDA path |
| Files & Folders | callouts in Shelf settings; elsewhere silent failures |
| Screen/System audio | errors logged only |
| Notifications / Microphone | not applicable (unused) |
