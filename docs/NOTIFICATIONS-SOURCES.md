# Notch notifications: sources, what works, what does not

Scope: the queue, ingestion and facade layer in `AtollNotch/Core` (`NotificationQueue.swift`, `NotificationIngress*.swift`,
`NotchNotificationCenter.swift`, `NotificationAdapters*.swift`) and the `scripts/atoll-notify` command. Companion to
`docs/NOTIFICATIONS-IDLE-AUDIT.md` (sections 4, 5, 7.2, 7.5, 7.6 T3, T8, T10). Nothing under `Toplet/` is touched yet:
wiring is the integration step.

## The statement that governs everything else

**Atoll cannot see other apps' notifications.** macOS has no public API that lets one app observe, read or intercept the
notifications another app posts. `UNUserNotificationCenter` only covers the calling app's own notifications
(audit section 5; the macOS SDK header exposes no cross-app query). Atoll therefore shows notifications that **reach it
on purpose**: from Atoll itself, from apps that integrate with it, from the `atoll-notify` command, from calendar and
reminders, and from AI agents the user has enabled. It does not show your Mail, Messages, Slack or Safari banners, and no
setting will make it.

Product copy to use: "Atoll shows notifications from Atoll itself, apps that integrate with it, the `atoll-notify`
command, calendar and reminders, and AI agents you enable. It does not read other apps' macOS notifications."

## SUPPORTED sources

Test status uses the standalone harness `AtollNotch/Tests/run_queue.sh` (swiftc only, no Xcode, fake clocks, temp dirs
under `/tmp/an-<pid>`, never `~/.atoll`). "Fakes" means the logic is verified against test doubles, not the real system
service. "Live" means it needs the running app and was NOT verified here.

| Source (`NotificationSource`) | What it does | Permission needed | How it is tested | Not verified |
|---|---|---|---|---|
| `cli`: `atoll-notify` over a private unix socket | A script, git hook, cron job or CI step posts a title, optional body, subtitle, icon, click action, priority and TTL. Reply is one JSON line, so scripts learn about rejections. | None beyond being the same macOS user. Socket is `~/.atoll/run/notify.sock`, mode 0600, directory 0700. Off until the user enables the CLI source. | Real `scripts/atoll-notify` with real `/usr/bin/nc` against (a) a fake server that captures the exact bytes (hostile arguments in every position, bash and dash, PATH hijack, exit codes, hostile server replies) and (b) the real server and facade (rate limit, source switch, stop, concurrency). Socket security suite T8 (see below). | Behaviour inside the signed app bundle; the `atoll-notify` install location on `PATH` (integration step). |
| `atoll`: Atoll's own `UNUserNotificationCenter` | Routes a notification Atoll itself posts into the notch and suppresses the duplicate system banner; falls back to the macOS banner when notch notifications are off for this source. Records the result of `requestAuthorization` (`lastAuthorization`) for the T10 probe. | Standard notification permission prompt, requested only when the integration calls `requestAuthorization()`; never at start. | Adapter logic through a protocol fake (banner suppression, fall-back, dedupe by identifier, URL validation, activation callback, authorisation result recorded). `UNNotificationContent` to info conversion tested with real `UNMutableNotificationContent`. The real delegate wrapper compiles with the rest. | **Live:** whether authorisation and `willPresent` work for an ad-hoc-signed accessory app on macOS 27 (audit R6/T10). Nothing about the real `UNUserNotificationCenter` was exercised. |
| `agentClaude`, `agentCodex`: AI agents | "Claude Code needs permission in `<project>`" (high), "waiting for you", "finished", "failed". One notification per agent session: a later state replaces the earlier one. Click opens the agent session. The tool detail goes in the body, so the privacy mode hides it. | The agent hooks the user already enabled in the AI-agents feature. This layer adds no new permission. | Mapping and status-transition table (19 transitions), dedupe per session, privacy hiding, Focus behaviour, wired through the facade with a click action. Uses a mirror enum of `AgentStatus`, so it does not depend on the AtollAgents module. | **Live:** real AgentCenter events (AtollAgents is not integrated into the app yet). |
| `extensionApp`: AtollExtensionKit apps | Protocol (`ExtensionNotificationAdapter`) plus a minimal gate (`AuthorizedExtensionNotificationAdapter`) that refuses anything not already authorised and anything whose claimed bundle id differs from the transport-verified one. | An existing `ExtensionAuthorizationManager` entry. The gate never creates one and never auto-authorises. | Fakes: unauthorised, spoofed identity, malformed identity, not started, and "authorisation is never consulted for an unverified identity". | **Not wired.** Do not advertise "apps can post notifications" until the extension server verifies callers (below). |
| `calendar`, `reminders`: EventKit | Thin protocol adapters (`CalendarAlertProviding`, `ReminderAlertProviding`) map an alert to a notification with a relative time ("In 5 min", "Starting now"), dedupe so a repeated alert does not stack, and let Focus and privacy policy apply. | The Calendar / Reminders access the user already granted for the existing features. | Fakes only. | **Live:** real EventKit providers (they should wrap the existing `CalendarService` and `ReminderLiveActivityManager`; not written here). |
| Focus | The queue consults an injected `isFocusActive` closure at accept time. Policies: `show`, `silence`, `silenceExceptCritical` (default). Silenced items go to in-memory history with a flag and are never shown. | None in this layer. The closure is where `DoNotDisturbManager` plugs in later. | Policy truth table, history flag, the closure is not even called under `show`, repeats are deduped. | **Live:** that `DoNotDisturbManager` reports Focus correctly on this Mac (it depends on private notification names and Full Disk Access, audit A10). |

