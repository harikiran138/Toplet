# AI coding agents in the Atoll notch: research and recommendation

Date: 2026-10-21. Repo: `Atoll-Local/Atoll` (GPL-3.0, Swift/SwiftUI, `Toplet/`). Read-only research: nothing from other repos was built, installed or run. Only built-in macOS tools were exercised on this Mac (macOS 27.2) to measure latency and behaviour.

Evidence tags (every claim carries one):

- **VERIFIED(Sn)**: read in the primary source listed as `Sn` in section 7 (official docs, repo source, GitHub API). `VERIFIED(Sn,3p)` means the fact comes from a third-party repo's source or README (the third party is the source, not the vendor).
- **MEASURED**: observed on this Mac while writing this document (macOS 27.2, Apple Silicon/x86 build of `/usr/bin/*`).
- **INFERRED**: a conclusion from verified facts, not stated by any source.
- **UNKNOWN**: could not be established. Test before relying on it.

Caveat on method: web pages were read through a summarising fetcher, so field names are high-confidence but not byte-exact. Before writing parsers, record real payloads from a live session (see 8.1) and diff them against this document. Claude Code docs describe versions up to about v2.1.295; Codex CLI up to about 0.163 (VERIFIED(S23)). Both move fast.

---

## 0. Findings and recommended approach (read this first)

1. **The space is crowded and mostly permissively licensed.** At least 8 notch apps do this (section 1). Five are code-compatible with GPL-3.0 (MIT / Apache-2.0 / GPL-3.0). One popular one (ClaudeNotch) is PolyForm Noncommercial and must not be copied; Vibe Island proper is closed source.
2. **Claude Code has a rich, official hook surface** (33 events, a blocking `PermissionRequest` hook that can allow/deny, `http` and `command` handlers, live reload of settings). It also has an official, supervised read API: `claude agents --json`, plus a per-running-session registry directory `~/.claude/sessions/` (existence official, keys from third-party source).
3. **Codex now has hooks too** (12 events incl. `PermissionRequest`, trust-by-hash review, `~/.codex/hooks.json` or `[hooks]` in `config.toml`), a local app-server with a unix control socket (`~/.codex/app-server-control/app-server-control.sock`), rollout JSONL, and a `codex://threads/<id>` deep link. The old `notify` program only supports `agent-turn-complete`.
4. **Approving from the notch works through the blocking `PermissionRequest` hook for both agents** (decision: allow or deny; exit 0 with no output = "let the terminal decide"). Codex's hook accepts only allow/deny (no `updatedInput`/`updatedPermissions`). Whether the terminal dialog is visible while the hook waits is UNKNOWN for both: test it, and offer a "Let terminal decide" button.
5. **Pre-existing sessions can be shown with no install at all**: `~/.claude/sessions/*.json` + `claude agents --json` + transcripts + `~/.codex/sessions/**/rollout-*.jsonl` + a `ps`/libproc scan. Hooks add live detail (current tool, approvals, subagents).
6. **Transport: a unix domain socket in a 0700 directory with a 0600 socket**, short path (macOS `sun_path` is 104 bytes), uid check with `LOCAL_PEERCRED`. The hook is a one-line shell command using `/usr/bin/nc -U` (MEASURED 5-8 ms round trip; python3 is a 30 ms Command Line Tools shim; perl 4.5 ms). It always `exit 0`s, so if Atoll is not running the agent behaves as without it.
7. **Do not reuse the extension WebSocket server (127.0.0.1/::1:9020)**: it auto-authorizes any first caller (VERIFIED(S60)), has no Origin check, is browser-reachable, and `nc` cannot speak WebSocket. Do not reuse the existing Claude/Codex OAuth quota clients for this feature either (they read other tools' tokens and call vendor servers, contradicting local-first).
8. **Recommended phasing**: (P0) passive discovery, zero install, read-only; (P1) opt-in hooks with preview-diff/backup/uninstall; (P2) notch approvals; (P3) Codex app-server for live status; (P4) quick tasks via `claude --bg` / `codex exec --json` or the embedded terminal. Details in section 8.

---

## 1. Open-source projects that already do this

Stars/dates from `api.github.com/repos/<owner>/<repo>` on 2026-10-21 (S40-S52). Licence = GitHub's detection plus the LICENSE head read where noted.

GPL-3.0 compatibility rule used here (not legal advice): MIT, BSD and Apache-2.0 code may be incorporated into a GPL-3.0 work (Apache-2.0 is one-way compatible with GPLv3), keeping the original copyright and licence notices. GPL-3.0 code may be incorporated freely. Atoll's LICENSE is the standard GPLv3 text and its file headers say "GPL-3.0-or-later" (VERIFIED(S60)). Code taken from a GPL-3.0 repo that does not say "or later" (Open Island's LICENSE contains no "only"/"or later" statement, VERIFIED(S41)) must keep its own header and licence, and the combined work is distributed under GPLv3. PolyForm Noncommercial, "Other", unlicensed and closed code: ideas only.

| # | Project | Licence (verified) | Stars / last push | Architecture | Code reuse? |
|---|---|---|---|---|---|
| 1 | **Coucou** `Louis-CFM/coucou` | MIT, "Copyright (c) 2026 Louis Raillé" (S42) | 5,656 / 2026-10-20 | `nb-hook` script -> unix socket -> app; blocking hook for approvals; Codex via hooks; iPhone via CloudKit + APNs relay | Yes (MIT), but huge and feature-bloated; read for UX |
| 2 | **Claude Island / Vibe Notch** `farouqaldori/vibe-notch` | Apache-2.0, "Copyright 2025 Farouq Aldori" (S43) | 2,527 / 2026-04-20 | Python hook `claude-island-state.py` -> `/tmp/claude-island.sock`; `HookSocketServer.swift` holds the fd open for `PermissionRequest` | Yes (Apache-2.0); original of the genre; keep NOTICE |
| 3 | **CodeIsland** `wxtsky/CodeIsland` | MIT, "Copyright (c) 2026 wxtsky" (S44) | 2,511 / 2026-10-11 | native `codeisland-bridge` -> `/tmp/codeisland-<uid>.sock`; hooks for Claude/Codex(`~/.codex/hooks.json`)/Gemini/Cursor; phone/watch companions | Yes (MIT) |
| 4 | **Open Island** `Octane0411/open-vibe-island` | **GPL-3.0** (LICENSE = standard GPLv3 text, no only/or-later statement) (S41) | 2,050 / 2026-10-16 | `OpenIslandHooks` CLI -> `BridgeServer` over `~/Library/Application Support/OpenIsland/bridge.sock`; Codex via hooks + `CodexAppServer.swift` + rollout scan; terminal resolvers for tmux/iTerm2/Ghostty/WezTerm/Warp | **Yes, same licence family**; best code to study (see below) |
| 5 | **Ping Island** `erha19/ping-island` | Apache-2.0 (LICENSE names Farouq Aldori; likely a claude-island derivative: INFERRED) (S45) | 1,135 / 2026-10-15 | `PingIslandBridge` launcher + hooks; Codex via hooks, live `codex app-server` websocket monitor, rollout fallback | Yes (Apache-2.0) |
| 6 | **Agents Island** `mustafahalabi/agents-island` | MIT (API) (S46) | 3 / 2026-08-11 | no-dependency SwiftPM app; **process scanner + registry readers** (`ClaudeSessions.swift`, `CodexSessions.swift`), non-blocking hook + spool + tty answers | Yes (MIT); best reference for P0 discovery |
| 7 | **claude-statistics** `sj719045032/claude-statistics` | MIT (API) (S47) | 47 / 2026-09-14 | menu bar usage/cost app plus a notch "island" using `PermissionRequest` hooks | Yes (MIT); usage parsing ideas |
| 8 | **Nook** `oa1mgo/nook-notch` | GPL-3.0 (API) (S48) | 9 / 2026-09-30 | hook installers + unix-socket ingress under `Nook/Services/Hooks`; notch for agents + music + system (same product shape as Atoll); README says "shaped by ideas from" claude-island and boring.notch | Yes (GPL-3.0) |
| 9 | **code-island** `rifqiakrm/code-island` | GPL-3.0 (API) (S49) | 8 / 2026-07-30 | notch dashboard for Claude/Codex incl. rate limits | Yes (GPL-3.0), tiny |
| 10 | **ClaudeNotch** `rawsun007/claude-notch` | **PolyForm Noncommercial 1.0.0** (LICENSE head read) (S50) | 53 / 2026-10-16 | menu-bar app, permission prompts and cost in notch | **No** (field-of-use restriction is incompatible with GPL); ideas only |
| 11 | **Vibe Island** `vibeislandapp/vibe-island` | no licence; repo is an issue tracker / community home (S51) | 158 / 2026-09-02 | closed-source commercial app | **No**; ideas only |
| - | tmux/TUI prior art: `asheshgoplani/agent-deck` (MIT, 1,128 stars), `kbwo/ccmanager` (MIT, 1,266), `samleeney/tmux-agent-status` (no licence, 289), `smtg-ai/claude-squad` (**AGPL-3.0**, 8,639), `ccusage/ccusage` (19,103 stars; API says NOASSERTION, LICENSE lives in `apps/ccusage/`, historically MIT: UNKNOWN) | see S52 | | hooks write status files (`~/.cache/tmux-agent-status/<session>.status`) or poll tmux panes | ideas only (AGPL adds network-copyleft obligations) |

