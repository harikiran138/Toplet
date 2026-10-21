# Toplet: security and license/provenance audit

- Repository: `Atoll-ai` worktree of `Ebullioscopic/Atoll` (`git remote -v`). Upstream base commit is `f039ca9`; the fork's commits are by `harikiran138`.
- Date: 2026-10-21. Method: read-only. Nothing was built, run, edited (other than this file) or committed.
  - The only network access was reading public license metadata from `api.github.com/repos/<owner>/<repo>`.
  - Line numbers come from `grep -n` / `cat -n` on the working tree.
- **The working tree changed while this audit ran.** Between 16:19 and 16:44 IST, other edits landed in `Info.plist`, `DynamicIslandApp.swift`, `ClaudeQuotaClient.swift`, `SoftwareUpdater.swift`, `UpdateChannel.swift`, `AtollUpdaterDelegate.swift` and other files (`stat` mtimes).
  - Findings were re-checked at 16:44. Where a problem was fixed during the audit, it is marked **FIXED DURING AUDIT** and the residual risk is listed.
  - Re-check every line number below against the commit you publish.
- This is not legal advice. Points marked **needs a lawyer** are ones where the answer depends on facts or law I cannot settle from the code.

Contents: A. License and provenance (A1-A4) · B. Security (B5-B10) · C. Prioritised findings.

---

## A. License and provenance

### A1. Project license, how GPL-3.0 applies, and the MIT question

What the repository says:

- `LICENSE:1-2` is the unmodified GNU GPL v3 text.
- Upstream headers say "version 3 of the License, or (at your option) any later version". Examples: `AtollAgents/Core/AgentSocketServer.swift:5-8`, `Toplet/managers/TerminalManager.swift:6-9`. A grep counts 774 header lines reading `Copyright (C) 2024-2026 Atoll Contributors`.
- `NOTICE:3-6`: Toplet is a fork of Atoll, "keeps that license", and Toplet changes are "Copyright (C) 2026 Toplet Contributors". `NOTICE:11-14` keeps upstream's statement that Atoll is derived from boring.notch (GPL-3.0).
- `ReadMe.md:139-142`: "the whole project, including your contributions, stays under GPL-3.0". `CONTRIBUTING.md:61`, `:83-84` and `:103` say the same for contributions.
- Public GitHub metadata: `Ebullioscopic/Atoll` = GPL-3.0, `TheBoredTeam/boring.notch` = GPL-3.0.
- `git log`: 861 commits by the upstream maintainer, plus at least 15 other upstream authors (for example 280, 199 and 57 commits). The fork adds 33 commits by `harikiran138`.
  - `AtollAgents/` and `AtollNotch/` are not tracked yet (`git ls-files` is empty).
  - Their synced copies, `Toplet/managers/Agents/*`, have only `harikiran138` in `git log`.

How GPL-3.0 applies to Toplet:

- Toplet is a "work based on" Atoll and boring.notch (GPL-3.0 section 0).
- Section 5(c): the modified work "as a whole" must be licensed under GPL-3.0 to everyone who receives it.
- Section 5(a): modified files must say they were changed (the `TopletProject.swift:2-4` header pattern does this).
- Section 6: every binary you distribute (DMG, zip, cask) needs the Corresponding Source for that exact build.
- Only copyright holders can relicense. Making the whole project MIT would need written consent from every Atoll and boring.notch contributor, plus the rtaudio author for the AGPL files (A2). That is not realistic.

What could carry MIT:

| Part | Can it be MIT? | Reason |
|---|---|---|
| Toplet as a whole (source tree or any binary) | **No** | It contains and modifies GPL-3.0 code (sections 5-6). |
| Your edits inside existing Atoll / boring.notch files (228 files under `Toplet/` differ from `f039ca9`, `git diff --stat`) | **No** | A modified GPL file stays GPL. You can release those lines only as part of the GPL file. |
| App-integrated copies of the agents module (`Toplet/managers/Agents/*`, `Toplet/components/Notch/Agents/*`) | **Uncertain; needs a lawyer** | They are compiled into the GPL app and partly rewired to call app code (`local/agents-compat.sh:7-18`). Whether code written only to plug into a GPL program is itself "based on" it is unsettled. If a file contains no upstream code, you can dual-license it MIT and GPL. The app still ships as GPL either way. |
| Stand-alone `AtollAgents/` and `AtollNotch/` sources | **Plausibly yes, for your own copyright** | They import only Apple frameworks (Foundation, SwiftUI, AppKit, Combine, Darwin, ImageIO, CoreGraphics, CoreFoundation, from a grep of `import` lines). They compile alone (`AtollAgents/Tests/run_core.sh:15-16` uses plain `swiftc`). `NOTICE:23-27` says no third-party source was copied. If that is true and you are the only author, you may offer these files under MIT. |
| New docs, `local/*.py` / `*.sh` build scripts, `docs/branding/` icon | Yes, if wholly yours | `local/tools/rebrand.py` and `local/prepare.py` are yours. The upstream sources they patch are not. |

Fix these before you put MIT on any file:

1. **The headers misattribute the new code.**
   - `AtollAgents/Core/AgentSocketServer.swift:2-3`, and all other `AtollAgents/` and `AtollNotch/` files, carry "Atoll (DynamicIsland) / Copyright (C) 2024-2026 Atoll Contributors". `git log` shows this code was written for the fork.
   - Four files have no header at all: `AtollAgents/UI/AgentsDashboardView.swift`, `AtollAgents/Core/AgentUsageHistory.swift`, `AtollAgents/Core/AgentDashboard.swift`, `AtollAgents/Tests/CoreTestsDashboard.swift`.
   - Correct the copyright line before any relicensing.
2. **Check the provenance.** The research notes name GPL-3.0 open-vibe-island and Apache-2.0 claude-island as studied (`docs/AI-AGENTS-RESEARCH.md:38-40`), and describe Open Island's hook, socket and terminal-jump design in detail (`:52`). Ideas are free. Copied or closely translated code keeps its original license. Compare `TerminalJumper.swift`, `HookCommand.swift` and `AgentSocketServer.swift` against those projects before marking them MIT.
3. **AI-assisted authorship.** Where code was mostly generated by an AI tool, the strength of the copyright claim (and so of any license grant) is unsettled in several jurisdictions. **Needs a lawyer** if it matters commercially.
4. **Inbound license for contributors.** `CONTRIBUTING.md:103` says contributions are GPL-3.0. If some files are to stay MIT, state that contributions to files headed `SPDX-License-Identifier: MIT` are MIT-licensed, or use a DCO.

Suggested README "License" text (replaces `ReadMe.md:137-142`):

> Toplet is free software under the GNU General Public License v3.0 (`LICENSE`). It is a fork of Atoll and contains code from boring.notch, both GPL-3.0, so Toplet as a whole, and every build of it, is distributed under GPL-3.0. A few files written only for Toplet, marked `SPDX-License-Identifier: MIT` in their header (currently the stand-alone `AtollAgents/` and `AtollNotch/` modules), are also available under the MIT License for reuse on their own; that does not change the license of the app. Third-party components keep their own licenses; see `NOTICE` and `THIRD_PARTY_LICENSES`.

**Conclusion.** Toplet must be published and distributed as GPL-3.0.

