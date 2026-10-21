# Toplet features

An honest list of what Toplet does today. **Status** says how sure we are:

- **Tested**: covered by automated tests in this repository.
- **Works**: implemented end to end and used daily, but without automated tests.
- **Partial**: works with known gaps (listed).
- **Off by default**: available in Settings.

Evidence for every row is in [audits/PRODUCT-REALITY-AUDIT.md](audits/PRODUCT-REALITY-AUDIT.md).

## The notch

| Feature | Status | Notes |
|---|---|---|
| Closed notch with live activities (music, timer, downloads, recording, Focus, camera/mic, battery, shelf) | Works | One activity at a time, highest priority first. Camera/mic indicators currently hide behind music. |
| Open notch with tabs | Works | Hover (or click / ⌘⇧I) to open. |
| Macs without a notch and external displays | Works | A drawn notch or a floating pill. Screens are matched by name, so two identical monitors can be confused. |
| Above full-screen apps and on every Space | Works | Uses a private window space (see Private APIs below). |
| Gestures: swipe down to open, up to close, left/right to skip | Works | |
| Minimalistic mode | Works | Home only (the Clock appears while an alarm rings). |
| Ship companion | Works (new) | Reacts to charging, low battery, downloads, timers, offline and night; moves briefly, then rests. Rules are tested. |

## Tabs

| Tab | Status | Notes |
|---|---|---|
| Home: music player | Works | Apple Music, Spotify, Cider, TIDAL, Amazon Music, YouTube Music, any Now Playing source. Shuffle/repeat support varies by player. |
| Lyrics (pin under the notch) | Tested | LRCLIB first, NetEase as fallback. Off by default. |
| Shelf (drag files in, AirDrop / share out) | Works | LocalSend can send but not receive yet. |
| Timer | Works | Presets, custom sound, optional mirroring of the Clock app's timer. |
| Clock | Partial (new) | 12/24-hour time, world clocks, alarms (ring with the notch open; catch up after sleep). Alarms need Toplet running — not a system alarm. |
| Games | Works (new) | Pairs (3 sizes), Tic-Tac-Toe (Relaxed or Perfect), Lights Out. Rules tested. |
| Usage (AI plan limits) | Works | Claude, Codex, Cursor, Antigravity, New API. Off by default. Reads tokens read-only. |
| Agents (Claude Code, Codex) | Tested (core) | Live sessions, approvals from the notch. Off by default. |
| Stats | Works | CPU, GPU, memory, network, disk. Off by default. |
| Notes (+ Apple Notes sync) | Works | Sync is off by default. |
| Clipboard history | Tested (persistence) | Skips items marked concealed by password managers. |
| Terminal | Works | Off by default. |
| Color picker | Works | As a panel (⌘⇧P); the tab is not reachable yet. |

## System

| Feature | Status | Notes |
|---|---|---|
| Volume / brightness HUD replacement | Works | Suspends the system HUD process while active. |
| Per-app volume | Partial | Levels are not re-applied after relaunch until the popover is opened. |
| Bluetooth device HUD with battery | Works | |
| Battery / charging HUD | Works | |
| Focus (Do Not Disturb) indicator | Works | Reading Focus state may need Full Disk Access. |
| Keep awake (caffeinate) | Tested | ⌘⇧K. |
| Lock screen widgets (media, timer, weather, reminders) | Works | Private API; may break with macOS updates. |
| Calendar and reminders | Works | |
| Screen Assistant (AI chat) | Partial | Only Gemini receives attached images; API keys are stored in preferences, not the Keychain. |
| Extensions (AtollExtensionKit) | Partial, off by default | Local API only while enabled; browsers are rejected; clients are approved automatically (to be replaced by a prompt). |
| Updates | Off | No Toplet release feed yet; upstream Atoll updates are blocked on purpose. |

## Privacy

- No analytics, telemetry or accounts.
- Network use: weather (Open-Meteo), lyrics (LRCLIB, NetEase), artwork lookup (iTunes Search),
  AI plan limits (the providers you enable), model pricing (a JSON file on GitHub), and
  Screen Assistant requests you send. Each can be turned off by disabling its feature.
- Everything else stays on your Mac.

## Private APIs

Toplet uses some private macOS interfaces (MediaRemote, SkyLight/CGS window spaces, CoreBrightness,
DisplayServices, screen-capture detection, suspending OSDUIHelper). They make the notch feel native,
but they can break with macOS updates and rule out the Mac App Store. Toplet is distributed
directly instead.
