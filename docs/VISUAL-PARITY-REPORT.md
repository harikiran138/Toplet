# Visual parity report

**Status: BLOCKED. No visual parity claim is made.**

## What exists
* The build uses the unmodified sources: `git diff f039ca9 -- Toplet/` is empty. Layout, shapes, spacing, fonts and animation code are therefore the original code, run through the Swift compiler unchanged except for three mechanical, behaviour-neutral transformations: `@State` is renamed to the identical `SwiftUI.State` alias, `#Preview` blocks are removed from the build copy, and one asset symbol (`Image(.github)`) is rewritten.
* Observed at runtime: a layer-27 borderless panel at the top centre of the built-in display (`x=415 y=-4 w=640 h=222`) and the Onboarding window. The build agent captured one screenshot of the Onboarding "Choose Your Profile" window rendering SF Symbols and gradients (deleted afterwards because it also showed unrelated desktop content).

## What could not be compared
* **No reference build** of upstream Atoll exists on this Mac to compare against (it would need the official binary or Xcode), and no reference screenshots or recordings were provided.
* **Not inspected at all:** closed and expanded notch dimensions, corner radii, materials, shadows, album-art presentation, control alignment, animation timing and direction, hover response, gestures, HUD positions, light/dark appearance, the non-notch fallback.
* **Possible differences from the asset conversion** (listed in `BUILD-ISSUES-AND-FIXES.md` §4): the `TidalLogo` template-rendering intent is not preserved; loose SVG/PNG replaces the compiled asset catalog; localisation falls back to the English key when a language lacks an entry. All are expected to be cosmetic; none was checked visually.
* The notch geometry was observed on a notched built-in display only.

## How to complete this
Run the official Atoll release and `~/Applications/Atoll.app` side by side (change `BUNDLE_ID` in `local/assemble.py` first so they do not share preferences), at the same resolution and appearance, and compare closed/expanded states and animations. A person has to do this; a pixel diff is unnecessary because the layout code is identical.
