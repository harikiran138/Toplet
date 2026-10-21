# Connecting Atoll to YouTube Music

Atoll does not talk to YouTube directly. Its "Youtube Music" source controls the free, open-source **YouTube Music desktop app** through that app's local **API Server** plugin (`MediaControllers/YouTube Music Controller/`). No account, payment or API key is needed for Atoll; the desktop app itself uses your own YouTube Music session (free tier or Premium, your choice).

## How the connection works (OBSERVED in the source)
1. Atoll checks that an app with bundle id `com.github.th-ch.youtube-music` is **running** (`NSWorkspace`); if not, nothing is attempted.
2. `POST http://localhost:26538/auth/DynamicIsland` returns a bearer token. With the plugin's default `AUTH_AT_FIRST` strategy the desktop app shows an **Allow / Deny dialog** the first time (Deny is the default button). After Allow, the client id is stored in the plugin's `authorizedClients`.
3. Atoll then reads `/api/v1/song`, opens the WebSocket `/api/v1/ws` for live updates, and falls back to polling every 2 s. Controls call `/api/v1/play|pause|next|previous|shuffle|switch-repeat` and seek/like endpoints.
4. When the YouTube Music app launches, Atoll switches its media source to "Youtube Music" automatically (setting `mediaController`), and back when it quits.

## What was installed and configured on this Mac
| Item | Detail |
|---|---|
| App | `YouTube-Music-3.12.0-arm64.dmg` from `github.com/pear-devs/pear-desktop` release v3.12.0 (MIT). 124,129,961 bytes; **SHA-512 verified** against the release's own `latest-mac.yml` |
| Installed to | `~/Applications/YouTube Music.app` (bundle id matches what Atoll expects; arm64; upstream build is only linker-signed, not Developer-ID signed or notarised; its code-signature seal does not fully verify, which is how upstream ships it) |
| Plugin config | `~/Library/Application Support/YouTube Music/config.json`, `plugins["api-server"]`: `enabled: true`, **`hostname: "127.0.0.1"`** (the plugin's default is `0.0.0.0`, i.e. reachable from your whole network), `port: 26538`, `authStrategy: "AUTH_AT_FIRST"`, a freshly generated random `secret`. Backup of the original: `config.json.bak-before-atoll` |

## Verified on this Mac
* Server listens only on `127.0.0.1:26538`; a request to the Wi-Fi address is refused.
* `GET /api/v1/song` without a token → **HTTP 401**.
* Atoll (pid running) holds an **ESTABLISHED** TCP connection to `127.0.0.1:26538`, and the plugin's `authorizedClients` contains `DynamicIsland` (it is only written after Allow is clicked).
* Atoll's setting `mediaController` = `"Youtube Music"`.

## Not verified
* Track data actually appearing in Atoll's notch, play/pause/next/previous/seek/like from Atoll, artwork and lyrics — nothing was playing, and this session cannot click in the YouTube Music window or hover the notch (no Accessibility permission). **To check: play any song in YouTube Music, then hover the notch.**
* Sign-in to YouTube Music is done by you inside the YouTube Music app; this setup does not touch it.

## Using it
1. Open `~/Applications/YouTube Music.app` (sign in if you want your library), play a song.
2. Open Atoll. The notch should show the track; hover it to expand and use the controls.
3. If Atoll shows nothing: Atoll → Settings → Media → source "Youtube Music"; make sure the YouTube Music app is running and Plugins → API Server is ticked; if you clicked Deny earlier, remove the entry from `authorizedClients` (or delete the plugin's stored clients) and relaunch both apps.

## Security notes
* Anything that can reach `127.0.0.1:26538` and gets Allow from you can control playback; the Allow dialog is the consent step. Do not switch `authStrategy` to `NONE`, and do not change `hostname` back to `0.0.0.0`.
* Port 26538 is hard-coded in Atoll; if the YouTube Music app is not running, another local process could listen there. Atoll only talks to it when the YouTube Music app is running (bundle-id check).
* Undo: quit the YouTube Music app, restore `config.json.bak-before-atoll`, or delete `~/Applications/YouTube Music.app` and `~/Library/Application Support/YouTube Music`.