- MIT is possible only as an extra permission on files you wrote entirely yourself that contain no upstream code. The stand-alone `AtollAgents/` and `AtollNotch/` modules are the realistic candidates, once their headers are corrected and their provenance checked.
- The app-integrated glue is a grey area (needs a lawyer).

### A2. Third-party code and dependencies

Vendored or adapted source in the tree:

| Component | Evidence | License (how verified) | GPL-3.0 compatible? | Attribution present? |
|---|---|---|---|---|
| boring.notch | 89 files say "Originally from boring.notch project" (`grep -rl`). `SettingsView.swift:5` "Created by Richard Kunkli". | GPL-3.0 (GitHub API) | Yes, same license | `NOTICE:11-14`, `ReadMe.md:124`. Upstream copyright lines were replaced by "Atoll Contributors"; restoring the original holders is good practice (GPL sections 4-5). |
| rtaudio (ZephyrCodesStuff) | `Toplet/audio/AudioTap.swift:3-4`, also `AudioProcessor.cpp:3`, `AudioProcessor.hpp:3`, `AudioBridge.h:3`, `AudioBridge.mm:3`, `RealTimeAudioSpectrum.swift:3` | **AGPL-3.0** (GitHub API `spdx_id`; also `docs/DEPENDENCY-AND-LICENSE-AUDIT.md:20`) | Yes, combinable (GPL-3.0 section 13 / AGPL-3.0 section 13). The AGPL terms keep applying to those files. | **Defective.** The headers grant GPL-3.0 (`AudioTap.swift:9-12`); a downstream project cannot switch AGPL to GPL. Not in `NOTICE`. Fix the six headers to AGPL-3.0-or-later, add a NOTICE entry, or get written permission from the author. |
| Stats (exelban), SMC / IOReport / CPU sensors | `ReadMe.md:126` credit; upstream ReadMe called it the "source implementation" (`git show f039ca9:ReadMe.md:110`). Files: `Toplet/utils/SMC.swift`, `utils/IOReportBridging.swift`, `utils/CPUSensorCollector.swift`. | MIT, "Copyright (c) 2019 Serhiy Mytrovtsiy" (GitHub API; earlier audit) | Yes | **Missing.** MIT requires its notice in copies of substantial portions, and no MIT text exists in the repo. Add it to the three files and to `THIRD_PARTY_LICENSES`. Not diffed against Stats. |
| SwiftTerm | `Toplet/managers/TerminalManager.swift:4` "Adapted from SwiftTerm"; package vendored and patched in `local/.work/vendor/SwiftTerm/LICENSE` | MIT (Miguel de Icaza, xterm.js authors, SourceLair, Christopher Jeffrey) | Yes | The header credit is there, but the MIT text is not shipped with the app. |
| SkyLightWindow | Package (`project.pbxproj:1012-1015`); vendored and patched `local/.work/vendor/SkyLightWindow/LICENSE` | MIT, "Copyright (c) 2025 Lakr Aream" | Yes | `ReadMe.md:128` credit only. |
| DynamicNotch (battery HUDs) | Upstream ReadMe: "thanks DynamicNotch for letting us use their battery huds" (`git show f039ca9:ReadMe.md:120`). No source file names it (grep). | GPL-3.0 (GitHub API) | Yes | ReadMe credit only. Which files derive from it is UNKNOWN. |
| OpenUsage | `Toplet/managers/LLMUsage/Quota/CodexQuotaClient.swift:4` "request+response shape per OpenUsage" | MIT (GitHub API) | Yes | ReadMe credit. Reusing an API shape is not copying code; if code was copied, add the MIT notice. |
| mediaremote-adapter (framework, Perl script, `NowPlayingTestClient`) | `mediaremote-adapter/mediaremote-adapter.pl:2-3` "Copyright (c) 2025 Jonas van den Berg … BSD 3-Clause"; binaries in `Frameworks/`, `mediaremote-adapter/`, `Contents/Helpers/` | BSD-3-Clause (GitHub API) | Yes | Script header kept. BSD-3 requires the notice in the **documentation of binary redistributions**, and none ships. The exact upstream commit of the prebuilt binaries is UNKNOWN (`docs/DEPENDENCY-AND-LICENSE-AUDIT.md:23`). `mediaremote-adapter/MediaRemoteAdapter.framework` is an unreferenced duplicate. |
| Wick timer design (Nate) | `ReadMe.md:132`; upstream ReadMe says permission was given | Design permission, not a code license | n/a | Credit only. Permission is said to be informal. Keep the credit; get it in writing if you rely on it. |
| Alcove | `ReadMe.md:125` "inspiration" | Proprietary product | n/a (ideas only) | Fine as an inspiration credit. |

SwiftPM dependencies. Xcode references are at `Toplet.xcodeproj/project.pbxproj:972-1071`. The local build manifest is `local/.work/Package.swift:19-31`, with pins in `local/.work/Package.resolved`. Licenses were read from `local/.work/.build/checkouts/*/LICENSE*` and `local/.work/vendor/*/license`:

| Package | Pin / kind | License (file read) | Notes |
|---|---|---|---|
| Defaults, KeyboardShortcuts (vendored and patched) | `local/.work/vendor/*`; Xcode `upToNextMajor` (`pbxproj:1044-1055`) | MIT, Sindre Sorhus | Compatible. |
| LaunchAtLogin-Modern | branch `main` (`pbxproj:980-983`), rev `a04ec1c3` | MIT, Sindre Sorhus | Branch-pinned. |
| LottieUI | branch `main` (`pbxproj:1060-1063`) | MIT, "Copyright (c) 2022 jasu" | Pulls lottie-spm `main`. |
| lottie-spm / Lottie 4.5.2 | branch `main`, rev `04f2fd18` (`local/.work/Package.resolved`) | Apache-2.0 | Prebuilt binary xcframework. Keep the Apache text and any NOTICE. |
| MacroVisionKit | 0.1.0 (`pbxproj:972-975`) | MIT, "Copyright (c) 2024 github.com/theboringhumane" | |
| Sparkle 2.7.0 | `pbxproj:988-991` | MIT plus bundled BSD / zlib-style notices (`checkouts/Sparkle/LICENSE`) | Prebuilt binary. Ship its LICENSE. |
| swift-collections | `pbxproj:1068-1071` | Apache-2.0 with Runtime Library Exception | |
| swiftui-introspect | `pbxproj:1036-1039` | MIT, "Copyright 2019 Timber Software" | |
| SwiftTerm | `pbxproj:1020-1023`; vendored and patched | MIT | |
| SkyLightWindow | branch `main` (`pbxproj:1012-1015`); vendored and patched | MIT | Private SLS APIs (B9). |
| **AtollExtensionKit** | branch `main` (`pbxproj:1004-1007`), rev `e2d30af` (2026-03-16) | **Unclear.** At the pinned revision there is no LICENSE file (`ls checkouts/AtollExtensionKit`), while `README.md:469-471` says MIT. Upstream added a LICENSE on 2026-03-19 (commit `296562051f`), and GitHub now reports **LGPL-3.0**. | Either way it is GPL-3.0 compatible. Pin a revision that has the LICENSE file and record LGPL-3.0. It is upstream-owned infrastructure (B5). |
| open-meteo (server, AGPL-3.0) and Pow (MIT) | `pbxproj:996-999`, `:1028-1031` | — | Referenced but **not linked** (absent from `local/.work/Package.swift:19-31`). Remove both references so SBOM tools do not report an AGPL component. |

