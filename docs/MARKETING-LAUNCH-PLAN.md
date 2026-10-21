# Toplet launch plan

**Status: drafts only.** Nothing here has been posted, scheduled or submitted. Every post,
repository setting and external service below needs a maintainer's explicit go-ahead.

## Positioning

**Toplet is an open-source living notch companion for macOS.**

Why someone would pick it, each claim checked against the code (see [FEATURES.md](FEATURES.md)):

| Claim | True today? | Evidence |
|---|---|---|
| Original animated ship character | Yes | `components/Ship/ShipView.swift`, moods in `managers/Ship/ShipMood.swift` |
| Useful daily tools (music, timers, alarms, AI limits, shelf, clipboard) | Yes | FEATURES.md |
| Privacy-first, local, no accounts or analytics | Yes | No analytics SDKs (security audit §B8); network uses listed in FEATURES.md |
| Free and open source | Yes | GPL-3.0 |
| Low resource use | Partly | ~2% idle CPU measured with Agents on and two active sessions (PERFORMANCE-AUDIT.md); launch takes ~1.8 s |
| Community-created modules | Not yet | The extension kit exists; ship character packs are on the roadmap. Say "planned". |
| Easy install | **Not yet** | No Developer ID signing; building from source is the only clean path |

Do **not** claim: "lightest notch app", benchmarks against other apps, download or star counts,
"works with every music player", or community packs as a current feature.

## Gate before any public launch

1. Signed and notarized release on GitHub Releases ([RELEASE.md](RELEASE.md)). A launch that asks
   people to build from source or bypass Gatekeeper wastes the one chance to make a first impression.
2. Real screenshots and a short demo recording (guide below).
3. Repository public with README, CONTRIBUTING, issue templates, at least 5 real `good first issue`
   tickets taken from [ROADMAP.md](ROADMAP.md).
4. A maintainer available for the first 48 hours to answer questions and triage bugs.

## Repository settings (to apply when public)

- **Description:** "A free, open-source living notch companion for macOS: music, timers, alarms, AI usage limits, games and a little ship with personality. Local-first, no accounts."
- **Website:** the landing page (`site/`, e.g. GitHub Pages — free; needs approval to enable).
- **Topics** (each checked for relevance): `macos`, `swift`, `swiftui`, `open-source`, `notch`,
  `dynamic-island`, `macos-app`, `productivity`, `menu-bar`. (`desktop-app` is generic; skip.)
- **Social preview:** upload `docs/branding/social-preview.png` (1280×640).
- **Discussions:** enable with categories Q&A, Ideas, Show and tell.
- **Labels:** `good first issue`, `help wanted`, `bug`, `enhancement`, `accessibility`,
  `performance`, `design`, `docs`, `needs-triage`.

## Screenshots and demo (must be real)

Take them on a real Mac running a release build; never mock them up.

1. Clean desktop wallpaper, Dock hidden, no private content (notifications off, no personal files, mail or chats visible).
2. Closed notch with the ship (unplug and replug the charger to show the charging mood).
3. Open notch: Home (music playing), Usage (with your plan limits), Clock (alarms + world clocks), Games.
4. Light and dark Settings: General, Ship companion.
5. A 10–15 s screen recording (⌘⇧5): hover to open, switch tabs, close; export a GIF under 5 MB.

Save them in `docs/media/` and reference them from the README and landing page.

## Funnel and what we can responsibly measure

Discovery → repository visit → demo viewed → download → successful first use → continued use →
star / contribution / recommendation.

Measure only with GitHub's own aggregate data: repository traffic (views, clones, referrers),
release download counts, stars, issues and pull requests opened, first-time contributors. No
analytics in the app or on the landing page. Optional later: an opt-in, anonymous "how is it going"
issue template after a month.

## Draft: Show HN

> **Show HN: Toplet – an open-source notch companion for macOS with a little ship**
>
> I've been working on Toplet, a free, GPL-licensed app that turns the MacBook notch into a small
> living panel: music controls, timers and alarms, world clocks, your Claude/Codex/Cursor plan
> limits in plain words ("Session limit · resets in 1 hr 45 min · 47%"), a file shelf, clipboard
> history, quick games, and a tiny vector ship beside the notch that reacts when you charge,
> download, finish a timer or go offline.
>
> It's a fork of Atoll (itself built on boring.notch), focused on being local-first (no accounts,
> no analytics) and light on resources: we cut idle CPU from double digits to about 2% on our test
> machine. It uses a few private macOS APIs to feel native, so it's distributed directly rather than
> through the App Store.
>
> Source, build instructions and an honest feature list: <link>. Feedback and contributors very welcome.

## Draft: Reddit (r/macapps, r/MacOS — check each sub's self-promotion rules first)

> **Toplet: a free, open-source "living" notch app for macOS**
>
> Hi! Toplet puts music, timers, alarms, world clocks, AI usage limits and a few mini games in the
> notch, plus a small ship that reacts to what your Mac is doing. It's GPL, has no account or
> tracking, and builds in a few minutes. It's early: signed downloads are coming. I'd love to hear
> what's useful and what's annoying. <link>

## Draft: Product Hunt (only after signed releases)

- **Tagline:** A little ship for your Mac's notch.
- **Description:** Toplet is a free, open-source notch companion for macOS: music, timers, alarms,
  AI usage limits, games and a small ship with personality. Local-first, no accounts, no ads.
- **First comment:** why we built it, what's next (character packs, tasks), how to contribute.

## Draft: developer communities (Swift forums, Mastodon/Bluesky, dev.to)

> We open-sourced Toplet, a SwiftUI + AppKit notch app. Things that might interest Swift folks: a
> Canvas-drawn character with a pure state machine (tested with plain `swiftc`), an event-driven
> alarm scheduler that catches up after sleep, Liquid Glass with material fallbacks, and a
> command-line build that needs no Xcode. Good first issues are labelled. <link>

## Release notes template

```markdown
## Toplet <version>

<one-sentence summary of the theme of this release>

### New
- …

### Improved
- …

### Fixed
- …

### Known issues
- …

**Install:** download `Toplet-<version>.dmg`, open it and drag Toplet to Applications.
Checksums: `Toplet-<version>.sha256`. Requires macOS 14.6 or later.
Thanks to <contributors> for this release!
```

## Initial release announcement (draft)

> Toplet 0.x is the first release of a community fork of Atoll. It renames the app, adds
> Claude-style AI usage limits you can pin under the notch, Games and Clock tabs, the ship companion,
> glass surfaces, and a big cut in idle CPU. Everything stays on your Mac. Build it, try it, and tell
> us what to make next.

## Community rules of the road

No bought stars, bots, sock puppets or mass posting. Post once per community, follow each
community's rules, answer every comment, and say clearly that you are the maintainer.
