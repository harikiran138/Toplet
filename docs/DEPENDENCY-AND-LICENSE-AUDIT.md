# Atoll dependency and licence audit

- Repo: `<repo>`, branch `local-build`, commit `f039ca9`, `VERSION` 2.3.3 (OBSERVED: `git log`, `VERSION`).
- Audit date: 2026-10-21. Method: read-only inspection of the working tree, plus read-only fetches of public files from GitHub at the exact resolved revisions. Nothing downloaded was executed or built.
- Not legal advice. Where a licence could not be verified it is marked UNVERIFIED.

Evidence tags used throughout:

- **OBSERVED** - read directly from a file in this repo, from tool output (`file`, `lipo`, `codesign`, `otool`, `nm`, `strings`), or from a public file fetched at a pinned revision.
- **INFERRED** - a conclusion drawn from OBSERVED facts, not stated by any source.
- **UNKNOWN** - could not be determined from what was available.

How licences were verified: for each pinned package, the `LICENSE` / `license` file was fetched from `raw.githubusercontent.com/<owner>/<repo>/<resolved-sha>/` and its title and copyright lines were read. "Verified (file @ sha)" below means that. `Package.swift` of each package was fetched at the same sha to see its dependencies and products.

---

## 1. Headline findings

1. **Open-Meteo package is not linked and cannot be linked.** `open-meteo/open-meteo` 1.4.16 is the AGPL-3.0 weather *server* (package name `OpenMeteoApi`, depends on Vapor, NIO, flatbuffers, etc.). It declares no `products:` array, only an executable target `openmeteo-api`. It is listed in the project's `packageReferences` but is absent from the app target's `packageProductDependencies` and from the Frameworks build phase, and no Swift file imports it (all OBSERVED). Atoll reaches Open-Meteo only through plain HTTPS calls to `api.open-meteo.com` and `air-quality-api.open-meteo.com`. The package reference is dead weight and should be removed in a rebuild (Decision: Remove).
2. **`rtaudio`-derived code is AGPL-3.0, but Atoll's headers on those files say GPL.** Six files in `Toplet/audio/` carry "Original work Copyright (C) 2026 ZephyrCodesStuff ... Modified work ... Atoll Contributors" and a GPL-3.0-or-later notice. The upstream repo is licensed AGPL-3.0 (OBSERVED: GitHub API `spdx_id: AGPL-3.0` and the fetched `LICENSE`). A downstream project cannot drop AGPL terms from derived files on its own; AGPL-3.0 section 13 / GPL-3.0 section 13 allow *combining* with GPL-3.0 code, but the AGPL part stays AGPL. INFERRED: those headers understate the licence. No NOTICE entry exists for rtaudio.
3. **Stats (exelban/stats, MIT) is credited in `ReadMe.md` as the source of the SMC / IOReport / CPU sensor code, but no MIT notice exists anywhere in the repo.** `utils/SMC.swift`, `utils/IOReportBridging.swift` and `utils/CPUSensorCollector.swift` carry only the Atoll GPL header (OBSERVED). MIT requires the copyright and permission notice to be kept in "copies or substantial portions" (Stats copyright: "Copyright (c) 2019 Serhiy Mytrovtsiy", OBSERVED from fetched LICENSE). Whether the code is a substantial portion is INFERRED from the ReadMe wording; the code itself was not diffed against Stats.
4. **Boring.Notch lineage is documented only loosely.** 103 source files say "Originally from boring.notch project" but their copyright line was replaced with "Atoll Contributors". `NOTICE` and `ReadMe.md` acknowledge boring.notch (GPL-3.0, OBSERVED). GPL-3.0 section 5(a) and section 7 care about preserving upstream copyright notices; INFERRED: this is a soft compliance gap, not a licence conflict (same licence).
5. **Three prebuilt binaries sit in the repo with no build recipe**: `MediaRemoteAdapter.framework` (two identical copies), `Contents/Helpers/NowPlayingTestClient`. Their upstream is `ungive/mediaremote-adapter` (BSD-3-Clause, source available), but the exact upstream commit they were built from is UNKNOWN. See section 5.
6. **Two SPM packages are binary targets (prebuilt, fetched as zips)**: Sparkle 2.7.0 and Lottie 4.5.2 (via `lottie-spm`). Checksums are pinned by those packages' manifests.
7. **No third-party licence bundle ships in the app.** `COPYRIGHT_ASSETS` refers to "any THIRD_PARTY_LICENSES files" but no such file exists (OBSERVED: `ls`). There is no in-app acknowledgements screen (OBSERVED: grep). The MIT / BSD / Apache notices of the dependencies are therefore not reproduced anywhere in a shipped binary. A rebuild that is redistributed should add them.
8. **No payment, licence-key, paywall or analytics SDK found** in `Toplet/` (OBSERVED: grep for paywall/licence-key/StoreKit/Sentry/Firebase/Mixpanel/etc. returned nothing relevant). Optional paid third-party services exist (AI assistant API keys, Spotify cookie/secret flows, Open-Meteo commercial tier) - see section 2.

---

## 2. Dependency table

Package.resolved is `version: 3`, `originHash d05fd8c8...`, 15 pins (OBSERVED). The Xcode project declares 13 remote package references and links 11 products into the `Atoll` app target (OBSERVED: `project.pbxproj` lines for `packageReferences`, `packageProductDependencies`, and the Frameworks phase). Min macOS 14.6, Swift 5.0 language mode, hardened runtime on (OBSERVED).

Legend for "Local operation": Yes = works fully offline / on-device; Partial = core works but a feature needs network or a third-party service; No = needs a remote service to function.

