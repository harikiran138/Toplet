# Final delivery report — Atoll, local build

Plain summary: Atoll **builds, installs and launches** on this Mac using only the Command Line Tools, from the **unmodified original sources**. A large part of its behaviour could **not** be exercised (it needs a person at the machine, macOS permission grants, or Xcode). Those parts are marked BLOCKED, not PASS.

## A. Build
| Item | Value |
|---|---|
| Source commit (baseline) | `f039ca923d1bbbf17a3610ec2cfbf017ab3bd02d` (`dev`, v2.3.3) |
| Working branch | `local-build` (docs + `local/` tooling only; `git diff f039ca9 -- Toplet/ Toplet.xcodeproj/ Frameworks/ mediaremote-adapter/` is empty) |
| macOS / hardware | macOS 27.2 (26B5101f), arm64, MacBook Air M2, 16 GB |
| Xcode | **Not installed** (`xcode-select -p` = Command Line Tools). `xcodebuild` cannot run. Documented environment blocker; the Xcode project was **not** built |
| Toolchain actually used | Swift 6.4 + SwiftPM, SDK `MacOSX27.0`, Swift 5 language mode, deployment target 14.6 |
| Build | `local/build.sh release` → 363 Swift files + ObjC++/C++ audio target, 7 m 13 s clean |
| How Xcode-only pieces were replaced | non-invasive overlay (`local/`): `@State` → `@AtollState` (same `SwiftUI.State` type), `#Preview` stripped from the build copy, asset catalog converted to loose resources + lookup shim, `.xcstrings` → `.strings`, SwiftTerm Metal renderer omitted, 4 packages vendored with the same edits. Details and every error: `BUILD-ISSUES-AND-FIXES.md` |
| Output | `dist/Atoll.app` (76 MB) and installed copy `~/Applications/Atoll.app` — arm64 only |
| Signing | ad-hoc (`-`), hardened runtime; `codesign --verify --deep --strict` passes. Only entitlement removed: `com.apple.security.mach-services` (an ad-hoc binary cannot hold it). No SIP / Gatekeeper / TCC changes |

## B. Runtime (verified by me on the installed app)
* Launches and stays alive: **yes** (30 s watch; three launch/quit/relaunch cycles).
* Notch overlay: **a layer-27 borderless panel exists at the top centre** of the built-in display (`415,-4  640×222`); contents not inspected. Onboarding window appears on first launch.
* Reopens after quit: **yes**.
* Crash reports from Atoll: **0**.
* Works offline for local features: **NOT TESTED** (network not disconnected, no traffic captured). Code reading says Category-A features need no network (`FREE-LOCAL-OPERATION.md`).
* Menu-bar extra: **not seen** (no status-item window appeared in the window list). Unverified.
* While running it freezes the system volume HUD process (`OSDUIHelper`, state T) as the original does; it is resumed on quit every time. If the system HUD ever looks stuck: `pkill -CONT OSDUIHelper`.

## C. Functionality (status per feature area)
Legend: PASS verified by running · PARTIAL works with a documented limitation · BLOCKED cannot be verified here · FAIL · NOT IMPLEMENTED. Per-feature rows with sources and permissions are in `FEATURE-MATRIX-A.md` / `FEATURE-MATRIX-B.md`.

| Area | Status | Evidence / reason |
|---|---|---|
| App starts, no crash, relaunches | **PASS** | runtime checks above |
| Notch panel created at top centre | **PASS** (existence and geometry only) | CGWindowList |
| Onboarding window renders | **PASS** | build agent's screenshot; window observed by me |
| A. Island interaction: hover/click/swipe open-close, auto-collapse, transitions, multi-display, menu-bar interplay, light/dark, non-notch | **BLOCKED** | needs a human or Accessibility-permitted input; not exercised |
| B. Media (Apple Music, Spotify, others, controls, artwork, lyrics, visualiser) | **BLOCKED** | needs players + Automation/permissions; the media adapter is a prebuilt private-API blob whose behaviour on macOS 27 is unknown. Code audit: default visualiser is random bars, not audio |
| C. System monitoring (CPU, memory, disk, network, battery, GPU, temps) | **BLOCKED** | not exercised. Code audit: GPU Compute/Video/Other is a fixed 60/25/15 split and "Top Processes" is ranked by CPU, i.e. not real GPU data — these are defects, not hardware limits |
| D. Live activities (battery, volume/brightness HUD, recording/camera/mic indicators, focus, downloads, timers, Bluetooth) | **BLOCKED** | not exercised. Timer lifecycle logic regression test passes (PASS for that logic only) |
| E. Productivity (clipboard, timers, calendar, colour picker, shelf, shortcuts, terminal, notes) | **BLOCKED** (UI) | not exercised. Colour Picker "History Size" and Shelf "Expanded drag detection" are non-functional in the source |
| F. Lock-screen widgets | **BLOCKED** | private SkyLight API, macOS-version sensitive; not exercised |
| G. Settings | **BLOCKED** | preferences store persists across relaunch (PASS, generic); individual panes/keys not exercised; some keys are dead per the audit |
| Extensions (WebSocket 127.0.0.1:9020, XPC) | **PARTIAL** | the WebSocket listener is up. The XPC mach service runs without crashing but probably receives no connections without the entitlement, so extension apps likely cannot attach over XPC |
| Unit / UI test targets (XCTest) | **BLOCKED** | no XCTest without Xcode |
| Instruments performance work | **BLOCKED** | no Instruments |

