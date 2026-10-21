# Agent hook formats: what was verified, what was not

Date: 2026-10-21. Scope: the exact hook configuration formats that `AtollAgents/Hooks/*` writes into Claude Code's user settings and Codex's `hooks.json`. Companion to `docs/AI-AGENTS-RESEARCH.md` (sections 1.3, 2.4, 2.8, 3.3, 5.2, 5.3).

Tags: **VERIFIED** = read in the primary source on this date (URL given). **MEASURED** = observed on this Mac (macOS 27.2) by `AtollAgents/Tests/run_hooks.sh`. **UNKNOWN** = could not be established; the code does not rely on it. Caveat: the docs pages were read through a summarising fetcher (WebFetch), except the Claude settings JSON schema which was downloaded with curl and parsed as JSON, so field names are high-confidence but quoted prose is not byte-exact.

## 1. Claude Code

### 1.1 Verified

Sources: https://code.claude.com/docs/en/hooks, https://code.claude.com/docs/en/settings, https://www.schemastore.org/claude-code-settings.json (the published JSON schema; `json.schemastore.org/...` 301-redirects there).

- **Shape** (VERIFIED, docs + schema): `hooks.<EventName>` is an array of matcher groups; a group is `{ "matcher"?: string, "hooks": [handler, ...] }`; a command handler is `{ "type": "command", "command": string, "timeout"?: number (seconds), "async"?, "asyncRewake"?, "shell"?, "if"?, "statusMessage"?, "args"? }`. Other handler types exist (`http`, `mcp_tool`, `prompt`, `agent`); Atoll writes only `command`.
- **No marker key is possible** (VERIFIED, schema): `hookMatcher` has `additionalProperties: false` (only `matcher`, `hooks`) and the command handler has `additionalProperties: false` (only the nine keys above). An `"atoll": true` key would fail schema validation. Atoll therefore recognises its entries by the **exact command string** (plus a signature check to find its own older/other-socket entries, see 4).
- **Events** (VERIFIED, schema): 31 names; all 17 that Atoll uses are present: `SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, PermissionDenied, Notification, Stop, StopFailure, SubagentStart, SubagentStop, TaskCreated, TaskCompleted, PreCompact, PostCompact`. An unknown event name produces a "Settings Warning" and that entry is skipped, the rest of the file stays in effect (VERIFIED, settings page "Fix a broken settings file").
- **Matcher** (VERIFIED, hooks page): `"*"`, `""` or an omitted matcher matches everything; events without matcher support (`UserPromptSubmit`, `Stop`, `TaskCreated`, `TaskCompleted`, ...) silently ignore the field. Atoll **omits `matcher`** everywhere.
- **Timeout** (VERIFIED): seconds; default 600 for command hooks (30 on `UserPromptSubmit`, 10 on `MessageDisplay`). `SessionEnd` hooks share a **1.5 s budget; a per-hook `timeout` raises it, up to 60 s**.
- **PermissionRequest output** (VERIFIED): `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny", ...}}}`; `updatedInput`/`updatedPermissions` for allow, `message`/`interrupt` for deny. Exit code 2 does not change the flow and its stderr is discarded. Empty stdout + exit 0 on this event is **not stated** by the page (UNKNOWN; research 2.3 assumes "terminal decides").
- **Exit codes** (VERIFIED): 0 = success; 2 = block (event dependent); any other code = non-blocking error shown as `<hook> hook error ... Failed with non-blocking status code`. Hence every Atoll command ends in `; exit 0`.
- **Plain stdout** (VERIFIED): on `UserPromptSubmit` exit 0 the plain stdout is added to Claude's context (research 2.3 lists `SessionStart` too). Hence non-blocking Atoll hooks send stdout and stderr to `/dev/null`.
- **Shell form** (VERIFIED, docs): the `command` string is passed to a shell, "`sh -c` on macOS and Linux". The schema's `shell` property says the default `"bash"` "uses the login shell (bash/zsh/sh)". The two statements are not identical; the Atoll command is therefore plain POSIX and tested under `sh`, `bash` and `zsh`. A user whose login shell is fish/nushell is not covered by the schema text (UNKNOWN).
- **Same handler in several files runs once** (VERIFIED, docs). How "same" is decided (command string? whole object?) is **not stated** (UNKNOWN). Atoll writes to the user file only, so this only matters if the user also copied the command elsewhere.
- **Settings are strict JSON** (VERIFIED, settings page): "a `//` comment or a trailing comma is a syntax error", reported as a Settings Error. So a file the parser rejects is also broken for Claude Code; Atoll refuses it instead of "repairing" it.
- **Live reload** (VERIFIED, docs): settings files are watched and hooks are re-read in the running session ("Direct edits to hooks in settings files are normally picked up automatically"). Not tested empirically against a live `claude`.
- **User file location** (VERIFIED, settings page): `~/.claude/settings.json`; `CLAUDE_CONFIG_DIR` relocates settings, history and plugins. The hooks page does not mention `CLAUDE_CONFIG_DIR` (it does not need to).
- **`disableAllHooks`** (VERIFIED, schema + docs): boolean; true disables all hooks (and statusLine execution); a managed `true` cannot be overridden. **`allowManagedHooksOnly`** (VERIFIED): managed settings only. Atoll reports both and still writes (the user may flip the flag later).
- **`statusLine`** (VERIFIED, schema): object `{type:"command", command, padding?, refreshInterval?, hideVimModeIndicator?}`. Atoll never reads, writes or wraps it.

