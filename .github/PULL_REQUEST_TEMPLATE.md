## What and why

<!-- What does this change, and what problem does it solve? Link the issue: "Closes #123". -->

## How to test

<!-- Steps a reviewer can follow on their own Mac. -->

## Screenshots or clip

<!-- Required for UI changes: before and after. Delete this section otherwise. -->

## Checklist

- [ ] One focused change; the title follows Conventional Commits (`feat(clock): …`, `fix(usage): …`)
- [ ] Commits are signed off (`git commit -s`)
- [ ] Tests added or updated, and `AtollAgents/Tests/run_core.sh` / `run_hooks.sh` pass when touched
- [ ] Works with Reduce Motion, Reduce Transparency and Increase Contrast; controls have accessibility labels
- [ ] No new network request, or it is explained in its settings footer and can be turned off
- [ ] No secrets, tokens or personal data in code, logs or screenshots
- [ ] New files carry the GPL-3.0 header; third-party code or assets are listed in `NOTICE`
- [ ] `CHANGELOG.md` updated under *Unreleased* if users will notice the change
