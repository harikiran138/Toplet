# AI Agents in the Atoll notch: integration

Branch `feature-ai-agents` (worktree `Atoll-ai`, based on `local-build`). The feature was built and tested standalone in `AtollAgents/` (core 1230, hooks 406, UI 382 checks); this document is about wiring it into the real app. Background: `docs/AI-AGENTS-RESEARCH.md`, `docs/AI-AGENTS-HOOK-FORMATS.md`, `docs/NOTIFICATIONS-IDLE-AUDIT.md` section 6 (integration conventions).

**Default OFF.** With `enableAgentsFeature = false` nothing runs: no socket, no discovery scan, no timer, no Combine subscription other than the one `Defaults` observer that waits for the switch. The Agents tab and the closed-notch glyph do not exist.

## 1. What changed

New files (all under `Toplet/`, picked up by the synchronized group and by `local/prepare.py`):

| File | Purpose |
|---|---|
| `managers/Agents/*.swift` (28 files) | Core + Hooks, copied from `AtollAgents/Core` and `AtollAgents/Hooks` by `local/sync-agents.sh` |
| `components/Notch/Agents/*.swift` (12 files) | UI, copied from `AtollAgents/UI` (without the snapshot harness) |
| `managers/AgentsIntegration.swift` | `AgentsRuntime` (lifecycle, settings to center, diagnostics log), `AgentsClosedModel`, `AgentsLog` |
| `components/Notch/NotchAgentsHost.swift` | `NotchAgentsHostView` (the tab) and `AgentsClosedLiveActivity` (closed-notch wing) |
| `components/Settings/AIAgentsSettings.swift` | the "AI Agents" settings page |
| `local/agents-compat.sh` | run after the sync: two mechanical fixes to the synced copies (section 6) |

Edits to existing files (additive, one concern each):

| File | Change |
|---|---|
| `enums/generic.swift` | `case agents` in `NotchViews` |
| `DynamicIslandViewCoordinator.swift` | `.agents` in `tabOrder` after `.llmUsage` |
| `components/Tabs/TabSelectionView.swift` | tab "Agents" (SF Symbol `sparkles`) when `enableAgentsFeature` |
| `ContentView.swift` | `case .agents:` view, height 240 in `dynamicNotchSize`, closed-notch branch (after the timer branch, so music and timer win), one `@ObservedObject` (`AgentsClosedModel`, publishes only when the summary changes) |
| `DynamicIslandApp.swift` | `AgentsRuntime.shared.configure()` at launch, `shutdown()` in `applicationWillTerminate`, height 240 in `calculateRequiredNotchSize`. The lifecycle logging and the automatic/sudden termination opt-out are untouched |
| `models/Constants.swift` | five Defaults keys (below) |
| `components/Settings/SettingsView.swift` | `SettingsTab.aiAgents` ("AI Agents", Developer group, `sparkles`), `detailView` case, search entries, "open this page" notification, hidden in Minimalistic UI like Stats/Terminal |
| `local/assemble.py`, `project.pbxproj` | `NSAppleEventsUsageDescription` now also says jumping to the terminal or editor of an agent session |

