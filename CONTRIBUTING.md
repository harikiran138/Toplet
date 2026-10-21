# Contributing to Toplet

Thanks for coming aboard. Toplet is built by its community, and every kind of help counts:
code, design, testing, documentation, translations, and good bug reports.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to help

| You like… | Try |
| --- | --- |
| Swift and SwiftUI | Issues labelled `good first issue` or `help wanted` |
| Design and animation | Ship characters, idle animations, themes, icons |
| Testing | Reproduce open bugs on your Mac and add the details |
| Writing | Docs, in-app copy, translations in `Localizable.xcstrings` |
| Ideas | A feature request issue that describes the problem first |

## Build and run

You need macOS 14.6 or later and either Xcode or the Command Line Tools.

- **Xcode**: open `Toplet.xcodeproj` and run the **Toplet** scheme.
- **Command Line Tools**: `./local/build.sh release` builds `dist/Toplet.app`, and
  `./local/install.sh` copies it to `~/Applications`.

Run the fast test suites before you open a pull request:

```bash
AtollAgents/Tests/run_core.sh      # agents core
AtollAgents/Tests/run_hooks.sh     # Claude Code / Codex hook install
local/tests/run.sh                 # build-overlay checks
```

UI changes in the Agents module also have a snapshot harness: `AtollAgents/Tests/run_ui.sh`.

### Repository map

| Path | What lives there |
| --- | --- |
| `Toplet/` | The app (sources, assets, Info.plist, entitlements) |
| `Toplet/components/Notch/` | Tabs and views drawn inside the notch |
| `Toplet/managers/` | State and services (media, usage, clock, games…) |
| `AtollAgents/`, `AtollNotch/` | Stand-alone modules with their own tests, synced into the app |
| `local/` | Command-line build, install and the `rebrand.py` tool |
| `docs/` | Design notes, audits, branding sources |

Internal names such as the `Atoll` Swift module and `Atoll*`/`DynamicIsland*` type names are
kept on purpose: renaming them would break the extension kit and saved data. User-facing text says
**Toplet**.

## Pull request rules

1. **Open an issue first for anything bigger than a small fix**, so we can agree on the approach
   before you spend time on it. Small fixes and docs can go straight to a pull request.
2. **One change per pull request.** Keep refactors separate from features and fixes.
3. **Branch from `main`** and name it `feat/…`, `fix/…`, `docs/…`, `perf/…` or `chore/…`.
4. **Write commit messages in the [Conventional Commits](https://www.conventionalcommits.org) style**,
   for example `feat(clock): add snooze length setting` or `fix(usage): keep reset time in sync`.
5. **Sign off every commit** (`git commit -s`) to certify the
   [Developer Certificate of Origin](https://developercertificate.org): you wrote the change or have
   the right to submit it under GPL-3.0.
6. **Tests pass and new logic has tests.** Pure rules (game boards, clock recurrence, usage wording)
   belong in plain Swift types that can be tested without the UI.
7. **UI changes include before and after screenshots** (or a short clip for animation), in both
   light and dark notch states where it matters.
8. **Update docs and the changelog** (`CHANGELOG.md`, under *Unreleased*) when behaviour changes.

### Quality bar

Every pull request is reviewed against these points:

- **Accessibility**: works with *Reduce Motion* (no essential animation), *Reduce Transparency*
  (opaque surfaces), *Increase Contrast*, VoiceOver labels on controls, and keyboard use where text is entered.
- **Look and feel**: use the shared surface (`.notchSurface()` / `NotchSurface.swift`) instead of
  ad-hoc backgrounds, follow the system typography, and use springs that feel native.
- **Performance**: nothing polls or animates while the notch is closed unless the user asked for it
  (pinned items, timers). Heavy work stays off the main thread. Watch CPU in Activity Monitor before and after.
- **Privacy**: local first. New network requests need a clear reason, a setting to turn them off,
  and a line in the feature's settings footer explaining what is sent. No analytics or tracking.
- **Security**: never log tokens, prompts or personal data. Store secrets in the Keychain, never in
  `UserDefaults`. Shell commands and AppleScript must escape every value they interpolate.
- **Compatibility**: macOS 14.6 is the minimum; guard newer APIs with `#available`.
- **Licensing**: new files carry the GPL-3.0 header used in the codebase. Only add third-party code
  or assets whose license is compatible with GPL-3.0, and record them in `NOTICE`.

### Review and merge

- A maintainer reviews within a week; if you have not heard back, a friendly ping is welcome.
- At least **one maintainer approval** and **green CI** are required to merge.
- Pull requests are squash-merged, so the title becomes the commit message.
- Reviews are about the code, never the person. Disagreements are settled in the open on the
  pull request; maintainers make the final call and explain why.

## Reporting bugs and asking for features

Use the issue templates. For bugs, include your macOS version, Mac model, Toplet version or commit,
the steps to reproduce, and what you expected. The menu bar icon's **Tools → Export Logs** item collects logs that help a lot; check them for anything private before attaching.

Found a security problem? Do not open a public issue; follow [SECURITY.md](SECURITY.md).

## License

Toplet is licensed under the GNU GPL v3.0, and so are your contributions. See [LICENSE](LICENSE).
