# Your first contribution to Toplet

Welcome aboard! This page gets you from zero to a merged pull request.

## 1. Build it (≈10 minutes)

```bash
git clone https://github.com/harikiran138/Toplet.git && cd Toplet
./local/build.sh release && ./local/install.sh && open ~/Applications/Toplet.app
```

Or open `Toplet.xcodeproj` in Xcode and press Run. Stuck? [DEVELOPMENT.md](DEVELOPMENT.md).

## 2. Find your way around (≈15 minutes)

Read [ARCHITECTURE.md](ARCHITECTURE.md). The three files to open first:

- `Toplet/ContentView.swift`: the notch itself (closed and open).
- `Toplet/components/Notch/`: one view per tab.
- `Toplet/models/Constants.swift`: every setting.

## 3. Pick something

| If you like… | Start here |
|---|---|
| Swift / SwiftUI | `good first issue` label; [ROADMAP.md](ROADMAP.md) items marked so |
| Accessibility | VoiceOver labels for icon-only buttons ([audits/UI-UX-AUDIT.md](audits/UI-UX-AUDIT.md) §3) |
| Design and animation | New ship appearances in `components/Ship/ShipView.swift` (`ShipPalette`) |
| Performance | [audits/PERFORMANCE-AUDIT.md](audits/PERFORMANCE-AUDIT.md) §9 |
| Testing | Move a rule into a pure type and add it to `tests/pure/run.sh` |
| Translations | `Toplet/Localizable.xcstrings` (open in Xcode) |
| Docs | Anything in `docs/` that confused you is worth a fix |

Comment on the issue to claim it, so two people don't do the same work.

## 4. Make the change

- Branch: `feat/…`, `fix/…`, `docs/…`.
- Keep it focused; add or update tests; run `tests/pure/run.sh` and the suites in DEVELOPMENT.md.
- Commit with `git commit -s` (Developer Certificate of Origin) and a Conventional Commit message.

## 5. Open the pull request

Fill in the template (screenshots for UI changes). A maintainer reviews within about a week.
Thanks for helping the little ship sail!
