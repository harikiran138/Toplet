# Building Atoll without Xcode: issues, fixes, shims, feature impact

Branch `local-build`, base `f039ca9` (v2.3.3). Host: macOS 27.2 arm64, Swift 6.4, SDK `MacOSX27.0`, **Command Line Tools only**.

Status legend: **VERIFIED** = I ran it and saw the result on this Mac. **NOT VERIFIED** = reasoned, not exercised.

## 0. Result in one paragraph

`local/build.sh release` produces `dist/Atoll.app` (ad-hoc signed, ~76 MB, ~46 MB arm64 executable). It compiles all 363 Swift files plus the ObjC++/C++ audio target against the unmodified repository sources. **`git diff` on `Toplet/` is empty: zero source patches were needed.** Everything is done by the overlay in `local/` (prepare script -> generated copy in git-ignored `local/.work/` -> `swift build` -> `assemble.py`). The app launches, stays alive (45 s observed), creates the notch panel and the onboarding window, writes no crash report, and quits cleanly. See section 8 for what was and was not verified.

Timings (M2, 16 GB): clean `local/build.sh release` from an empty `local/.work`: 7m13s (dependency resolution incl. 56 MB Lottie binary ~2 min, compile ~5-6 min); debug build ~3 min.

## 1. Architecture of the overlay

```
local/prepare.py      copies Toplet/**/*.swift -> .work/Sources/Atoll, applies mechanical transforms,
                      clones the 4 packages that need changes at their pinned revisions -> .work/vendor/*,
                      writes .work/Package.swift (+ Package.resolved with the Xcode project's pins),
                      runs tools/make_resources.py -> .work/resources
local/package/        Package.swift.in (template) + replacement manifests for Defaults and SwiftTerm
local/shims/          AtollState.swift, AtollAssets.swift (copied into the build copy)
local/tools/          swiftxform.py (#Preview strip, @State rename), make_resources.py (asset/strings converter)
local/assemble.py     .app layout, Info.plist, entitlements, inside-out ad-hoc signing
local/build.sh        prepare + swift build + assemble + codesign --verify
local/install.sh      copy to ~/Applications
local/smoke.sh        launch, watch, crash-report check, OSDUIHelper un-freeze, quit
local/tests/run.sh    everything runnable without Xcode (section 7)
local/patches/       (empty) hook for unified diffs, `atoll-*.patch` against the original sources and
                      `vendor-<Name>-*.patch`; prepare.py applies them if present. None were needed.
```

Package graph: one executable target `Atoll` (module name `Atoll`, as `PRODUCT_NAME`), one C-family target `CAtollAudio`, and the same 11 SwiftPM products at the **same revisions as `Package.resolved`** (7 unmodified remote packages by revision; 4 vendored copies). Swift language mode 5 (`SWIFT_VERSION = 5.0`), deployment target 14.6, `DEBUG` defined for debug builds only.

## 2. Every problem met, cause, fix

