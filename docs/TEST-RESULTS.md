# Test results

Host: macOS 27.2 arm64 (MacBook Air M2, 16 GB), Command Line Tools only (no Xcode), Swift 6.4. Branch `local-build`, base `f039ca9`.
Only things that were actually run are listed. Raw output: `docs/logs/`.

## Automated tests that ran

| Test | Result | Evidence |
|---|---|---|
| `local/tests/state_semantics.swift` (the `@AtollState` replacement keeps per-view state across body re-evaluation, `$binding`, `init(initialValue:)`, optionals) | **5 / 5 PASS** | `logs/local-tests-run.txt` |
| `local/tests/asset_lookup.swift` (`Image("x")` / `NSImage(named:)` against the converted loose resources; missing names return nil/empty) | **12 / 12 PASS** | same |
| `tests/test_privacy_configuration.py` (entitlements, usage strings, release-workflow signing flags) | **6 / 6 PASS** | same |
| `tests/test_timer_lifecycle.py` (compiles the app's real `managers/TimerLifecycle.swift` with `swiftc` and runs the regression) | **1 / 1 PASS** | same |
| `tests/test_cursor_quota_payload.swift` (5 JSON-decoding cases against the app's real `CursorQuotaPayload.swift`) | **PASS** ("tests passed") | same |
| Dependency build probe: 11 SwiftPM products built with Command Line Tools | 7 build as-is; 4 need the overlay (3 `@State`/`#Preview`, 1 Metal) | scratch run, described in `BUILD-ISSUES-AND-FIXES.md` |
| Full app build, release: 363 Swift files + C++ audio target | **PASS** (7 m 13 s clean, reported by the build agent; the resulting bundle was verified independently) | `BUILD-ISSUES-AND-FIXES.md` |
| `codesign --verify --deep --strict dist/Atoll.app` | **PASS** (ad hoc, hardened runtime) | run by me |
| `lipo -archs` on the executable | `arm64` | run by me |

Total: 25 automated test results (17 + 6 + 1 + 1), all passed, 0 failed; plus the build, signature and architecture checks above.

## Runtime checks (run by me on the installed app, `~/Applications/Atoll.app`)

| Check | Result |
|---|---|
| Launch, stays alive 30 s | PASS (pid stayed up; no relaunch loop) |
| Three launch → quit → relaunch cycles | PASS, each quit cleanly, nothing left running |
| Windows created (CGWindowList, no permission needed) | PASS: one layer-27 borderless panel at the top centre (`x=415 y=-4 w=640 h=222` on the 1470-pt built-in display, i.e. the notch window) and the first-launch Onboarding window (400×628) |
| Crash reports from Atoll | **0**. One new report appeared during a run (`ExcUserFault_nsattributedstringagent`, an Apple system text service marked `is_simulated`, coalition `com.anthropic.claudefordesktop`): not Atoll |
| `OSDUIHelper` (the system volume HUD, which Atoll freezes with SIGSTOP) | State `T` (stopped) while Atoll ran, `S` (running) again after quit, every time. Never left frozen |
| Preferences persistence | A marker written to the app's defaults domain survived three relaunches (this tests the preferences store, **not** each of Atoll's 373 settings individually) |
| Listening sockets | Only `127.0.0.1:9020` and `[::1]:9020` (the extension WebSocket server). No other listener |

## Not run, and why

| Not run | Reason |
|---|---|
| `TopletTests` (22 files, 276 XCTest functions), `TopletUITests` | Command Line Tools have no `XCTest.framework`. **BLOCKED** (needs Xcode) |
| Interactive behaviour: hover / click / swipe open and close, auto-collapse, gestures, animation, multi-display, media controls, HUDs, live activities, clipboard, shelf, timers UI, lock-screen widgets, every settings pane | Needs a person at the machine and/or Accessibility permission for input injection. **BLOCKED**, not claimed |
| Permission granted / denied / revoked flows | Needs a person to click macOS prompts; I do not touch TCC. **BLOCKED** |
| Offline test | I did not disconnect the network or capture traffic. "Works offline" for local features is **from code reading only** (`FREE-LOCAL-OPERATION.md`), not tested |
| Network-egress security test | Not captured. Sparkle's silence means "no automatic check scheduled", not "proven no traffic" |
| Instruments (Time Profiler, Energy Log, Allocations) | Xcode-only. See `PERFORMANCE-REPORT.md` for what was measured instead |
| `tests/test_claude_keychain.*`, `scripts/test_claude_keychain.sh` | Deliberately **not run**: they read the Keychain / other apps' credentials |
| Visual comparison with a reference build | No reference build available; see `VISUAL-PARITY-REPORT.md` |

## Notes
* `python3 -m unittest tests.test_privacy_configuration` (the CI form) fails on the system Python 3.9.6 because `tests/` is not a package there; running the files directly or via `unittest discover` passes.
* About 260 compiler warnings (debug) come from the upstream code and were not suppressed.