### Trust model of the command-line source

Any process running as the same user can post. That is documented, not hidden:

- The socket directory is 0700, the socket 0600, and the peer uid is checked with `LOCAL_PEERCRED` at `accept()`.
  There is no TCP port and no WebSocket. It does not reuse the extension server on port 9020, which auto-authorises the
  first caller.
- The sender chooses the app name, so the notch **always** shows `"<app> (via CLI)"` (or `atoll-notify`), never a bare
  app name. A script cannot present itself as Mail.
- The sender may ask for any priority, including `critical`, which bypasses Focus. Critical is still rate limited
  (4x the normal ceiling) and capped by the queue.
- Rate limits stack: per peer pid (60/min), all peers (240/min), then the queue's per-source limit
  (`rateLimitPerMinute`, default 30/min). A per-pid limit alone cannot stop a shell loop, because every `nc` invocation is
  a new process, so the queue's per-source limit is the real backstop.
- URLs are validated before a click can use them: `https`, `http`, `mailto`, `file` (existing path, never an app
  bundle, script or installer), and custom schemes are accepted **syntactically only** (nothing checks that an app
  handles them). `javascript:`, `data:`, `vbscript:` and similar are refused, as are credentials in URLs and non-local
  `file:` hosts. The action is validated again at click time.

### Wire protocol

One JSON object per connection, terminated by EOF (`nc -U` half-closes when its input ends), at most 1 MiB:

```json
{"v":1,"title":"Build done","body":"42 tests","subtitle":"CI","app":"make","bundleID":"com.apple.Terminal",
 "symbol":"hammer.fill","url":"https://example.com/run/42","priority":"high","ttl":6,"dedupe":"ci","thread":"main","sensitive":true}
```

Required: `v` (must be 1) and `title`. `url`, `openApp` (bundle id) and `tab` are mutually exclusive click actions.
`priority` is `low|normal|high|critical`; `ttl` is 1 to 300 seconds (the wire accepts up to 3600 and the queue clamps);
`symbol` is an SF Symbol name (`[A-Za-z0-9.]`). Unknown keys are ignored. Reply, one line:
`{"ok":true,"id":"<uuid>"}` or `{"ok":false,"error":"<fixed text>"}`. Error texts are fixed strings; nothing the client
sent is echoed back. Invalid UTF-8 is repaired (U+FFFD) rather than rejected.

Limits: 64 concurrent connections, 2 s to deliver a complete request, 2 s for the handler to answer, 1 MiB. Strings are
sanitised on arrival: control, bidi and zero-width characters stripped, ANSI sequences removed, title and subtitle 120
and body 400 graphemes.

### The `atoll-notify` command

```
atoll-notify -t "Deploy finished" -b "prod, 42 s" -a deploy -p high --ttl 8 --dedupe deploy -u https://example.com/run/42
long_task | atoll-notify -t "Output" -b -        # body from stdin
```

POSIX `sh`, macOS built-ins only (`/usr/bin/nc`, `printf`, `head`, `tr`); no python, no eval. Every argument is escaped
and sent as data. Exit status: **0** sent, or Atoll is not running (a one-line hint goes to stderr, so pipelines never
break); **1** Atoll rejected it (reason on stderr); **2** usage error; **3** Atoll not reachable and `--strict` was given.
Each text value is capped at 8192 bytes by the script.

### Privacy behaviour (all sources)

- Redaction happens **at accept time**, before anything is stored. The queue keeps only the redacted display, so raw
  text of a hidden field is not retained in the queue, the history, a decision value or the arbiter callback. Tests
  assert this with reflected dumps and a 4-gram leak scan over 120 random redactions.