| # | Symptom / error | Cause | Fix (where) | Why this is minimal |
|---|---|---|---|---|
| 1 | `swift package` cannot be used: project is Xcode-only | no `Package.swift` | `local/package/Package.swift.in`, mirrors pbxproj (target, 11 products, frameworks `Accelerate IOKit ApplicationServices Cocoa`, rpath `@executable_path/../Frameworks`, `-Fsystem <SDK>/System/Library/PrivateFrameworks`, bridging header) | generated, outside `Toplet/` |
| 2 | `'swiftLanguageMode' is unavailable` (manifest) | needs tools-version 6.0 | tools-version 5.10 + `swiftLanguageVersions: [.v5]` | one line |
| 3 | `error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found ... plugin for module 'SwiftUIMacros' not found` on every `@State` (417 uses in 90 files; also inside Defaults, KeyboardShortcuts, SkyLightWindow) | on SDK 27 `State` is *both* a struct (still a normal `@propertyWrapper`) *and* a macro, and the plugin ships only with Xcode. **A local `struct State`, `typealias State` and `@SwiftUI.State` all still resolve to the macro** (tried, all fail) | `swiftxform.rename_state`: `@State` -> `@AtollState`, `State(initialValue:/wrappedValue:)` -> `AtollState(...)`, plus `shims/AtollState.swift`: `typealias AtollState<Value> = SwiftUI.State<Value>` | see section 3 |
| 4 | `#Preview` (65 uses in 59 files; 5 more in KeyboardShortcuts/SwiftTerm) needs `PreviewsMacros` | same missing plugin class | `swiftxform.strip_previews`: brace-matching (string/comment aware) removal, replaced with blank lines so line numbers stay valid; asserts every block has a trailing closure. `PreviewProvider` structs need no macro and are left alone | previews are dev-time only |
| 5 | Bridging header + `.mm`/`.cpp` in the same module | SwiftPM cannot mix Swift and C-family in one target | `CAtollAudio` target (`AudioBridge.mm`, `AudioProcessor.cpp/.hpp`, `include/AudioBridge.h`), Swift gets `-import-objc-header .work/Bridging/Toplet-Bridging-Header.h` (identical content except `audio/AudioBridge.h` -> `AudioBridge.h`) and `-Xcc -I.../CAtollAudio/include`. **VERIFIED compiles and links; no Swift source change** | uses the same mechanism as Xcode |
| 6 | `error: type 'ImageResource' has no member 'github'` (`components/Notch/DynamicIslandExtrasMenu.swift:59`, `Image(.github)`) | Xcode synthesises asset symbols from the catalog; no actool -> no symbol. (The architecture audit counted 0 such uses; there is exactly 1) | `prepare.rewrite_asset_symbols`: `Image(.sym)` -> `Image("<imageset name>")` (fails the prepare if a symbol has no imageset) | 1 call site, table-driven |
| 7 | `Image("name")` renders nothing from loose files | **VERIFIED by experiment:** SwiftUI `Image(String)` only looks in compiled catalogs; AppKit `NSImage(named:)` *does* find loose PNG/JPEG/**SVG**/ICNS in `Contents/Resources` | `shims/AtollAssets.swift`: `extension Image { init(_ name: String) }` (module-local overload without default argument; no ambiguity - tested) tries `NSImage(named:)` first, else falls back to SwiftUI's own initialiser (same empty result as before). No source edits for the 9 literal sites nor `Image(iconStatus)` | one 8-line shim |
| 8 | Defaults' manifest pulls `swift-syntax` (macro products) | irrelevant to the `Defaults` library | `package/vendor/Defaults/Package.swift` keeps only the `Defaults` target (+ its `PrivacyInfo.xcprivacy` resource). Sources identical except `@State` rename | build time, disk |
| 9 | SwiftTerm: `Shaders.metal` is declared `.process(...)` -> needs the `metal` compiler | Xcode-only tool; executables/benchmarks also drag in argument-parser, docc, package-benchmark | `package/vendor/SwiftTerm/Package.swift`: library target only, `Shaders.metal` as `.copy(...)`. Sources identical except 2 `#Preview` removals | see section 4, feature impact |
| 10 | `Bundle.module` of vendored packages (Defaults, KeyboardShortcuts, SwiftTerm resource bundles) | SwiftPM's accessor checks `Bundle.main.resourceURL` first | `assemble.py` copies `*.bundle` from the build products into `Contents/Resources` | same place Xcode puts them |
| 11 | no `actool` | Xcode-only | `tools/make_resources.py` (section 5) | |
| 12 | no `xcstringstool` | Xcode-only | `make_resources.py` writes `<lang>.lproj/Localizable.strings` for the 19 languages (section 5) | |
| 13 | Ad-hoc signature + `com.apple.security.mach-services` | restricted entitlement an ad-hoc binary cannot hold (CI comment in `.github/workflows/ci.yml`: "amfid kills ad-hoc app") | `assemble.py` writes `.work/Atoll.local.entitlements` = original minus `mach-services` only; `$(PRODUCT_BUNDLE_IDENTIFIER)` expanded as Xcode would. Kept: camera, apple-events (+Spotify/Music/Notes exceptions), calendars, `disable-library-validation`, both mach-lookup exceptions | section 6 |
| 14 | Xcode "Embed" of Sparkle/Lottie | binary xcframeworks | `assemble.py` copies `Sparkle.framework`, `Lottie.framework` from the build products into `Contents/Frameworks` (the exe has `@rpath` -> `@executable_path/../Frameworks`) and signs inside-out: Sparkle XPC services -> Autoupdate -> Updater.app -> framework -> Lottie -> exe -> app | mirrors the Release-only shell phase |
| 15 | Copy phases | pbxproj: *Resources* phase contains `MediaRemoteAdapter.framework`, `mediaremote-adapter.pl`, 6 Lottie JSON; *CopyFiles* phase copies `Contents/Helpers/NowPlayingTestClient` to `Contents/Helpers` | `make_resources.py` / `assemble.py` do exactly these. Framework and helper arrive already ad-hoc signed; Xcode does not re-sign files copied by these phases either | |
| 16 | Resources found by code in two ways (`subdirectory:` first, then flat) | synchronized group layout uncertainty (audit open question 5) | `BluetoothHUDAnimations/` kept as a folder (code tries the subdirectory form first, then flat); sounds, `pricing.json`, Lottie JSON flat | covers both lookups |
| 17 | Sparkle would poll upstream's appcast | `SUFeedURL` + `SUPublicEDKey` in `Info.plist` | build-copy Info.plist: `SUEnableAutomaticChecks=false`, `SUAutomaticallyUpdate=false`. Sparkle is **not removed**; feed URL left unchanged, so a *manual* "Check for Updates" would still contact `raw.githubusercontent.com` and could offer to replace this build with the upstream DMG | section 6 |
| 18 | `ld: warning: search path '/Library/Developer/CommandLineTools/Developer/...' not found` | SwiftPM/CLT quirk | benign, ignored | |