### 1.2 Not verified (and what the code does about it)

- Whether an extra key inside a handler would warn at runtime: schema says invalid, runtime behaviour UNKNOWN. Not needed (no marker).
- Whether the terminal permission dialog stays visible while a PermissionRequest hook is waiting: UNKNOWN (research 0.4). Consequence: the hook timeout is a bounded backstop (900 s), not 24 h.
- Managed settings path `/Library/Application Support/ClaudeCode/managed-settings.json`: **not re-verified** this session; it is only read, for a warning, and injectable (`managedClaudeSettingsPath`, nil disables).
- Hook behaviour in Claude Desktop / VS Code beyond "reads the same settings files" (research 2.7): UNKNOWN.
- `$PPID` equals the `claude` process pid in a shell-form hook: INFERRED (research 2.4); the server also gets the socket peer pid.

## 2. Codex

### 2.1 Verified

Source: https://learn.chatgpt.com/docs/hooks.md (the old `https://developers.openai.com/codex/hooks.md` answers 308 to it). A web search also surfaced `https://developers.openai.com/codex/hooks`, `https://learn.chatgpt.com/codex/hooks`, and a third-party guide (https://codex.danielvaughan.com/2026/05/25/codex-cli-hooks-after-ga-event-model-trust-verification-production-patterns/) whose `timeout: 30` example matches the official shape.

- **hooks.json** (VERIFIED): top-level `hooks` key wraps the event names; each event maps to an array of matcher groups; each group holds `hooks: [handler...]`; optional top-level `description` is allowed and ignored. Handler `{ "type": "command", "command": "...", "timeout": N, "statusMessage"?, "async"? ... }` (`type` is `command` or `mcp_tool`; `prompt`/`agent` are parsed but skipped). `timeout` is seconds, default 600; `SessionEnd` and `Interrupt` default to 1 and max out at 3.
- **Events** (VERIFIED, exactly 12): `SessionStart, SessionEnd, SubagentStart, SubagentStop, PreToolUse, PermissionRequest, PostToolUse, PreCompact, PostCompact, UserPromptSubmit, Stop, Interrupt`.
- **Matcher** (VERIFIED): a regex; `"*"`, `""` or omitted matches everything; `UserPromptSubmit`, `Stop`, `Interrupt` ignore it. Atoll omits it.
- **Locations** (VERIFIED): `~/.codex/hooks.json`, `~/.codex/config.toml`, `<repo>/.codex/hooks.json`, `<repo>/.codex/config.toml`, plugins, managed. All matching hooks from all sources run (none overrides another). If one layer has both `hooks.json` and inline `[hooks]`, Codex merges them **and prints a startup warning**; the page recommends one representation per layer. Hooks are on by default; `[features] hooks = false` disables them (`codex_hooks` is a deprecated alias).
- **TOML form** (VERIFIED, verbatim fragments): `[[hooks.PreToolUse]]` with `matcher = "^Bash$"`, then `[[hooks.PreToolUse.hooks]]` with `type = "command"`; same handler fields as JSON. **Atoll does not write TOML** (no parser, no safe way); it only line-scans `config.toml` to warn about inline `[hooks]` and `hooks = false`.
- **Trust** (VERIFIED): non-managed hooks do not run until reviewed with `/hooks` in the CLI; trust is recorded against the hook's current hash; new or changed hooks are skipped until re-trusted; at startup Codex warns to open `/hooks` when review is needed. `--dangerously-bypass-hook-trust` skips persisted trust for one invocation.
- **Output** (VERIFIED): `PermissionRequest`: "If no matching hook decides, Codex uses the normal approval flow"; plain stdout is ignored for `PreToolUse/PermissionRequest/PostToolUse/PreCompact/PostCompact`; plain stdout is added as developer context for `SessionStart`, `UserPromptSubmit`, `SubagentStart`; "Exit 0 with no output is treated as success".

