# Addendum: review of realfishsam/agent-notch

Source reviewed (read-only, nothing executed): https://github.com/realfishsam/agent-notch — "the open-source alternative to vibe-island", 310 stars, created 2026-07-21, MIT, Copyright (c) 2026 realfishsam. One 1,182-line `main.swift` (AppKit, no dependencies), README, two GIFs and eight `pets/*.webp` spritesheets.

## What it does
No hooks, no APIs, no accounts. A session is "a running agent process attached to a TTY", polled every 3 s: `ps` finds `claude`/`codex`, `lsof` maps each to the transcript it holds open (Codex) or its working directory (Claude Code, which appends-and-closes its transcript), transcripts supply prompt, model, snippets and subagents. Busy = process alive and transcript written in the last 30 s; idle = alive but quiet; done = process gone for 2 polls; idle > 6 h dropped. A tiny indicator beside the collapsed notch (walking mascot while running, green blob once finished until you focus the terminal) and a click-to-open panel with one row per session titled by the user's latest prompt, subagents folded under a dropdown, and a model tag. Its own README names the weakness: the ~30 s "afterglow" caused by inferring state from transcript writes; hooks are its stated upgrade path.

## What Atoll's Agents feature adopts (ideas only; no code copied)
| Idea | In Atoll |
|---|---|
| Zero-hook passive discovery | Already P0 in our design; hooks add exact state on top. The two modes are complementary |
| Exact pid → file mapping (Codex holds its rollout open; Claude is matched by cwd) | Implemented with libproc (`PROC_PIDLISTFDS`, `PROC_PIDFDVNODEPATHINFO`) instead of `lsof`; no process spawn |
| Busy/idle hybrid (30 s window, 2-poll death, 6 h drop) | Used only as the fallback for sessions without hooks; live hook status always wins; the "estimated from activity" limitation is shown in the UI |
| "Finished since you last looked", cleared when you focus the terminal | `hasUnseenCompletion` + acknowledgement on host-app activation, jump, or a new prompt |
| Indicator beside the collapsed notch | New `AgentsClosedIndicator` for Atoll's closed notch, zero width when idle |
| Rows titled by the user's prompt, model tag, subagent dropdown | In the row design |

## What it does not adopt
* The pet spritesheets: Codex pets are © OpenAI (the README says so) and the user asked for native SwiftUI motion, no downloaded assets. All motion is built from SwiftUI springs, phase/keyframe animators and SF Symbol effects.
* The 8 Hz animation timer and 3 s unconditional polling: the opposite of the idle-cost work done on Atoll. Our scan runs only while the feature is on and the indicator/tab needs it, and every decorative animation stops when nothing is visible.
* Approving permissions: agent-notch is read-only. Atoll's approvals go through the agents' blocking `PermissionRequest` hook (Allow once / Deny / Let terminal decide), which fails open.

## Licence handling
MIT is compatible with Atoll's GPL-3.0. No source was copied, so no MIT text needs to be bundled for it; the credit is kept in `NOTICE` for the ideas that are clearly borrowed. If any file is later copied, keep the MIT notice and "Copyright (c) 2026 realfishsam" with it.