Compiler warnings (~260 in debug, e.g. main-actor calls from nonisolated contexts that are errors only in Swift 6 mode, deprecated `onChange`, `kIOMasterPortDefault`) are from the upstream code and were **not suppressed**.

## 3. The `@State` shim: exact semantics (deviation from the brief)

The brief suggested a `@StateObject` box. I first checked the premise and found something better: the SDK still exports the *real* `SwiftUI.State<Value>` as a property wrapper (`@frozen @propertyWrapper public struct State`, `init(wrappedValue:)`, `init(initialValue:)`, `projectedValue: Binding`, `_makeProperty`). Only the *spelling* `@State` is hijacked by the macro. Therefore `@AtollState` = the genuine SwiftUI `State`:

* storage is SwiftUI's own (view-graph attribute), not a re-implemented box: persistence, invalidation, animation transactions and `$x` bindings behave identically;
* the only change is the textual attribute name; no semantic change, no extra object per `@State`, no `@Published` publishing-during-view-update warnings that a `@StateObject` box would add;
* `@AtollState var x: T?` (implicit `nil`) works via SwiftUI's own `init()` for `ExpressibleByNilLiteral`.

**VERIFIED** with `local/tests/state_semantics.swift` (runs in `local/tests/run.sh`): inside a real `NSHostingView`, (a) initial value, (b) mutation through the setter, (c) mutation through a child `@Binding` created from `$count`, (d) the parent re-evaluating its body with a different `init(initialValue:)` argument does **not** reset the state, (e) parent body re-evaluation observed. All PASS.

What it does *not* do: the real macro also enables an Observable-class optimisation (`State(wrappedValue: @autoclosure ...) where Value: Observable` is internal). Atoll has 1 `@Observable` class (`DownloadManager`) and does not store it in `@State` (grep), so no difference. `@Entry`/`@Animatable` macros: 0 uses.

## 4. Feature impact (honest list)

