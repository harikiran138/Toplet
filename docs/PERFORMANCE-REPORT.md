# Performance report

Measured on the installed release build (`~/Applications/Atoll.app`, ad-hoc signed), macOS 27.2, MacBook Air M2 16 GB, on AC power, one built-in display. Idle = Atoll running with the Onboarding window open and no interaction. **This is a baseline only.** No optimisation was applied, so there is no before/after.

## Measured

| Metric | Result | How |
|---|---|---|
| Resident memory, idle | 93 MB at 15 s, rising to 108–116 MB over ~30 s | `top -pid -l 8 -s 4` (logs/idle-top-sample.txt) |
| Memory footprint | `phys_footprint` 116 MB, peak 116 MB | `footprint -p` |
| CPU, idle (instantaneous per 4 s interval) | 0.0 – 0.7 % | `top` |
| Power column (`top`) | 0.0 – 0.7 | `top` |
| Idle wake-ups | 0 | `top` IDLEW column |
| Threads | 6 – 7 | `top` |
| Earlier `ps` sampling over 60 s | RSS 146–155 MB, `%cpu` 0.0–2.3 (this is a lifetime average, so it understates bursts) | logs/idle-ps-sample.txt |
| Executable size / bundle size | 46.6 MB / 76 MB | `ls`, `du` |
| Launch to notch window present | present when first checked, 15 s after `open` (finer timing not measured) | `CGWindowList` |
| Build time, clean release | 7 min 13 s (includes the dependency download) | build agent |

Differences between runs (88 MB RSS in the build agent's run, 147–165 MB in mine) are within normal variation for a SwiftUI app and depend on which windows have been shown.

## Not measured (BLOCKED or out of scope)

* Time Profiler, Allocations, Leaks and the Energy Log: Instruments is part of Xcode.
* Energy impact in mW: `powermetrics` needs root.
* Animation frame rate / hitching during expand and collapse, CPU while the visualiser, media, system-monitor or live activities are active: needs interaction.
* Memory growth over hours (leak check). The app contains a self-memory watchdog (see `FEATURE-MATRIX-A.md`); not exercised.

## Static observations (from the audit, not measured)

* The default visualiser draws random bars with `CGFloat.random` on a timer, so it costs CPU without representing audio.
* Settings is a 9.7 k-line SwiftUI surface and the app registers 373 Defaults keys; several observers and timers exist (see `LOCAL-ARCHITECTURE-AUDIT.md`).
* No optimisation was made because there is no profiler and no baseline under load; changing code without measurement would contradict the brief.