- Modes: `off` shows everything; `hidePreview` (default) keeps title and app and removes subtitle and body; `hideAll`
  shows "Notification from `<app>`". A sender's `sensitive` flag forces at least `hidePreview` and never loosens `hideAll`.
- Notification text is never written to disk, `UserDefaults`, a log or a distributed notification. History is in memory
  only (`historyLimit`, default 50). A test greps the Core files for logging, persistence, broadcast and network APIs.
- Changing the privacy mode applies to later notifications; an item already queued keeps the redaction it was accepted with.

### Extensions: why the JSON file path is off limits

The extension manager writes live-activity payloads in plaintext to
`~/Library/Application Support/AtollExtensions/live_activities.json` and broadcasts the full payload over
`DistributedNotificationCenter` (audit A11, B12). Notification text must never go through that path. The extension
transport has to hand text to `ExtensionNotificationAdapter.receive` in memory, with a bundle id taken from its own peer
check. Before "apps can post notifications" is advertised, the extension server also needs: caller verification instead of
auto-authorising the first caller (B13), the rate limit that is recorded but never enforced, and a bundle-id check on
the descriptor.

## NOT IMPLEMENTED (and why)

| Idea | Status | Why not |
|---|---|---|
| Showing other apps' notifications (Mail, Messages, Slack, Safari, ...) | **Not possible.** | No public API exists. See the statement at the top. |
| Reading the Notification Center database (`usernoted`, `~/Library/Group Containers/group.com.apple.usernoted/db2/db`) | Not implemented. | Needs Full Disk Access, the schema is undocumented and changes between releases, Apple moved the database specifically to protect it, and it contains the private text of every app's notifications. Atoll already asks for Full Disk Access for Focus detection only and must not widen that. |
| Scraping Notification Center banners with Accessibility (AX observer on `com.apple.notificationcenterui`) | Not implemented, not recommended. | Brittle (view hierarchy varies by macOS version, reports of it silently stopping), cannot suppress Apple's own banner so the user would see every notification twice, and it needs the Accessibility permission. If it were ever offered it would have to be a clearly labelled experimental toggle, off by default, with no claim of completeness. |
| Mail, Messages | Not implemented. | No public new-message event. A user can attach a Mail rule that runs a script calling `atoll-notify`; Atoll never reads Mail. |
| Wildcard observer on distributed notifications | Not implemented. | Not supported since macOS 10.15, and other apps do not post notifications there. |

## Settings (the contract's `NotificationSettings`)

Defaults: disabled; duration 4 s; queue length 5; dedupe window 10 s; privacy `hidePreview`; Focus `silenceExceptCritical`;
sources `atoll, cli, agentClaude, agentCodex, extensionApp`; 30 per minute per source (0 = unlimited); history 50.
The facade runs the socket, adapters and timer only while it is started **and** enabled **and** the source is switched on;
switching the master switch or the CLI source off closes the socket and removes the file at once. Persistence is an
injected closure; the Defaults wiring is the integration step.

Queue behaviour in one place: order is priority descending then arrival; a `high` or `critical` newcomer that outranks the
current item preempts it and the preempted item resumes with its remaining time; when full, the oldest lowest-priority
item is evicted, and a `critical` item is never evicted or silenced; a duplicate (same key, or identical content) replaces
a live item in place or is ignored for the dedupe window; a never-shown item that waited more than two minutes is dropped
when its turn comes (critical items never expire in the queue); hovering pauses the TTL; one scheduled task serves the whole
facade (no polling).

## Tests

```
AtollNotch/Tests/run_queue.sh        # compile + run; exit 0 only when every check passes
```

Suites: T3 queue, sanitiser, validators and wire decoder; T8 socket security (permission bits 0700/0600, wrong-uid
refusal, oversize, slow-loris and trickle, malformed input, per-peer and global rate limit, 64 concurrent clients,
connection cap, stop while connected and while replying, stale socket, live listener, regular file and symlink at the path,
path too long, descriptor leak check); the real script end to end; facade behaviour with a fake clock and a fake
scheduler; adapters; a privacy lint over the Core sources.

## Unverified (needs the live app)

- Real `UNUserNotificationCenter` authorisation and delegate behaviour for the ad-hoc-signed accessory build (T10 probe).
- Real Focus state through `DoNotDisturbManager` and `INFocusStatusCenter`.
- Real AgentCenter and EventKit events (only fakes here).
- How the notch looks and where the TTL, hover and click hooks attach in `ContentView` (the UI and arbiter agents own that).
- Multi-display behaviour (sneak peeks have no target screen today, audit B11).
