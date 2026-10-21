# Atoll v2.3.3 — Free / local-first operation audit

Repo: `<repo>`, branch `local-build`, commit `f039ca9`. Source root `Toplet/` unless a path starts with `../` or is a repo-root folder.
**Nothing was built or run.** Tags: **OBSERVED (file:line)**, **INFERRED**, **UNKNOWN**. No capability below is claimed to "work".
**No patch in this document has been applied.** Section 7 only *proposes* changes.

## 0. Category definitions used

| Cat | Meaning |
|---|---|
| **A** | Fully local. No network, no account, no private/version-fragile API (public macOS APIs only). |
| **B** | Optional free online. Works without an account/key/payment but contacts a public server (GitHub, Open-Meteo, Apple iTunes Search, LRCLIB…). |
| **C** | User-controlled third-party service: needs the user's own account/API key/other app, or reads another tool's credentials. Includes loopback links to a third-party app the user runs. |
| **D** | Platform-dependent: private/undocumented APIs, sensors, lock screen, process signalling, or behaviour that is tied to specific macOS versions. Can break on any OS update. A capability can be tagged `A+D` etc. when it has both a local part and a fragile part. |

## 1. Headline findings

1. **No payment, licence check, subscription gate, trial, paywall, activation, StoreKit or licensing SDK exists in the code** (searched; details in section 2). Everything is unlocked. "PRO" strings are dead UI behind `if false`. Donation links only.
2. **No telemetry/analytics/crash-reporting SDK exists** (section 3). The app never sends usage data to the maintainers. It does, however, make many *functional* network calls to third parties (section 4).
3. **Default-on network behaviour on a fresh install** (settings left untouched): Sparkle updater is started at launch; Lock-screen weather (Open-Meteo, and wttr.in as a fallback) with a Location prompt at launch; explicit-content lookups to Apple iTunes Search / Spotify embed for every track played; Apple-Music album art via iTunes Search; Apple Music "animated artwork" via MusicKit (needs Music authorization). See section 5.
4. **Default-on local system modification:** the default HUD replacement `SIGSTOP`s Apple's `OSDUIHelper` and installs an active CGEvent tap (Accessibility); the lock-screen windows use private SkyLight; the optional fullscreen-artwork action rewrites the user's wallpaper plist. See section 6 (category D).
5. **High-risk optional feature:** the LLM Usage Monitor reads other tools' OAuth tokens/keychain items, can refresh and overwrite Claude Code's stored credentials, and scrapes process command lines (off by default; section 4 and FEATURE-MATRIX-B.md section H).
6. **Local-security finding:** the extension RPC/XPC servers start unconditionally and auto-authorize any first caller, including access to Shelf file contents (FEATURE-MATRIX-B.md section J).

## 2. Payment / licence / subscription / trial audit