| Package | Source | Version / revision actually resolved | Licence (verified how) | Function in Atoll | Local operation | Payment requirement | Security notes | Decision |
|---|---|---|---|---|---|---|---|---|
| **AtollExtensionKit** (product linked) | `github.com/Ebullioscopic/AtollExtensionKit` | branch `main` @ `e2d30afedbbcc259bec7eeb1bea0757e52f4ca01` (no tag) | **UNVERIFIED.** README line 5 and 469 claim MIT, but no LICENSE file exists at that revision (GitHub contents listing: `.gitattributes .github .gitignore API_DOCUMENTATION.md IMPLEMENTATION_STATUS.md Package.swift QUICK_START_GUIDE.md README.md Samples Sources Tests`). Same author as Atoll, so INFERRED low conflict risk. | Client SDK for third-party "extensions" to push live activities / widgets into Atoll (16 `import AtollExtensionKit` sites). Used with a Mach service `com.ebullioscopic.Atoll.xpc` (entitlement). | Yes (local IPC). Marketplace link `getatoll.app/marketplace` is only a URL in Settings. | None | Opens an XPC / Mach-service surface to other local processes; Info.plist entitlement `mach-services` and `mach-lookup.global-name` exceptions. Branch-pinned: `swift package update` would move it. | Keep (local); ask author to add a LICENSE file; consider disabling extension server if unused. |
| **Defaults** | `github.com/sindresorhus/Defaults` | 9.0.3 @ `00c82eff4550c87cf9c547d7e5493a6a97837061` | MIT. Verified (`license` file @ sha: "MIT License, Copyright (c) Sindre Sorhus"). | Typed `UserDefaults` wrapper; imported in ~163 files. Pulls `swift-syntax` for its macro target. | Yes | None | Pure Swift; build-time macro plugin only. | Keep |
| **KeyboardShortcuts** | `github.com/sindresorhus/KeyboardShortcuts` | 2.3.0 @ `045cf174010beb335fa1d2567d18c057b8787165` | MIT. Verified (`license` @ sha). | User-configurable global hotkeys. | Yes | None | Registers global hotkeys via Carbon event APIs (no private API in the package manifest; source not audited). | Keep |
| **LaunchAtLogin-Modern** (product `LaunchAtLogin`) | `github.com/sindresorhus/LaunchAtLogin-Modern` | branch `main` @ `a04ec1c363be3627734f6dad757d82f5d4fa8fcc` | MIT. Verified (`license` @ sha). | "Launch at login" toggle via `SMAppService`. | Yes | None | Branch-pinned (not a tag). Registers a login item. | Keep |
| **lottie-spm** (transitive, via LottieUI; also `import Lottie` in 5 files) | `github.com/airbnb/lottie-spm` | branch `main` @ `04f2fd18cc9404a0a0917265a449002674f24ec9` | Apache-2.0. Verified (`LICENSE` of lottie-spm @ sha, and `LICENSE` of `airbnb/lottie-ios` tag 4.5.2, both "Apache License 2.0"). | Lottie renderer for idle/lock animations. | Yes for bundled JSON. One animation URL is fetched at runtime from `assets9.lottiefiles.com` (`LottieAnimationView.swift:29`, `AnimationEditorView.swift:634`). | None | **Binary blob**: `binaryTarget` `Lottie.xcframework.zip` from lottie-ios release 4.5.2, checksum `92206ff6af80373903767214ac16215838f6da11dedca789c0439299b46b6694` (OBSERVED in its Package.swift). Built by Airbnb with Xcode 15.2. Source exists (lottie-ios 4.5.2) but SPM consumes the prebuilt zip. | Keep; optionally switch to source package `airbnb/lottie-ios` 4.5.2 to remove the blob. |
| **LottieUI** | `github.com/jasudev/LottieUI` | branch `main` @ `0cd5b54a1c8467b19c01f56395aec179087b62e2` | MIT. Verified (`LICENSE` @ sha, "Copyright (c) 2022 jasu"). | SwiftUI wrapper (`LottieView`, `LUStateData`) over Lottie. | Yes | None | Branch-pinned; depends on `lottie-spm` branch `main`, so a plain `swift package update` can change Lottie. | Keep (or replace with Lottie's own SwiftUI `LottieView` and drop this package). |
| **MacroVisionKit** | `github.com/TheBoredTeam/MacroVisionKit` | 0.1.0 @ `5e8b06c448298de182638bb28ca064eaf6b1fe99` | MIT. Verified (`LICENSE` @ sha, "Copyright (c) 2024 github.com/theboringhumane"). | Fullscreen-window detection (hide notch over fullscreen apps). | Yes | None | Uses `CGWindowListCopyWindowInfo` (public API; `FullscreenDetector.swift` at the sha has no `dlopen`/`SLS`/`CGS` hits). Screen-recording permission may be implied by window-title access (INFERRED). | Keep |
| **open-meteo** (**NOT linked**) | `github.com/open-meteo/open-meteo` | 1.4.16 @ `f18ccb781804c444b87e6175a4b62ecfbe0212dc` (tag confirmed by `git ls-remote`) | **AGPL-3.0.** Verified (`LICENSE` @ sha is GNU AGPL v3; GitHub API `spdx_id AGPL-3.0`; repo description "Free Weather Forecast API for non-commercial use"). | **None at link level.** Package is the Open-Meteo *server* (`OpenMeteoApi`: Vapor, flatbuffers, NetCDF, eccodes, curl-swift; macOS 15 platform; `unsafeFlags`). No library product is declared. Atoll's weather feature is separate code: `LockScreenWeatherManager.swift` calls the public REST API. | Weather feature: Partial (needs network; falls back to wttr.in). | None for the package. The *API* is free for non-commercial use only (10,000 calls/day, 5,000/hour, 600/min; subscriptions or ads count as commercial); paid plans exist for commercial use. Data is CC BY 4.0 (OBSERVED: open-meteo.com/en/terms). | Not linked, so no AGPL code is in the binary (OBSERVED: absent from product dependencies and Frameworks phase). Package.resolved lists the pin but not Vapor etc., so Xcode did not resolve its server dependencies (UNKNOWN why). Risk: it makes SBOM tools and reviewers believe an AGPL component ships. No in-app CC BY attribution text found (OBSERVED: grep). | **Remove** the package reference (project edit, not done here). Keep API use as optional; add "Weather data by Open-Meteo.com (CC BY 4.0)" if the weather widget is kept. |
| **Pow** (**NOT linked**) | `github.com/EmergeTools/Pow` | 1.0.5 @ `a504eb6d144bcf49f4f33029a2795345cb39e6b4` | MIT. Verified (`LICENSE` @ sha, "Copyright (c) 2023 Emerge Tools, Inc."). | Declared in `packageReferences` but not in target products and not imported (OBSERVED). | n/a | None | Would pull `SnapshotPreviews-iOS` 0.7.6 only for iOS. Unused. | **Remove** reference. |
| **SkyLightWindow** | `github.com/Lakr233/SkyLightWindow` | branch `main` @ `4a7e8628c85e6b2ec429b57657a556a2171a4864` | MIT. Verified (`LICENSE` @ sha, "Copyright (c) 2025 Lakr Aream"). | Puts Atoll windows above the lock screen (lock-screen widgets, full-screen artwork, timer widget). Used in 4 managers via `SkyLightOperator.shared.delegateWindow`. | Yes | None | **Private API.** `SkyLightOperator.swift` loads private `SLS*` symbols (`SLSMainConnectionID`, `SLSSpaceCreate`, `SLSSpaceSetAbsoluteLevel`, `SLSShowSpaces`, `SLSSpaceAddWindowsAndRemoveFromSpaces`) and uses `kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock`. Can break on any macOS update; not App Store-eligible. Branch-pinned. | Keep for lock-screen features; Investigate if lock-screen widgets are not needed (then Remove). |
| **Sparkle** | `github.com/sparkle-project/Sparkle` | 2.7.0 @ `0ca3004e98712ea2b39dd881d28448630cce1c99` | MIT plus bundled external licences (BSD for bsdiff, MIT for sais, a zlib-style licence for ed25519, etc.). Verified (`LICENSE` @ sha lists copyrights incl. Andy Matuschak, Elgato, Kornel Lesinski, Mayur Pawashe, and an "EXTERNAL LICENSES" section). | Auto-update (`SPUStandardUpdaterController`, `SoftwareUpdater.swift`). Feed `https://raw.githubusercontent.com/Ebullioscopic/Atoll/main/Updates/appcast.xml`; EdDSA public key `SUPublicEDKey q2YQaJ1u...` in Info.plist. | No for updating (network). App itself works without it. | None | **Binary blob**: `Sparkle-for-Swift-Package-Manager.zip`, checksum `a1fb05c4fd6b73bc351f4d326e6171473b7a99b7f2bfa8f5f69f7281f66dc387` (OBSERVED in its Package.swift). Info.plist enables `SUEnableDownloaderService` and `SUEnableInstallerLauncherService`. A locally rebuilt app would still poll the upstream appcast; an update there is signed with the upstream key, so it would be offered as an update to the official build. | **Replace/disable for local build**: remove `SUFeedURL` and set no-auto-check, or drop Sparkle. Keep if you intend to host your own appcast with your own key. |
| **swift-argument-parser** (transitive) | `github.com/apple/swift-argument-parser` | 1.7.1 @ `626b5b7b2f45e1b0b1c6f4a309296d1d21d7311b` | Apache-2.0 with Runtime Library Exception. Verified (`LICENSE.txt` @ sha contains "Runtime Library Exception"). | Required only by SwiftTerm's `Termcast` executable; not linked into Atoll (INFERRED: SwiftTerm library target does not use it; the app links only product `SwiftTerm`). | n/a | None | Resolution-time only. | Keep (transitive; no action) |
| **swift-collections** (product `Collections`) | `github.com/apple/swift-collections` | 1.1.4 @ `671108c96644956dddcd89dd59c203dcdb36cec7` | Apache-2.0 with Runtime Library Exception. Verified (`LICENSE.txt` @ sha). | Ordered collections (`import OrderedCollections` in 1 file). | Yes | None | Pure Swift. | Keep (or Replace with stdlib if that one use is trivial) |
| **swift-syntax** (transitive) | `github.com/swiftlang/swift-syntax` | 601.0.1 @ `f99ae8aa18f0cf0d53481901f88a0991dc3bd4a2` | Apache-2.0 with Runtime Library Exception. Verified (`LICENSE.txt` @ sha). | Needed by Defaults' macro plugin at build time (OBSERVED: Defaults `Package.swift` requires `swift-syntax from: 601.0.0`). | Yes | None | Build-time macro host only. First clean build compiles it (slow). | Keep (transitive) |
| **SwiftTerm** | `github.com/migueldeicaza/SwiftTerm` | 1.13.0 @ `8e7a1e154f470e19c709a00a8768df348ba5fc43` (project min 1.5.0) | MIT. Verified (`LICENSE` @ sha: Miguel de Icaza 2019-2022, plus xterm.js authors, SourceLair, Christopher Jeffrey - all MIT-style under one grant). | Embedded terminal tab. `TerminalManager.swift` header says "Adapted from SwiftTerm". | Yes | None | The terminal spawns a local shell/pty as the user (INFERRED from the feature; not traced). Unsandboxed app, so full user shell access. | Keep (or Remove if you do not want an embedded shell). |
| **swiftui-introspect** (product `SwiftUIIntrospect`) | `github.com/siteline/swiftui-introspect` | 1.3.0 @ `807f73ce09a9b9723f12385e592b4e0aaebd3336` | MIT. Verified (`LICENSE` @ sha, "Copyright 2019 Timber Software"). | Reaches underlying AppKit views from SwiftUI (4 imports). | Yes | None | Relies on view-hierarchy structure, fragile across macOS releases. | Keep |

Packages in the resolved graph that are **not** in the app binary: `open-meteo`, `Pow`, `swift-argument-parser` (OBSERVED/INFERRED as noted). That leaves 12 pinned packages that matter at build/link time.

### 2.1 Non-SPM dependencies and vendored code

| Item | Source / provenance | Licence (verified how) | Function | Local op | Payment | Security notes | Decision |
|---|---|---|---|---|---|---|---|
| **MediaRemoteAdapter.framework** (`Frameworks/` and a byte-identical copy in `mediaremote-adapter/`) | `ungive/mediaremote-adapter` (Perl script header: "Copyright (c) 2025 Jonas van den Berg ... BSD 3-Clause"). Bundle id `com.vandenbe.MediaRemoteAdapter`, version 0.1.0. | BSD-3-Clause. Verified (upstream `LICENSE` at `master`, "Copyright (c) 2025, Jonas van den Berg and contributors"). The binary itself carries no licence text. | Reads now-playing info and sends transport commands for any player, including on macOS 15.4+ where direct MediaRemote use is blocked. | Yes (all local) | None | See section 4. Ad-hoc signed, no Team ID, links private `MediaRemote`; loaded by `/usr/bin/perl`. | Keep (core media feature); rebuild from upstream source if you want a verifiable binary. |
| **mediaremote-adapter.pl** | Same upstream, modified/older copy (SHA-256 `248bc02f89650de0f019...` vs upstream master `d97802e46db9535e2549...`; differs in help text and options such as `--now`, `--no-artwork`, `test`). | BSD-3-Clause (header in file). | Perl launcher that `dl_load_file`s the framework and calls an exported symbol. | Yes | None | Read in full; see section 4. | Keep |
| **NowPlayingTestClient** (`Contents/Helpers/`) | Upstream test client from the same project (strings: `com.vandenbe.MediaRemoteAdapter.NowPlayingTestClient`; uses `MPNowPlayingInfoCenter`). Atoll renamed it. | BSD-3-Clause by provenance (INFERRED from identifier; the binary carries no licence). | `MediaChecker.swift` runs it to test whether the adapter is entitled to use MediaRemote. | Yes | None | arm64-only, ad-hoc "linker-signed", no Info.plist. On Intel this test cannot run (INFERRED). | Keep (or Remove the test-mode feature). |
| **rtaudio-derived audio code** (`audio/AudioProcessor.cpp/.hpp`, `AudioBridge.h/.mm`, `AudioTap.swift`, `RealTimeAudioSpectrum.swift`) | `github.com/ZephyrCodesStuff/rtaudio`. Headers: "Original work Copyright (C) 2026 ZephyrCodesStuff ... Modified work Copyright (C) 2026 Atoll Contributors". | **AGPL-3.0.** Verified (fetched `LICENSE`; GitHub API `spdx_id AGPL-3.0`; README badge "AGPLv3.0"). Atoll's headers say GPL-3.0-or-later. | Live music visualizer (CoreAudio tap, Accelerate DSP). | Yes | None | Uses CoreAudio process taps (`NSAudioCaptureUsageDescription`). | Keep for local use; fix headers/NOTICE before redistributing (section 6). |
| **Stats-derived sensor code** (`utils/SMC.swift`, `utils/IOReportBridging.swift`, `utils/CPUSensorCollector.swift`) | ReadMe: "source implementation ... derived from Stats project readers" (`exelban/stats`). | MIT. Verified (Stats `LICENSE`, "Copyright (c) 2019 Serhiy Mytrovtsiy"). No MIT notice in this repo. | CPU temperature, frequency, per-core load. | Yes | None | **Private APIs**: `IOReport*` loaded dynamically, SMC access through IOKit `AppleSMC`. Can break across macOS versions. | Keep (add MIT notice). |
| **Boring.Notch-derived code** (103 files with "Originally from boring.notch project", plus `metal/visualizer.metal` "Created by Harsh Vardhan Goswami") | `github.com/TheBoredTeam/boring.notch` | GPL-3.0. Verified (fetched `LICENSE` at `main`; GPL v3 text). Same licence as Atoll. | Media controllers, calendar, notch view, battery, image service, etc. | Yes | None | n/a | Keep (preserve NOTICE and ReadMe credit). |
| **SwiftTerm-adapted terminal** (`managers/TerminalManager.swift`) | Header "Adapted from SwiftTerm". | MIT (see SwiftTerm row). | Terminal pane. | Yes | None | See SwiftTerm. | Keep |
| **Private Apple frameworks referenced in project** | `CoreBrightness`, `DisplayServices`, `OSD` added as file references (`/System/Library/PrivateFrameworks/...`); `SYSTEM_FRAMEWORK_SEARCH_PATHS` includes `$(SDKROOT)/System/Library/PrivateFrameworks`. | Apple; not redistributed. | Brightness / OSD HUD replacement. | Yes | None | Private API use; not App Store-eligible; may break on OS updates. | Keep for local use. |
| **Network services called by code** | `api.open-meteo.com`, `air-quality-api.open-meteo.com`, `wttr.in`, `lrclib.net`, `music.163.com` (NetEase lyrics), `itunes.apple.com`, `api.music.apple.com`, Spotify (`api.spotify.com`, `accounts.spotify.com`, `spclient.wg.spotify.com`), `api.anthropic.com`, `api.openai.com`, `api.groq.com`, `generativelanguage.googleapis.com`, `cursor.com` / `api2.cursor.sh`, `chatgpt.com`, `cloudcode-pa.googleapis.com`, `raw.githubusercontent.com` (appcast, LLM pricing JSON, Spotify secret dictionary). | n/a | Optional features. | Partial: every one is an optional feature; core notch/media/timer/clipboard/stats work offline (INFERRED from feature layout, not run-tested). | AI assistant: user supplies provider API key (paid by provider). Open-Meteo free for non-commercial use. Spotify canvas / like features rely on an `sp_dc` cookie flow and a third-party secrets file (`xyloflake/spot-secrets-go`), which is a Spotify-ToS grey area (INFERRED). | `Info.plist` sets `NSAllowsArbitraryLoads = true` (ATS disabled). LLM usage code reads local credentials: `~/.claude/.credentials.json`, `~/.claude.json`, `~/.codex/auth.json`, a Cursor token store, and Keychain via `KeychainReader` (OBSERVED file paths). `ModelPricingManager` fetches `pricing.json` from the upstream `dev` branch at startup. | Investigate each; disable features you do not use. |
| **Dev scripts** (`scripts/*.rb`, `scripts/*.sh`, `tests/*`) | Ruby scripts manipulate the Xcode project (xcodeproj gem). | Atoll (GPL-3.0 by repo licence; headers not checked) | Maintainers' tooling | n/a | None | Not part of the app bundle (OBSERVED: not in Resources). Not run. | Keep, ignore for build. |

---

## 3. Version / pin hygiene (affects reproducible local builds)

- **Branch-tracked, not tagged (OBSERVED in `project.pbxproj`)**: AtollExtensionKit, LaunchAtLogin-Modern, SkyLightWindow, LottieUI. `Package.resolved` pins each to a commit, so a clean resolve is reproducible. `File > Packages > Update to Latest` or `swift package update` would move them. LottieUI additionally tracks `lottie-spm` `main`, which means Lottie's version is whatever LottieUI resolved.
- Declared minimums vs resolved: Sparkle min 2.6.4 -> 2.7.0; Defaults min 9.0.2 -> 9.0.3; KeyboardShortcuts min 2.2.4 -> 2.3.0; SwiftTerm min 1.5.0 -> 1.13.0; Pow min 1.0.4 -> 1.0.5. All are "up to next major".
- Two Sparkle/Lottie binaries are downloaded by SwiftPM at resolve time and checked against checksums in those packages' manifests. The first clean build therefore needs network access to GitHub release assets.
- INFERRED: `swift-syntax` 601.x needs Xcode 16.x / Swift 6.0+ toolchain to build macros (`Defaults` requires `from: "601.0.0"`).

---

## 4. `MediaRemoteAdapter.framework`, `mediaremote-adapter.pl`, `NowPlayingTestClient`

### 4.1 What is in the tree (OBSERVED)

| File | Type | Size | SHA-256 | Archs | Signature |
|---|---|---|---|---|---|
| `Frameworks/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter` | Mach-O universal dylib | 462,128 B | `829e9cdbce5602a92f56f125e3921a82215fa6cc09a8e6fdff39d3b991dbcdac` | x86_64, arm64, arm64e (`lipo -archs`) | ad-hoc, `TeamIdentifier=not set`, `valid on disk`, flags `0x2(adhoc)` |
| `mediaremote-adapter/MediaRemoteAdapter.framework/...` | byte-identical to the above (`cmp` returned equal) | same | same | same | same |
| `Contents/Helpers/NowPlayingTestClient` | Mach-O 64-bit executable | 77,848 B | `4ef9a27dab6d45ad50510d90794f75caaaf0fbc031229b373053dcbaf4d1795d` | arm64 only | ad-hoc, linker-signed (`0x20002`), no Info.plist, no sealed resources |
| `mediaremote-adapter/mediaremote-adapter.pl` | Perl script, 257 lines | - | `248bc02f89650de0f019...` | - | unsigned (script) |

Framework `Info.plist`: identifier `com.vandenbe.MediaRemoteAdapter`, `CFBundleVersion 0.1.0`, `CFBundleShortVersionString 0.1`. Git history for these paths: `d5894e4 Enable Hardened Runtime`, `4015e0d Fix: Migrations` (OBSERVED), i.e. committed binaries, no build script in `scripts/` or `.github/workflows` that produces them (OBSERVED: grep for MediaRemoteAdapter across `scripts/` and `.github/` found nothing).

### 4.2 What the framework does (OBSERVED from `otool -L`, `nm -gU`, `strings`)

- Links only system libraries: Foundation, AppKit, JavaScriptCore, UniformTypeIdentifiers, CoreFoundation, ImageIO, libobjc, libSystem. No network frameworks, no CFNetwork/NSURLSession symbols found.
- Exports C entry points the Perl script looks up: `adapter_get`, `adapter_get_env`, `adapter_stream`, `adapter_stream_env`, `adapter_send(_env)`, `adapter_seek(_env)`, `adapter_shuffle(_env)`, `adapter_repeat(_env)`, `adapter_speed(_env)`, `_adapter_is_it_broken_yet` (the `test` function).
- Resolves private `MRMediaRemote*` functions at run time (`MRMediaRemoteGetNowPlayingInfo`, `...SendCommand`, `...SetElapsedTime`, `...RegisterForNowPlayingNotifications`, etc.) from `/System/Library/PrivateFrameworks/MediaRemote.framework`, and reads parameters from `MEDIAREMOTEADAPTER_PARAM_*` / `MEDIAREMOTEADAPTER_OPTION_*` environment variables.
- Output: JSON lines on stdout (title, artist, album, artwork data, bundle id, elapsed time, etc.).
- Mechanism (INFERRED, consistent with the upstream README text fetched from `ungive/mediaremote-adapter`): macOS 15.4+ only lets Apple-entitled processes use MediaRemote, so the app runs `/usr/bin/perl` (an Apple platform binary that has the entitlement) and has it `dlopen` this helper framework. Atoll calls it as `/usr/bin/perl <script> <framework> stream --micros` (OBSERVED in `NowPlayingController.swift:273-278`; also in `AmazonMusicController.swift:200` and `MediaChecker.swift:53`).
- Test client strings: `MPNowPlayingInfoCenter`, "Unknown Title/Artist/Album", `NowPlayingPublishTest`. It publishes fake now-playing data so the adapter can check it works.

### 4.3 The Perl script, read in full (OBSERVED, 257 lines)

Behaviour:

1. Header: "Copyright (c) 2025 Jonas van den Berg ... BSD 3-Clause License".
2. `use strict; use warnings; use DynaLoader; use File::Spec; use File::Basename;` - no other modules, no `system`, backticks, `exec`, `open`, `eval STRING`, sockets, or file writes. Its only I/O is `print` of help text, `print STDERR` of errors, and `exit`.
3. With fewer than two arguments it prints help and exits 0.
4. Takes `FRAMEWORK_PATH` (must end in `.framework`; checked with `-e` on `<path>/<basename>`), optionally a `NowPlayingTestClient` path (if it contains `NowPlayingTestClient` or `/`), which it stores in `$ENV{NOWPLAYING_CLIENT}`.
5. Loads the framework with `DynaLoader::dl_load_file($framework, 0)`.
6. Whitelists the function name: `stream | get | send | seek | shuffle | repeat | speed | test`; anything else fails.
7. Parses `--option[=value]` and `-x` flags. For `stream` only `no-diff`, `debounce=N`, `micros`, `human-readable`/`h` are accepted; for `get` only `micros`, `human-readable`/`h`, `now`. Unknown options -> `fail`.
8. For `send/seek/shuffle/repeat/speed` it takes one positional argument and places it in an environment variable `MEDIAREMOTEADAPTER_PARAM_adapter_<fn>_0_<name>`; for `stream`/`get` options become `MEDIAREMOTEADAPTER_OPTION_*`. It then picks the exported symbol (`adapter_<fn>` or `adapter_<fn>_env`), installs it with `dl_install_xsub("main::<fn>", $symbol)` and calls it inside `eval { }`.
9. Rejects extra arguments ("Too many arguments").

Safety assessment (INFERRED from the above):

- The script itself is small, has no network or filesystem writes, no shell invocation, and a strict argument whitelist. I found nothing malicious in it.
- Its trust model is: **whatever native code is at `FRAMEWORK_PATH` runs inside Apple's `perl` with perl's entitlements.** The script performs no integrity check on the framework. The safety of the feature therefore rests on (a) the framework binary in the app bundle and (b) nobody being able to replace it or alter the arguments. Atoll passes bundle-internal paths (`Bundle.main.resourceURL/MediaRemoteAdapter.framework`), and the app's own entitlements include `com.apple.security.cs.disable-library-validation` (OBSERVED), which weakens library validation for the app and is probably there to allow the ad-hoc framework / helper pattern (INFERRED).
- The framework binary is a prebuilt blob whose exact upstream commit is UNKNOWN. Its symbol list matches the script's expectations. It has no network imports (OBSERVED). It could not be decompiled here; a deeper review needs a rebuild from upstream source (section 7).
- `MediaChecker`/`NowPlayingController` pass only fixed argument lists (`stream --micros`, `test`), not user text (OBSERVED in the code locations above for the stream case; other call sites not exhaustively traced).
- The script and framework use a **private Apple API**. It can stop working with any macOS update, and it is not App Store-eligible.
- The Atoll copy of the script is **older / modified** relative to current upstream `master` (OBSERVED by `diff`: different option names and help text; upstream adds `--no-artwork`, `--allow-missing-title`, `elapsedTimeNow`, `test`/`TEST_CLIENT_PATH`). The framework build must match the script version; mixing a newer script with this framework may fail.
- Duplicate copy: `mediaremote-adapter/MediaRemoteAdapter.framework` is not referenced by the Xcode project (only `Frameworks/MediaRemoteAdapter.framework` and the `.pl` are). INFERRED: dead duplicate.
- Packaging detail: the project copies the framework into **Resources**, not Frameworks (`MediaRemoteAdapter.framework in Resources`), because it is loaded by path at run time rather than linked. When Xcode re-signs the bundle, `codesign --deep` behaviour for a framework in Resources is something to check on the first local build (UNKNOWN).

---

## 5. GPLv3 compatibility analysis

Atoll is GPL-3.0 (`LICENSE` is the FSF GPL v3 text, 35,149 bytes; source headers say "version 3 ... or (at your option) any later version"; GitHub API reports `GPL-3.0`) (OBSERVED). Compatibility is judged against that.

| Component | Licence | Compatible with GPLv3 distribution? | Notes |
|---|---|---|---|
| Defaults, KeyboardShortcuts, LaunchAtLogin-Modern, LottieUI, MacroVisionKit, Pow, SkyLightWindow, SwiftTerm, swiftui-introspect | MIT | Yes | Permissive; one-way compatible into GPL. Must keep each copyright + permission notice in redistributed copies (source and, per common practice, binary documentation). |
| Sparkle 2.7.0 | MIT + external BSD / MIT / zlib-style notices | Yes | Notices listed in Sparkle's `LICENSE` should accompany a binary redistribution of the framework. It is a prebuilt binary, so the notice must be shipped separately. |
| lottie-spm / lottie-ios 4.5.2 | Apache-2.0 | Yes with GPLv3 (not with GPLv2-only) | Apache-2.0's patent and notice terms fit GPLv3. Keep Apache `LICENSE` and any `NOTICE`. Atoll is GPLv3 "or later", fine. |
| swift-collections, swift-argument-parser, swift-syntax | Apache-2.0 + Runtime Library Exception | Yes | Exception removes attribution requirement for compiled output of these libraries. Only `Collections` is linked at run time; `swift-syntax` is build-time. |
| mediaremote-adapter (framework, script, test client) | BSD-3-Clause | Yes | Must retain the copyright notice and conditions in redistributions, including binary (reproduce in documentation). Do not use the author's name to endorse. The Perl file already keeps its header. |
| Stats-derived code | MIT | Yes | Add the Stats MIT notice (currently missing). |
| boring.notch-derived code | GPL-3.0 | Yes (same licence) | Keep upstream credit; consider restoring copyright holder names in headers. |
| DynamicNotch (battery HUDs, per ReadMe "thanks for letting us use") | GPL-3.0 (GitHub API) | Yes by licence; permission wording is in ReadMe only | Repo licence is GPL-3.0, so use is permitted regardless; the ReadMe credit is sufficient attribution. No file in `Toplet/` mentions it (grep), so which files are derived is UNKNOWN. |
| OpenUsage (LLM usage tracking inspiration) | MIT (GitHub API) | Yes | No source file mentions it (grep) so whether code was copied is UNKNOWN. |
| rtaudio-derived files | **AGPL-3.0** | **Yes, with conditions.** | GPLv3 section 13 and AGPLv3 section 13 expressly allow combining a GPLv3 work with an AGPLv3 work into one program. The AGPL terms keep applying to the AGPL-derived part; the rest stays GPLv3. Obligations: keep AGPL notice and licence on those files, state modifications, and if you ever let users interact with it *remotely over a network* offer them the corresponding source. A desktop app used locally does not trigger section 13 in practice (INFERRED), but the headers currently say GPL not AGPL, which is the defect. Fix by correcting the headers (or obtaining a written relicence from ZephyrCodesStuff). |
| **Open-Meteo server package** | AGPL-3.0 | N/A as shipped; **would** be compatible by the same AGPL/GPL combination rule if linked | Not linked, no library product. Remove the reference so the question never arises. |
| **Open-Meteo API data** | CC BY 4.0 data; free API non-commercial only | Not a software licence issue | Attribution is required for the data. Free tier excludes apps with subscriptions or ads. Personal local use is fine. A paid/commercial distribution of Atoll would need an Open-Meteo plan or another provider. |
| AtollExtensionKit | README says MIT, **no LICENSE file** | UNVERIFIED | Same author as Atoll; low risk, but the repo is formally unlicensed until a file is added. |
| Private Apple frameworks / APIs (SkyLight, MediaRemote, CoreBrightness, DisplayServices, OSD, IOReport, AppleSMC) | Apple, not redistributed | Not a copyright/licence issue (dynamic lookup of system symbols) | Contractual/App Store issue only. Not eligible for the Mac App Store. |
| Third-party logos / Apple product videos | See section 6 | Trademark/copyright issue, not a GPL issue | |

Other GPLv3 mechanics for a rebuild you give to others (OBSERVED requirement; INFERRED application): provide corresponding source for the exact build (including your changes), keep `LICENSE`, `NOTICE`, copyright headers, state that you changed the files (section 5(a)), and do not impose extra restrictions. Binary blobs you distribute (Sparkle, Lottie, MediaRemoteAdapter) must have source offered or be "System Libraries"/separately licensed components; for Sparkle and Lottie the sources are public, for MediaRemoteAdapter the upstream source is public but the exact commit used is UNKNOWN.

---

## 6. Asset copyright and trademark analysis

### 6.1 What the repo says (OBSERVED)

- `COPYRIGHT_ASSETS`: "Unless otherwise noted, the original assets created specifically for Atoll ... are Copyright (C) 2024-2026 Atoll Contributors." Third-party assets "retain their original licenses and copyrights; see NOTICE and any THIRD_PARTY_LICENSES files". It does **not** state a licence for Atoll's original assets. Because `LICENSE` is GPL-3.0 for the repository, INFERRED: assets in the repo are most plausibly GPL-3.0 by default, but `COPYRIGHT_ASSETS` states only a copyright, not a grant. Treat asset reuse outside Atoll as UNVERIFIED and ask the maintainers.
- `TRADEMARKS`: "Atoll and DynamicIsland are trademarks of their respective owners" (no named owner), "not associated with ... Apple or Apple's 'Dynamic Island' product". It grants no trademark licence either way.
- `NOTICE`: boring.notch derivation (GPL-3.0) and `FingerprintScan.json` "by Eddy Gann, downloaded from LottieFiles and used under the Lottie Simple License".

### 6.2 Asset inventory

| Asset | Where | Provenance evidence | Status |
|---|---|---|---|
| `FingerprintScan.json` | `LottieAnimations/` | NOTICE: Eddy Gann, LottieFiles Lottie Simple License (the JSON itself has `nm: "Print Scan JSON"`, no author meta) | Licence named in NOTICE; **terms of the Lottie Simple License not verified here** (UNVERIFIED). That licence allows free use but is not an open-source licence; redistribution of the raw JSON as a standalone asset may be restricted. Keep in the app; do not republish separately. |
| `Dog waiting.json`, `Moody Dog.json`, `Orange Cat Peeping.json`, `Reindeer.json`, `Lock.json` | `LottieAnimations/` (5 files) | JSON metadata: `Dog waiting` generated by "LottieFiles AE 3.0.2", name `TUTORIAL`; `Orange Cat Peeping` by `@lottiefiles/toolkit-js 0.33.2`, name `appy_present`; `Moody Dog` name `dog`; `Reindeer` name `polar bear`; `Lock` name `Unlock 2`. No author or licence recorded; **not mentioned in NOTICE**. | **UNKNOWN provenance, likely LottieFiles downloads (INFERRED).** Not covered by `COPYRIGHT_ASSETS` ("original assets created specifically for Atoll") unless the authors are Atoll contributors, which nothing indicates. Risk if redistributed. For private local use, low practical risk. |
| `lock.mp3`, `unlock.mp3`, `timer.mp3`, `lowbattery.mp3`, `dynamic.m4a`, `audio-feedback.m4a` | `Toplet/` | ID3/encoder tags only (Lavf58/60). `lowbattery.mp3` contains an embedded JSON blob from a mobile video editor ("product":"vicut", "os":"android"). Durations: 0.50 s, 0.52 s, 12.3 s, 1.23 s, 7.5 s, 0.03 s. | **UNKNOWN provenance/licence.** Lock/unlock sounds may imitate system sounds (INFERRED, unconfirmed). `lowbattery.mp3` was exported from a consumer video editor, so its source material is unidentified. Not in NOTICE. |
| `BluetoothHUDAnimations/*.mov` (8 files: AirPods, AirPods Gen 3, Gen 4, Max, Pro, Pro 3, Beats Solo, Beats Studio) | `Toplet/` | File names depict Apple/Beats products. Metadata not readable (`mdls` returned null). | **Likely Apple-derived imagery or look-alike renders (INFERRED; UNKNOWN origin).** Apple and Beats are trademarks; product imagery is generally Apple copyright. Not in NOTICE. Highest risk item for redistribution. |
| App icons | `Assets.xcassets/AppIcon*.appiconset` (stable, Alpha, Beta, Dev, Nightly) and `logo`, `logo2`, `ebullioscopic`, `.github/assets/atoll-logo.png`, `DynamicIslandSamples/logo.png` | Named `Atoll_1024*.png`; created for Atoll. | Atoll project branding ("Atoll"). See trademark rules below. |
| Third-party brand logos | `AmazonMusicLogo`, `CiderLogo`, `TidalLogo`, `YouTubeMusicLogo`, `Github` (GitHub Mark), `LinkedIn`, `LocalSend`, `chrome` (Google Chrome icon) | Third-party marks used for identification | Trademarks/copyrights of their owners. Used to identify supported services (nominative use). Do not rebrand them or imply endorsement. GitHub mark has its own usage guidelines. |
| `desktop.jpeg`, `glassdesktop` jpeg, `sparkle.svg`, `spotlight.svg`, `bolt.png`, `plug.png` | `Assets.xcassets` | No provenance recorded | UNKNOWN (wallpaper photos and icons). Check before redistribution. |
| `DynamicIslandSamples/` (30 MB: 8 PNG, 1 GIF) | repo root | Screenshots of the app. Not in the Xcode project (OBSERVED: no references in `project.pbxproj`). | Not shipped in the app. They may contain third-party content (wallpapers, album art) visible in screenshots (UNKNOWN). |
| Localization (`Localizable.xcstrings`, 2.6 MB; `tr.lproj`) | root and `Toplet/` | Text | Covered by repo licence; contributor attribution not recorded. |

### 6.3 What may and may not be redistributed or rebranded (INFERRED from the files above)

May (for a local or shared rebuild under GPL-3.0):
- Source code, including derived boring.notch / Stats / rtaudio parts, as long as notices and the correct licences are preserved (section 7).
- Atoll's own code-level strings and layout.

Should not, without further verification:
- Re-release the five unattributed Lottie JSON files, the audio files, the Bluetooth `.mov` product videos, or the third-party logos as standalone or "your own" assets. Replace or remove them in any public build.
- Present the build as the official "Atoll" or reuse the Atoll name, icon set, bundle id `com.Ebullioscopic.Atoll`, update feed or EdDSA key, or the `getatoll.app` / `ebullioscopic.github.io` links as if it were official. `TRADEMARKS` is vague, but the name and icon are the project's identity. A fork should rename and re-icon.
- Use Apple's "Dynamic Island", AirPods, Beats, or Apple Music marks in a way that suggests affiliation. `TRADEMARKS` itself disclaims affiliation with Apple.

Must:
- Keep `LICENSE`, `NOTICE`, `COPYRIGHT_ASSETS`, `TRADEMARKS` and the ReadMe acknowledgements intact when redistributing.

---

## 7. What a local-only rebuild may keep, and what must be preserved

### 7.1 May keep (private, on your own Mac)

For a build you run only yourself, GPL-3.0 imposes no distribution duties, and the practical risks are technical, not legal. Keep:

- All code-level dependencies that are linked: Defaults, KeyboardShortcuts, LaunchAtLogin, Lottie (+LottieUI), MacroVisionKit, SkyLightWindow, SwiftTerm, SwiftUIIntrospect, swift-collections, and Sparkle (if you want to keep the updater code, but see below).
- MediaRemoteAdapter framework, script and test client (core media feature).
- The rtaudio-derived visualizer, Stats-derived sensors, boring.notch-derived code.
- Private-API features (lock-screen windows, brightness/OSD, IOReport/SMC): they work only for local use and may break after macOS updates.
- Bundled assets for personal use.

### 7.2 Recommended changes for a clean local-only rebuild (not applied; this audit is read-only)

1. Remove the unused `open-meteo` and `Pow` package references (and their `Package.resolved` pins) so no AGPL server package is cloned or listed.
2. Disable Sparkle's upstream feed: delete `SUFeedURL` and `SUPublicEDKey` or turn off automatic checks, so your build is not offered the upstream DMG. Change `PRODUCT_BUNDLE_IDENTIFIER` (currently `com.Ebullioscopic.Atoll`; Debug is `.dev`) and the `com.ebullioscopic.Atoll.xpc` mach-service name if you do not want to collide with an installed official Atoll.
3. Turn off, by default, network-dependent features you do not want: weather (Open-Meteo/wttr.in), lyrics (lrclib, NetEase), Spotify canvas/secrets, AI assistant, LLM usage tracking (reads local credentials), remote `pricing.json` fetch, remote Lottie URL.
4. Consider reverting `NSAllowsArbitraryLoads` to a narrower ATS configuration.
5. Remove the dead duplicate `mediaremote-adapter/MediaRemoteAdapter.framework` copy.

### 7.3 Must be preserved if you share or publish the rebuild

- `LICENSE` (GPL-3.0), `NOTICE` (boring.notch GPL-3.0; Eddy Gann Lottie Simple License), `COPYRIGHT_ASSETS`, `TRADEMARKS`, the ReadMe acknowledgements.
- All source-file headers, including "Originally from boring.notch project", "Adapted from SwiftTerm" and the rtaudio "Original work Copyright (C) 2026 ZephyrCodesStuff" line. Do not strip them.
- The BSD-3-Clause header in `mediaremote-adapter.pl` and, in any binary redistribution, the BSD-3-Clause text for the MediaRemoteAdapter framework and test client.
- Third-party licence texts to add (they do not exist in the repo today): MIT for Defaults, KeyboardShortcuts, LaunchAtLogin-Modern, LottieUI, MacroVisionKit, SkyLightWindow, SwiftTerm (with its xterm.js / SourceLair / Jeffrey notices), swiftui-introspect, **Stats** (Serhiy Mytrovtsiy); Sparkle's MIT + external-licence text; Apache-2.0 for Lottie, swift-collections, swift-syntax; **AGPL-3.0 notice for the rtaudio-derived files**; BSD-3 for MediaRemoteAdapter.
- Corresponding source for the exact build you ship, including your modifications, plus a statement that files were changed.
- Open-Meteo data attribution (CC BY 4.0) if the weather feature is shipped.

---

## 8. Binary / prebuilt items that cannot be rebuilt from source here

"Cannot be rebuilt here" means the repo does not contain the source or a build recipe, or SwiftPM consumes a prebuilt artefact.

| # | Item | Location | Why it cannot be rebuilt from this repo | Source exists elsewhere? |
|---|---|---|---|---|
| 1 | `MediaRemoteAdapter.framework` (universal x86_64 / arm64 / arm64e; ad-hoc signed) | `Frameworks/` | No sources or CMake in the repo; no recipe in `scripts/` or CI. Upstream commit used is UNKNOWN. | Yes: `github.com/ungive/mediaremote-adapter` (CMake, Objective-C, BSD-3-Clause). Atoll's copy is older than current `master` (script diff), so a rebuild must pair framework and script from the same upstream commit. |
| 2 | Duplicate of #1 | `mediaremote-adapter/MediaRemoteAdapter.framework/` | Same; unreferenced duplicate. | Same. |
| 3 | `NowPlayingTestClient` (arm64-only) | `Contents/Helpers/` | No sources in repo. | Yes, test client target in the same upstream project. |
| 4 | **Sparkle 2.7.0** | resolved by SwiftPM as `Sparkle-for-Swift-Package-Manager.zip`, sha256 `a1fb05c4fd6b73bc351f4d326e6171473b7a99b7f2bfa8f5f69f7281f66dc387` | Binary target; SwiftPM downloads the release zip, not source. Includes Sparkle's XPC services and `Autoupdate`, `Updater.app`. | Yes: `sparkle-project` source at tag 2.7.0 (build separately). |
| 5 | **Lottie 4.5.2 XCFramework** | via `lottie-spm`, `Lottie.xcframework.zip`, sha256 `92206ff6af80373903767214ac16215838f6da11dedca789c0439299b46b6694` | Binary target, built by Airbnb with Xcode 15.2. | Yes: `airbnb/lottie-ios` 4.5.2 as a source package. |
| 6 | Audio: `lock.mp3`, `unlock.mp3`, `timer.mp3`, `lowbattery.mp3`, `dynamic.m4a`, `audio-feedback.m4a` | `Toplet/` | Encoded media, no project files. Provenance UNKNOWN. | UNKNOWN |
| 7 | Video: 8 Bluetooth HUD `.mov` files | `Toplet/BluetoothHUDAnimations/` | Encoded media. Provenance UNKNOWN. | UNKNOWN |
| 8 | Raster/vector art: app icons (5 sets), logos, `desktop.jpeg`, `glassdesktop` jpeg, SVG/PNG icons; `DynamicIslandSamples/*` (PNG, GIF) | `Assets.xcassets`, `DynamicIslandSamples/` | Exported images, no layered sources in repo. | Possibly with the author; UNKNOWN |
| 9 | Lottie JSON (6 files) | `LottieAnimations/` | These are exports; the After Effects sources are not in repo. They are text and editable, but the originals are not here. | LottieFiles (for those from there) |
| 10 | Release artefacts referenced by `Updates/appcast*.xml` (DMGs hosted on GitHub Releases, EdDSA signatures) | external | Built and signed with the maintainer's Developer ID and Sparkle key. | Build from source yourself; signatures cannot be reproduced without the private key. |
| 11 | Apple private frameworks (`MediaRemote`, `SkyLight`, `CoreBrightness`, `DisplayServices`, `OSD`, `IOReport`) | `/System/Library/PrivateFrameworks` | Provided by macOS; headers/interfaces are re-declared in Atoll or its dependencies. | Apple only |

Items 4 and 5 can be replaced by source builds if you want a fully source-built chain; items 1-3 need the upstream `ungive/mediaremote-adapter` source and a decision on which commit to match.

---

## 9. Open questions (UNKNOWN)

- Exact upstream commit of the committed `MediaRemoteAdapter.framework` and `NowPlayingTestClient`.
- Authorship and licence of the five unattributed Lottie files, six audio files, eight Bluetooth `.mov` files, `desktop`/`glassdesktop` images and miscellaneous icons.
- Terms of the "Lottie Simple License" as applied to `FingerprintScan.json` (named in NOTICE, text not fetched).
- Why `Package.resolved` omits the server dependencies of `open-meteo` (Vapor etc.).
- How closely `SMC.swift`, `IOReportBridging.swift` and `CPUSensorCollector.swift` match Stats (no diff done).
- Whether `AtollExtensionKit` is intended to be MIT (README only).
- Which source files, if any, copy code from DynamicNotch or OpenUsage.
- Runtime behaviour: nothing was built or run; feature-offline claims are based on code layout and URL inventory.
