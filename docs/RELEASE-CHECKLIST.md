# Release checklist

Copy this into the release issue and tick it off. Details: [RELEASE.md](RELEASE.md).

**Before**
- [ ] `main` is green in CI (`Toplet tests`, and the Xcode build).
- [ ] `tests/pure/run.sh`, `AtollAgents/Tests/run_core.sh`, `run_hooks.sh`, `run_dashboard.sh` pass locally.
- [ ] `python3 local/tools/rebrand.py . --dry-run` reports `0 files`.
- [ ] Version bumped (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`) following SemVer.
- [ ] `CHANGELOG.md`: *Unreleased* renamed to the version with today's date.

**Manual smoke test on a real Mac** (fresh user account if possible)
- [ ] First launch: onboarding appears, permissions are asked only when needed.
- [ ] Notch opens and closes by hover, click and ⌘⇧I; tabs switch; Settings opens.
- [ ] Music: play/pause/skip with at least Apple Music and Spotify.
- [ ] Timer and an alarm ring; Stop and Snooze work.
- [ ] Notchless Mac or external display: the notch is placed sensibly.
- [ ] Sleep and wake; lock and unlock: the notch comes back.
- [ ] Reduce Motion and Reduce Transparency on: nothing essential is lost.
- [ ] Idle CPU with the notch closed stays low (`top -pid $(pgrep -x Toplet)` for a minute).
- [ ] Quit and relaunch; launch at login (if enabled) works.

**Build and publish**
- [ ] `SIGN_IDENTITY=… NOTARY_PROFILE=… BUILD=1 local/release.sh` — output says *Developer ID* and *notarized: yes (stapled)*.
- [ ] `spctl --assess --type open --context context:primary-signature dist/release/Toplet-<v>.dmg` accepts it.
- [ ] Draft a GitHub Release with the tag `v<version>`, attach the DMG, ZIP and `.sha256`, paste the changelog section.
- [ ] If the update feed is live: sign and publish the appcast entry.
- [ ] Publish the release (a maintainer approves; nothing is announced automatically).

**After**
- [ ] Install from the published DMG on a second Mac.
- [ ] Open the next *Unreleased* section in `CHANGELOG.md`.