## D. Cost
* **Required payments: none.** Required accounts: none. A code search found no payment, licence, subscription, trial, activation or paywall logic (only dead "PRO" badges behind `if false`), and no analytics/telemetry SDK.
* Building needs only free tooling; first dependency resolution downloads pinned public GitHub packages. An Apple Developer account is **not** needed for this local build.
* On by default and needs internet but no account: Sparkle (automatic checks disabled in this build; the feed URL still points upstream), Open-Meteo weather (free, **non-commercial use only**, CC BY 4.0 attribution not found in the app), iTunes/Spotify explicit-track lookups, Apple Music artwork/MusicKit, lyrics lookups (lrclib.net, music.163.com), wttr.in fallback when Location is denied.
* Optional features with third-party accounts: Spotify (cookie), LLM-usage readers (Claude/Cursor/Codex/OpenRouter), YouTube Music, MusicKit. None is required for the app to launch.

## E. Quality
* Tests that ran: **25 results, all passed** (`TEST-RESULTS.md`). XCTest suites (276 functions) and UI tests: not runnable.
* Performance baseline (no optimisation applied): idle ≈ 93–116 MB, CPU 0.0–0.7 %, 6–7 threads (`PERFORMANCE-REPORT.md`).
* Visual parity: **not assessed**; layout code is the original (`VISUAL-PARITY-REPORT.md`).
* Security / privacy findings (from the audit, see `FREE-LOCAL-OPERATION.md`, `MACOS-PERMISSIONS.md`):
  1. Extension WebSocket server starts at every launch on `127.0.0.1` and `::1` port **9020** (confirmed listening), auto-authorises the first caller and can return Shelf file contents.
  2. API keys (Gemini/OpenAI/Claude/Groq) and a Spotify `sp_dc` cookie are stored in **plaintext UserDefaults**; clipboard history is stored in plaintext with no sensitive-content filter.
  3. The opt-in LLM-usage monitor can read other tools' tokens, spoof Claude Code's User-Agent and write a rotated refresh token back to the Keychain.
  4. Network defaults listed in D; a prebuilt, unauditable MediaRemote adapter runs inside `/usr/bin/perl`, and the app keeps `disable-library-validation`.
  5. Licence-notice gaps: six AGPL-derived audio files with GPL headers, Stats-derived code without an MIT notice, no third-party licence texts bundled, assets of unknown provenance (`DEPENDENCY-AND-LICENSE-AUDIT.md`). Fine for local use; fix before redistributing.
* Platform limits: private APIs (SkyLight, MediaRemote, CGS, IOReport, SMC, DisplayServices) can change or fail on newer macOS; each rebuild is a new app to TCC (permissions must be re-granted).

## F. Deliverable and how to use it
* App: `~/Applications/Atoll.app` (also `dist/Atoll.app`). Open it normally; macOS may require approval for an ad-hoc signed app (System Settings → Privacy & Security → Open Anyway — do not disable Gatekeeper).
* Rebuild from source: `local/build.sh release`, then `local/install.sh` (`LOCAL-INSTALLATION.md`).
* Do **not** click "Check for Updates" (it would offer upstream's release over this build).

## What needs your decision
1. **Local-first patches.** The audit proposes 17 patches (P1–P17 in `FREE-LOCAL-OPERATION.md`), e.g. start the extension server only when enabled, move secrets to the Keychain, remove default-on network lookups, point or remove the Sparkle feed. None is applied, because each changes behaviour that the brief says not to remove silently and I cannot test the interactive effect here. Say which to apply.
2. **Full verification.** Installing Xcode (about 35 GB; this Mac has ~12 GB free) would unlock the XCTest suites, Instruments and the official project build. Interactive features need you to use the app and grant permissions.