### 1.1 What the best ones do, concretely

- **Open Island (S41, S53, S54)**: modules `OpenIslandApp / Core / Hooks / Setup`. Hook CLI reads agent stdin, forwards a JSON envelope over a unix socket, writes a directive on stdout only when needed, exits silently when the bridge is down ("fail open") (VERIFIED(S53,3p)). On launch it restores a cache, discovers `~/.claude/projects/` transcripts and `~/.codex/sessions/**/rollout-*.jsonl`, reconciles with `ps`/`lsof` (VERIFIED(S53,3p)). Terminal jump: Terminal.app TTY via AppleScript; iTerm2 session/TTY probe; Ghostty by window id; WezTerm/Kaku CLI pane targeting; tmux `switch-client` then `select-window` then `select-pane`; cmux unix socket; Warp via SQLite + AX menu click; VS Code via `code` CLI (VERIFIED(S53,S54,3p)). Claude usage: a managed statusLine bridge caches `rate_limits` to `/tmp/open-island-rl.json`; Codex 5h/7d windows come from local rollout files; the bridge refuses to overwrite a user's custom statusLine (VERIFIED(S53,3p)). Hook helper is copied to `~/Library/Application Support/OpenIsland/bin/OpenIslandHooks`.
- **Claude Island (S43)**: hook script is `#!/usr/bin/env python3`, PID = `os.getppid()`, tty via `ps -p <ppid> -o tty=`, only `PermissionRequest` blocks (socket timeout 300 s), prints `hookSpecificOutput.decision.behavior` allow/deny, exits 0 with no output for "ask" so Claude falls back to its own prompt (VERIFIED(S55,3p)). Installer registers events by `claude --version` gates and gives `PermissionRequest` a `timeout` of 86400 (VERIFIED(S56,3p)).
- **Agents Island (S46)**: reads `~/.claude/sessions/*.json` (pid -> session, cwd, status), `~/.claude/tasks/`, transcripts tail-only with an mtime cache, Codex rollouts for status and `update_plan` checklists; polls every 2 s; `ps -axwwo pid=,ppid=,pcpu=,tty=,etime=,args=` and `/usr/sbin/lsof -a -d cwd -p <pids> -Fn` (VERIFIED(S57,S58,3p)).
- **Codex integration in the field**: CodeIsland and Coucou use Codex hooks; Ping Island and Open Island also talk to `codex app-server`; CodeIsland notes the one-time `/hooks` trust review and that trust hashes live in `~/.codex/config.toml` under `[hooks.state]` (VERIFIED(S44,S45,3p)).

### 1.2 What to learn

1. Fail open everywhere; the hook must never be able to wedge the agent (Open Island, Coucou).
2. Only the permission hook blocks; every other event is fire-and-forget (Claude Island).
3. Show a "Reply in terminal" / "let the terminal decide" escape (Coucou).
4. Tail-only transcript parsing with mtime caches; transcripts exceed 100 MB (Agents Island).
5. Backup + diff preview before editing `~/.claude/settings.json` (Coucou); keep a stable hook command string so Codex's hash trust does not drift.
6. Do not overwrite a user's existing statusLine (Open Island).

### 1.3 What to avoid (verified weaknesses)

| Weakness | Where | Fix for Atoll |
|---|---|---|
| Fixed, predictable socket in shared `/tmp` with unlink-then-bind; `chmod 0600` after `bind` (window of default perms); no peer check | Claude Island `HookSocketServer.swift` (VERIFIED(S59,3p)); CodeIsland `/tmp/codeisland-<uid>.sock` | 0700 private dir, `umask(0o177)` before `bind`, `LOCAL_PEERCRED` check |
| Client-supplied `toolUseId` used as the pending-approval key; duplicate id overwrites and leaks the earlier fd; no caps/timeouts on pending map or buffers; decision string not validated | Claude Island (VERIFIED(S59,3p)) | server-generated UUID per connection, size caps, build the decision JSON yourself |
| Installer starts from `{}` and **overwrites settings.json when parsing fails**; no backup | Claude Island `HookInstaller.swift` (VERIFIED(S56,3p)) | refuse to write on parse failure; timestamped backup; atomic write; show diff |
| `bind()` with default dir perms, no `chmod`/`getpeereid`, no read timeout | Open Island `BridgeTransport`/`BridgeServer` (VERIFIED(S53,3p), "not found in visible portion" for BridgeServer tail) | as above |
| Approval by synthesising keystrokes into a tty / Accessibility | Agents Island (VERIFIED(S57,3p)) | do not do this; use the hook decision channel only |
| Scraping other tools' OAuth tokens/keychain items | Atoll's own `ClaudeQuotaClient`/`CodexQuotaClient` (VERIFIED(S60)) | use statusLine relay and local logs |
| Python dependency for hooks | Claude Island | `/usr/bin/nc` |
| Closed/unnotarized helper binaries and remote relays | Coucou's Cloudflare APNs relay (`relay/`) (VERIFIED(S42,3p)) | out of scope: Atoll must stay local-only |

---

## 2. Claude Code integration surface (docs.claude.com redirects to code.claude.com)

### 2.1 Hook events (VERIFIED(S1))

Current list (33): `SessionStart, Setup, UserPromptSubmit, UserPromptExpansion, PreToolUse, PermissionRequest, PermissionDenied, PostToolUse, PostToolUseFailure, PostToolBatch, Notification, MessageDisplay, SubagentStart, SubagentStop, TaskCreated, TaskCompleted, Stop, StopFailure, TeammateIdle, InstructionsLoaded, ConfigChange, CwdChanged, DirectoryAdded, FileChanged, WorktreeCreate, WorktreeRemove, PreCompact, PostCompact, PreModelSwitch, PostModelSwitch, Elicitation, ElicitationResult, SessionEnd`.

Atoll needs only: `SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, PermissionDenied, Notification, Stop, StopFailure, SubagentStart, SubagentStop, TaskCreated, TaskCompleted, PreCompact, PostCompact`. Version-gate registration (Claude Island gates by `claude --version`; unknown event names produce a "Settings Warning" and are skipped, VERIFIED(S3)).

### 2.2 Stdin JSON (VERIFIED(S1))

Common fields, all events: `session_id`, `prompt_id` (UUID, matches OTel `prompt.id`), `transcript_path`, `cwd`, `scratchpad_dir` (v2.1.257+), `permission_mode` (`default|plan|acceptEdits|auto|dontAsk|bypassPermissions`), `effort{level}`, `hook_event_name`; inside a subagent also `agent_id`, `agent_type`. Tool events add `tool_name`, `tool_input`, `tool_use_id`.

| Event | Extra fields |
|---|---|
| SessionStart | `source` (`startup|resume|clear|compact|fork`), optional `model`, `agent_type`, `session_title`; on resume/fork also `seconds_since_last_response`, `context_tokens`, `prompt_cache_likely_expired`, `estimated_cache_write_usd` |
| SessionEnd | `reason` (`clear|resume|logout|prompt_input_exit|other`); default hook budget **1.5 s** (raise with per-hook `timeout`, max 60 s) |
| UserPromptSubmit | `prompt` (pasted text arrives expanded), optional `session_title` |
| PreToolUse | `tool_name`, `tool_input`, `tool_use_id` (Bash input includes `command`, `description`, `timeout`, `run_in_background`) |
| PermissionRequest | `tool_name`, `tool_input`, optional `mcp_server`, optional `permission_suggestions[]` (e.g. `{type:"addRules", rules:[{toolName,ruleContent}], behavior:"allow", destination:"localSettings"}`). **No `tool_use_id`.** |
| PostToolUse | `tool_input`, `tool_response`, `tool_use_id`, `duration_ms` |
| Notification | `message`, optional `title`, `notification_type` in `permission_prompt, idle_prompt, auth_success, elicitation_dialog, elicitation_url_dialog, elicitation_complete, elicitation_response, agent_needs_input, agent_completed, quota_auto_resume_*, plugin_notification`. `permission_prompt` fires only after ~6 s without an answer. |
| Stop | `stop_hook_active`, `last_assistant_message`, `background_tasks[]`, `session_crons[]`. Does not fire on user interrupt; API errors fire `StopFailure` (`error` in `rate_limit, overloaded, authentication_failed, billing_error, max_output_tokens, ...`). |
| SubagentStart / SubagentStop | `agent_id`, `agent_type`; Stop adds `agent_transcript_path` (example `.../<session>/subagents/agent-<id>.jsonl`), `last_assistant_message`; `transcript_path` is the parent's |
| TaskCreated / TaskCompleted | `task_id`, `task_subject`, optional `task_description`, `teammate_name`, `team_name` (deprecated), `agent_id` (v2.1.290+). The page frames these around agent teams; whether the plain `TaskCreate` tool also fires them is UNKNOWN. |
| PreCompact / PostCompact | `trigger` (`manual|auto`), `custom_instructions` / `compact_summary` |

