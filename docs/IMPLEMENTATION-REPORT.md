# Implementation report — 2026-10-21

What changed in this round of work, how it was verified, and what is still open. "Verified" means
the evidence column was produced on this machine today; anything else is labelled as an estimate or
as not verified. Commits are on the `toplet` branch of the integration tree (`Atoll-ai`).

## Summary

| Area | Result |
|---|---|
| Audits | Four evidence-backed audits in `docs/audits/` (product reality, UI/UX, performance, security/license). |
| Reliability and performance | Idle CPU with the Agents feature on and two active Claude Code sessions: **11–66% → ~2%** (measured). |
| Security | 1 critical and 4 high/medium findings fixed (extension API, upstream workflows, clipboard secrets, Gemini key, credential write-back). |
| Product | Claude-style usage limits + pin, Games tab, Clock tab, ship companion, glass surfaces, scroll blur removed. |
| Identity | Renamed to Toplet everywhere users see it; new icon; bundle id `app.toplet.Toplet` with settings migration. |
| Open source | README, CONTRIBUTING (PR rules), CoC, SECURITY, SUPPORT, CONTRIBUTORS, issue/PR templates, architecture/dev/feature/roadmap/release docs, CI. |
| Distribution | `local/release.sh` produces DMG + ZIP + checksums; **not signed with Developer ID, not notarized** (no credentials available). |
| Marketing | Landing page (`site/`), social preview, launch plan with drafts. **Nothing published.** |

## Feature table

| Feature | Previous status | New status | Files | Tests | Evidence | Remaining issues | Commit |
|---|---|---|---|---|---|---|---|
| Usage limits wording | Tokens/$ and "5-hour/7-day quota"; percent used + left | "Session limit · Resets in 1 hr 45 min · 47%", per-model weekly rows, used/left setting | `managers/LLMUsage/*`, `NotchLLMUsageView.swift` | `tests/pure` usage-wording: pass | Offscreen render of the view with sample data; test output | Live provider responses not exercised in tests | 3583095 |
| Pin usage under closed notch | Not implemented | Strip under the closed notch, limits-only refresh every 2/5/15 min | `PinnedUsageView.swift`, `LLMUsageManager.swift`, `ContentView.swift` | Wording suite | Offscreen render at three widths | Not visually verified on the live notch | 3583095, 1764f30 |
| Claude token handling | Refreshed and wrote back Claude Code's OAuth token | Read-only; asks to open Claude Code when expired | `Quota/ClaudeQuotaClient.swift` | — | Code review | Limits unavailable while Claude Code's token is expired | 3583095 |
| Games tab | Pairs inside Agents dashboard | Own tab: Pairs (3 sizes), Tic-Tac-Toe (Relaxed/Perfect), Lights Out; stays open until click outside | `managers/Games/*`, `NotchGamesView.swift`, `ContentView.swift` | game-boards: pass (incl. exhaustive "Perfect never loses") | Offscreen renders, test output | No keyboard play | 981f2bb, 1764f30 |
| Clock tab + alarms | Not implemented | 12/24-hour setting, world clocks, alarms (repeat, snooze, catch-up after sleep, silent when tab off), "Here" map | `managers/Clock/*`, `NotchClockView.swift`, `DynamicIslandApp.swift` | clock-rules: pass | Offscreen renders, test output | Alarms need Toplet running (no system notification yet); not rung live in this session | 981f2bb, 1764f30 |
| Ship companion | Not implemented | Vector ship, 12 moods, priority state machine, burst animation, 3 appearances, Settings preview | `managers/Ship/*`, `components/Ship/*` | ship-mood: pass | Offscreen render of every mood and notch size; idle CPU ~2% with the build that includes it | Hidden while another live activity (e.g. Agents) owns the closed notch; not screenshotted live | d540c8f, 1764f30 |
| Glass surfaces | Only the Agents tab | Shared `NotchSurface` on Usage, Games, Clock, Timer, Notes cards | `NotchSurface.swift` + views | — | Offscreen renders | Other tabs still use ad-hoc fills (UI audit §2) | 981f2bb, 1764f30 |
| Scroll blur | Scrolling blurred the whole tab; macOS 26 edge blur | Removed; light fade kept | `ContentView.swift`, `NotchSurface.swift` | — | Code review | Not visually verified live | 1764f30 |
| Agents usage history CPU | Archive re-encoded every 10 s | Dirty tracking, save ≤ 1/min, flush on stop, cached report | `AtollAgents/Core/AgentUsageHistory.swift` (+ app copy) | run_dashboard 32/32, run_core 1262/1262 | `top`: before 0–66%, after 1.9–3.3%; `sample` before | Folder enumeration every 10 s remains | 13f02a1 |
| Extension WebSocket API | On by default, no auth, auto-approve, path traversal | Off by default, start/stop with setting, browser Origin rejected, file names confined | `ExtensionRPCServer.swift`, `ExtensionRPCService.swift`, `Constants.swift`, `DynamicIslandApp.swift` | Existing RPC XCTests not run (no Xcode) | `lsof`: nothing listens on 9020 after install | Clients still auto-approved when enabled; XPC path unauthenticated | 1764f30 |
| Clipboard secrets | Password-manager items stored | Concealed/transient/auto-generated items skipped | `ClipboardManager.swift` | — | Code review | Not tested with a live password manager | 1764f30 |
| Gemini key | In URL query | `x-goog-api-key` header | `ScreenAssistantManager.swift` | — | Code review | Keys still in preferences, not Keychain | 1764f30 |
| ⌘⇧T conflict | Demo timer stole browsers' reopen-tab | No default; saved binding released once | `ShortcutConstants.swift`, `TopletProject.swift` | — | Saved value observed in prefs before fix | Other ⌘⇧ defaults remain (UI audit #5) | 1764f30 |
| Rename to Toplet | Atoll | Toplet name, icon, menu bar sailboat, permission prompts, 19 languages; bundle id + migration; Notes folder rename | `local/tools/rebrand.py`, many | rebrand dry-run: 0 files; privacy tests 7/7 | Installed bundle audited (Info.plist, all `.lproj`, binary strings); 92/92 settings migrated | AtollExtensionKit SDK messages; old Keychain/XPC identifiers kept on purpose | 1764f30 |
| Upstream updates and workflows | Sparkle pointed at Atoll; release/mirror ran on any fork push | Feed/key removed, updater not started; workflows guarded to upstream; new read-only CI | `Info.plist`, `DynamicIslandApp.swift`, `.github/workflows/*` | CI not yet run on GitHub | YAML review | `ci.yml` Xcode build not verified here | 1764f30 |
| Xcode build of idle engine | `AtollNotch` types missing from the Xcode project | Synced into `Toplet/AtollNotchIdle` | `local/sync-notch.sh`, `local/prepare.py` | Local build passes | Build log | Xcode build itself not run (no Xcode on this machine) | 13f02a1 |
| Release packaging | Upstream release workflow only | `local/release.sh`: DMG, ZIP, SHA-256; Developer ID + notarization when provided | `local/release.sh` | — | Produced Toplet-2.3.3.dmg (hdiutil verify: VALID), zip, sha256 | Not signed/notarized; arm64 only; version still upstream's 2.3.3 | 7d5de62 |
| Notch appearance in Light Mode | Only 5 views forced dark; `.primary` text black on black elsewhere | Notch window uses the dark appearance | `DynamicIslandWindow.swift` | — | Code review (Mac under test is in Dark Mode) | Not visually checked in Light Mode | 86fdd44 |
| Tab bar accessibility | Icon-only, no label | Tooltip + VoiceOver label + selected trait | `TabButton.swift` | — | Code review | ~60 other icon-only buttons remain (UI audit) | 86fdd44 |
| Stopped system processes after a crash | OSDUIHelper/wallpaper stayed SIGSTOPped until reboot | SIGCONT at every launch | `DynamicIslandApp.swift` | — | After relaunch OSDUIHelper is stopped again only by Toplet's active HUD replacement (expected) | No crash-time handler yet | 86fdd44 |