### 2.2 Not verified

- **Does `Stop`/`SubagentStop`/`Interrupt` accept EMPTY stdout?** The page says `Stop` "expects JSON on stdout when it exits 0. Plain text output is invalid", but also says exit 0 with no output is success in general, and for `Interrupt` says exit 0 with no output is accepted. For `Stop`/`SubagentStop` empty output is therefore **UNKNOWN**. Atoll sends empty output (the product rule: hooks print nothing except a PermissionRequest answer). **First thing to test with a live Codex.** If Codex reports a hook failure on every Stop, the fix is `printf '{}'` for those two events, which changes the command bytes: bump `HookCommand.commandVersion` and the pins.
- How the trust hash is computed, what it covers, and where trust is stored (the page does not mention `[hooks.state]`; research 3.3 has it from a third party). Atoll's rule: **never change the command bytes without bumping `commandVersion`**; the report always tells the user to run `/hooks` once and that a changed command needs a new review.
- `CODEX_HOME` is not mentioned on the hooks page (it is in the config docs per research 3.1; not re-fetched).
- The shell Codex uses to run `command` (the page only says it runs with the session `cwd`). The command is POSIX shell and uses only `$HOME`, `$PPID`, `printf`, `cat`, `[ -S ]`.
- Whether the Codex desktop app runs these hooks (research 3.3: INFERRED).

## 3. The commands (byte-stable; `HookCommand.swift`, pinned in the tests)

```
Claude/Codex, non-blocking events (all but PermissionRequest):
S="$HOME/.atoll/run/agent.sock"; [ -S "$S" ] || exit 0; { printf '{"v":1,"agent":"claude","ppid":%s}\n' "$PPID"; cat; } | /usr/bin/nc -w 1 -U "$S" >/dev/null 2>&1; exit 0

PermissionRequest (blocking; the only one whose stdout reaches the agent):
S="$HOME/.atoll/run/agent.sock"; [ -S "$S" ] || exit 0; { printf '{"v":1,"agent":"claude","ppid":%s}\n' "$PPID"; cat; } | /usr/bin/nc -U "$S" 2>/dev/null; exit 0
```

