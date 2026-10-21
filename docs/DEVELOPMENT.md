# Developing Toplet

Everything you need to build, run and test Toplet on your Mac. If something here is wrong or
missing, that is a bug in the docs: please open an issue.

## Requirements

- macOS 14.6 or later (Apple silicon or Intel).
- Either **Xcode 16+**, or just the **Xcode Command Line Tools** (`xcode-select --install`).
- About 3 GB of free disk space for a first build (package checkouts and build cache).

## Get the code

```bash
git clone https://github.com/harikiran138/Toplet.git
cd Toplet
```

## Build and run

### With Xcode

1. Open `Toplet.xcodeproj`.
2. Select the **Toplet** scheme and *My Mac*.
3. Press **Run** (⌘R). Debug builds use the bundle id `app.toplet.Toplet.dev`, so they keep their
   own settings and permissions apart from an installed release.

Code signing: set your own team in *Signing & Capabilities*, or choose *Sign to Run Locally*.

### With the Command Line Tools only

```bash
./local/build.sh release        # → dist/Toplet.app  (debug: ./local/build.sh debug)
./local/install.sh              # copies it to ~/Applications/Toplet.app (quit Toplet first)
open ~/Applications/Toplet.app
```

`local/build.sh` runs three steps you can also run on their own:

1. `local/prepare.py` generates a SwiftPM package in `local/.work/` from the Xcode sources
   (it never edits tracked files).
2. `swift build` compiles it (`JOBS=2 ./local/build.sh` limits parallel jobs on a busy Mac).
3. `local/assemble.py` builds the `.app` bundle, writes Info.plist, strips the upstream update
   feed, and signs it ad hoc.

The first build takes several minutes; later builds are incremental.

## Tests

| Command | What it checks | Needs |
|---|---|---|
| `tests/pure/run.sh` | Usage-limit wording, game rules, clock rules, ship moods | CLT |
| `bash AtollAgents/Tests/run_core.sh` | AI agents core (≈1,260 checks) | CLT |
| `bash AtollAgents/Tests/run_hooks.sh` | Claude Code / Codex hook installer (≈400 checks) | CLT |
| `bash AtollAgents/Tests/run_dashboard.sh` | Agents usage history and dashboard | CLT |
| `bash AtollAgents/Tests/run_ui.sh` | Agents UI snapshot invariants (renders PNGs) | CLT |
| `bash AtollNotch/Tests/run_idle.sh` / `run_arbiter.sh` / `run_queue.sh` | Idle animations, closed-notch event arbiter, notification queue | CLT |
| `python3 -m unittest discover -s tests -p 'test_*.py'` | Privacy and configuration checks | Python 3 |
| Xcode ⌘U | `TopletTests` (XCTest: lyrics, media, clipboard, downloads…) | Xcode |

CI runs the CLT suites on every pull request (`.github/workflows/toplet-ci.yml`).

**Write new logic so it can be tested this way:** put the decision in a plain Swift type with no
SwiftUI or system calls (see `managers/Ship/ShipMood.swift`, `managers/Clock/ClockRules.swift`),
then add a suite to `tests/pure/run.sh`.

## Stand-alone modules

`AtollAgents/` and `AtollNotch/` are developed and tested on their own and copied into the app:

```bash
local/sync-agents.sh     # AtollAgents → Toplet/managers/Agents + components/Notch/Agents
local/sync-notch.sh      # AtollNotch  → Toplet/AtollNotchIdle
```

Change the module, run its tests, sync, then build the app.

## Renaming and user-visible text

User-facing text says **Toplet**. `local/tools/rebrand.py . --dry-run` lists any string literal
that still says "Atoll" outside the protected identifiers; CI fails if it finds one. Internal
identifiers (Keychain services, the extension protocol, the support folder) keep their old names
on purpose — see the docstring in that script.

## Debugging

- Logs: `log stream --predicate 'subsystem == "app.toplet.Toplet"'`, or the menu bar icon →
  **Tools → Export Logs**. (In zsh, `log` is a shell built-in: call `/usr/bin/log`.)
- Logging level: **Tools → Logging Level** in the menu bar menu.
- Reset settings for a clean first launch: quit Toplet, then
  `defaults delete app.toplet.Toplet` (debug builds: `app.toplet.Toplet.dev`).
- Performance: Activity Monitor or `top -pid $(pgrep -x Toplet) -stats cpu,mem,idlew`;
  `sample $(pgrep -x Toplet) 5` shows where CPU time goes.

## Permissions while developing

macOS remembers permissions (Accessibility, Bluetooth, Calendar, folders…) by the app's **code
signature**. An ad-hoc build is identified only by a hash of that exact binary, so every rebuild
looks like a new app and macOS asks again, even for permissions you already granted.

Fix it once per Mac:

```bash
local/make-signing-identity.sh      # creates "Toplet Local Signing" (asks for your login password)
```

From then on `local/build.sh` signs with that certificate (it prints `signing identity: …`), macOS
sees the same app on every build, and permissions survive rebuilds. Grant them one last time after
the first build signed this way. `local/make-signing-identity.sh --remove` deletes the certificate.
`TOPLET_SIGN_IDENTITY="…" local/build.sh` signs with any other identity, such as a Developer ID.

Toplet also avoids asking in the first place: its own files live in
`~/Library/Application Support/Toplet` (not the protected Documents folder), and folder access is
only checked when you open the Shelf settings.

## Uninstall

1. Quit Toplet (menu bar icon → Quit).
2. Delete `~/Applications/Toplet.app` (or `/Applications/Toplet.app`).
3. Optional cleanup:
   - Settings: `defaults delete app.toplet.Toplet`
   - Data: `~/Library/Application Support/Atoll`, `~/Library/Application Support/DynamicIsland`
   - Agent socket folder: `~/.atoll`
   - Claude Code / Codex hooks: remove them first in **Settings → AI Agents → Uninstall hooks**
4. Remove Toplet from **System Settings → Privacy & Security** lists if you like.