The transcript is written asynchronously and may lag; use `last_assistant_message` on Stop (VERIFIED(S1)).

### 2.3 Returning a decision (VERIFIED(S1))

- Exit `0`: success; stdout is parsed as JSON only if it is **one JSON object with nothing around it**. Exit `2`: blocking error (stderr is the reason) but **not honoured for PermissionRequest** (leaves flow unchanged). Any other code: non-blocking error, the action proceeds and a `<hook> hook error` notice is shown. **Plain stdout is injected into Claude's context for `UserPromptSubmit`, `UserPromptExpansion`, `SessionStart`, `PostModelSwitch`**: an Atoll reply on those events must be empty or a JSON object, never text.
- PermissionRequest allow/deny: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny", "updatedInput":{...}|"updatedPermissions":[...] (allow only), "message":"...", "interrupt":true (deny only)}}}`. `updatedPermissions` entry types: `addRules, replaceRules, removeRules, setMode, addDirectories, removeDirectories`; `bypassPermissions` via `setMode` only if already available at launch. `"defer"` is **not** valid here. Deny and ask rules are still evaluated. In sessions that cannot show a prompt (`-p` background subagents) no decision means denied. With an SDK/`--permission-prompt-tool` host, hooks and host race and first decision wins.
- PreToolUse: `hookSpecificOutput.permissionDecision` = `allow|deny|ask|defer`, `permissionDecisionReason`, `updatedInput`. `defer` works only in `-p` mode. Multiple hooks: deny > defer > ask > allow.
- Universal: `continue`, `stopReason`, `systemMessage`, `suppressOutput`. Stop/SubagentStop: `decision:"block"` + `reason` (continuation cap 8).
- Timeouts (s): command/http/mcp_tool default 600; 30 for UserPromptSubmit/Pre-/PostModelSwitch; 10 MessageDisplay; SessionEnd 1.5 s budget. On timeout the hook is cancelled and its output discarded; the action proceeds unless `onFailure:"block"` (v2.1.295+), which on PermissionRequest denies.
- `async:true` (command hooks only): runs in the background, cannot block or decide; not timeout-enforced after start; killed at `-p` teardown.
- Handler types: `command` (shell form `sh -c`, or exec form with `args` and no shell), `http`, `mcp_tool`, `prompt`, `agent`. **`http` hook**: POST of the same JSON; 2xx + JSON body = same schema as command output; non-2xx, connection refused and timeouts are non-blocking errors; `headers` may interpolate only env vars listed in `allowedEnvVars`; org policy can restrict with `allowedHttpHookUrls` (VERIFIED(S1)).

### 2.4 Where hooks are configured, merge, trust (VERIFIED(S1,S3))

- Sources: `~/.claude/settings.json` (user), `.claude/settings.json` (project), `.claude/settings.local.json`, managed policy (system dir / MDM / server-managed), plugin `hooks/hooks.json` (while enabled), skill and subagent frontmatter. `CLAUDE_CONFIG_DIR` relocates `~/.claude`.
- Merge: **entries from user, project, local and managed are added together**; an identical handler defined in several files runs once; matching hooks for an event run **in parallel**. `disableAllHooks`, `allowManagedHooksOnly` exist. `--settings '{...}'` can inject hooks for one run and `--bare`/`--safe-mode` skip hooks.
- Settings files are watched and **reloaded in the running session, including hooks** (VERIFIED(S3)); a `ConfigChange` hook fires. Contrast: Claude Island/Agents Island READMEs tell users to restart sessions (3p): trust the docs, verify empirically.
- **Workspace trust**: in interactive sessions hooks from every settings file, even the user's, are held back until the user accepts the trust dialog for that folder (VERIFIED(S1)). New sessions in untrusted folders will not report: the process/registry scan (section 4) covers them.
- Env for hooks: `CLAUDE_PROJECT_DIR`, `CLAUDECODE=1`, `CLAUDE_CODE_CHILD_SESSION=1` (VERIFIED(S12)); `$PPID` in a shell-form hook is the `claude` process (INFERRED from `sh -c` spawn; Claude Island relies on `getppid()`, VERIFIED(S55,3p)).
- Cleaner install options than editing user settings: (a) a local **plugin** carrying `hooks/hooks.json` (listed as a hook source; uninstall is one command; read-only in VS Code UI, VERIFIED(S1,S10)); (b) merge into `~/.claude/settings.json` with backup, diff preview, marker key, atomic write, refuse on parse errors. Never edit managed settings.

### 2.5 Transcripts, status and todos

- Path `~/.claude/projects/<project>/<session-id>.jsonl`, `<project>` = cwd with non-alphanumerics replaced by `-` (truncated to 200 chars + hash when longer); subagent transcripts in `.../<session>/subagents/`; big tool results in `.../tool-results/`. Entry format is **internal and changes between versions** (VERIFIED(S5,S4)). Retention 30 days default (`cleanupPeriodDays`). Third-party parsers dispatch on `"type"` in `ai-title, last-prompt, assistant, user`, read `message.model`, `tool_use` items and `tool_result` (`tool_use_id`), and treat "the last `tool_use` with no matching result" as current activity (VERIFIED(S57,3p)).
- **Live registry**: `~/.claude/sessions/` holds one small file per running session "used to detect concurrent sessions and crashes", removed on exit, crash leftovers cleared on next launch (VERIFIED(S4)). Keys (third-party reader): `pid`, `sessionId`, `cwd` required; `name`, `status`, `statusUpdatedAt` optional; file names are not trusted for the pid; stale files "may linger" so cross-check the process table (VERIFIED(S57,3p)). The format is undocumented: parse defensively.
- **Supervised read API**: `claude agents --json [--all] [--cwd <path>]` prints a JSON array: `cwd`, `kind` (`interactive|background`), `startedAt` (unix ms) always; `id` and `state` (`working|blocked|done|failed|stopped`) for background sessions; `pid` and `status` (`busy|waiting|idle`) while the process lives; `waitingFor` (`permission prompt|input needed|sandbox request|worker request|dialog open`) when waiting; `sessionId`, `name`. Docs call it "the supervised way to read session state from outside Claude Code" (VERIFIED(S6)). Cost: spawning `claude` per poll; poll at 2-5 s only while the notch section is visible, and fall back to the registry when the binary is absent.
- Background sessions state: `~/.claude/jobs/<id>/state.json`, `~/.claude/daemon/roster.json`; docs say **not a stable interface** (VERIFIED(S6)). No public supervisor socket protocol is documented (VERIFIED(S6)).
- **Todos/tasks**: default task tools are `TaskCreate/TaskGet/TaskList/TaskUpdate`; legacy `TodoWrite` only with `CLAUDE_CODE_ENABLE_TASKS=0`; these tools are present by default **only on Opus 4.7, Sonnet 4.6, Haiku 4.5 and earlier**, and on newer models the list stays empty unless `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` (VERIFIED(S7,S8,S12)). The UI must therefore tolerate "no checklist" as the normal case. Task files: `~/.claude/tasks/<session-or-list-id>/<n>.json` with `subject`, `status` (`pending|in_progress|completed|deleted|cancelled`); `CLAUDE_CODE_TASK_LIST_ID` names a shared list (VERIFIED(S8,S57,3p)).
- **Subagents**: tool is `Agent` (older name `Task`; third-party parsers accept both, VERIFIED(S7,S57)). Signals: `SubagentStart/SubagentStop` (`agent_id`, `agent_type`), hook payloads from inside a subagent carry `agent_id`/`agent_type`, background subagents surface their permission prompts in the **main** session naming the subagent (VERIFIED(S1,S7)).
- **Permission modes** are in every payload (`permission_mode`); `bypassPermissions` sessions never emit `PermissionRequest` (INFERRED).

### 2.6 `claude` process and CLI facts

