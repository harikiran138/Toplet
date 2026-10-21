# Toplet roadmap

What we plan to work on, in rough order. Nothing here is a promise or a date; it changes as we
learn. Items marked **good first issue** are small and well scoped. Want one? Comment on its issue
(or open one) so nobody duplicates work.

## Now: make the first public release trustworthy

- [ ] **Developer ID signing and notarization** so the download opens without Gatekeeper warnings
      (needs an Apple Developer account; pipeline ready in `local/release.sh`).
- [ ] **Toplet's own update feed** (Sparkle key + appcast) — see [RELEASE.md](RELEASE.md).
- [ ] **Version and identity:** choose Toplet's first version number (the app still carries
      upstream's 2.3.3); point the About page and links at the Toplet repository.
- [ ] **Universal build** (arm64 + x86_64) in the command-line build.
- [ ] **Extension approval prompt:** replace auto-approval of extension clients with a user prompt.
- [ ] **Store Screen Assistant API keys in the Keychain** instead of preferences.

## Next: reliability and polish

- [ ] Identify displays by display ID, not name (two identical monitors), and debounce screen
      change rebuilds.
- [ ] Restore the notch reliably after unlock and wake (fallback when the unlock notification is missed).
- [ ] Re-apply per-app volume levels at launch.
- [ ] Show the camera/mic privacy indicator next to music instead of behind it.
- [ ] Respect Reduce Motion in the notch's own open/close and tab animations.
- [ ] VoiceOver labels for icon-only buttons (tab bar, header, music controls) — **good first issue**.
- [ ] Confirm before clearing clipboard history everywhere — **good first issue**.
- [ ] Design tokens (spacing, radii, type, ocean palette, motion) adopted tab by tab
      (proposal in [audits/UI-UX-AUDIT.md](audits/UI-UX-AUDIT.md)).
- [ ] Faster launch: defer work done before `applicationDidFinishLaunching` (~1.8 s today).
- [ ] Remove unused packages (Pow, open-meteo) and dead code listed in the product audit — **good first issue**.

## Later: the living ship and new tools

- [ ] More ship moods (weather, music rhythm) and community **character packs** (a documented
      palette + shape format).
- [ ] Tasks in the notch: Apple Reminders first, then GitHub (via the `gh` CLI) and others.
- [ ] One-click setup for Claude Code / Codex / Cursor, and a Toplet MCP server so agents can show
      progress in the notch.
- [ ] Alarms as system notifications, so they ring even when Toplet is not running.
- [ ] An iPhone companion (limits, timers and tasks in the Dynamic Island) — needs a design first.
- [ ] Homebrew cask (after signed releases).

## Done recently

See [CHANGELOG.md](../CHANGELOG.md). Highlights: Claude-style usage limits with pinning, Games and
Clock tabs, the ship companion, glass surfaces, the Toplet rename, and a large idle-CPU fix.