Defaults keys (all additive): `enableAgentsFeature` false, `agentsApprovalTimeoutSeconds` 90 (clamped 15...600; the installed hook's blocking timeout is 900 s and must stay above it), `agentsShowClosedIndicator` true, `agentsPassiveDiscovery` true, `agentsNotifyOnFinish` false.

## 2. How it works

* `AgentsRuntime` owns the `AgentCenter` (not `AgentCenter.shared`, because the core reads the approval timeout and the discovery switch once, at `start()`). Changing either setting while running stops the center, builds a new one with the new config and starts it (debounced 0.8 s; pending approvals fall back to the agent's own prompt; the board is persisted so nothing is lost). Views observe the runtime, so they follow the replacement.
* Master switch on: `AgentCenter.start()` binds `~/.atoll/run/agent.sock` (directory 0700, socket 0600, peer uid checked) and starts passive discovery (process list + the agents' own local session files). Off: `stop()` releases the socket, timers and queues; `currentView` falls back to Home if it was Agents.
* Polling budget: the core scans every 15-60 s; `AgentsRuntime` asks for 5 s scans only while the Agents tab is open or the closed glyph is drawn.
* Closed notch: `AgentsClosedSummary.make(...)` feeds `AgentsClosedModel`; `ContentView` inserts `AgentsClosedLiveActivity` only when the summary is non-empty (otherwise the branch is skipped and the chain behaves exactly as before: zero width). Size contract of the UI module: glyph height = `effectiveClosedNotchHeight - 12` (+12 on hover), width `n*h + (n-1)*4` for n = 1...2. Layout: glyph wing, the black notch body, an equal empty wing (keeps the shape centred on the camera housing). Tap: `currentView = .agents`, then the notch opens. The glyph only animates while hovered or when an agent needs you: an always-breathing glyph kept SwiftUI rendering at display rate (about 10 % CPU measured on an idle Mac), a static one costs nothing.
* "Sound when an agent finishes" (off by default): plays the system "Glass" sound when the count of unseen completions rises and the Agents tab is not open.
* Settings page: `AgentsSettingsSection` (master toggle, status, Refresh discovery, hooks Preview/Install/Uninstall with confirmation dialogs, per-agent checkboxes, Codex `/hooks` trust note, approval timeout stepper, privacy note) plus "Discover running agent sessions", "Show agents in the closed notch", "Sound when an agent finishes" and a "Terminal jumping" block with a button that opens System Settings > Privacy > Automation.
* Notch Settings button / Install button: open the Settings window and select the AI Agents page (`Notification.Name.atollOpenAIAgentsSettings`).

## 3. Enabling it and installing hooks

1. Settings > AI Agents > "Show AI coding agents in the notch". Already-running Claude Code and Codex sessions appear after a few seconds with an estimated status. No file outside Atoll is touched.
2. Optional, for live status and approving tool calls from the notch: tick Claude Code and/or Codex, press "Preview changes...", read the exact files and backup, then "Install hooks...". Nothing is written before that confirmation.
3. Codex: run `/hooks` once inside Codex and trust the Atoll entry; until then Codex ignores it. If the hook command text ever changes Codex asks again (its trust is a hash).
4. Terminal jumping: the first jump makes macOS ask for Automation permission for that terminal; review it with "Open Automation settings".

Uninstall: Settings > AI Agents > "Uninstall hooks...". Only entries carrying Atoll's marker are removed; every other setting and hook stays. Each file was backed up (timestamped, next to the original) before the first edit, so the backup can also be restored by hand. Turning the master switch off stops everything but leaves installed hooks in place; they fail open (exit 0 immediately when the socket is missing), so the agents behave exactly as without Atoll.

## 4. Security model

* Transport: unix socket in `~/.atoll/run` (0700) with mode 0600, owner = the user, peer uid verified; no network port, nothing reachable from a browser. Deliberately not the extension WebSocket server (it auto-authorizes the first caller).
* Hooks are a pure `sh` one-liner through `/usr/bin/nc`, byte-stable, `exit 0` always; only `PermissionRequest` blocks and only its stdout (a decision JSON built by Atoll, never echoed from client text) reaches the agent. Atoll closes the connection without an answer after the approval timeout (default 90 s, max 600 s) and on quit, which makes the agent show its own prompt (verified live, section 7). Nothing is ever approved automatically; Allow buttons exist only for live, hook-verified sessions.
* Installer: explicit, previewed, backed up, atomic, refuses to touch a file it cannot parse, removes only marked entries.
* Local only: no network requests, no telemetry. Content (prompts, commands, paths, titles) is shown in the notch but never logged: the `agents` log category carries counts and states only (section 5).
* Privilege: no new entitlements. Apple Events use the existing `apple-events` entitlement and macOS Automation consent.

## 5. Diagnostics (no content)

`os_log` subsystem `com.ebullioscopic.Atoll`, category `agents`:

    /usr/bin/log show --last 5m --predicate 'subsystem == "com.ebullioscopic.Atoll" AND category == "agents"' --style compact

Lines: `start timeout=15 passive=yes indicator=yes`, `sessions=3 live=1 passive=2 claude=3 codex=0 pending=0 unseen=0 listening=yes`, `session agent=claude status=running via=hook|passive`, `event kind=PermissionRequest agent=claude`, `approvals-closed count=1`, `sessions-removed count=N`, `restart reason=settings`, `stop`, `stop reason=quit`. No prompts, commands, titles, paths or session ids. (`event kind=` is derived from the center's state, since the engine's private ingest path is not exposed.) There is no debug dump and no test hook that answers an approval.

## 6. Keeping it in sync with `AtollAgents/`

```
local/sync-agents.sh <this repo>      # from the tree that owns AtollAgents/
local/agents-compat.sh                # then, in this tree
```

`agents-compat.sh` applies two mechanical fixes to the synced copies only (the standalone sources are untouched; the same changes belong in `AtollAgents/` at the source):

1. `UsageSnapshot` collides with `managers/LLMUsage/UsageProvider.swift` (`struct UsageSnapshot`), which the standalone tests could not see; it is renamed `AgentUsageSnapshot`.
2. `AgentSession.uiFinishedUnseen` in `AgentsComponents.swift` was still the fixture stand-in (`AgentsUnseenFixture.ids.contains(id)`), so "finished since you last looked" never showed in the real app; it now returns `hasUnseenCompletion`, as the file's own integration note says.

## 7. Limits

* Passive sessions have an estimated status (running lingers about 30 s after the agent stops) and no approvals; live detail needs hooks.
* Approvals reach only sessions that report through hooks. Whether the agent's own prompt stays visible while a hook waits is unknown for both agents; "let the terminal decide" is always available and is what happens on timeout.
* The notch tab asks for 240 pt of height; the closed glyph hides when the screen is locked, in Minimalistic UI, or when another closed activity (music, timer, battery HUD, ...) is shown.
* No Xcode here: the build is the overlay (`local/build.sh`), `@State` is renamed by the overlay; the agent files avoid `@State`, `#Preview` and macros.
* Each rebuild of an ad-hoc signed app is a new app to TCC, so Automation consent for terminal jumping must be granted again.

## 8. Live verification (2026-10-21, macOS 27.2, release build, copy with bundle id `com.local.atoll.aiagents`)

* Process alive 56 s after launch, no new crash report; socket `~/.atoll/run/agent.sock` (dir 0700, socket 0600, owner = user), removed on quit and when the feature is off.
* Passive discovery on this Mac: 2 real Claude Code sessions, 0 Codex (counts only; the ChatGPT app's embedded Codex is not an interactive session).
* Hook-shaped events through the exact `HookCommand` string with `/usr/bin/nc`: SessionStart (idle), UserPromptSubmit (running), PreToolUse (running), blocking PermissionRequest (needsPermission, pending=1, orange glyph), Stop (done, unseen, green check glyphs). The unanswered PermissionRequest closed after the 15 s test timeout with 0 bytes on stdout and exit 0 (fail open).
* Closed notch with a pending approval: layer-27 panel stayed at 415,-4 640x222 (same as without the feature); a strip-only capture showed the glyphs (deleted afterwards).
* Stability soak: 5 x 300 events over about 13 s each, plus 3 enable/disable relaunch cycles: process alive throughout, 0 new crash reports.
* Feature off: no socket, about 1 % CPU (same as the user's own Atoll, measured over 45 s). Feature on with a static glyph: about 2 %. With the first, always-breathing glyph it was about 11 %, hence the static glyph.
* Not verified live: the opened Agents tab and Settings page (no clicks were synthesised; covered only by the standalone UI harness), the zero-width state with no sessions (real agents here keep emitting hook events, so the count is never zero; the branch is guarded by `!summary.isEmpty` and `width(for:)` is 0 for an empty summary), answering an approval from the UI.