- Native binary: launcher `~/.local/bin/claude` symlinks into `~/.local/share/claude/versions/<ver>`; the npm package installs the **same native binary** and "does not itself invoke Node"; Homebrew casks `claude-code` / `claude-code@latest`; binary is signed "Anthropic PBC" and notarised (VERIFIED(S13)). Process `comm` is therefore likely the version string or `claude`: UNKNOWN; match on resolved executable path and code signature, not on argv[0] text. Exclude `-p/--print`/`stream-json` headless runs and GUI helpers (heuristics from VERIFIED(S58,3p)).
- statusLine (stdin JSON, runs on events, **300 ms debounce**, optional `refreshInterval` s, in-flight run cancelled by new triggers): `session_id`, `session_name`, `prompt_id`, `transcript_path`, `cwd`, `model{id,display_name}`, `workspace{current_dir,project_dir,added_dirs,git_worktree,repo{host,owner,name}}`, `cost{total_cost_usd,total_duration_ms,total_api_duration_ms,total_lines_added,total_lines_removed}`, `context_window{total_input_tokens,total_output_tokens,context_window_size,used_percentage,remaining_percentage,current_usage}`, `rate_limits{five_hour,seven_day{used_percentage,resets_at}, spend_limit}` (only for claude.ai Pro/Max or gateway, after first response, windows independently absent), `version`, `effort`, `thinking`, `fast_mode`, `vim`, `agent`, `pr`, `worktree`, `prompt_cache` (VERIFIED(S2)). This is the **only** official, local, no-credential source of Claude plan rate limits. Only one `statusLine.command` can be configured, so Atoll must wrap and chain the user's existing command (tee stdin to Atoll, then exec the original).
- Headless/quick-task flags (VERIFIED(S14)): `claude --bg "prompt"` (background session, returns id; cannot combine with `-p`; checks workspace trust), `claude -p --output-format stream-json --verbose [--include-hook-events] [--forward-subagent-text]`, `--permission-mode`, `--allowedTools`, `--max-turns`, `--max-budget-usd`, `--no-session-persistence`, `--permission-prompt-tool mcp__server__tool` (needs an MCP server), `--permission-prompts none`, `--session-id`, `-n/--name`. Management: `claude attach|logs|stop|respawn|rm <id>`, `claude daemon status`. `claude --desktop [--resume <session-id>]` opens the session in Claude Desktop (v2.1.285+).
- Deep links: `claude-cli://open?cwd=&repo=&q=` opens a **new** terminal session (not a jump to an existing one); registered handler app at `~/Applications/Claude Code URL Handler.app`; `vscode://anthropic.claude-code/open?prompt=` opens a **new** tab in the focused VS Code window (VERIFIED(S11,S10)). Neither can focus an existing session.

### 2.7 Claude Desktop and VS Code differences

- Desktop app "reads the same settings files as the CLI"; hook behaviour in the Code tab, transcript path, process names and whether it spawns the `claude` binary locally are all **UNSTATED** (VERIFIED(S9)). Open Island lists "Claude Code (Desktop App)" as supported through hooks (VERIFIED(S53,3p)). CodeIsland reads Cowork sessions read-only from `~/Library/Application Support/Claude/local-agent-mode-sessions/` (VERIFIED(S44,3p)). Desktop transcripts are kept at any age unless `desktopSessionCleanupPeriodDays` is set (VERIFIED(S4)). Desktop `dontAsk` mode is CLI-only (VERIFIED(S9)).
- VS Code extension: bundles its own CLI copy; `~/.claude/settings.json` is shared with the CLI, including hooks; lists hooks in a Customize view; IDE integration is a loopback WebSocket MCP server `ide` with a per-activation random token in `~/.claude/ide/<port>.lock` (0600 in a 0700 dir) presented as `X-Claude-Code-Ide-Authorization`; tool names appear to hooks as `mcp__claude-vscode__getDiagnostics` (VERIFIED(S10)). That lock-file design (random token, owner-only file, owner-only dir) is a good template for Atoll's own channel.

### 2.8 Minimal safe, fail-open hook command (Claude Code)

```jsonc
// ~/.claude/settings.json (merged, one entry per event; matcher "*" where applicable)
{ "hooks": { "PermissionRequest": [ { "matcher": "*", "hooks": [ {
    "type": "command",
    "command": "S=\"$HOME/.atoll/run/agent.sock\"; [ -S \"$S\" ] || exit 0; { printf '{\"v\":1,\"agent\":\"claude\",\"ppid\":%s}\\n' \"$PPID\"; cat; } | /usr/bin/nc -U \"$S\" 2>/dev/null; exit 0",
    "timeout": 600 } ] } ],
  "PreToolUse": [ { "matcher": "*", "hooks": [ {
    "type": "command",
    "command": "S=\"$HOME/.atoll/run/agent.sock\"; [ -S \"$S\" ] || exit 0; { printf '{\"v\":1,\"agent\":\"claude\",\"ppid\":%s}\\n' \"$PPID\"; cat; } | /usr/bin/nc -w 1 -U \"$S\" >/dev/null 2>&1; exit 0",
    "timeout": 3 } ] } ] } }
```

Why this is fail-open (all MEASURED on macOS 27.2 with a test server unless noted):

- `[ -S sock ] || exit 0`: Atoll not running and the socket file absent: no process is spawned; exit 0 with empty stdout = success with no decision.
- Stale socket file (no listener): `nc -U` exits 1 in ~5 ms with no stdout; the trailing `; exit 0` hides the code, avoiding the "hook error" notice that any non-0/2 exit triggers (VERIFIED(S1)).
- Round trip with a live server: ~5-8 ms. macOS `nc` half-closes on stdin EOF, so the server can frame by EOF; a 200 KB payload worked.
- Non-blocking events use `nc -w 1`: it gives up after 1 s of inactivity and exits 0 with no output (MEASURED). The blocking `PermissionRequest` hook omits `-w` and relies on the hook `timeout`.
- If Atoll dies while a request is pending, the kernel closes the socket, `nc` sees EOF and returns empty output (INFERRED; test), so Claude falls back to its own flow.
- Server must write **only** a single JSON object (or nothing) back: for `UserPromptSubmit` and `SessionStart` any stray text would be injected into the model context (VERIFIED(S1)).
- Pitfall (MEASURED): `AF_UNIX path too long` is raised for a 138-char path; macOS `sun_path` is 104 bytes. Keep the socket path short (`~/.atoll/run/agent.sock`), never under `Application Support` plus a long username, and never under `$TMPDIR` (Claude can relocate temp via `CLAUDE_CODE_TMPDIR`, VERIFIED(S4)). The same limit bit Codex users (VERIFIED(S24)).
- Alternative with no helper at all: an `http` hook to loopback. Native fail-open (refused = non-blocking error) but needs a TCP port (browser/DNS-rebinding reachable), bearer interpolation only from `allowedEnvVars` (so the token must live in Claude's environment), and may be blocked by `allowedHttpHookUrls`; whether a refused connection prints a notice is UNKNOWN. Not recommended.

---

## 3. Codex integration surface

CLI/desktop/IDE docs moved: `developers.openai.com/codex/*` 308-redirects to `learn.chatgpt.com/*` (VERIFIED(S16)). `github.com/openai/codex`: Apache-2.0, 130,220 stars, pushed 2026-10-21 (VERIFIED(S25)).

### 3.1 Config and files (VERIFIED(S16))

`CODEX_HOME` defaults to `~/.codex`: `config.toml`, `auth.json` (only with file-based credential storage; else keychain), `history.jsonl` (disable with `[history] persistence="none"`), logs/caches. Rollouts in `sessions/` and `archived_sessions/` (constants `SESSIONS_SUBDIR`, `ARCHIVED_SESSIONS_SUBDIR`, VERIFIED(S61)).

### 3.2 `notify` (legacy, VERIFIED(S16))

`notify = ["python3", "/path/notify.py"]`; the program receives **one JSON argument** (argv, not stdin). Only event: `agent-turn-complete`; fields `type`, `thread-id`, `turn-id`, `cwd`, `input-messages`, `last-assistant-message`. Built-in `tui.notifications` (`agent-turn-complete`, `approval-requested`), `tui.notification_method` (`auto|osc9|bel`), `tui.notification_condition` (`unfocused|always`). **Use hooks instead of `notify`**: `notify` cannot report running/waiting/approval and Atoll would be competing for the single `notify` slot with the user's own.

### 3.3 Hooks (VERIFIED(S15))

- Events (12): `SessionStart, SessionEnd, SubagentStart, SubagentStop, PreToolUse, PermissionRequest, PostToolUse, PreCompact, PostCompact, UserPromptSubmit, Stop, Interrupt`.
- Locations: `~/.codex/hooks.json`, `~/.codex/config.toml` `[[hooks.PreToolUse]]` tables, `<repo>/.codex/hooks.json`, `<repo>/.codex/config.toml`, plugin-bundled hooks, managed hooks (`requirements.toml`). **All matching hooks from all sources load and run concurrently** (no override). Hooks are on by default; `[features] hooks=false` disables.
- **Trust**: non-managed hooks must be reviewed with `/hooks` in the CLI; trust is tied to the hook's hash, a changed hook is skipped until re-trusted; `--dangerously-bypass-hook-trust` exists; project hooks load only if the `.codex/` layer is trusted. Third-party notes say state is stored in `config.toml` (`[hooks.state]`, VERIFIED(S44,3p)) and that moving the binary invalidates the hash (INFERRED). Consequence for Atoll: install once, keep the `command` string byte-stable (point at a stable shim; update the shim's content, not the command), and tell the user to run `/hooks` once. Silent skipping if untrusted is the failure mode.
- Stdin: `session_id`, `transcript_path` (nullable), `cwd`, `hook_event_name`, `model`, `permission_mode`, per-turn `turn_id`; `PreToolUse/PostToolUse`: `tool_name`, `tool_use_id`, `tool_input`, `tool_response`; `PermissionRequest`: `tool_name`, `tool_input` (with `tool_input.description`); `SubagentStart/Stop`: `agent_id`, `agent_type`, `agent_transcript_path`; `Stop`: `stop_hook_active`, `last_assistant_message`; `SessionStart.source` in `startup|resume|clear|compact|fork`; `SessionEnd.reason` (always `other`); `Interrupt` (on user interrupt of an active turn, not for subagents).
- Output: `PermissionRequest`: allow `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` or deny with `message`; **any deny wins, otherwise an allow skips the prompt, no decision = normal approval flow; `updatedInput`, `updatedPermissions`, `interrupt` fail closed**; the hook does not run for commands that need no approval. `PreToolUse` supports `deny` and `allow`+`updatedInput`; `ask` is unsupported (the hook fails, the tool continues). `Stop`/`SubagentStop` require JSON on exit 0. Exit 2 blocks for several events. Default timeout 600 s; `SessionEnd`/`Interrupt` default 1 s, max 3 s. `async:true` supported (max 8 concurrent). Tool hooks cover Bash, `exec_command`, `apply_patch` (matchable as `Edit`/`Write`), MCP tools and local function tools such as `update_plan`; **hosted tools (WebSearch) are not covered** and "treat tool hooks as a guardrail, not a complete enforcement boundary".
- A third party reports PermissionRequest runs before Codex's automatic reviewer decides (S26, unverified); CodeIsland reads the reviewer from the rollout `turn_context` or `approvals_reviewer` in config (VERIFIED(S44,3p)). Atoll should show "auto-reviewed" requests as informational.
- Does the Codex **desktop (ChatGPT) app** run these hooks? The docs page is silent; a third-party troubleshooting post says desktop project hooks can sit "pending review" until trusted (S26) and Open Island/Coucou list the desktop app as supported (S53): treat as supported but verify (INFERRED).