## Verified test results (this machine, today)

| Suite | Result |
|---|---|
| `tests/pure/run.sh` | usage-wording, game-boards, clock-rules, ship-mood: all PASS |
| `AtollAgents/Tests/run_core.sh` | 1262 passed, 0 failed |
| `AtollAgents/Tests/run_hooks.sh` | 407 passed, 0 failed |
| `AtollAgents/Tests/run_dashboard.sh` | 32 passed, 0 failed |
| `python3 -m unittest discover -s tests` | 7 passed (one stale assertion updated to check intent) |
| `local/build.sh release` | Succeeds (builds 7–9 today, last at 16:58) |
| XCTest (`TopletTests`) | **Not run** — no Xcode on this machine |

## Honest quality assessment

**Verified:** the app builds, installs, launches without faults, migrates settings, and idles at
~2% CPU in a heavy agents scenario; the pure rules are tested; the installed bundle carries the
Toplet name and permission texts in every language; the extension port no longer listens by default.

**Known log noise:** three CoreUI "unable to find a bundle" faults at launch, present before
this work too (an asset-catalog lookup in a bundled framework); harmless, to be traced.

**Not verified (needs a person at the Mac or Xcode):** live screenshots of the open notch, the
ship and the pin strip on the real notch; alarms ringing; sleep/wake and multi-display behaviour;
XCTest and the Xcode build; light-mode Settings; VoiceOver.

**Blockers for a public release:** Developer ID signing and notarization (no account available),
Toplet's own update feed, a Toplet version number and repository URL (the repository URL is now set; signing and the feed are still missing),
and real screenshots. See [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md) and [ROADMAP.md](ROADMAP.md).

**Estimate, not measured:** the remaining audit backlog (display identity, Reduce Motion in the
notch, VoiceOver labels, launch time) is roughly 2–4 weeks of focused work for one developer.