| Item | Impact |
|---|---|
| Asset catalog `AccentColor` | colorset has no colour value (empty `universal` entry) so Xcode also used the system accent; **no change**. `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` has nothing to point at. |
| `Color("x")`, `NSColor(named:)`, `ImageResource` | none used, except the one `Image(.github)` (rewritten). Nothing lost. A future `Color("x")` would need a table (not generated; no colour assets exist). |
| `TidalLogo` `template-rendering-intent = template` | **not preserved** (loose SVG has no template flag). It is only used through `NSImage(named:)` in `AppIconImage`, which redraws it via `fitted(toSide:)`; cosmetic at most. NOT VERIFIED visually. |
| Image variants for dark/high-contrast appearances | none exist in the catalog (checked); converter would log `SKIP` if one appeared |
| `defaultmusic.imageset` (no file) and `Image("dynamicisland")` (no imageset) | already broken upstream; unchanged |
| App icons | `AppIcon.icns` (Finder/Dock/About) and the four alternates `AppIconDev/Alpha/Beta/Nightly.icns` built with `iconutil`; slot PNGs that were not the right pixel size are resized with `sips`. `CFBundleIconFile=AppIcon`. The alternate-icon *picker* uses the `CFBundleIcons` dictionary (`BundleInfos.iconFileName`), which a catalog build writes; this build writes none, so code falls back to `"AppIcon"`. NOT VERIFIED in the UI. |
| Localisation | `Localizable.xcstrings` converted to `.strings` for all 19 languages (all keys have `stringUnit`s only; no plural/device variations exist; 21 empty entries skipped). Keys without an `en` entry fall back to the key (= English source text), same as Xcode. Not compared byte-for-byte with `xcstringstool` output. `Info.plist` strings: `tr.lproj/InfoPlist.strings` copied; usage descriptions in other languages did not exist upstream. |
| SwiftTerm GPU renderer | **no functional loss expected**: Atoll never calls `setUseMetal` (grep), and SwiftTerm's Metal renderer is documented as off by default. If someone enables it, `MetalTerminalRenderer.makeLibrary()` falls back to compiling the shipped `Shaders.metal` source at run time (`device.makeLibrary(source:)`). NOT exercised. |
| `Toplet/metal/visualizer.metal` | not compiled, not shipped; no code loads it |
| Extension XPC channel (`com.ebullioscopic.Atoll.xpc`) | listener is created without the `mach-services` entitlement. **VERIFIED: it does not crash on macOS 27.2** (tiny test with an ad-hoc signed `NSXPCListener(machServiceName:)`, and the full app ran 45 s, debug and release). Without a launchd registration of that name the listener is unlikely to receive connections, so third-party AtollExtensionKit apps probably cannot attach over XPC; the `ws://127.0.0.1:9020` RPC server is independent. NOT VERIFIED with a real extension client. No source patch made. |
| Ad-hoc signature | TCC grants (Accessibility, Screen Recording, Automation, ...) are tied to the code directory hash of an ad-hoc binary, so **each rebuild is a new app to TCC** and must be re-granted. Not touched here. |
| Unit tests | `TopletTests` (22 files / 276 `XCTest` functions) and the UI tests **cannot run**: CLT has no `XCTest.framework` (only Swift `Testing`). |
| `Contents/Helpers/NowPlayingTestClient`, `MediaRemoteAdapter.framework` | prebuilt arm64 blobs from the repo, bundled as the Xcode project does (provenance already flagged in DEPENDENCY-AND-LICENSE-AUDIT). Whether `/usr/bin/perl` can load the adapter on macOS 27 (Now Playing) is NOT VERIFIED. |
| Debug vs release | release is the default; debug build also verified to launch |

## 5. Resource conversion details (`tools/make_resources.py`)