### 3.4 `codex exec --json` (VERIFIED(S18))

JSONL on stdout: `thread.started{thread_id}`, `turn.started`, `turn.completed{usage{input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens}}`, `turn.failed`, `item.started`/`item.completed` (item types seen: `command_execution{command,status}`, `agent_message`; reasoning, file changes, MCP calls, web searches, plan updates described in prose), `error`. Flags: `-o/--output-last-message`, `--output-schema`, `codex exec resume --last|<id>`, `--sandbox read-only|workspace-write|danger-full-access` (default read-only), `--ephemeral` (no rollout), `--ignore-user-config`, `--ignore-rules`, `--approve-for-me`; `--full-auto` removed. Good for **quick tasks**. `codex mcp-server`: not covered by any page I fetched (UNKNOWN; the MCP docs page covers Codex as MCP client only, VERIFIED(S62)); not needed.

### 3.5 App server (VERIFIED(S17) unless noted)

- JSON-RPC 2.0 with the `"jsonrpc"` field omitted on the wire. Transports: `--listen stdio://` (default, JSONL), `ws://IP:PORT` (experimental/unsupported; `Origin` header requests get 403; non-loopback listeners unauthenticated by default; auth flags `--ws-auth capability-token|signed-bearer-token`), **`--listen unix://[PATH]`** (WebSocket over HTTP Upgrade on a unix socket), `off`. Handshake: `initialize` then `initialized` notification before anything else; capabilities `experimentalApi`, `optOutNotificationMethods`.
- **Default control socket**: `$CODEX_HOME/app-server-control/app-server-control.sock` (constants `app-server-control`, `app-server-control.sock`, lock `app-server-startup.lock`, VERIFIED(S21)). Hardening in source: parent dir created 0700 and rejected if not owned by the user or group/world-writable, socket mode 0600 (`CONTROL_SOCKET_MODE = 0o600`), physical socket name is a SHA-256 of the rendezvous path in a shared per-user daemon dir, rendezvous is a symlink verified to point there (VERIFIED(S20)). The managed daemon keeps the real socket at `/tmp/codex-daemon-<uid>/<hash>` with a symlink in `CODEX_HOME` that dangles after reboot (VERIFIED(S23)). `codex app-server proxy` relays bytes to that socket; each client connection needs its own `initialize`. Observed: launching `codex agents` or the desktop app starts the managed daemon (`codex app-server --listen unix:// --managed-daemon`) (VERIFIED(S23), single user report); third parties say v0.157.0 made daemon auto-start the default and v0.149/0.148 added the `codex agents` dashboard (S26, INFERRED; `daemon_auto_start = false` disables). **Whether the Codex TUI and desktop app share one daemon, and whether a second client can observe another client's live thread and its approvals, is UNKNOWN**: test with `thread/list`, `thread/resume`.
- Methods: `thread/start|resume|fork|read|list|archive|unarchive|delete|unsubscribe|revert`, `turn/start|steer|interrupt`. `thread/list` params `cursor, limit, sortKey (created_at|updated_at|recency_at), sortDirection, modelProviders, sourceKinds (cli|vscode|exec|appServer|subAgent...; default cli+vscode), archived, cwd, searchTerm`; thread fields `id, preview, ephemeral, modelProvider, createdAt, updatedAt, name, status`. **Thread status**: `notLoaded|idle|systemError|active` with `activeFlags` such as `waitingOnApproval`.
- Notifications: `thread/started`, `thread/status/changed`, `thread/closed`, `thread/name/updated`, `turn/started`, `turn/completed`, `item/started`, `item/completed`, `item/agentMessage/delta`, `serverRequest/resolved`, `thread/tokenUsage/updated`, `turn/plan/updated {turnId, explanation?, plan:[{step,status: pending|inProgress|completed}]}`, `account/rateLimits/updated`. `account/rateLimits/read` returns `rateLimits{limitId, primary/secondary{usedPercent, windowDurationMins, resetsAt}}` (VERIFIED(S17)).
- **Approvals** (server -> client requests, the client must answer): `item/commandExecution/requestApproval` (`itemId, threadId, turnId, reason?, command?, cwd?, commandActions?, proposedExecpolicyAmendment?, networkApprovalContext?, availableDecisions`) answered with `accept | acceptForSession | decline | cancel | {acceptWithExecpolicyAmendment:{execpolicy_amendment:[...]}}`; `item/fileChange/requestApproval` (`reason?, grantRoot?`); `item/permissions/requestApproval`; `mcpServer/elicitation/request`; `tool/requestUserInput` (experimental). Then `serverRequest/resolved`.
- **What can and cannot be done for approvals**: (a) via the `PermissionRequest` hook: allow/deny, works for CLI and (INFERRED) desktop, needs the one-time trust; (b) via app-server: only if Atoll is the connection that receives the request, i.e. a client that started or resumed the thread. Whether a passive second connection is also asked to answer is UNKNOWN. So the app-server is for **read-only live status** (status flags, plan, tokens, rate limits) unless a spike proves otherwise; approvals go through the hook.

### 3.6 Rollout logs (INFERRED from S61, S22, S28 third-party; official docs call the format unstable)

`~/.codex/sessions/YYYY/MM/DD/rollout-<ISO-ts>-<uuid>.jsonl` (third parties also report `.jsonl.zst` in some versions, and the rollout crate has a `compression` module: handle both; VERIFIED(S61) module list, S28 3p). Each line `{timestamp, type, payload}`, `type` in `session_meta` (id, cwd, provider, CLI version), `response_item`, `event_msg`, `turn_context`, `compacted` (S28, 3p). `event_msg.payload.type` (snake_case, VERIFIED(S22)): `task_started|turn_started`, `task_complete|turn_complete`, `turn_aborted`, `user_message`, `agent_message`, `plan_update`, `plan_delta`, `exec_approval_request`, `apply_patch_approval_request`, `request_permissions`, `request_user_input`, `exec_command_begin|end`, `patch_apply_begin|end`, `mcp_tool_call_begin|end`, `token_count`, `context_compacted`, `collab_agent_spawn_begin|end`, `sub_agent_activity`, `hook_started|completed`, `shutdown_complete`, `thread_goal_updated`. Open Island derives Codex 5h/7d windows from the local rollout (VERIFIED(S53,3p)), so `token_count` carries rate-limit data (INFERRED). Status derivation in section 6. Codex also keeps a SQLite state DB (thread index): do not touch it (schema UNKNOWN).

