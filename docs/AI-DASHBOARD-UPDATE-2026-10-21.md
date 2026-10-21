# AI dashboard update — 21 October 2026

## Delivered source changes

Canonical sources are in `AtollAgents/` in the Atoll checkout. `local/sync-dashboard.py` copies them into the integrated `../Atoll-ai` checkout while preserving its runtime/host glue. The integrated checkout also includes the existing updated idle-animation manager/editor/presets from Atoll.

- Activity overview: working, waiting and idle sessions; completed checklist tasks, excluding cancelled tasks; separate working/idle/waiting subagent counts. Active-duration label is visible even in a short viewport.
- Usage: Last hour, Today, 24 hours and rolling seven days, provider filtering, input/output/cache breakdown, trend chart and top projects. Existing enabled-provider quota snapshots supply five-hour/seven-day percentages, reset countdowns and labelled estimated cost. Refresh quota is explicit and calls quota-only clients; opening Agents does not trigger the legacy full-history scan.
- Closed notch: compact local last-hour token total; existing status glyphs remain static when not animating.
- Alerts: classified attention requests, finished turns and failures with installed provider logos, project/source and jump-to-session. Last 50 observed changes, in memory only; no conversation content persisted in alert history.
- Focus: 15/25/50-minute presets, pause/resume/reset; deadline-based timing continues through tab changes and sleep while the app remains running.
- Play: optional pairs game, with no background clock or keyboard interception. Approval requests retain priority above all dashboard screens.
- Identity: installed app icons for session cards and Alerts. The standalone notch notification component now resolves a source bundle ID to an installed icon, retaining symbol fallback and existing privacy redaction.
- Discovery: internal Codex protocol messages no longer become user-facing prompts. Codex spawn completion now creates a running child under its actual thread ID instead of marking a tool-call ID finished. Claude TeammateIdle events and passive idle/wait states are distinct.

## Accounting and coverage

The incremental local ledger reads Claude assistant usage and Codex cumulative token counters. Streamed Claude updates replace component maxima for the same response. Codex cumulative snapshots contribute deltas. Read offsets and deduplicated records are checkpointed atomically in `~/Library/Application Support/Atoll/agents-usage-v1.json`, with private file permissions. No credentials or prompts are saved there.

Reads are bounded to 8 MiB per refresh, 2 MiB per file per pass, with oversized records skipped and a 100,000-request retention cap. The view identifies partial indexing and checkpoint errors. Recent local history is indexed on launch, so complete seven-day totals may take several refreshes. The ledger is available when passive discovery is enabled.

Tokens consumed, context occupancy, provider quota and estimated cost are distinct concepts. Counts cover locally available logs, including cache traffic; they do not claim account-wide coverage or an official bill. Task totals cover discovered session checklists; stopped/idle sessions do not prove a project's acceptance criteria passed. Alerts describe finished turns rather than claiming the entire project is complete.

The new TeammateIdle hook entry is installed only through the existing hook installer with its backup/diff workflow; this update does not overwrite user hook/status-line settings; quota refresh uses the existing enabled-provider integration. Existing hooks and passive discovery continue working without that optional entry.

macOS does not expose a public API for capturing every other app's notifications. Existing supported CLI/extension/calendar/reminder adapters are separate integrations; this update does not claim universal Notification Center mirroring. The standalone notification UI icon improvement is verified independently; AI Alerts are integrated in the running-app build.

## Validation

- Core: 1,257 checks passed, zero failures.
- Hooks: 407 checks passed, zero failures, including the 18-event Claude registration set and 17 nonblocking events.
- Full updated Agents fallback UI: 218 checks passed. A glass-only installed-logo Reduced Motion regression was fixed by preserving static closed-notch glyphs.
- Final focused dashboard, live-clock and closed-indicator verification: fallback 54 passed; glass 45 passed; zero failures.
- Standalone notification UI: fallback 178 passed; glass 181 passed; zero failures.
- Existing unchanged idle UI evidence: 109 passed, zero failures (`/tmp/claude-501/verify-idle.log`).
- Final release build, assembly and code signature checks passed. Evidence: `logs/codex-improvements-app-release-check.log`.
- Installed and running: `/Users/you/Applications/Atoll.app`, PID 65438; installed executable checksum matches the final release record.
- Activity and Usage inspected live; internal task envelopes no longer appeared as task previews. Focus, Play, Alerts, live-clock and Reduced Motion passed the model/render checks.
- Corrected-build physical memory samples stayed around 156–272 MiB during indexing; final sample 182.9 MiB. No repeat memory warning was observed after the correction.
- Original rollback: `/Users/you/Library/Application Support/Atoll/Backups/Atoll-before-dashboard-2026-10-21.app`.
- macOS reports Accessibility approval is needed again for hardware volume/brightness HUD controls after the rebuild. No OS permissions were granted automatically.

Final accounting checks (including Codex log truncation, internal task/team envelopes, and a 200 KB untrusted model field): 27 passed, zero failures. Live verification exposed a legacy full-scan memory spike; automatic legacy refresh was removed, ISO formatters are reused, and autorelease pools bound parsing temporaries. The corrected build was installed and checked live; measurements are in `logs/codex-atoll-live-memory.csv`.

Logs and final screenshots are under `docs/logs/`. Earlier failure logs are preserved. No new dependency environment was installed. The final release also bounds model identifiers in its checkpoint. The release build reuses Atoll-ai's existing `.work` cache with two compiler jobs; available disk space was checked before building.

## Primary research

- https://code.claude.com/docs/en/statusline — context fields are not cumulative spend; provider quota fields can be absent.
- https://code.claude.com/docs/en/monitoring-usage — token/cache accounting, telemetry, estimated cost.
- https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs — actual child thread IDs and spawn lifecycle semantics.
- https://developer.apple.com/videos/play/wwdc2023/10194/ — recognizable app identity and concise live activity presentation.

## Operational notes

A concurrent session regenerated shared build inputs during one verification attempt, causing missing-input errors. The final successful serial release used the corrected source files; input hashes are recorded in `logs/codex-final-build-inputs.json`. Changes remain uncommitted in the source and integrated checkouts for review.

Only two inactive interim app bundles created by this task were removed. Original rollback, usage checkpoint, source, UI evidence and failure logs remain. `logs/codex-dashboard-cleanup.json` records allocation reported by du separately from observed free-space change. Other sessions' checkouts, build caches and processes were preserved. The small memory probe and its source remain available with the diagnostic evidence.