Gaps across the table:

- `ReadMe.md:135` says "Third-party notices are in NOTICE", but `NOTICE` has none of the MIT, BSD or Apache texts.
- `COPYRIGHT_ASSETS:7-8` points to "THIRD_PARTY_LICENSES files", which do not exist.
- Add a `THIRD_PARTY_LICENSES` file with the full texts listed above: MIT for Defaults, KeyboardShortcuts, LaunchAtLogin, LottieUI, MacroVisionKit, SkyLightWindow, SwiftTerm, swiftui-introspect and Stats; Sparkle's MIT plus its external notices; Apache-2.0 for Lottie and swift-collections; BSD-3 for mediaremote-adapter; the AGPL notice for rtaudio; LGPL for AtollExtensionKit.
- Copy that file into `Contents/Resources` of every build.

### A3. Assets: images, logos, Lottie, sounds, video, fonts

| Asset | Location | Status | Action |
|---|---|---|---|
| Toplet icon (owner-supplied) | `docs/branding/toplet-icon-1024.png`, `toplet-icon-source.webp`; used as `Assets.xcassets/AppIcon.appiconset/Toplet_*.png`, `logo2.imageset/Toplet_1024.png` | Stylised sailing ship with a blank pennant. Not a Jolly Roger and not a known ship design (inspected visually). No embedded generator or C2PA metadata (`strings` found none). | Record its origin (who made it, and the tool's terms if AI-generated). Fine to ship. |
| Alpha / Beta / Dev / Nightly icons | `Assets.xcassets/AppIcon{Alpha,Beta,Dev,Nightly}.appiconset/*` | **Still Atoll's ring icon** (inspected `AppIconNightly…/icon_128x128.png`). `release.yml` selects them per channel (`ASSETCATALOG_COMPILER_APPICON_NAME`, `:271-274`, `:304`). | Replace them, or point all channels at the Toplet icon, before any non-stable build. |
| Upstream author logo | `Assets.xcassets/ebullioscopic.imageset/819b…png`, shown on the welcome screen (`components/Onboarding/WelcomeView.swift:78-85`) | Upstream maintainer's brand on Toplet's first-run screen | Remove it, or move it to a clearly labelled "based on Atoll by Ebullioscopic" credit in About. |
| `.github/assets/atoll-logo.png`, `iosdevcentre.jpeg` | `.github/assets/` | Atoll branding, and a third-party image of unknown origin | Remove if not used by the README. |
| Third-party brand logos: `AmazonMusicLogo`, `CiderLogo`, `TidalLogo` (SVG), `YouTubeMusicLogo`, `Github` (GitHub Mark), `LocalSend` | `Toplet/Assets.xcassets/*.imageset` | Trademarks and copyrighted logos of their owners. Used only to label integrations (nominative use). `TRADEMARKS:10-11` disclaims ownership. | Low risk if kept small, unmodified and next to the service name, with no suggestion of endorsement. Check each brand's guidelines (GitHub and Spotify publish theirs). **Not to be redistributed separately or used as Toplet branding.** No Spotify logo file exists; only the name is used. |
| Lottie: `FingerprintScan.json` | `LottieAnimations/` | Eddy Gann, LottieFiles "Lottie Simple License" (`NOTICE:16-19`) | Keep the NOTICE entry; do not republish the JSON on its own. |
| Lottie: `Dog waiting.json`, `Moody Dog.json`, `Orange Cat Peeping.json`, `Reindeer.json`, `Lock.json` | `LottieAnimations/` | **Provenance unknown.** Probably LottieFiles downloads; no author or license is recorded, and they are not in NOTICE (`docs/DEPENDENCY-AND-LICENSE-AUDIT.md:171`). | Find the sources and licenses, or replace them before publishing. |
| Remote Lottie | `components/Music/LottieAnimationView.swift:29` loads `assets9.lottiefiles.com/packages/lf20_mniampqn.json` | Fetched at run time, not redistributed | License unknown; prefer a bundled asset that is licensed. |
| Sounds: `lock.mp3`, `unlock.mp3`, `timer.mp3`, `lowbattery.mp3`, `dynamic.m4a`, `audio-feedback.m4a` | `Toplet/` | **Provenance unknown.** `lowbattery.mp3` contains metadata from a consumer video editor (`docs/DEPENDENCY-AND-LICENSE-AUDIT.md:172`). | Find out where they came from, or replace them with your own or CC0 sounds. |
| Bluetooth HUD videos (AirPods, AirPods Pro/Max/Gen3/Gen4/Pro 3, Beats Solo/Studio) | `Toplet/BluetoothHUDAnimations/*.mov`; forced into the bundle by `release.yml` "Copy BluetoothHUD Animations" (`:318-345`) | **Highest-risk asset.** They show Apple and Beats products and are likely Apple-derived renders (INFERRED; origin unknown). | Do not redistribute until you have permission. Replace them with generic glyphs or SF Symbols (`airpods`, `airpodspro`, `beats.headphones`). |
| Wallpapers and icons: `desktop.jpeg`, `glassdesktop` (an iPhone photo export, judging by the `…_1_201_a.jpeg` name), `sparkle`, `spotlight`, `bolt`, `plug` | `Assets.xcassets` | Unknown origin | Check them, or replace. |
| `DynamicIslandSamples/` (screenshots, GIF) | repo root | Not in the app bundle. May show third-party wallpapers or album art. | Replace with your own screenshots. |
| Fonts | — | None bundled (no `.ttf`, `.otf` or `.woff` found) | — |
| `dist/` | contains `Atoll.app` and `Toplet.app` | Ignored by git (`.gitignore:173`) | Never commit or attach it. `dist/Atoll.app` still carries upstream's Sparkle feed and key. |

Trademarks and fork identity:

- `TRADEMARKS:3-6` says forks "should use their own name and icon" and that "Atoll" and "Toplet" belong to upstream (`:10-11`).
- A separately named fork must not present itself as Atoll. The following still do:
  - Channel icons (above), the welcome-screen logo (`WelcomeView.swift:78`), and "Made with ❤️ by Ebullioscopic" (`components/Settings/SettingsView.swift:4273`).
  - Donation link `buymeacoffee.com/kryoscopic` (`strings/constants.swift:22`, opened at `SettingsView.swift:4195`).
  - Upstream privacy policy `ebullioscopic.github.io/Toplet/privacy-policy` (`Onboarding/WelcomeView.swift:64`, `OnboardingFinishView.swift:65`). It describes upstream's data practices, not Toplet's.
  - `getatoll.app/marketplace` (`components/Settings/ExtensionsSettings.swift:72`, `:81`).
  - Keychain services `com.Ebullioscopic.Atoll.*` (`MediaControllers/CiderTokenStore.swift:25`, `managers/Spotify/SpotifyTokenStore.swift:39`, `managers/LLMUsage/NewAPIUsage.swift:38`).
  - Mach service `com.ebullioscopic.Atoll.xpc` (`Toplet.entitlements:11`).
  - Logger subsystem `com.atoll.DynamicIsland` (`Quota/CodexQuotaClient.swift:6`).
  - `release.yml:30` `APP_NAME: Atoll` and the "Atoll-XML-Updater[bot]" identity (`release.yml:632`, `:678`).
  - `Updates/appcast*.xml`, upstream's signed release history (`Updates/appcast.xml:4-11`).
- Crediting upstream is correct and required. Presenting its brand as yours is not. `TopletProject.swift:35-36` (`upstreamURL` used as a credit) is the right pattern.

### A4. Protected character IP (One Piece, Jolly Roger, and similar)

**None found.**

- A case-insensitive grep of `Toplet/`, `AtollAgents/`, `AtollNotch/`, `LottieAnimations/`, `docs/` and `ReadMe.md` (Swift, JSON, Markdown and string catalogs) for One Piece names (Luffy, Zoro, straw hat, Jolly Roger, Going Merry, Thousand Sunny, Mugiwara) and other franchises (Pokémon, Mario, Disney, Marvel, Ghibli, Sanrio, Naruto, Minecraft) returns only unrelated matches such as `renamingSection`.
- The Toplet icon is a generic ship with a blank flag (A3).
- The ReadMe tagline "One little ship" (`ReadMe.md:144`) is generic.
- The Lottie animations are a dog, a cat, a reindeer, a lock and a fingerprint, none of which belong to a franchise.

---

## B. Security

The app is **not sandboxed**: `project.pbxproj:791` sets `ENABLE_APP_SANDBOX = NO`, and `Toplet/Toplet.entitlements:1-28` has no `app-sandbox` key. Every primitive below therefore runs with the user's full rights.

### B5. Local IPC surfaces

**B5.1 Extension WebSocket RPC server: Critical.** File: `Toplet/services/Extensions/ExtensionRPCServer.swift` and `ExtensionRPCService.swift`.

Who can connect:
- It binds `127.0.0.1` and `::1` only (`ExtensionRPCServer.swift:87-90`, `:102-110`), port 9020 (`:92`), with a loopback peer check. The LAN is excluded.
- **Any local process** can connect, including sandboxed App Store apps that have `network.client`.
- **Probably a web page in the user's browser** too: `ws://127.0.0.1` is reachable from pages, and newer Chrome local-network prompts may or may not gate it (not tested).
- It starts unconditionally at launch (`DynamicIslandApp.swift:754`).

Authentication:
- None, and no `Origin` check. Only the WebSocket options at `ExtensionRPCServer.swift:104-106` are set; a grep for `Origin` or a token finds nothing.
- The client chooses its own identity (`params.bundleIdentifier`).
- `atoll.requestAuthorization` then approves it: "Auto-authorize for now" (`ExtensionRPCService.swift:151-152`).
- The relevant defaults are all `true`: `enableThirdPartyExtensions`, `enableExtensionNotchInteractiveWebViews`, `enableExtensionFileSharing` (`models/Constants.swift:1395`, `:1401`, `:1408`).

Impact:
1. **Read any file the user can read.**
   - `addFilesToShelf` with `paths` bookmarks any existing path (`ExtensionRPCService.swift:544-559`).
   - `getShelfItemData` returns the file's bytes (`:436-445`).
   - Example: `~/.ssh/id_*`, or `~/.claude/.credentials.json`.
2. **Write any file through path traversal.**
   - `fileName` from the client is joined with `appendingPathComponent(fileName)` and written with no checks (`:567-574`).
   - Example: `../../../../Users/<u>/Library/LaunchAgents/x.plist`, which gives persistent code execution at next login.
3. **Read the shelf, then watch it.** `getShelfItems` returns the current shelf, and `subscribeShelfEvents` streams later changes.
4. **Show prompts and fake content.** It can open an `NSOpenPanel`, start a share, and inject HTML notch or lock-screen content that looks like any app.

Fix:
- Off by default.
- A per-install random token, stored in a 0600 file and required on the first frame.
- Reject any request that carries a browser `Origin`.
- An explicit user consent prompt naming the peer process.
- Remove `paths`; accept only bytes.
- Sanitise `fileName` to `lastPathComponent`; reject `..`, `/` and empty names; write with `.withoutOverwriting`.
- Set a maximum message size.

**B5.2 Extension distributed notifications: High.** File: `Toplet/managers/Extensions/ExtensionEventBridge.swift`.

- It observes `com.ebullioscopic.Atoll.extensions.{liveActivity,lockScreenWidget,notchExperience}Snapshot` from any sender (`:134-146`, names at `:160-164`).
- The only check is that the `sourcePID` in `userInfo` is not the app's own pid (`:136-137`). The sender supplies that value.
- The payloads replace the state of the live-activity, widget and notch-experience managers without authorization or validation.
- With no payload attached, the app reloads `~/Library/Application Support/AtollExtensions/*.json` instead, and any same-user process can write those files.

Fix: remove this bridge, since the project builds no helper processes. Otherwise authenticate the sender and re-run authorization plus `ExtensionDescriptorValidator` on every payload.

**B5.3 Extension XPC: Medium-High.** File: `Toplet/services/Extensions/ExtensionXPCServiceHost.swift`.

- Listener `NSXPCListener(machServiceName: "com.ebullioscopic.Atoll.xpc")` (about `:25`, `:55-58`), started at `DynamicIslandApp.swift:753`.
- Peers are identified by `NSRunningApplication(processIdentifier:)` → bundle id. There is no `setCodeSigningRequirement` or audit-token check (grep finds none), so any app can claim any bundle id, and pid reuse is possible.
- A first-time request is approved without a prompt (`ExtensionXPCService.swift:55-61`, authorize at `:58`).
- XPC exposes UI content only, not files.
- The local build drops the mach-service entitlement (`local/assemble.py:93`). Whether the name is reachable at all without a launchd plist was not verified.
- Fix: `NSXPCConnection.setCodeSigningRequirement(...)`, user consent on first use, and a Toplet-named service.

**B5.4 LocalSend: Medium.** File: `Toplet/components/Shelf/Services/LocalSendService.swift`.

What it is:
- **Send only.** There is no upload receiver; the only server routes are `register` and `info` (`:675`, `:724`). Path traversal on received file names therefore does not apply.
- It opens a TCP listener on port 53317 on **all interfaces** (`:84-88`, `:602-612`) and joins UDP multicast `224.0.0.167:53317`.
- It runs while the shelf share view is open, plus about 30 s afterwards (`:84-121`).

Risks:
- TLS accepts any server certificate (`LocalSendTLSDelegate`, `:1041-1048`) and never pins it to the announced fingerprint.
- On `.secureConnectionFailed` it retries over HTTP (`:1007-1027`).
- Devices are keyed by a self-declared fingerprint, and the announced `ip` is trusted, so any LAN host can impersonate a known device and receive the files.
- It discloses the computer name on the LAN.

Fix: pin the certificate SHA-256 to the fingerprint; no HTTP fallback; use the packet's source address; require an explicit device choice.

**B5.5 Agent unix socket: Low (well built).** Files: `AtollAgents/Core/AgentSocketServer.swift`, compiled as `Toplet/managers/Agents/`.

- Off by default (`Constants.swift:1304`).
- Directories are created 0700 and checked to be non-symlink and owner-only (`:207-233`). The socket is created under `umask(0o177)`, re-checked with `lstat`, and forced to 0600 (`:153-171`).
- A stale socket is unlinked only after a refused connect probe (`:236-252`). On stop it unlinks only if inode and device still match (`:198-202`).
- `LOCAL_PEERCRED` uid must equal euid (`:275-281`, `:343-345`).
- Limits: 1 MiB per connection, 2 s read deadline, 64 connections, 16 pending approvals (`:45-48`).
- Clients cannot approve anything. Replies go only to the connection that asked (`:320-331`), and decisions are built server-side (`ApprovalBroker.swift:155-179`).
- What remains is same-user spoofing: fake sessions or prompts, or a spoofed `Stop` that cancels a pending approval (it fails safe to the terminal prompt). Optional: check `LOCAL_PEERPID` and its code signature.

**B5.6 Other distributed notifications: Low.**

- `com.apple.screenIsLocked` / `screenIsUnlocked` (`LockScreenManager.swift:141-154`), BetterDisplay OSD, brightness, IOBluetooth, Focus and Music/Spotify observers can all be spoofed by any process.
- The effect is cosmetic: HUDs, a lock chime. A fake lock is undone by checking the real lock state (`LockScreenManager.swift:356-385`).
- `BluetoothAudioManager.swift:265-272` observes `forName: nil` (every distributed notification), which is wasteful.

**B5.7 URL schemes, AppleEvents.**

- No `CFBundleURLTypes` in `Toplet/Info.plist`, so web pages have no URL-scheme entry point.
- `application(_:open:)` only adds files to the shelf (`DynamicIslandApp.swift:164-185`).
- The Spotify OAuth redirect uses `atoll-spotify://` (`SpotifyOAuthService.swift:34`). Rename it.

### B6. Credentials

| Credential | Code | Read / write | Storage of Toplet's copy |
|---|---|---|---|
| Claude Code OAuth (`~/.claude/.credentials.json`, then Keychain `Claude Code-credentials*`) | `managers/LLMUsage/Quota/ClaudeQuotaClient.swift:178-190` | **Read only as of 16:43** (`:192-200`: "Toplet never refreshes Claude Code's token or writes it back") | In memory (`ClaudeCredentialStore`) |
| Codex `auth.json` (`$CODEX_HOME`, `~/.codex`, `~/.config/codex`), Keychain `Codex Auth` | `Quota/CodexQuotaClient.swift:88-102` | Read only | In memory |
| Cursor `state.vscdb` (opened read-only), Keychain `cursor-access-token` | `Quota/CursorTokenStore.swift:6`, `:28-34` | Read only; also builds a `WorkosCursorSessionToken` cookie (`CursorQuotaClient.swift:42`) | In memory |
| Antigravity / Gemini CLI | `AntigravityUsageProvider.swift:79`: `/usr/bin/security find-generic-password -a antigravity -s gemini -w` (fixed argv). It also reads `csrf_token` from other processes' argv via `ps` (`:231`, `:323`). | Read only | In memory |
| Spotify `sp_dc` cookie, web-player token | Pasted by the user or captured from a non-persistent WKWebView (`SpotifyLoginSheet.swift:104`). No browser cookie DB is read. | — | **Plaintext UserDefaults** (`Constants.swift:1235-1236`) |
| AI assistant keys: Gemini, OpenAI, Claude, Groq | `Constants.swift:1385-1388` | — | **Plaintext UserDefaults** |
| Spotify OAuth, Cider token, New API keys | `SpotifyTokenStore.swift:39`, `CiderTokenStore.swift:25`, `NewAPIUsage.swift:38` | — | Keychain, `AfterFirstUnlock` |

Claude Code token write-back: **FIXED DURING AUDIT, with residue.**

- Earlier the same day, the client refreshed Claude Code's token. It used Claude Code's OAuth client id against `platform.claude.com/v1/oauth/token` and wrote the rotated pair back into Claude Code's file or Keychain item, with no lock shared with Claude Code. That races Claude Code's own refresh and can sign the user out of Claude Code.
- The current file is read-only (`ClaudeQuotaClient.swift:192-200`). Residue:
  1. `ClaudeKeychainStore.update` / `updateCommand`, which runs `security add-generic-password -U` (`KeychainReader.swift:87-108`), is still compiled but no longer called. Delete it so the write path cannot come back by accident.
  2. The usage request still presents itself as Claude Code: `User-Agent: claude-code/2.1.69` (`ClaudeQuotaClient.swift:141`). Use an honest `Toplet/<version>` UA.
  3. `KeychainReader.freshestGenericPassword` lists the metadata of **all** generic-password items (`KeychainReader.swift:26-37`, `kSecMatchLimitAll`) and filters in memory. Query by service instead.
- Ethics: reading another app's bearer token is acceptable only when opt-in and disclosed. `enableLLMUsageFeature` is off by default (`Constants.swift:1274`), which is good. Writing another app's credentials should not return.
- Onboarding should say plainly which other apps' tokens and transcripts (`~/.claude/projects`, `~/.codex/sessions`) Toplet reads.

Logging:
- No token values reach logs in the credential paths reviewed (`CodexQuotaClient.swift:36`, `:50`, `:64`, `:68` log status codes only).
- `utils/Logger.swift:105` marks every message `%{public}@`, so whatever is logged is readable in sysdiagnose and `log show`.
- `ScreenAssistantManager.swift:418` puts the Gemini key in the URL query (`?key=`). `:804` prints network errors, which may include that URL (unconfirmed). Move the key to an `x-goog-api-key` header.

Fix:
- Move the AI keys and `sp_dc` into the Keychain.
- Keep LLM usage opt-in.
- Delete the dead Claude write path.
- Stop impersonating Claude Code's user agent.

### B7. Command and script injection

There is no `sh -c`, `zsh -c`, `bash -c`, `osascript`, `system()`, `popen` or `posix_spawn` in the app sources (grep). All `Process` uses pass argv arrays. The interpolated `NSAppleScript` sites are:

| Site | Interpolated input | Escaping | Verdict |
|---|---|---|---|
| `managers/AppleMusicAirPlayManager.swift:123` (toggle) and `:217` (volume) | AirPlay device name; LAN devices choose their own names | Only `"` becomes `\"`; backslash and newline are not escaped | **Insufficient, Medium.** A name such as `x\" & (do shell script …) --` closes the string literal. The user must act on that device. Not exploited here. A 63-byte Bonjour limit constrains the payload. Fix: reuse `AppleScriptEscaper.literal`, or send an Apple Event with parameters. |
| `managers/AppleNotesSyncManager.swift:304`, `:319-321`, `:332` | Note title, HTML body, Notes id | `appleScriptEscape` handles `\`, `"`, CR and LF (`:377-384`), plus HTML escaping (`:359-374`) | Sufficient. |
| `managers/Agents/TerminalJumper.swift:288-340` (same as `AtollAgents/Core`) | tty, cwd from agent sessions | tty must match `^/dev/ttys[0-9]{1,5}$`; `AppleScriptEscaper.literal` escapes `\` and `"` and drops control characters (`:136-152`) | Sufficient. |
| `TerminalJumper.swift:175`, `:367` (tmux) | Targets parsed from `tmux list-panes` | argv; a leading `-` is rejected (`:166`) | Safe. |
| `AtollAgents/Hooks/HookCommand.swift:101-137` | Socket path written into `~/.claude/settings.json` / Codex hooks as an `nc -U` one-liner | Double-quoted, with `\ " $` and backtick escaped and control characters rejected. JSON escaping is complete (`OrderedJSON.swift:161-176`). No app path is embedded, so spaces are fine. | Sufficient. |
| `AppleMusicController.swift`, `SpotifyController.swift` scripts | Numbers, booleans, constants | n/a | Safe. |
| `SystemOSDManager.swift:107-110`, `:530-531`; `FullScreenArtworkWindowManager.swift:482-503` | Process names (constants) | argv | Safe, but see B9 on SIGSTOP. |
| `components/Shelf/Services/TemporaryFileStorageService.swift:149-216` (`zip`), `DynamicIslandApp.swift:1407-1410` | Names of dropped files | argv without `--` | Low: a file named `-T…` is read as an option. Add `--`. |
| `managers/TerminalManager.swift:291-298` | `Defaults[.terminalShellPath]` (`Constants.swift:1316`) | Executable path | By design; anything that can write the preferences chooses the shell. |

### B8. Network

No analytics, telemetry or crash-reporting SDK was found. A grep for Sentry, Firebase, Mixpanel, Amplitude, TelemetryDeck, PostHog, AppCenter, Crashlytics, Aptabase, Countly and Bugsnag over the source, `project.pbxproj` and both `Package.resolved` files matches only the word "amplitude" in an audio log line. There are no ping or usage POSTs. "Crash report" copies a local file to the clipboard (`SettingsView.swift:7081-7098`).

ATS is disabled app-wide: `NSAllowsArbitraryLoads = true` (`Info.plist:5-9`). Every hard-coded remote endpoint is HTTPS. Plain HTTP occurs only for loopback, LAN, artwork URLs (`ImageService.swift:63`) and URLs the user types (`NewAPIUsage.swift:166`; Ollama default `Constants.swift:1392`). Replace the blanket flag with `NSAllowsLocalNetworking` plus specific exceptions.

| Destination | Code | Trigger | Default | Data sent |
|---|---|---|---|---|
| `api.open-meteo.com`, `air-quality-api.open-meteo.com`; fallback `wttr.in` | `LockScreenWeatherManager.swift:615-632`, `:712-732`, `:798-810` | Launch, then every 30 min, and on settings changes | **On** (`Constants.swift:1090`, `:1100`) | **Latitude/longitude to 4 decimals (~11 m).** Round to 2. The CC BY attribution for Open-Meteo data is missing. |
| `itunes.apple.com/search?term=<title artist>` | `MusicManager.swift:229-239`, `:1311` | Every track change, from any Now Playing source | **On, no setting** | Track title and artist. Add a toggle. |
| `open.spotify.com/embed/track/<id>` | `SpotifyController.swift:520-528`, `MusicManager.swift:389` | Spotify track change | **On, no setting** | Track id, spoofed browser user agent |
| `api.music.apple.com`, `mvod.itunes.apple.com` | `AnimatedArtworkManager.swift:70`, `:117`, `:159-187` | Apple Music track change | On (`Constants.swift:1142`) plus MusicKit consent | Search terms, song id |
| `lrclib.net`, `music.163.com` (NetEase) | `MusicManager.swift:1909-1912`, `NetEaseLyrics.swift:49-103` | Track change | Off (`Constants.swift:1518`) | Title, artist |
| `raw.githubusercontent.com/Ebullioscopic/Atoll/dev/.../pricing.json` | `ModelPricingManager.swift:98`, `:138` | First cost calculation | Off (LLM usage off) | GET. **Upstream controls the data** (cost estimates only). Re-target it or bundle it. |
| `raw.githubusercontent.com/xyloflake/spot-secrets-go/.../secretDict.json`; `open.spotify.com/api/token`; `spclient.wg.spotify.com` | `SpotifyAuthManager.swift:36-38`, `:137-177`; `SpotifyController.swift:621-628` | Token refresh, Canvas | Only with `sp_dc` | A third party controls the TOTP secret. `sp_dc` goes to Spotify only (`SpotifyAuthManager.swift:157`). Unofficial scraping with spoofed user agents; Spotify ToS risk. |
| `accounts.spotify.com`, `api.spotify.com/v1` | `SpotifyOAuthService.swift:38-39`, `SpotifyLibraryAPI.swift:27` | User connects | Off | PKCE, tokens |
| `api.anthropic.com/api/oauth/usage`, `chatgpt.com/backend-api/wham/usage`, `api2.cursor.sh`, `cursor.com/api/usage-summary`, `cloudcode-pa.googleapis.com` | `ClaudeQuotaClient.swift:136-141`, `CodexQuotaClient.swift:39-45`, `CursorQuotaClient.swift:31-43`, `AntigravityUsageProvider.swift:615-660` | Every 5 min (`Constants.swift:1293`) | Off | Other apps' bearer tokens (B6) |
| `generativelanguage.googleapis.com`, `api.openai.com`, `api.groq.com`, `api.anthropic.com/v1/messages`, user's local endpoint | `ScreenAssistantManager.swift:418`, `:441`, `:470`, `:498`, `:509-522` | User sends a message | Needs a key | Prompt, screenshots, files. Gemini key in the query string. |
| `assets9.lottiefiles.com` | `LottieAnimationView.swift:29` | Music view, when the visualizer is off | Visualizer on by default (`Constants.swift:1039`) | GET |
| LocalSend multicast, /24 sweep, peers | `LocalSendService.swift:60-61`, `:307-319`, `:960-981` | Shelf share view appears | When the shelf is used | Computer name, device model, then files (B5.4) |
| Sparkle feed | `DynamicIslandApp.swift:46-50` | — | **Not started while there is no Toplet feed** (`:49`, fixed during audit) | — |
| Browser links only: `getatoll.app`, `ebullioscopic.github.io`, `buymeacoffee.com/kryoscopic`, `github.com/Ebullioscopic/Atoll` | A3 | User clicks | — | Upstream branding (A3) |

### B9. Entitlements, hardened runtime, private APIs, Sparkle, notarization

Entitlements (`Toplet/Toplet.entitlements`):

| Key | Lines | Assessment |
|---|---|---|
| `com.apple.security.cs.disable-library-validation` | 5-6 | Weakens hardened runtime: any dylib can be loaded into the process. `MediaRemoteAdapter.framework` is loaded by `/usr/bin/perl`, not by the app (`NowPlayingController.swift:271-276`). Test without the key once everything carries one Developer ID signature; drop it if nothing breaks. |
| `device.camera`, `automation.apple-events`, `personal-information.calendars` | 7-8, 13-16 | Match features (Mirror, Spotify/Music/Notes, terminal jump, calendar). |
| `mach-services` `com.ebullioscopic.Atoll.xpc` | 9-12 | Upstream name; collides with an installed Atoll. Rename it, or drop it along with B5.3. |
| `temporary-exception.apple-events`, `temporary-exception.mach-lookup.global-name` | 17-27 | Sandbox-only keys, inert in an unsandboxed app. Remove them. |
| Location | added only by `local/assemble.py:96` | Add `com.apple.security.personal-information.location` to the real entitlements file as well (needed under hardened runtime for weather). |

Hardened runtime is on for Debug and Release (`project.pbxproj:792`, `:868`) and in the local build (`local/assemble.py:158`).

Private APIs. They can break on any macOS update and exclude the Mac App Store:
- **MediaRemote**: loaded directly (`NowPlayingController.swift:54-68`), and on macOS 15.4+ through `perl` plus the BSD-3 adapter.
- **CGS / SkyLight**: `private/CGSSpace.swift:26-38`; `ScreenRecordingManager.swift:23-29` (`@_silgen_name("CGSIsScreenWatcherPresent")`, `CGSRegisterNotifyProc`); SkyLightWindow's `SLS*` calls.
- **CoreBrightness, DisplayServices, OSD** frameworks (`project.pbxproj:89-91`, `:847`).
- **IOReport / SMC** (`utils/IOReportBridging.swift`).

OSDUIHelper:
- `SystemOSDManager.swift:528-538` runs `/usr/bin/killall -STOP OSDUIHelper`.
- Elsewhere it uses `killall -9` (`:107-110`) and `launchctl kickstart` / `load -w` (`:124`, `:153`). Wallpaper processes are SIGSTOPped too (`FullScreenArtworkWindowManager.swift:482-503`).
- A crash while the helper is stopped leaves the system HUD frozen. The termination handler (`DynamicIslandApp.swift:311-314`) does not run on a crash, and only `local/smoke.sh:8` repairs it.
- Keep this opt-in, and SIGCONT any stopped OSDUIHelper at launch.

Sparkle: **FIXED DURING AUDIT, with residue.**
- At the start of the audit, `Toplet/Info.plist:20-23` still held upstream's `SUFeedURL` and `SUPublicEDKey`. Only `local/assemble.py:47-49` stripped them, so an Xcode-built Toplet would have started Sparkle against the Atoll appcast and accepted Atoll's EdDSA-signed DMGs. The reason: `AtollUpdaterDelegate.feedURLString` returns nil (`services/AtollUpdaterDelegate.swift:25-27`), which Sparkle treats as "use Info.plist".
- At 16:44 both keys are gone (`Info.plist:1-25`), and the updater is not started while `TopletProject.updatesFeedBase` is nil (`DynamicIslandApp.swift:47-50`, `TopletProject.swift:33`).
- Residue:
  1. `SoftwareUpdater.swift:69-72` still offers an "Automatically check for updates" toggle. Hide it while there is no feed.
  2. `Updates/appcast*.xml` are upstream's signed history. Delete them.
  3. Before enabling updates, generate your own key with Sparkle's `generate_keys`, put only the public key in Info.plist, and keep the private key in a protected CI environment.
  4. `SettingsView.swift:1139` creates a second, unstarted controller; harmless.

Developer ID and notarization, what is needed:
1. Your own Apple team. Replace `9Y64TRM77N` in:
   - `project.pbxproj:790`, `:866`
   - `ExportOptions.plist:7-8`
   - `.github/workflows/release.yml:31`
   - the identity "Developer ID Application: Hariharan Mudaliar" in `release.yml:362`, `:370`, `:377`, `:418`, which is the upstream maintainer's name.
2. Sign inside-out with `--options runtime --timestamp`:
   - Sparkle XPC services, Autoupdate, Updater.app
   - Lottie.framework
   - **`MediaRemoteAdapter.framework` and `Contents/Helpers/NowPlayingTestClient`**, which are ad-hoc signed and deliberately not re-signed (`local/assemble.py:176-177`). Notarization rejects ad-hoc Mach-O files.
   - Then the app.
3. Use the minimal entitlements above.
4. `xcrun notarytool submit --wait`, then `xcrun stapler staple` the DMG.
5. Publish the tagged source for each binary (GPL section 6), plus `THIRD_PARTY_LICENSES` inside the bundle.

### B10. GitHub workflows (`.github/workflows/*.yml`)

`pull_request_target` is not used anywhere (grep). No workflow echoes a secret. Every action is pinned to a tag (`actions/checkout@v4`, `actions/create-github-app-token@v2`, `actions/github-script@v7`, `actions/upload-artifact@v4`, `maxim-lobanov/setup-xcode@v1`), **not to a SHA**.

| Workflow | permissions | Issues | Action for the fork |
|---|---|---|---|
| `ci.yml` | **not declared** | `push` and `pull_request` (`:3-13`); `persist-credentials: false` (`:35`); `sudo DevToolsSecurity -enable` (`:71`); no secrets. | Add `permissions: contents: read`; pin by SHA. Keep. |
| `release.yml` | `contents: write` (`:20-21`) | Runs on **every push** to `nightly`, `alpha`, `beta`, `main` (`:3-9`). Uses `APP_ID` / `APP_PRIVATE_KEY` (`:51-54`), the Developer ID p12 and password (`:192-194`), notary key (`:222-223`, `:427-428`) and `SPARKLE_ED_PRIVATE_KEY` (`:234`). Hard-codes `APP_NAME: Atoll`, `TEAM_ID` (`:30-31`) and upstream's identity (`:362-418`). `npx create-dmg` installs an **unpinned npm package** while the signing keychain is unlocked (`:401`). Copies the Bluetooth `.mov` files (A3). Pushes the appcast as "Atoll-XML-Updater[bot]" (`:632`, `:678`). Cleanup at `:685-692` deletes the keychain and keys. | **Disable** until you have your own team, certificate and Sparkle key. Then rename everything, pin `create-dmg@<exact>`, pin actions by SHA, and move secrets to an `environment:` with required reviewers. Trigger on tags, not every push. |
| `mirror-release.yml` | `contents: read` (`:15-16`) | Pushes **all branches and tags** to `github.com/Atoll-Labs/Atoll` using `secrets.ORG_REPO_TOKEN` embedded in the URL (`:41-52`). `${{ github.event.release.body }}` is inside a heredoc (`:86-88`), and `release.name` is interpolated into `run:` (`:116`, `:129`): expression injection by whoever can publish a release. | **Delete.** It targets upstream's organisation. |
| `nightly-merge.yml` | `contents: write`, `pull-requests: write` (`:11-13`) | Daily cron merges `dev` → `nightly` and pushes (`:4-6`, `:50-66`). | Disable unless you use that branch model. |
| `update-pricing.yml` | `contents: write` (`:8-9`) | Guarded with `if: github.repository == 'Ebullioscopic/Atoll'` (`:14`), so it is inert in the fork. Uses `curl -s openrouter.ai` → commit (`:32`, `:52-74`). | Re-target it to your repo, or delete it. (The app fetches pricing from upstream, B8.) |
| `triage-slash-commands.yml` | `issues: write` (`:6-7`) | `issue_comment`, gated on `vars.TRUSTED_TRIAGE_USERS` (`:13`). Labels go through the API, not shell. | Set the variable or delete. |
| `validate-changelog.yml` | **not declared** | `pull_request` from `dev`; checkout of PR head (`:15-18`); `${{ github.base_ref }}` in shell (`:24`) is a fixed branch name. | Add `permissions: contents: read`. |

---

## C. Prioritised findings

| ID | Severity | Area | Finding | Evidence | Fix |
|---|---|---|---|---|---|
| S1 | **Critical** | IPC | Extension WebSocket RPC on 127.0.0.1:9020 has no authentication or Origin check and auto-authorizes any client. It allows reading any file and writing any file through `fileName` traversal. On by default. | `ExtensionRPCServer.swift:87-110`; `ExtensionRPCService.swift:151-152`, `:544-559`, `:567-574`, `:436-445`; `Constants.swift:1395`, `:1408`; started at `DynamicIslandApp.swift:754` | Off by default; token plus Origin rejection; user consent; drop `paths`; sanitise `fileName` |
| S2 | **High** | IPC | Distributed-notification snapshots let any process replace live activities, widgets and HTML notch content with no authorization | `ExtensionEventBridge.swift:134-146`, `:160-164` | Remove the bridge, or authenticate and validate |
| S3 | **High** | Release | `release.yml` signs, notarizes and publishes with upstream's team, identity and app name on every branch push. `mirror-release.yml` pushes all refs to `Atoll-Labs/Atoll` with a token. | `release.yml:3-9`, `:30-31`, `:362-418`; `mirror-release.yml:41-52` | Disable or delete; rebuild with your own identity, tag triggers and a protected environment |
| S4 | **High** | License | rtaudio-derived files are AGPL-3.0 upstream but their headers grant GPL; no NOTICE entry | `audio/AudioTap.swift:3-12` (and 5 sibling files); GitHub API `AGPL-3.0` | Correct the headers to AGPL, add to NOTICE, or get permission |
| S5 | **High** | Assets | Bluetooth HUD videos of Apple and Beats products, of unknown origin, are forced into release bundles | `Toplet/BluetoothHUDAnimations/*.mov`; `release.yml:318-345` | Replace with SF Symbols or your own renders |
| S6 | **Medium** | Injection | AirPlay device names reach `NSAppleScript` with only `"` escaped | `AppleMusicAirPlayManager.swift:123`, `:217` | `AppleScriptEscaper.literal`, or Apple Event parameters |
| S7 | **Medium** | IPC | XPC peers are identified by a bundle id looked up from the pid, with no code-signing requirement; auto-approved; upstream mach name | `ExtensionXPCServiceHost.swift:25`, `:55-58`; `ExtensionXPCService.swift:55-61`; `Toplet.entitlements:9-12` | `setCodeSigningRequirement`, consent prompt, rename |
| S8 | **Medium** | Network | LocalSend accepts any TLS certificate, falls back to HTTP, trusts the announced IP and fingerprint, and listens on all interfaces | `LocalSendService.swift:1041-1048`, `:1007-1027`, `:84-88`, `:602-612` | Pin the certificate to the fingerprint; no fallback; use the source IP |
| S9 | **Medium** | Credentials | AI API keys and Spotify `sp_dc` / web token are in plaintext UserDefaults; Gemini key in the URL | `Constants.swift:1235-1236`, `:1385-1388`; `ScreenAssistantManager.swift:418` | Keychain; `x-goog-api-key` header |
| S10 | **Medium** | License | No `THIRD_PARTY_LICENSES`; MIT (incl. Stats), BSD-3, Apache, Sparkle notices are not shipped; README says "notices are in NOTICE" | `ReadMe.md:135`; `COPYRIGHT_ASSETS:7-8`; `NOTICE:1-27` | Add the file and copy it into the bundle |
| S11 | **Medium** | Branding | The fork still presents upstream brand and infrastructure: channel icons, welcome logo, "Made with ❤️ by Ebullioscopic", upstream privacy policy, donation link, `getatoll.app`, Keychain and XPC names | A3 list (e.g. `WelcomeView.swift:64`, `:78`; `SettingsView.swift:4273`; `constants.swift:22`) | Rename and re-icon; link your own privacy policy |
| S12 | **Medium** | Privacy | No setting controls the iTunes and Spotify embed lookups of every track; weather sends coordinates to about 11 m | `MusicManager.swift:229-239`, `:389`; `LockScreenWeatherManager.swift:707-715` | Add a toggle; round coordinates |
| S13 | **Medium** | Assets | Five Lottie files, six sounds and wallpapers have no provenance | `LottieAnimations/*.json`; `Toplet/*.mp3`, `*.m4a`; `Assets.xcassets/desktop`, `glassdesktop` | Trace or replace |
| S14 | **Low** | Platform | `disable-library-validation` entitlement; ATS disabled app-wide | `Toplet.entitlements:5-6`; `Info.plist:5-9` | Remove if not needed; `NSAllowsLocalNetworking` |
| S15 | **Low** | Credentials | Dead Claude Keychain write path remains; Claude Code user agent impersonated; Keychain-wide metadata enumeration (write-back itself FIXED DURING AUDIT) | `KeychainReader.swift:26-37`, `:87-108`; `ClaudeQuotaClient.swift:141`, `:192-200` | Delete `update`; honest user agent; query by service |
| S16 | **Low** | Supply chain | Runtime data from upstream (`pricing.json`) and a third-party repo (Spotify secret); branch-pinned SwiftPM packages; unpinned `npx create-dmg`; actions not pinned by SHA | `ModelPricingManager.swift:98`; `SpotifyAuthManager.swift:36`; `pbxproj:980-1063`; `release.yml:401` | Re-target or bundle; pin by revision and SHA |
| S17 | **Low** | Platform | OSDUIHelper SIGSTOP leaves the system HUD frozen after a crash | `SystemOSDManager.swift:528-538`; `DynamicIslandApp.swift:311-314` | Opt-in; SIGCONT at launch |
| S18 | **Low** | License | New fork files carry "Atoll Contributors" headers or none; this blocks any MIT claim | `AtollAgents/Core/AgentSocketServer.swift:2-3`; 4 header-less files (A1) | Correct the authorship lines before marking anything MIT |
| S19 | **Low** | Workflows | `ci.yml` / `validate-changelog.yml` declare no `permissions`; release body and name interpolated into shell in `mirror-release.yml` | `ci.yml:1-15`; `validate-changelog.yml:1-12`; `mirror-release.yml:86-88`, `:116` | `permissions: contents: read`; pass values through `env:` |
| S20 | **Low** | Injection | `zip` gets dropped file names without `--` | `TemporaryFileStorageService.swift:174`, `:187`; `DynamicIslandApp.swift:1410` | Insert `--` |
| S21 | **Info** | Sparkle | Upstream feed and key were in `Info.plist`, and Sparkle would have used them in Xcode builds. **FIXED DURING AUDIT**; the auto-check toggle and upstream `Updates/appcast*.xml` remain. | `Info.plist:1-25` (16:44); `DynamicIslandApp.swift:47-50`; `SoftwareUpdater.swift:69-72`; `Updates/appcast.xml:4-11` | Hide the toggle; delete the appcasts; own EdDSA key before enabling |
| S22 | **Info** | IPC | Agent socket: 0700 directory, 0600 socket, peer uid check, size, time and connection limits, approvals answered only on the originating connection | `AgentSocketServer.swift:45-48`, `:153-171`, `:207-252`, `:275-281` | Optional `LOCAL_PEERPID` and code-signature check |

Not verified (runtime): whether a browser page can reach `ws://127.0.0.1:9020`; whether the XPC mach name is reachable from other processes; whether the AirPlay payload survives Music's name handling; the WebSocket framework's default message size; the exact upstream commit of the prebuilt MediaRemoteAdapter binaries.