Method (reproducible): case-insensitive grep over `*.swift`, `*.plist`, `*.m`, `*.json`, `*.xml`, `*.md`, workflows and scripts for: `licen[cs]e` (excluding GPL headers), `purchase`, `subscri(be|ption)`, `paywall`, `trial`, `storekit`, `gumroad`, `lemonsqueezy`, `paddle`, `revenuecat`, `isPro`, `premium`, `donat`, `sponsor`, `buymeacoffee`, `activation`; plus an import census (`StoreKit`, `PassKit`, no hits; the app's imports are listed by `grep ^import`).

| Hit | Meaning (OBSERVED) |
|---|---|
| `strings/constants.swift:21-22` `productPage`, `sponsorPage = https://www.buymeacoffee.com/kryoscopic` | donation link only; opened in the browser on click (`components/Notch/DynamicIslandExtrasMenu.swift:64-68` "Love Us", `components/Settings/SettingsView.swift:4170-4185` About > Donate) |
| `components/Onboarding/ProOnboarding.swift:22` `struct ProOnboard` | **never instantiated** anywhere (grep). Contains `if false { Text("PRO") … }` (`:49-63`) and a "Buy us a coffee" button to a LinkedIn URL (`:60`) |
| `components/Onboarding/WelcomeView.swift:51-64` | same dead `if false { Text("PRO") … }` badge |
| `.github/FUNDING.yml`, `ReadMe.md:24-30,162` | GitHub Sponsors / Buy-Me-A-Coffee badges |
| `isSubscribed` (`models/CalendarModel.swift:30`, `Providers/CalendarServiceProviding.swift:153`) | EventKit "subscribed calendar" flag, unrelated to payments |
| `ClaudeUsageProvider.swift:32`, `UsageProvider.swift:65`, `NotchLLMUsageView.swift:58` | displays the *user's Claude plan label* (e.g. "Max 5x") read from `~/.claude.json`; not an Atoll entitlement |
| `AppleMusicController.swift:409-410` | comment about favouriting working "whether or not the user subscribes" |

Result: **no licence file, no activation call, no receipt validation, no trial timer, no feature flag tied to payment or account**. Atoll itself requires **no account of any kind**. (Some *features* require the user's accounts at *other* services — section 4 category C.) Distribution is GPL-3.0 (`../LICENSE`, `../NOTICE`).

## 3. Telemetry audit

- Searched for analytics/crash SDK names and strings (`analytics|telemetry|crashlytics|sentry|mixpanel|amplitude|posthog|firebase|bugsnag|appcenter|plausible|countly|telemetrydeck|aptabase`) in sources, plists, the pbxproj and `Package.resolved`: **no hits** other than the unrelated word "segment"/"segmented". `Package.resolved` lists no analytics package (packages: AtollExtensionKit, Defaults, KeyboardShortcuts, LaunchAtLogin-Modern, lottie-spm, LottieUI, MacroVisionKit, open-meteo, Pow, SkyLightWindow, Sparkle, swift-argument-parser, swift-collections, swift-syntax, SwiftTerm, swiftui-introspect).
- Sparkle: Sparkle can send an anonymous "system profile" with update checks only if `SUEnableSystemProfiling` is set; `Info.plist` does not set it (OBSERVED absence; `Info.plist:1-29`). The update request itself reveals IP + app version to GitHub (INFERRED).
- Logging: `Logger`/`os_log`/`print` write locally. "Export Logs & Crash Reports" is a user-initiated save panel that zips `log show` output and `Atoll` crash reports to a user-chosen file (`DynamicIslandApp.swift:1315-1380`). It **does not upload** anything (OBSERVED).
- No device identifier, install ID or beacon was found. (INFERRED from the absence of any POST of local data to a maintainer-controlled host: all outbound hosts are listed in section 4.)
- Maintainer-controlled hosts the app *fetches from*: `raw.githubusercontent.com/Ebullioscopic/Atoll/{main,dev}/…` (appcasts, pricing), `github.com/Ebullioscopic/Atoll/releases/…` (DMG). A GitHub request exposes the client IP to GitHub (INFERRED).

## 4. Network endpoint inventory

Gathered by grepping `https?://|wss?://`, `URLSession|URLRequest|NWConnection|NWListener|WKWebView|Data(contentsOf:)|.download(` over all Swift/ObjC sources, plus Info.plist/appcast. "Default" = state with no settings changed. Account = needs a login/API key/payment.

### 4.1 Outbound internet

| # | Endpoint | File:line | Purpose | On by default? | Account/key/payment | Offline behaviour |
|---|---|---|---|---|---|---|
| N1 | `https://raw.githubusercontent.com/Ebullioscopic/Atoll/main/Updates/appcast.xml` (+`appcast-beta/-alpha/-nightly.xml`) | `Info.plist:21`; `models/UpdateChannel.swift:51-62`; `services/AtollUpdaterDelegate.swift:25-27` | Sparkle update feed | Updater **starts at every launch** (`DynamicIslandApp.swift:42-45`). Automatic checking: INFERRED to require the user's consent on the second launch because `SUEnableAutomaticChecks` is absent from `Info.plist` (Sparkle default behaviour; unverified). Manual "Check for Updates…" always available (`DynamicIslandApp.swift:55`). | none | check fails; app unaffected (UI wording UNKNOWN) |
| N2 | `https://github.com/Ebullioscopic/Atoll/releases/download/v<ver>/Atoll-<ver>.dmg` | `Updates/appcast.xml:11,19,27,35…` (enclosure URLs) | Sparkle update payload (EdDSA-verified against `SUPublicEDKey`, `Info.plist:22-23`) | only after the user accepts an update (or if "Automatically download updates" is enabled by the user) | none | n/a |
| N3 | `https://api.open-meteo.com/v1/forecast` | `managers/LockScreenWeatherManager.swift:712` | lock-screen weather (lat/lon rounded to 4 dp) | **YES** — `enableLockScreenWeatherWidget` default true (`models/Constants.swift:1095`); fetched at launch (`DynamicIslandApp.swift:1104-1108`) and on lock | none (no API key) | falls back to a battery-only snapshot (INFERRED from the catch branch `:~125-160`) |
| N4 | `https://air-quality-api.open-meteo.com/v1/air-quality` | `:798` | AQI row | YES (AQI toggle `lockScreenWeatherShowsAQI` default true, `Constants.swift:1105`) | none | row omitted |
| N5 | `https://wttr.in/<lat,lon>?format=j1&aqi=yes` and `https://wttr.in/?format=j1&aqi=yes` | `:626` | alternative weather provider **and automatic fallback when Open-Meteo is selected but no location is available** (`:609-613`) | **Conditionally default**: used when Location is denied/unavailable even though the provider is Open-Meteo (sends client IP for server-side geolocation) | none | falls back as N3 |
| N6 | `https://itunes.apple.com/search?term=<title artist>&media=music&entity=song&limit=15` | `managers/MusicManager.swift:233` (`MusicExplicitnessResolver`, called via `refreshGenericExplicitFlag` `:1279-1320`, from `:1028,1036`) | "Explicit" (E) badge for the playing track | **YES, no setting** gates it: runs whenever now-playing metadata lacks an explicit flag | none | no badge |
| N7 | `https://open.spotify.com/embed/track/<id>` | `MusicManager.swift:389`; `MediaControllers/SpotifyController.swift:520` | Spotify explicit-flag lookup | YES when the source is Spotify (`MusicManager.swift:1232-1245`) | none | falls back to N6 |
| N8 | `https://itunes.apple.com/search?term=<title artist>&media=music&entity=song&limit=10` then image fetch from the returned `artworkUrl100` host (replaced to 600x600) | `MediaControllers/AppleMusicController.swift:37-50,58-100` | album art for the Apple Music controller | YES when controller = Apple Music, which is the **default controller on macOS >= 15.4** (`Constants.swift:1529-1534`) | none | no artwork (returns nil on any error) |
| N9 | MusicKit catalog search + `https://api.music.apple.com/v1/catalog/<storefront>/songs/<id>?extend=editorialVideo` and HLS `https://mvod.itunes.apple.com/….m3u8` | `managers/AnimatedArtworkManager.swift:23-110,155-200` | animated (motion) album art on the lock-screen fullscreen artwork | YES when Apple Music plays: `lockScreenMusicFullscreenVideoArtwork` default true (`Constants.swift:1147`), triggered by `MusicManager.swift:1025,2209-2227`; needs **MusicKit authorization** (`NSAppleMusicUsageDescription`, `Info.plist:10-11`) | Apple ID with Apple Music access presumably; MusicKit developer-token provisioning for a locally signed build is UNKNOWN (code has a back-off for token failures `:62-66`) | nothing shown |
| N10 | `https://lrclib.net/api/search?track_name=&artist_name=` | `MusicManager.swift:1912` | synced lyrics | **No** — `enableLyrics` default false (`Constants.swift:1506`) | none | no lyrics |
| N11 | `https://music.163.com/api/search/get/web`, `https://music.163.com/api/song/lyric` | `managers/NetEaseLyrics.swift:95,103` | lyrics fallback after LRCLIB miss (`MusicManager.swift:1869`) | No (needs `enableLyrics`) | none | no lyrics |
| N12 | `https://open.spotify.com/api/token` with cookie `sp_dc` + TOTP; `https://raw.githubusercontent.com/xyloflake/spot-secrets-go/main/secrets/secretDict.json` (third-party-maintained TOTP secrets) | `managers/SpotifyAuthManager.swift:36-37,152-175` | impersonates the Spotify **web player** to fetch tokens for Canvas video | No — only after the user pastes an `sp_dc` cookie (`Constants.swift:1244`) | the user's Spotify cookie (stored in plaintext Defaults) | Canvas absent |
| N13 | `https://spclient.wg.spotify.com/canvaz-cache/v0/canvases`, `https://api.spotify.com/v1/tracks/<id>` | `SpotifyController.swift:621,476` | Spotify Canvas video / track metadata | No (needs N12 token) | Spotify web-player token | absent |
| N14 | `https://accounts.spotify.com/authorize`, `https://accounts.spotify.com/api/token`, `https://api.spotify.com/v1/…` | `managers/Spotify/SpotifyOAuthService.swift:39-40,80-120`; `SpotifyLibraryAPI.swift:27` | like/unlike library (PKCE, scopes `user-library-read/modify`) | No — needs the user's own Spotify developer Client ID (`spotifyLibraryClientID`) | Spotify developer app | feature unavailable |
| N15 | `https://accounts.spotify.com/en/login` (embedded `WKWebView`), `https://open.spotify.com/` | `components/Settings/SpotifyLoginSheet.swift:25-36,102-257` | cookie capture helper UI | only when the user opens the sheet | Spotify login | n/a |
| N16 | `https://generativelanguage.googleapis.com/v1beta/models/<id>:generateContent?key=<API KEY>` | `managers/ScreenAssistantManager.swift:418` | Screen Assistant (Gemini) — API key in the URL query | only when the user chats with a Gemini key configured (`:405-415`) | user's Gemini API key | error message in chat |
| N17 | `https://api.openai.com/v1/chat/completions` | `:441` | Screen Assistant (OpenAI) | as N16 | user's key | error |
| N18 | `https://api.groq.com/openai/v1/chat/completions` | `:470` | Screen Assistant (Groq) | as N16 | user's key | error |
| N19 | `https://api.anthropic.com/v1/messages` | `:498` | Screen Assistant (Claude) | as N16 | user's key | error |
| N20 | `https://api.anthropic.com/api/oauth/usage` | `managers/LLMUsage/Quota/ClaudeQuotaClient.swift:135` | Claude usage limits (uses Claude Code's OAuth token, spoofed UA `claude-code/2.1.69`) | No — requires `enableLLMUsageFeature` (default false, `Constants.swift:1283`); then the Claude provider is default on | the user's Claude Code login | limits absent |
| N21 | `https://platform.claude.com/v1/oauth/token` | `ClaudeQuotaClient.swift:231` | **refreshes Claude Code's OAuth token and writes it back** (`:189-204`) | as N20, only when the stored token is expired | same | n/a |
| N22 | `https://chatgpt.com/backend-api/wham/usage` | `Quota/CodexQuotaClient.swift:39` | Codex limits | as N20 (Codex provider default on) | Codex/ChatGPT login | absent |
| N23 | `https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`, `https://cursor.com/api/usage-summary` | `Quota/CursorQuotaClient.swift:31,41` | Cursor limits | as N20 (Cursor provider default on) | Cursor login | absent |
| N24 | `https://cloudcode-pa.googleapis.com`, `https://daily-cloudcode-pa.googleapis.com` (`/v1internal:retrieveUserQuotaSummary`, `:fetchAvailableModels`) | `managers/LLMUsage/AntigravityUsageProvider.swift:612-668` | Antigravity quota (fallback when the local language server isn't found) | as N20 | Google token in keychain item `gemini`/`antigravity` | absent |
| N25 | user-supplied `<base>/api/user/self`, `/api/log/self/stat` | `managers/LLMUsage/NewAPIUsage.swift:162-262` | "New API" gateway balances | No (`enableNewAPIProvider` false) | user's gateway + key | error row |
| N26 | `https://raw.githubusercontent.com/Ebullioscopic/Atoll/dev/DynamicIsland/managers/LLMUsage/pricing.json` | `managers/LLMUsage/ModelPricingManager.swift:98,132-147` | model price table refresh | only once the LLM usage cost path runs (singleton first touched from `ModelPricing.cost`, INFERRED from call graph) | none | bundled copy used |
| N27 | `https://assets9.lottiefiles.com/packages/lf20_mniampqn.json` | `components/Music/LottieAnimationView.swift:29`, used at `ContentView.swift:1801` | default music-visualizer Lottie when `useMusicVisualizer` is off and no custom visualizer is selected | No (default `useMusicVisualizer` true, `Constants.swift:1044`; the remote JSON is only reached on the `else` branch, `ContentView.swift:1777-1802`) | none | blank visualizer |
| N28 | user-entered Lottie JSON URLs | `components/Settings/IdleAnimationsSettingsSection.swift:471`; `components/Music/LottieAnimationView.swift:33-37` (custom visualizer URL) | custom idle animation / visualizer | No | none | broken animation |
| N29 | arbitrary http/https image URLs supplied by media apps (cover art) | `managers/ImageService.swift:62-67` (rejects non-http(s)) | artwork download for Spotify/YouTube Music/etc. | YES when those controllers report an artwork URL | none | placeholder art |
| N30 | `URLSession.shared.download(from: <video url>)` | `managers/FullScreenArtworkWindowManager.swift:1080` | caches a canvas/aerial video for the wallpaper takeover | only on user tap of lock-screen artwork | none | not shown |
| N31 | `https://ebullioscopic.github.io/Toplet/privacy-policy`, `https://github.com/Ebullioscopic/DynamicIsland`, `https://www.buymeacoffee.com/kryoscopic`, `https://getatoll.app/marketplace`, `https://github.com/th-ch/youtube-music`, `https://developer.spotify.com/dashboard`, `https://aistudio.google.com/app/apikey`, `https://betterdisplay.pro`, `https://lunar.fyi`, `https://github.com/Paxsenix0/Spotify-Canvas-API`, LinkedIn profile | `components/Onboarding/WelcomeView.swift:79`, `OnboardingFinishView.swift:65`, `strings/constants.swift:21-22`, `ExtensionsSettings.swift:72`, `SettingsView.swift:3235,2498,2506,8714`, etc. | links opened in the default browser **on user click only** | n/a | none | n/a |
| N32 | Build time: SwiftPM resolves 16 packages from GitHub (`Package.resolved`) | `../Toplet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | needed to compile; includes `open-meteo/open-meteo` 1.4.16 which appears unused (not linked, FEATURE-MATRIX-B.md section K) | build only | none | build cannot proceed offline unless the package cache is warm |

### 4.2 Loopback / LAN endpoints (no internet)

| # | Endpoint | File:line | Purpose | Default | Notes |
|---|---|---|---|---|---|
| L1 | inbound WebSocket `127.0.0.1:9020` and `[::1]:9020` | `services/Extensions/ExtensionRPCServer.swift:50,70-92`; started `DynamicIslandApp.swift:709-710` | extension JSON-RPC | **listening from launch regardless of settings** | auto-authorizes first caller; see FEATURE-MATRIX-B.md J |
| L2 | XPC mach service `com.ebullioscopic.Atoll.xpc` | `ExtensionXPCServiceHost.swift:25-26,38-58`; entitlement `Toplet.entitlements:9-12` | extension XPC | listening from launch | no client signature requirement |
| L3 | outbound `http://localhost:26538` (+WebSocket upgrade) | `MediaControllers/YouTube Music Controller/YouTubeMusicModels.swift:33`, `YouTubeMusicNetworking.swift` | YouTube Music desktop (th-ch) API server, token auth | only when controller = YouTube Music | requires that third-party app |
| L4 | outbound `http://localhost:<port>/api/v1/playback` | `MediaControllers/CiderController.swift:97` | Cider API | only when controller = Cider | token in Keychain |
| L5 | outbound `http://localhost:11434` (editable) + `/api/chat` | `Constants.swift:1378`; `ScreenAssistantManager.swift:517` | local LLM (Ollama) | only when "Local Model" chosen | — |
| L6 | outbound TCP `localhost:23803` | `managers/LunarManager.swift:158-163` | Lunar display-control app | only when third-party DDC integration is on with provider Lunar (`Constants.swift:1443`, default off) | also **reads Lunar's API key from its UserDefaults suite** `fyi.lunar.Lunar` (`:62-63`) |
| L7 | outbound `127.0.0.1:<dynamic port>` (http/https) | `AntigravityUsageProvider.swift:186-195,356-372` | Antigravity language-server RPC | only with LLM usage + Antigravity provider | port and CSRF token come from `ps` output |
| L8 | UDP multicast `224.0.0.167:53317` + HTTPS/HTTP listener & probes on port 53317 | `components/Shelf/Services/LocalSendService.swift:60-61,95-139,362-367,627-654` | LocalSend LAN file transfer | on demand (when a share/LocalSend UI or picker opens, `FileShareView.swift:56`, `LocalSendDevicePickerWindowManager.swift:231`) | TLS delegate accepts any certificate (`:1058-1063`); no `NSLocalNetworkUsageDescription` key exists |
| L9 | `NWPathMonitor` + CoreWLAN SSID + `/usr/sbin/networksetup` | `managers/NetworkConnectivityManager.swift:43-100,245-290` | Wi-Fi/connectivity HUD | **on at launch** (`DynamicIslandApp.swift:773`) | local only |

### 4.3 App Transport Security

`Info.plist:5-9` sets `NSAppTransportSecurity > NSAllowsArbitraryLoads = true` (OBSERVED): the app may speak plain HTTP to any host. It is needed for L3-L6 style localhost HTTP and for user-typed New API URLs, but it also removes the platform's cleartext protection for every request. Proposal P7.

## 5. What a pristine, untouched install does on the network and to the system (defaults)

| Behaviour | Evidence | Needs |
|---|---|---|
| Starts Sparkle (feed from GitHub) | `DynamicIslandApp.swift:42-45` | internet only when checking |
| Asks for Location, fetches weather (Open-Meteo, else wttr.in) | `DynamicIslandApp.swift:1104-1108`; `Constants.swift:1095` | internet + Location |
| Creates `CBCentralManager` -> Bluetooth prompt at launch | `DynamicIslandApp.swift:114`; `BluetoothAudioManager.swift:44,2310` (INFERRED prompt) | Bluetooth |
| Starts media-key CGEvent tap -> Accessibility prompt, `SIGSTOP`s `OSDUIHelper` | `MediaKeyInterceptor.swift:164-217,464-470`; `SystemHUDManager.swift:326`; `SystemOSDManager.swift:214-226`; `Constants.swift:1400` | Accessibility |
| Watches `~/Downloads` | `DownloadManager.swift:167-205`; `Constants.swift:1199` | Downloads folder TCC (INFERRED) |
| Polls the pasteboard every 0.5 s and records history (3 items) to the prefs plist, images to `~/Documents/ClipboardData` | `ClipboardManager.swift:374-381,756-778`; `Constants.swift:1359-1364` | none |
| Monitors Focus/DND (log stream + `~/Library/DoNotDisturb/DB`), screen-recording (pgrep), camera/mic usage (CMIO/CoreAudio), caps lock, network | `DynamicIslandApp.swift:758-776`; `Constants.swift:1468,1476,1483,1492` | FDA (optional), none |
| macOS 15.4+: Apple Music controller via AppleScript, artwork + explicit lookups over the internet; MusicKit animated art | `Constants.swift:1529-1534`; N6, N8, N9 | Automation (Music), Apple Music authorization |
| Opens RPC WebSocket on 127.0.0.1:9020 and XPC mach service | `DynamicIslandApp.swift:709-710` | none |
| Mirrors the macOS Clock timer via `log stream` | `Constants.swift:1328`; `SystemTimerBridge.swift:154-170` | Accessibility (for AX part) |
| Onboarding requests Camera + Calendar + Reminders | `OnboardingView.swift:152-158` | user clicks Allow |

## 6. Capability classification (EVERY capability)

`Net` references section 4 IDs. "Default" is on/off for the stock settings.

| # | Capability | Cat | Default | Net | Basis / notes |
|---|---|---|---|---|---|
| 1 | Notch/Dynamic-Island window, hover, gestures, sizing, shadows, multi-display | A | on | — | AppKit/SwiftUI; uses private `CGSSpace` for the notch space (`private/CGSSpace.swift`, `managers/NotchSpaceManager.swift:27-32`) -> **A+D** (level 2147483647 Space) |
| 2 | Menubar icon, Settings window, onboarding, tips (TipKit), haptics, launch-at-login | A | on | N31 on click | `LaunchAtLogin` package |
| 3 | Minimalistic UI, appearance (accent, glass, icons), custom app icon | A | off/on | — | local |
| 4 | Idle animations (local Lottie files) | A | off | N28 if URL | |
| 5 | Music: Now-Playing via MediaRemote adapter (macOS < 15.4 default; Amazon Music uses it too) | **D** | on < 15.4 | — | private `MediaRemote.framework` loaded (`NowPlayingController.swift:70`) and a prebuilt unauditable binary driven by `/usr/bin/perl` (`:259-305`) |
| 6 | Music: Apple Music controller (AppleScript + distributed notifications) | A (control) / **B** (art, explicit, animated art) | on >= 15.4 | N6,N8,N9 | `Constants.swift:1529-1534` |
| 7 | Music: Spotify controller (AppleScript + notifications) | A (control) / B (explicit N7) | off | N7 | |
| 8 | Spotify Canvas via `sp_dc` cookie | **C** (and ToS-grey) | off | N12,N13,N15 | cookie in plaintext Defaults |
| 9 | Spotify library like/unlike (PKCE OAuth) | **C** | off | N14 | user's Client ID |
| 10 | YouTube Music controller | **C** (loopback to user-run server) | off | L3 | |
| 11 | Cider controller | **C** (loopback) | off | L4 | |
| 12 | Tidal controller | **D** (Accessibility UI scraping: `TidalController.swift:168`) | off | — | |
| 13 | Lyrics (LRCLIB, NetEase) | **B** | off | N10,N11 | sends title/artist/album |
| 14 | Explicit badge lookups | **B** | **on, no switch** | N6,N7 | proposal P3 |
| 15 | Animated artwork (MusicKit) | **B/C** (Apple Music account) | on | N9 | proposal P4 |
| 16 | Real-time waveform (Core Audio process tap, macOS 14.2+) | **A+D** | off | — | `audio/AudioTap.swift:248-303`; system-audio TCC |
| 17 | Per-app volume (Core Audio process taps) | **A+D** | off | — | `audio/PerAppVolume/*`; `enablePerAppVolume` false |
| 18 | Music visualizer (local spectrum) | A | on | N27 only on a rare branch | |
| 19 | Lock-screen widgets (music, timer, weather+battery, reminder/calendar, focus, lock icon, extension widgets) | **D** | on | N3-N5 for weather | private SkyLight (`SkyLightOperator`); see FEATURE-MATRIX-B.md F |
| 20 | Fullscreen artwork wallpaper takeover | **D** | on (user taps) | N9,N30 | rewrites `…/com.apple.wallpaper/Store/Index.plist`, `SIGSTOP` wallpaper daemons |
| 21 | Lock-screen weather | **B + D** | **on** | N3-N5 | free, key-less |
| 22 | System HUD replacement (volume/brightness/keyboard backlight; inline/vertical/circular/custom OSD) | **D** | on | — | active CGEvent tap + `OSDUIHelper` `SIGSTOP`/`killall -9` + `launchctl kickstart` (`SystemOSDManager.swift:100-135`), CoreBrightness/DisplayServices private (`KeyboardBrightnessSensor.swift:153-175`, `SystemMediaControllers.swift:663-690,922`, `/usr/libexec/corebrightnessdiag` `SystemDisplayManager.swift:62-63`) |
| 23 | External-display DDC via BetterDisplay / Lunar | **C** | off | L6 | reads Lunar's stored API key |
| 24 | Battery/charging HUD & indicator | A | on | — | public IOKit power sources |
| 25 | Bluetooth device HUD + battery + AirPods listening mode | **D** | on | — | IORegistry, private selectors, `log stream`, CoreBluetooth (see FEATURE-MATRIX-B.md F1) |
| 26 | Focus/DND indicator | **D** | on | — | undocumented notifications, `log stream duetexpertd`, `~/Library/DoNotDisturb` JSON (FDA) |
| 27 | Screen-recording indicator | A+D | on | — | `pgrep screencapture` (`ScreenRecordingManager.swift:314-330`); stop button sends Cmd-Ctrl-Esc via System Events (Automation + Accessibility) |
| 28 | Camera / microphone privacy indicators | A | on | — | CMIO/CoreAudio property listeners (public) |
| 29 | Caps-lock indicator | A | on | — | global `.flagsChanged` monitor |
| 30 | Network/Wi-Fi HUD | A | on | — | CoreWLAN, `networksetup` |
| 31 | Downloads indicator | A | on | — | folder watch |
| 32 | Keep Awake (caffeinate) | A | on | — | IOPM assertion |
| 33 | Timers (in-app) | A | on | — | |
| 34 | Mirror system Clock timer | **D** | on | — | `log stream` private subsystem, plist, AX |
| 35 | Calendar + Reminders preview, lock-screen reminders | A | on | — | EventKit |
| 36 | Third-party calendar app hand-off (Fantastical) | C | off | — | |
| 37 | Clipboard history | A | on | — | privacy caveats in FEATURE-MATRIX-B.md E1 |
| 38 | Colour picker | A | on | — | `NSColorSampler` |
| 39 | File Shelf, drag-out, image background removal (Vision) | A | on | — | |
| 40 | AirDrop quick share | A | on | — | `NSSharingService` |
| 41 | LocalSend LAN transfer | A (LAN only) | on demand | L8 | local-network prompt string missing |
| 42 | Keyboard shortcuts | A | on | — | |
| 43 | Terminal (SwiftTerm) | A | off | — | spawns user shell |
| 44 | Notes | A | off | — | plaintext Defaults |
| 45 | Apple Notes sync | A | off | — | AppleScript, Automation->Notes |
| 46 | Stats (CPU/GPU/mem/disk/net/temps) | **A+D** | off | — | private IOReport via `dlopen`, SMC (`utils/*`) |
| 47 | LLM Usage — local JSONL aggregation (Claude/Codex logs) | A | off | — | reads `~/.claude/projects`, `~/.codex/sessions` |
| 48 | LLM Usage — vendor quota calls & credential reading | **C** (+D) | off | N20-N25 | see FEATURE-MATRIX-B.md H |
| 49 | LLM price table refresh | B | with 47/48 | N26 | |
| 50 | Screen Assistant (cloud providers) | **C** | on but inert without a key | N16-N19 | key in Defaults plaintext |
| 51 | Screen Assistant (local Ollama) | A (loopback) | needs setup | L5 | |
| 52 | Extension system (XPC + WebSocket RPC) | A (local) with C extensions | on | L1,L2 | open sockets from launch |
| 53 | Sparkle updates | **B** | updater started; auto-check needs consent (INFERRED) | N1,N2 | |
| 54 | Log export | A | manual | — | |
| 55 | Donation / links | n/a | click only | N31 | |

## 7. Proposed minimal patches for strictly local-first operation (NOT applied)

Each item lists file/line, the change, and the risk. They are independent; the first group removes internet defaults, the second hardens local exposure.

### 7.1 Remove default-on network behaviour

| ID | File:line and proposed minimal change | Risk |
|---|---|---|
| **P1 Disable Sparkle** | `DynamicIslandApp.swift:42-45`: pass `startingUpdater: false` (the code already constructs a non-started controller for the About fallback at `SettingsView.swift:1112`). `Info.plist:16-23`: delete `SUFeedURL`, `SUPublicEDKey`, `SUEnableDownloaderService`, `SUEnableInstallerLauncherService` (or add `SUEnableAutomaticChecks=false`, `SUAllowsAutomaticUpdates=false`). `services/AtollUpdaterDelegate.swift:25-27`: return `nil`. Optionally hide the "Check for Updates…" items (`DynamicIslandApp.swift:55`, `SettingsView.swift:4267`, `SoftwareUpdater.swift:47`). | Settings > About update toggles then act on an unstarted updater (INFERRED harmless but untested); removing the keys may emit a Sparkle "no feed" error if the user clicks "Check for Updates". A self-built app must never be updated from the upstream DMG, so this is the safer state. |
| **P2 Weather off by default; no IP fallback** | `models/Constants.swift:1095` `enableLockScreenWeatherWidget` default `false`. Also remove the launch block `DynamicIslandApp.swift:1104-1109` or keep it (it is already gated on the key). `managers/LockScreenWeatherManager.swift:609-613`: when `location == nil` return `throw WeatherProviderError.noData` instead of calling `fetchWttrSnapshot(location: nil)`. | Loses the weather row on the lock screen and skips the launch-time Location prompt. Battery/charging gauges that live inside the weather widget (`LockScreenWeatherWidget.swift`) would be hidden too unless the widget is split (INFERRED: they share one panel). Lower-impact alternative: only change `:609-613` (keeps Open-Meteo, no wttr.in). |
| **P3 No explicit-badge lookups** | `managers/MusicManager.swift:1217` (`refreshExplicitFlag`): `return` immediately after the `state.isExplicit` branch (`:1217-1230`), i.e. skip the Spotify embed lookup (`:1232-1273`) and the generic iTunes lookup (`:1275,1279-1320`). | The "E" badge disappears for sources that don't supply an explicit flag. |
| **P4 No iTunes artwork / MusicKit calls** | `MediaControllers/AppleMusicController.swift:58-100`: make `fetch(...)` return `nil` (or fetch artwork via AppleScript locally, INFERRED possible but not implemented here). `Constants.swift:1147` `lockScreenMusicFullscreenVideoArtwork` default `false`; `MusicManager.swift:2209` `fetchVideoArtwork()` early return. | Apple Music tracks show no album art unless the controller can read it locally (UNKNOWN); no animated artwork. Choosing the `Now Playing` controller on macOS < 15.4 avoids this path (artwork comes from MediaRemote locally — D risk instead). |
| **P5 No remote Lottie fallback** | `components/Music/LottieAnimationView.swift:29`: replace the lottiefiles.com URL with a bundled JSON or `EmptyView()`. | Cosmetic. |
| **P6 No price-table fetch** | `managers/LLMUsage/ModelPricingManager.swift:101-105`: remove the `Task { await fetchRemotePricing() }` in `init`. | Costs fall back to the bundled `pricing.json` and go stale. |
| **P7 Remove ATS bypass** | `Info.plist:5-9`: replace `NSAllowsArbitraryLoads` with `NSAllowsLocalNetworking = true` (keeps `http://localhost` links L3-L6). | `http://` New-API gateways and any plain-HTTP media-artwork URL (N29) stop loading; Spotify/others are HTTPS already. |
| **P8 Keep LLM usage inert** | `Constants.swift:1283` already defaults the master switch to `false`; additionally set `1284-1287` to `false` so enabling the master switch does not auto-read four tools' credentials. To keep only local token counting, in `ClaudeUsageProvider.swift:20-22` and `CodexUsageProvider.swift:23-25` drop the `quotaClient.fetchLimits()` calls (this removes N20-N22 and all credential/keychain reads for those two). Remove/skip `CursorUsageProvider` (`CursorUsageProvider.swift:12`) and `AntigravityUsageProvider` from the registry at `LLMUsageManager.swift:20`. | Usage tab shows token/cost totals but no limit bars. Never run `scripts/test_claude_keychain.sh` or `tests/test_claude_keychain.swift`: they read the Keychain. |
| **P9 Disable Spotify web-player scraping** | `managers/SpotifyAuthManager.swift:36-37,152-175`: gate `fetchWebPlayerToken` behind a build flag / return nil. | Spotify Canvas video unavailable. |
| **P10 Block IP/URL leaks from extensions** | `components/Extensions/ExtensionLockScreenWidgetView.swift:340-372`: make `isAllowed` return false for `http/https` regardless of the descriptor. | Extensions that rely on remote web content break. |

### 7.2 Local hardening (relevant to a "no surprises" local build)

| ID | File:line and change | Risk |
|---|---|---|
| **P11 Extension servers off by default** | `Constants.swift:1381` `enableThirdPartyExtensions` default `false`; `DynamicIslandApp.swift:709-710` wrap `extensionXPCServiceHost.start()`/`extensionRPCServer.start()` in `if Defaults[.enableThirdPartyExtensions]` (and start/stop on change). | Extensions stop working until enabled. |
| **P12 Require explicit consent** | `services/Extensions/ExtensionRPCService.swift:154-156` and `ExtensionXPCService.swift:57-62`: replace auto-authorize with a pending state that needs the Settings approval (UI exists in `ExtensionsSettings.swift`). Set `enableExtensionFileSharing` default `false` (`Constants.swift:1394`). Add `Origin` rejection in `ExtensionRPCServer.swift:271-300` and a code-signing requirement via `connection.setCodeSigningRequirement` in `ExtensionXPCServiceHost.swift:70-98`. | Third-party extension UX changes. |
| **P13 Clipboard safety** | `managers/ClipboardManager.swift:562-575` (`checkClipboard`): skip items whose pasteboard types include `org.nspasteboard.ConcealedType`/`TransientType`/`AutoGeneratedType`; `Constants.swift:1364` `persistClipboardHistory` default `false`; move images from `~/Documents/ClipboardData` (`ClipboardManager.swift:248-256`) to Application Support. | No cross-restart history by default. |
| **P14 Do not touch system processes/wallpaper** | `Constants.swift:1400` `enableSystemHUD` default `false` (keeps Apple's OSD, removes `SIGSTOP` of `OSDUIHelper` and the event tap prompt); `Constants.swift:1145` `lockScreenMusicFullscreenArtworkEnabled` default `false` (stops wallpaper-plist rewrite). | HUD replacement and fullscreen lock artwork off. |
| **P15 API keys to Keychain** | `Constants.swift:1371-1374` (Screen Assistant keys) and `1244-1247` (Spotify cookie/token): route through a Keychain store like `CiderTokenStore`. | Needs migration code; larger than a one-line patch. |
| **P16 Gemini key in header** | `ScreenAssistantManager.swift:418`: send `x-goog-api-key` header instead of `?key=` query. | Low. |
| **P17 Bind identity, not strings (LocalSend)** | `LocalSendService.swift:1058-1063`: pin certificate fingerprint advertised in discovery. | Protocol-specific; optional. |

### 7.3 Not removable by settings or small patches

- Build-time SwiftPM downloads (N32) — vendor the packages or cache them for an offline build.
- Private-API dependence (SkyLight/CGS/MediaRemote/IOReport/CoreBrightness/DisplayServices): removing it means removing the lock-screen widgets, Now-Playing-via-MediaRemote, Stats and parts of HUD; there is no public replacement for drawing above the lock screen.
- Prebuilt binaries `Frameworks/MediaRemoteAdapter.framework` and `Contents/Helpers/NowPlayingTestClient` cannot be audited; to avoid them, build the adapter from its upstream source or use the Apple Music/Spotify AppleScript controllers only (and remove the perl-driven controllers).

## 8. Offline behaviour summary

With the network completely blocked: all category A items work (INFERRED, nothing run). Lost: weather, explicit badges, Apple-Music artwork, animated artwork, lyrics, updates, price-table refresh, vendor quotas, AI chat via cloud. The code swallows these errors (`try?`/catch returning nil) rather than blocking the UI (OBSERVED in the call sites cited above), so a stalled network should not freeze the notch — but request timeouts range from 3 s to the URLSession default of 60 s (e.g. `AppleMusicController.swift:74,93` use `URLSession.shared` defaults), so slow-failing artwork lookups may delay art by up to a minute (INFERRED).