### 3.7 Codex quick facts

- Deep links: `codex://threads/<thread-id>` opens a local thread (id is the session UUID), `codex://threads/new?prompt=&path=&originUrl=` (S27, from search snippets; confirm the page). Jump = `open "codex://threads/<id>"` (INFERRED safe, it is a normal URL open).
- OTel: `[otel]` is disabled by default and ignored in project config (VERIFIED(S16)): never enable it from Atoll.
- Process: `codex` Rust binary / npm wrapper; names UNKNOWN. Identify via rollout recency + executable path + cwd.

---

## 4. Discovering sessions that started before any hook existed

### 4.1 Signals, best to worst

| Signal | Claude Code | Codex | Cost / caveat |
|---|---|---|---|
| Official list | `claude agents --json` (interactive + background, status, waitingFor) (VERIFIED(S6)) | none official for CLI; app-server `thread/list` + `thread/status/changed` if the socket is reachable (VERIFIED(S17)) | spawn / socket handshake |
| Live registry | `~/.claude/sessions/*.json` (pid, sessionId, cwd, status) (S4 official, keys 3p) | none | stale files; cross-check pid |
| Transcripts | `~/.claude/projects/<slug>/<id>.jsonl` mtime + tail parse | `~/.codex/sessions/Y/M/D/rollout-*.jsonl` mtime + tail parse | tail-only (512 KB window, S57), cache by mtime; may be zstd (Codex) |
| Process scan | `ps -axwwo pid=,ppid=,tty=,etime=,args=` (S58) or libproc | same | no state, only liveness/tty/cwd |
| Hooks | exact live state | exact live state | needs install + trust |

### 4.2 Process scan on macOS

- Atoll already shells out to `/bin/ps` and `/usr/sbin/lsof` elsewhere (VERIFIED(S60)). Note **`/usr/bin/lsof` does not exist; `/usr/sbin/lsof` does** (MEASURED). Prefer libproc over `ps`/`lsof`: `proc_listallpids`, `proc_pidpath`, `proc_pidinfo(PROC_PIDVNODEPATHINFO)` for **cwd**, `proc_pidinfo(PROC_PIDTBSDINFO)` for ppid/start time/`e_tdev` (controlling tty device), `sysctl(KERN_PROCARGS2)` for argv/env of same-uid processes (INFERRED: standard libproc/sysctl behaviour, not verified here). No TCC prompt is expected for same-uid processes (INFERRED).
- Identify Claude: executable resolves under `~/.local/share/claude/versions/`, a Homebrew Caskroom path, or `@anthropic-ai/claude-code-darwin-*`; confirm with `SecStaticCodeCheckValidity` and "Anthropic PBC" (VERIFIED(S13)); exclude `--print`/`-p`/`stream-json` with no tty, `.app/` GUI helpers, same-kind child forks, MCP servers (heuristics VERIFIED(S58,3p)). Map pid -> session via the registry; guard against PID reuse by comparing process start time with `startedAt`/`statusUpdatedAt`.
- Identify Codex: executable name `codex` (or node wrapper script path containing `@openai/codex`), no `app-server` in argv for "root" CLI sessions; match to a rollout by cwd + latest mtime (INFERRED). `codex app-server --managed-daemon` processes are infrastructure, not sessions.
- Status: Claude `status` from registry/`claude agents --json` (`busy|waiting|idle`, `waitingFor`); do not infer from CPU (Agents Island only uses CPU > 3% as a fallback, S58). Codex: last rollout `event_msg` (section 6); a rollout untouched for N minutes with a live process = idle; no live process and last event `task_complete`/`shutdown_complete` = done.

### 4.3 Mapping pid -> terminal and jumping

Walk `ppid` up to ~40 hops (S58) to the first GUI app (`NSRunningApplication` for the pid) or `tmux`/`screen`/`zellij`; record tty from the process.