* 18 imagesets -> loose files named after the **imageset** (not the file inside, e.g. `logo.imageset/Atoll.png` -> `logo.png`); `@2x/@3x` suffixes for scaled raster entries (only `chrome` has them); SVGs once. `NSImage(named:)` resolved all of: `bolt`, `spotlight` (SVG), `desktop`, `logo`, `Github` (SVG) - **VERIFIED** in `local/tests/asset_lookup.swift`.
* 5 appiconsets -> `.icns` via `iconutil`.
* strings: see section 4.
* The conversion report is written to `local/.work/resources/asset-conversion-report.txt` on every prepare.
* Not supported without actool: compiled `.car` features such as asset-catalog colour sets with values, vector-preserving PDF templates, appearance variants, `CFBundleIcons` generation. None are present in this catalog except where listed above.

## 6. Signing, bundle id, Sparkle

* Bundle id: **unchanged** `com.Ebullioscopic.Atoll` (Release value). Checked there is no installed Atoll and no `com.Ebullioscopic.Atoll[.dev]` preferences domain on this Mac, so no conflict. If you ever install the official build side by side, change `BUNDLE_ID` in `assemble.py`.
* Ad-hoc identity `-`, hardened runtime on (`flags=0x10002(adhoc,runtime)`), `--no-hardened-runtime` available. `codesign --verify --strict` passes. No SIP/Gatekeeper/TCC changes.
* Entitlements removed vs. original: `com.apple.security.mach-services` only.
* Sparkle: automatic checks off via Info.plist; no Sparkle log lines appeared during runs; not packet-captured, so "never contacts the network" is NOT proven, only "no automatic check scheduled".

## 7. Tests that were run

| Test | Result |
|---|---|
| `local/tests/state_semantics.swift` | 5/5 PASS |
| `local/tests/asset_lookup.swift` | 12/12 PASS |
| `tests/test_privacy_configuration.py` | 6 tests OK |
| `tests/test_timer_lifecycle.py` (swiftc of `TimerLifecycle.swift` + regression main) | OK |
| `tests/test_cursor_quota_payload.swift` (compiled with `CursorQuotaPayload.swift`) | "CursorQuotaPayload tests passed" |
| `tests/test_claude_keychain.swift` / `scripts/test_claude_keychain.sh` | **deliberately not run** (touch Keychain) |
| `TopletTests` (XCTest) | **cannot run** (no XCTest in CLT) |
| `TopletUITests` | cannot run |

## 8. Runtime verification (what exactly was observed)

Observed (debug build, then release build, `open dist/Atoll.app`):
* process alive after 45 s (release: RSS ~88 MB, 0.0 % CPU); debug alive 53 s; **0 new crash reports** in `~/Library/Logs/DiagnosticReports`;
* window list (`CGWindowListCopyWindowInfo`, no permission needed): a layer-27 borderless panel at the top centre (415,-4 640x222 on the 1470-pt built-in display) = the notch window, plus the "Onboarding" window (first launch);
* a screenshot (permission was available) showed the onboarding "Choose Your Profile" window rendered with its SF Symbols/gradients, i.e. SwiftUI, `@AtollState`, and the asset shim work at run time (screenshot was deleted afterwards because it also contained the user's browser);
* unified log: no crash/fault from Atoll itself. Noise: `com.apple.appintents ... linkd.autoShortcut` (unsigned app cannot register intents), `CoreUI: CUICatalog ... unable to find a bundle ... com.Ebullioscopic.Atoll` bursts (SwiftUI probing for a compiled catalog that does not exist; also appears for any no-`.car` app), `SystemTimerBridge: Accessibility permission missing` (expected, no TCC grant);
* in the debug run `OSDUIHelper` was observed in state `T` (stopped) while Atoll ran, and in state `S` again after Atoll quit; in the release run it was `S` throughout the 45 s. `smoke.sh` sends SIGCONT if it ever finds it stopped, before and after. Never left stopped in these runs.

Not verified: the menu-bar extra (no status-item window owned by the app appears in the window list, and the menu bar was not visible in the screenshot; `MenuBarExtra` is inserted by default because `menubarIcon` defaults to `true`, but I could not see it), the notch contents/hover/expand, media controls, lock-screen features, HUD replacement, everything behind permissions, terminal, extensions, any feature requiring network.

## 9. Reproduce

See `docs/LOCAL-INSTALLATION.md`.
