# Duplicate-install and permission check (2026-10-21)

## Duplicates
| Check | Result |
|---|---|
| Running instances | 1 (the installed `~/Applications/Atoll.app`) |
| Login item | exactly one `Atoll` entry (plus its normal "background tasks" child record), pointing at `~/Applications/Atoll.app` |
| Copies on disk with the same bundle id | **2**: the installed app and the build output `dist/Atoll.app`; Launch Services had registered **both**, so "Atoll" could resolve to either |
| Temporary test copies (`AtollBase`, `AtollNew`, bundle ids `com.local.atoll.*`) | existed in `dist/`; deleted and unregistered |
| Fix | `dist/Atoll.app` unregistered from Launch Services; `dist/.metadata_never_index` added; `local/install.sh` now does both automatically after installing. Launch Services now lists only the installed copy |

Rule going forward: run Atoll from `~/Applications` only (use `local/install.sh`); do not `open dist/Atoll.app`, which re-registers it.

## Permissions
| Item | Result |
|---|---|
| Usage-description strings | all 18 that the original Xcode project generates are present in the built `Info.plist` (Apple Events, Bluetooth, Calendars, Camera, Desktop/Documents/Downloads, Location, Microphone, Reminders) plus the 3 in the source `Info.plist` (Apple Music, audio capture, screen capture). Nothing is missing |
| Entitlements carried | apple-events (+ Music/Notes/Spotify exceptions), camera, calendars, disable-library-validation; **`mach-services` removed** (an ad-hoc signature cannot hold it) |
| **Gap found and fixed** | Core Location is used for lock-screen weather (`CLLocationManager`) but the hardened runtime needs `com.apple.security.personal-information.location`; neither upstream nor the first local build had it, so location was silently denied. Added to the local entitlements (standard, non-restricted) |
| Microphone | no code path captures microphone audio (0 files), so no audio-input entitlement is needed; the microphone usage string is vestigial |
| Accessibility | user grant in System Settings → Privacy & Security → Accessibility (6 files check `AXIsProcessTrusted`); no entitlement. Re-grant after every rebuild (ad-hoc signature = new identity) |
| Not verified | actual granted/denied/revoked behaviour of each permission (needs a person clicking prompts). Nothing here edits TCC |