(`"agent":"codex"` for Codex.) Custom socket: an absolute, `~/` or `$HOME/` path, escaped for double quotes (`"`, `\`, `$`, backtick), validated against the 103-byte `sun_path` limit; a hostile path cannot inject shell (tested).

Timeouts (seconds): non-blocking 3; `SessionEnd` (both agents) and Codex `Interrupt` 2 (inside Claude's raised-budget rule and Codex's 1-3 s window); `PermissionRequest` **900**. Justification for 900: Atoll answers, or closes without an answer so the agent falls back to its own prompt, after its own approval timeout (default about 120 s, clamped to `HookCommand.maxApprovalTimeoutSeconds` = 600). The hook timeout only bounds a **wedged** Atoll, so it must exceed 600 (a slow human never races it) but stay small, because whether the terminal dialog is visible during the wait is UNKNOWN. Claude Island's 86400 is rejected for that reason. The core must clamp its approval timeout to 600.

MEASURED here (macOS 27.2, `run_hooks.sh`): live server round trip with byte-exact `header + payload` (300 KB too); under `sh`, `bash` and `zsh`; empty stdout/stderr and exit 0 for: server that replies garbage (non-blocking), missing socket (fast, no spawn), stale socket file, regular file or directory at the path, `HOME` pointing nowhere, server that accepts and closes; wedged server (accepts, never closes): non-blocking hook returns in under 3 s; blocking hook returns the server's decision JSON verbatim and nothing when the server closes without one.

## 4. Merge and uninstall behaviour (`HooksFileEditor.swift`)

- Targets: `$CLAUDE_CONFIG_DIR/settings.json` or `~/.claude/settings.json`; `$CODEX_HOME/hooks.json` or `~/.codex/hooks.json`. Never project, local or managed files; never `config.toml`; never `statusLine`.
- Strict, order-preserving JSON reader (`OrderedJSON.swift`). Keeps key order, number tokens and string tokens byte-for-byte; **only whitespace is normalised** (indent detected: tab or N spaces, default 2; CRLF and BOM and trailing newline reproduced). A file Claude Code wrote itself (JSON.stringify, 2 spaces; layout checked against node's output) round-trips **byte-identical**, and install followed by uninstall returns the original bytes (tested). A hand-formatted or minified file gets re-indented on the first write; the backup keeps the original.
- Refuses (nothing written, no backup, no temp file): unparseable JSON (comments, trailing commas, truncated, invalid UTF-8, nesting over 128, file over 64 MiB), top level not an object, `hooks` not an object, a managed event that is not an array, duplicate `hooks` or event keys. An empty or whitespace-only file is treated as `{}` (nothing to lose).
- Order of operations: parse and plan every requested file, check writability (file, directory, backup directory), only then write. If a later write fails after an earlier one succeeded, the error is `partiallyApplied(report:)`.
- Write: timestamped backup `settings.json.atoll-backup-YYYYMMDD-HHMMSS` (mode 0600, `-NN` suffix on a same-second collision) next to the path the user gave, newest 5 kept (only names matching the exact pattern are ever deleted); temp file in the target's own directory, `fsync`, mode copied from the original (0600 and a 0700 directory for new files), lost-update guard (the file must be byte-identical to what was parsed, checked before the backup and again right before `rename`), atomic `rename`. Symlinked files (also dangling) are followed; the link is kept. A read-only file is refused (`readOnly`).
- Idempotent: if every entry is already present nothing is written and no backup is made.
- Ownership: **exact command string** = installed. Additionally the signature (Atoll's `{"v":1,"agent":"<agent>","ppid":%s}` header + `/usr/bin/nc` + the socket check) marks Atoll's own older-version or other-socket entries as **stale**: install replaces them (so events are never delivered twice), uninstall removes them. User hooks, including ones on the same events or inside the same group, are never touched; our handler inside a user's group is removed alone and the group stays.
- Uninstall removes only emptied containers it emptied itself (group, event key, `hooks` key). A `{}` file stays behind if Atoll had created it.
- `state()` = exact match per event: all 17 / 12 = installed, some = partial (`detailedState()`), none = not installed; unreadable files are reported (`unreadable`) and mapped to "not installed" in `HooksState`, never thrown.

Known limits: whitespace normalisation as above; hard links and extended attributes/ACLs of the original are not preserved (rename replaces the inode); two writers racing between the final check and `rename` can still lose an update (microseconds); a `~/.claude` that did not exist is created (0700).

## 5. Reconciliation notes

- Core's `HookInstalling` (Core/HookInstalling.swift) has `install(claude:codex:) throws` and `uninstall() throws` returning Void. `HookInstaller` conforms; the structured results come from `installWithReport` / `uninstallWithReport` (report: events added / already present / removed / stale removed, backup path, warnings, `needsCodexTrustReview`).
- Core's `HookMarkerInspector` looks for the substring `.atoll/run/agent.sock`, which Atoll's commands contain (`$HOME/.atoll/run/agent.sock`), so it also detects installs; it cannot tell exact from stale or partial. Prefer `HookInstaller.state()` / `detailedState()`.