| Host | Reliable jump | Notes |
|---|---|---|
| Terminal.app | AppleScript, match tab by `tty` (VERIFIED(S53,3p)) | Automation prompt |
| iTerm2 | AppleScript, session by tty/session id (VERIFIED(S53,3p)) | Automation prompt |
| Ghostty | AppleScript (since **1.3.0**, on by default, `macos-applescript=false` disables): app -> windows -> tabs -> terminals with `id`, `name`, `working directory`; `focus` command (VERIFIED(S29)); no `tty` property, so match by working directory/title (INFERRED) | Automation prompt |
| kitty | `kitten @ --to unix:/path focus-window --match pid:<n>` or `env:KITTY_WINDOW_ID`; needs `allow_remote_control` and `listen_on` (VERIFIED(S30)) | user must enable; opt-in only |
| WezTerm | `wezterm cli list --format json` (`pane_id, window_id, tab_id, workspace, title, cwd`; no tty_name) then `activate-pane` (list fields VERIFIED(S31); Open Island uses CLI pane targeting, VERIFIED(S53,3p)) | `WEZTERM_PANE` env |
| tmux | `tmux list-panes -a -F '#{pane_pid} #{pane_tty} #{session_name}:#{window_index}.#{pane_index}'`, then `switch-client`, `select-window`, `select-pane` (sequence VERIFIED(S54,3p)); then activate the terminal app hosting the client | no permission needed beyond running tmux |
| VS Code / Cursor | activate the app (`NSRunningApplication`) + `code <cwd>` / `vscode://file/<path>` to focus the window; **no per-tab/session focus** (Claude's `vscode://anthropic.claude-code/open` opens a new tab, VERIFIED(S10)); `claude` run in the integrated terminal has `CLAUDECODE` set but not `CLAUDE_CODE_CHILD_SESSION` (VERIFIED(S12)), which helps tell IDE terminals apart | window-level only |
| Warp | no public API; Open Island reads Warp's SQLite and clicks an AX menu item (S53,3p) | **avoid**; just activate Warp |
| Claude Desktop | `claude --desktop --resume <session-id>` (v2.1.285+) (VERIFIED(S14)) | needs `claude` on PATH |
| Codex desktop | `open codex://threads/<id>` (S27) | |

Permissions: Automation (TCC AppleEvents) per target app; Atoll has `com.apple.security.automation.apple-events` and hardened runtime but is not sandboxed (VERIFIED(S60)), **and its `Info.plist` has no `NSAppleEventsUsageDescription`** (only `tr.lproj/InfoPlist.strings` does) (VERIFIED(S60)): add it, and extend the `temporary-exception.apple-events` list only if a sandbox is ever adopted (today it is moot). Accessibility is needed only for keystroke/AX tricks: do not use them. Reading `~/.claude`, `~/.codex`, libproc and `ps` need no TCC permission (INFERRED); reading project files under `~/Desktop`/`~/Documents` would, and the feature should not need to.

---

## 5. Secure local transport recommendation

### 5.1 Comparison

| Option | For | Against |
|---|---|---|
| **Unix domain socket, `~/.atoll/run/agent.sock`** (recommended) | file-permission gate; no TCP port, so not reachable from web pages; `LOCAL_PEERCRED`/`LOCAL_PEERPID` available; kernel closes on peer death (clean fail-open); `nc -U` is built in; same pattern as Codex's control socket (S20) and Claude's IDE lock dir (S10) | `sun_path` limit 104 bytes (MEASURED failure); same-uid processes can still connect |
| Loopback HTTP + bearer token | Claude `http` hooks need no helper | TCP port reachable by browsers (DNS rebinding/CSRF); token readable by any same-uid process anyway; `allowedEnvVars` plumbing (S1) |
| Existing Atoll WS `127.0.0.1/::1:9020` | already there | auto-authorizes first caller, no Origin check, browser-reachable, starts unconditionally, needs a WebSocket client (S60); not usable from `nc` |

### 5.2 Server requirements (checklist)

1. `mkdir -m 0700 ~/.atoll ~/.atoll/run`; verify ownership (uid == `geteuid()`) and mode `0700` on every start, refuse otherwise (Codex does exactly this, VERIFIED(S20)); `umask(0o177)` before `bind`, then confirm `0600`; never in `/tmp`; unlink only if the path is a socket owned by us.
2. `getsockopt(LOCAL_PEERCRED)` (xucred uid == ours) on `accept`; log `LOCAL_PEERPID` for diagnostics. Do not claim the peer is "Claude": any same-uid process can say anything. A random token in a 0600 file adds nothing against same-uid attackers (they can read it), so do not pretend it does (Claude's own IDE token has the same property and Anthropic says so, VERIFIED(S10)).
3. Protocol: first line `{"v":1,"agent":...,"ppid":...}`, remainder is the agent's hook JSON, EOF-terminated (MEASURED to work with `nc`). Cap total bytes (1 MiB), read deadline for non-blocking events (2 s), max connections (e.g. 64) and max pending approvals (e.g. 16); drop on malformed JSON.
4. Pending approvals are keyed by **server-generated UUID bound to the open connection**; the decision is written back on that same connection only. There is **no** `approve(id)` RPC, so a spoofing process cannot approve someone else's request. Build the decision JSON server-side from an enum; never echo client strings into it (Claude Island validated none, S59).
5. Treat every field as untrusted display text: truncate, strip control/bidi characters, never render as markdown/links, never auto-open paths or URLs from payloads; validate `cwd` exists and, for jump actions, that the pid is alive, is the claimed agent and has the claimed cwd.
6. Approval timeout (configurable, default ~60-120 s): on expiry write nothing and close, so the agent falls back to its own prompt. Provide "Let terminal decide" (immediate empty close), "Allow once", "Deny"; "Always allow" via `updatedPermissions` only behind an explicit confirmation (it persists a rule in the user's settings, VERIFIED(S1)).
7. Spoof risk that remains: fake sessions/approval cards (display-only). Mitigate by labelling unverified sessions (no registry/pid match) and never putting Allow buttons on them.

### 5.3 Hook client choice (MEASURED on macOS 27.2, median of 7 spawns)

`/usr/bin/true` 1.8 ms; `/usr/bin/nc` 3.3 ms; `/usr/bin/perl -e 1` 4.5 ms (Perl 5.34.1, `IO::Socket::UNIX` loads); `/usr/bin/curl --version` 6.9 ms (`--unix-socket` supported, curl 8.7.1); `/usr/bin/python3 -c 1` 30.1 ms; `/usr/bin/osascript` 45 ms. `/usr/bin/python3` here is the Command Line Tools shim (hard-linked xcrun stub; the real interpreter is in `/Library/Developer/CommandLineTools`): on a Mac without CLT it triggers an installer prompt instead of running (INFERRED from shim design; Apple has said python is provided via CLT shims, S63), so **do not depend on python3** (Claude Island does). `nc -U` is the right default. A bundled signed Swift helper (Open Island style) is the alternative when you need richer logic, at the cost of a stable-path problem (Codex hash trust, app moves).

### 5.4 Reuse of Atoll's extension server / AtollExtensionKit?

No for ingestion (reasons in 5.1; the auto-authorize is at `ExtensionRPCService.swift:154-155` and the missing Origin check is already recorded in `docs/FEATURE-MATRIX-B.md` section J). Possible later: once agent sessions exist as an internal model, expose a **read-only** summary to authorized extensions through AtollExtensionKit (live activity of "N agents running"). Independently of this feature, harden 9020 (Origin rejection, per-app user consent, start only when enabled).

### 5.5 Existing Atoll code that helps

`NotchViews` enum (`enums/generic.swift:73`) already has `.llmUsage`, `.terminal`, `.extensionExperience`: add `.agents`. `ContentView.swift:1275` switches on it (`NotchLLMUsageView()`); `Defaults` key pattern `enableLLMUsageFeature` default false (`models/Constants.swift:1274`): add `enableAgentsFeature` default false. `managers/LLMUsage/JSONLUsageParser.swift`, `ModelPricing*` and `pricing.json` can price transcripts locally. `managers/TerminalManager.swift` (SwiftTerm) can host a quick-task session. Do **not** build on `ClaudeQuotaClient`/`CodexQuotaClient`: they read `~/.claude`/Keychain OAuth tokens, can rewrite Claude Code's stored credentials and call `api.anthropic.com`, `chatgpt.com/backend-api/wham/usage` (VERIFIED(S60), `FEATURE-MATRIX-B.md` H). For quota use: Claude statusLine `rate_limits` relay; Codex rollout `token_count` and, when connected, app-server `account/rateLimits/read` (this asks Codex, which does its own network call; label it as such).

---

## 6. Normalised data model

```swift
enum AgentKind { case claudeCode, codex }                 // + .other later
enum Surface   { case terminal, vscode, jetbrains, desktopApp, xcode, headless, background, unknown }
enum SessionStatus { case starting, running, waitingInput, needsPermission, idle, done, failed, stopped, unknown }
enum Provenance { case hook, registry, transcript, rollout, appServer, processScan }   // strongest wins per field

struct AgentSession {              // key: (kind, sessionId); never trust a client-supplied id for authorisation
    let kind: AgentKind; let sessionId: String           // Claude session_id / Codex thread-id (UUID)
    var name: String?; var title: String?                // /rename, ai-title, thread name, first prompt
    var cwd: URL; var projectName: String                // last path component or repo name
    var surface: Surface; var pid: Int32?; var startTime: Date?   // pid + start time guard against reuse
    var tty: String?; var hostApp: String?               // bundle id of terminal/IDE; tmux target if any
    var jump: JumpTarget?                                // terminal(tty) | tmux(pane) | deepLink(URL) | app(bundleId)
    var status: SessionStatus; var statusSince: Date; var waitingFor: String?
    var permissionMode: String?; var model: String?; var effort: String?
    var currentTool: ToolActivity?                       // name, short summary (truncated), startedAt, toolUseId
    var lastAssistantText: String?; var lastPrompt: String?   // truncated, display-only
    var tasks: [AgentTask]; var subagents: [Subagent]
    var pending: [PendingApproval]                       // 0..n, oldest first
    var usage: UsageSnapshot?
    var transcriptPath: URL?; var lastEventAt: Date; var provenance: [String: Provenance]
}
struct AgentTask { var id: String; var title: String; var status: TaskStatus /*pending|inProgress|completed|cancelled*/; var activeForm: String?; var order: Int }
struct Subagent { var id: String; var type: String?; var status: SubStatus /*running|done|failed*/; var startedAt: Date; var currentTool: ToolActivity?; var lastText: String?; var transcriptPath: URL? }
struct PendingApproval {           // lives only while the hook connection is open
    let id: UUID                    // server-generated
    var sessionKey: (AgentKind, String); var agentId: String?   // set when it comes from a subagent
    var tool: String; var summary: String; var detail: String?  // sanitised/truncated tool_input
    var suggestions: [PermissionSuggestion]                     // Claude permission_suggestions, Codex availableDecisions
    var createdAt: Date; var expiresAt: Date; var connection: ConnectionHandle   // answered ONLY via this
    var channel: Channel /*hook|appServer(readOnly)*/
}
struct UsageSnapshot { var costUSD: Double?; var inputTokens, outputTokens, cacheRead, cacheWrite: Int?
    var contextUsedPct: Double?; var contextWindow: Int?
    var fiveHourPct, sevenDayPct: Double?; var fiveHourResetsAt, sevenDayResetsAt: Date?; var source: String }
```

### 6.1 Claude Code event -> state

| Event (hook) | Effect |
|---|---|
| SessionStart(`source`) | upsert session; `status=idle` (`startup`) or keep (`resume/compact`); store `transcript_path`, `cwd`, model, `permission_mode`; bind pid from `$PPID`/registry |
| UserPromptSubmit | `status=running`, `lastPrompt`, clear `waitingFor`, clear stale pending |
| PreToolUse | `currentTool = tool_name + summarise(tool_input)`, `status=running` (not if already `needsPermission` for this tool) |
| PermissionRequest | create `PendingApproval`; `status=needsPermission`; if `agent_id` present attribute to that subagent |
| (decision sent or hook closed) | remove pending; `status=running` if allowed, else wait for next event (deny usually leads to `PermissionDenied` then more activity) |
| PermissionDenied | note denial; `status=running` |
| PostToolUse / PostToolUseFailure | clear `currentTool` (match `tool_use_id`); for `TaskCreate/TaskUpdate/TodoWrite` refresh `tasks` (also re-read `~/.claude/tasks/<id>/`); for `Agent` tool mark subagent done |
| Notification `idle_prompt` / `agent_needs_input` | `status=waitingInput`; `permission_prompt`: ignore (already covered by PermissionRequest, as Claude Island does) |
| SubagentStart / SubagentStop | add / finish `Subagent(agent_id)`; Stop carries `last_assistant_message` |
| TaskCreated / TaskCompleted | add / complete `AgentTask(task_id)` |
| Stop | `status=idle` (turn finished), `lastAssistantText = last_assistant_message`, clear tool and pending; notify "done" |
| StopFailure | `status=failed` (sticky until next prompt); show `error` (e.g. `rate_limit`) |
| PreCompact / PostCompact | transient `compacting` badge |
| SessionEnd | `status=done`, remove from "live" list (keep in history by transcript) |
| no events and registry says `waiting` | `needsPermission` if `waitingFor == "permission prompt"`, `waitingInput` otherwise |

Safety nets: expire `running` to `unknown` if no event for 10 min and the pid is dead; a missing registry file plus dead pid = `done`; pending approvals vanish when the connection closes.

### 6.2 Codex event -> state

| Source | Effect |
|---|---|
| Hook SessionStart / UserPromptSubmit / PreToolUse / PermissionRequest / PostToolUse / Stop / SubagentStart / SubagentStop / Interrupt / SessionEnd | same as Claude rows above (Interrupt: `status=idle`, mark "interrupted"); PermissionRequest allow/deny only |
| rollout `task_started`/`turn_started` | `running`; `task_complete`/`turn_complete` | `idle`; `turn_aborted` | `idle` (interrupted); `shutdown_complete` | `done` |
| rollout `exec_approval_request` / `apply_patch_approval_request` / `request_permissions` with no later `exec_command_begin`/`patch_apply_begin` or `turn_*` | `needsPermission` (read-only: answer in Codex) (INFERRED) |
| rollout `plan_update` / hook `update_plan` / app-server `turn/plan/updated` | replace `tasks` (`inProgress` -> in progress) |
| rollout `collab_agent_spawn_*`, `sub_agent_activity`, hook SubagentStart/Stop | subagents |
| rollout `token_count`, app-server `thread/tokenUsage/updated`, `account/rateLimits/updated` | `usage` |
| app-server `thread/status/changed` (`active`+`waitingOnApproval`) | `needsPermission` (read-only) |

---

## 7. Sources

Official (Claude Code), all under `https://code.claude.com/docs/en/` (the `docs.claude.com/en/docs/claude-code/...` URLs redirect there):

- S1 `hooks` (events, schemas, output, http hooks, timeouts, trust, async). S2 `statusline`. S3 `settings`. S4 `claude-directory` (application data, `sessions/`, `tasks/`, retention). S5 `sessions` (transcript path, resume, `--bg`). S6 `agent-view` (`claude agents --json`, jobs/daemon). S7 `tools-reference` (Agent, Task*, TodoWrite availability). S8 `interactive-mode` (task list). S9 `desktop`. S10 `vs-code` (extension, IDE lock file, URI handler). S11 `deep-links`. S12 `env-vars`. S13 `setup` (native binary, signing). S14 `cli-reference`.

Official (OpenAI / Codex):

- S15 https://learn.chatgpt.com/codex/hooks (from https://developers.openai.com/codex/hooks). S16 https://learn.chatgpt.com/docs/config-file/config-advanced (from .../codex/config-advanced; `notify`, hooks locations, otel, history). S17 https://learn.chatgpt.com/codex/app-server. S18 https://learn.chatgpt.com/codex/noninteractive. S19 https://learn.chatgpt.com/codex/app. S62 https://learn.chatgpt.com/codex/mcp. S27 https://developers.openai.com/codex/app/commands (deep links; read via search snippet only).
- S20 https://raw.githubusercontent.com/openai/codex/main/codex-rs/app-server-transport/src/transport/unix_socket.rs. S21 https://raw.githubusercontent.com/openai/codex/main/codex-rs/app-server-transport/src/transport/mod.rs. S22 https://raw.githubusercontent.com/openai/codex/main/codex-rs/protocol/src/protocol.rs. S61 https://raw.githubusercontent.com/openai/codex/main/codex-rs/rollout/src/lib.rs. S25 https://api.github.com/repos/openai/codex. S23 https://github.com/openai/codex/issues/54893. S24 https://github.com/multica-ai/multica/issues/4041 (macOS `SUN_LEN`).
- Third party (unverified by OpenAI): S26 https://codex.danielvaughan.com/2026/09/25/codex-cli-daemon-auto-start-stable-default-v0157/ , .../2026/08/29/codex-cli-v0149-multi-session-agents-dashboard-codex-queue-working-directory/ , .../2026/05/25/codex-cli-hooks-after-ga-event-model-trust-verification-production-patterns/ ; https://aident.ai/blog/fix-codex-desktop-project-hooks-not-running-trust ; https://github.com/openai/codex/issues/48195 . S28 https://codex.danielvaughan.com/2026/06/01/codex-cli-session-history-local-search-rollout-format-knowledge-mining/ .

Terminals: S29 https://ghostty.org/docs/features/applescript. S30 https://sw.kovidgoyal.net/kitty/remote-control/. S31 https://wezterm.org/cli/cli/list.html. S63 https://developer.apple.com/forums/thread/652014 (python3 shims in `/usr/bin`).

Projects (GitHub API + README/LICENSE/source read 2026-10-21): S40 https://github.com/openai/codex (see S25). S41 https://github.com/Octane0411/open-vibe-island (LICENSE, README, `Sources/OpenIslandCore/`). S42 https://github.com/Louis-CFM/coucou. S43 https://github.com/farouqaldori/vibe-notch. S44 https://github.com/wxtsky/CodeIsland. S45 https://github.com/erha19/ping-island. S46 https://github.com/mustafahalabi/agents-island. S47 https://github.com/sj719045032/claude-statistics. S48 https://github.com/oa1mgo/nook-notch. S49 https://github.com/rifqiakrm/code-island. S50 https://github.com/rawsun007/claude-notch. S51 https://github.com/vibeislandapp/vibe-island. S52 https://github.com/asheshgoplani/agent-deck , https://github.com/kbwo/ccmanager , https://github.com/samleeney/tmux-agent-status , https://github.com/smtg-ai/claude-squad , https://github.com/ccusage/ccusage . S53 https://raw.githubusercontent.com/Octane0411/open-vibe-island/main/README.md . S54 https://raw.githubusercontent.com/Octane0411/open-vibe-island/main/docs/architecture.md . S55 https://raw.githubusercontent.com/farouqaldori/vibe-notch/main/ClaudeIsland/Resources/claude-island-state.py . S56 https://raw.githubusercontent.com/farouqaldori/vibe-notch/main/ClaudeIsland/Services/Hooks/HookInstaller.swift . S59 https://raw.githubusercontent.com/farouqaldori/vibe-notch/main/ClaudeIsland/Services/Hooks/HookSocketServer.swift . S57 https://raw.githubusercontent.com/mustafahalabi/agents-island/main/Sources/AgentsIsland/ClaudeSessions.swift . S58 https://raw.githubusercontent.com/mustafahalabi/agents-island/main/Sources/AgentsIsland/AgentMonitor.swift .

Local: S60 Atoll repo: `Toplet/services/Extensions/ExtensionRPCServer.swift`, `ExtensionRPCService.swift:151-158` (auto-authorize), `Toplet.entitlements`, `Info.plist`, `enums/generic.swift:73`, `managers/LLMUsage/*`, `docs/FREE-LOCAL-OPERATION.md`, `docs/FEATURE-MATRIX-B.md` sections H and J, `LICENSE`, `NOTICE`. Measurements: this document, section 2.8 and 5.3 (macOS 27.2).

---

## 8. Practical next steps

### 8.1 Spikes to run before coding (each is small)

1. **Payload recorder**: a dev-only hook that appends raw stdin of every event to `~/.atoll/dev/payloads/*.jsonl`; run one Claude and one Codex session (terminal, VS Code, desktop app) and diff against sections 2-3. Answers: `$PPID` correctness, which events fire in desktop/VS Code, whether `TaskCreate` fires `TaskCreated`, and the real shape of `~/.claude/sessions/*.json`.
2. **Permission-dialog visibility**: does the terminal dialog show while a `PermissionRequest` hook is blocking (Claude and Codex)? Decides the default approval timeout and whether "Let terminal decide" is needed at once.
3. **Codex app-server observer**: with the managed daemon running, connect to `~/.codex/app-server-control/app-server-control.sock` (WebSocket upgrade), `initialize`, `thread/list`, then `thread/resume` a thread owned by the TUI: do status/notifications flow, and does an approval request reach a second client?
4. **Hook trust UX**: confirm what Codex does with an untrusted Atoll hook (silent skip) and design a "needs `/hooks` review" state in the notch.
5. **Pid reuse and registry staleness** under `kill -9` of a `claude` session.

### 8.2 Phasing

- **P0 (no install, read-only)**: registry + `claude agents --json` + transcripts + rollouts + libproc scan, 2 s poll only while the section is visible, session list with status, cwd, terminal jump, usage from transcripts. Needs only Automation permission for jumps.
- **P1 (opt-in hooks)**: Settings screen shows exact JSON to be merged, backup, diff, "Remove hooks" button, health check (path exists, hash/trust state for Codex). Plugin form for Claude as the cleaner alternative. Chain, never replace, an existing `statusLine`.
- **P2 (approvals)**: `PermissionRequest` blocking path only, with the server rules in 5.2.
- **P3 (Codex live)**: app-server read-only status; Codex approvals stay on the hook.
- **P4 (quick tasks)**: explicit user action, shows the exact command, defaults to read-only/plan (`claude --bg --permission-mode plan`, `codex exec --sandbox read-only --json`), with `--max-turns`/`--max-budget-usd`; or simply start `claude`/`codex` inside Atoll's existing embedded terminal so the native approval UI is used.
- Always off by default (`enableAgentsFeature = false`), no network calls from this feature, no telemetry, no accounts, uninstall removes every hook entry it added.
