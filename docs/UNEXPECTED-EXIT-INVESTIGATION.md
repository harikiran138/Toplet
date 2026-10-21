# Why Atoll closed by itself (investigation)

Symptom: a running Atoll (pid 80016, installed local build) disappeared with no crash report. This note records what the system log proves, what it does not, and what was changed.

## Finding (OBSERVED in the unified log, read with `/usr/bin/log`)
* At **11:31:04.349** Atoll logged `RECEIVED:(aevt,quit)` → `Handling Quit AppleEvent` → `applicationShouldTerminate: NSTerminateNow` → `Termination complete`, then its normal exit handlers (`Entering exit handler`, `AtExit has already fired`). That is an **orderly exit requested by another process through a standard "quit" Apple Event**.
* It was **not a crash** (no report, exit handlers ran), **not a kill signal**, **not the memory watchdog** (`MemoryUsageMonitor` only shows a dialog, at 1 GB; Atoll was at ~144 MB) and **not memory-pressure termination** (`runningboardd`: "Ignoring jetsam update because this process is not memory-managed").
* `appleeventsd` shows the only peer that looked up Atoll's Apple Event port in that window was **pid 97920, `com.apple.linkd`** (the Shortcuts / App Intents service), 1 ms before the quit arrived.
* Atoll's own code cannot send quit events to other apps (`grep`: it only terminates its own helper `Process` objects). Every in-app quit path is a button the user clicks and does not go through an Apple Event.

## Not established
* **Who or what asked `linkd` to do it** (a Shortcut/automation, Siri/Spotlight, or another automation agent on the machine). The log does not record the original requester. Your Shortcuts list was only checked by name (5 items, none named like "quit"); their contents were not opened.
* A test copy of Atoll (`AtollBase`, a different bundle id) had been launched 30 s earlier by the measurement harness. No code path links the two, so it is a coincidence in time, not shown to be a cause.

## Corrections to earlier statements
* The first diagnosis in this session ("system memory pressure / automatic termination") was a hypothesis and turned out to be **wrong**; an earlier "nothing in the logs" conclusion was invalid because `log` in this shell is a zsh builtin, not `/usr/bin/log`.

## Changes made (commit on `local-build`)
1. `DynamicIslandApp.swift`: `applicationShouldTerminate` **records who requested a quit** (sender pid and bundle id for an Apple Event quit, or "from inside Atoll") and **never blocks** it. Verified: quitting a test copy with `osascript` logged `quit requested by Apple Event from pid 99744 (osascript)`. Look for it with:
   `/usr/bin/log show --last 1h --info --predicate 'subsystem == "com.ebullioscopic.Atoll" AND category == "lifecycle"'`
2. Launch and terminate lines are written straight to the system log (not gated by Atoll's user log-level, which defaults to silent).
3. Atoll now opts out of macOS automatic/sudden termination (`NSSupportsAutomaticTermination=false`, `NSSupportsSuddenTermination=false`, and the matching `ProcessInfo` calls). This is a harmless hardening; it does **not** stop an Apple Event quit and is not claimed as the fix.
4. `local/perf/watch_exit.py` records the state and the log around any future exit, including `appleeventsd` lines.

## If it happens again
Run the lifecycle command above: it names the sender. If the sender is `linkd`/`shortcuts`, review Shortcuts → Automations for anything that quits apps. If it is another app, that app is the cause.
