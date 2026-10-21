# Local installation (Command Line Tools only, no Xcode)

Tested on: macOS 27.2 arm64, Swift 6.4 (`swift --version`), SDK `MacOSX27.0`, `xcode-select -p` = `/Library/Developer/CommandLineTools`.
Needs: `python3` (the CLT one, 3.9), `git`, `swift`, `codesign`, `iconutil`, `sips`, `ditto`, and network access **only** for the first dependency resolution (pinned GitHub revisions; one 56 MB prebuilt Lottie zip and the Sparkle zip). Disk: `local/.work` is ~1.3 GB after a release build (debug + release together ~3 GB); the app is 76 MB.

## From a clean checkout

```bash
git clone <your fork or this checkout> Atoll && cd Atoll
git checkout local-build

local/build.sh release        # ~7 min on an M2 (measured: 7m13s from an empty `local/.work`, including the dependency download)
```

`local/build.sh` does, in order:

1. `python3 local/prepare.py` - creates the git-ignored `local/.work/` (transformed copy of the sources, 4 vendored packages at their pinned revisions, converted resources, `Package.swift`). The repository's own files are not touched.
2. `swift build -c release --product Atoll` inside `local/.work`.
3. `python3 local/assemble.py --config release` - writes `dist/Atoll.app` and signs it ad hoc (inside-out, hardened runtime).
4. `codesign --verify --strict dist/Atoll.app`.

Use `local/build.sh debug` for an unoptimised build (faster, ~3 min, 84 MB executable).

## Install and run

```bash
local/install.sh                          # copies to ~/Applications/Atoll.app (refuses if Atoll is running)
open ~/Applications/Atoll.app
```

Or run `dist/Atoll.app` in place. First launch shows the onboarding window.

Check that it behaves: `local/smoke.sh dist/Atoll.app 45` (launches, waits, counts new crash reports, makes sure `OSDUIHelper` is not left stopped, quits).

Run the tests that do not need Xcode: `local/tests/run.sh` (after `local/prepare.py`).

## What you must know

* **Re-grant permissions after every rebuild.** The app is ad-hoc signed, so macOS treats each build as a different app for TCC (Accessibility, Screen Recording, Automation, Camera, ...). Nothing here edits TCC.
* Bundle id is `com.Ebullioscopic.Atoll`; if you also install the official build, edit `BUNDLE_ID` in `local/assemble.py` first.
* Sparkle automatic checks are disabled in the generated `Info.plist`. The feed URL is unchanged, so do **not** click "Check for Updates" unless you want the official release offered over your build.
* Atoll uses private APIs and **suspends `OSDUIHelper`** (the system volume/brightness HUD) while its HUD replacement runs. If your system HUD ever looks frozen after quitting/crashing Atoll: `pkill -CONT OSDUIHelper`.
* Uninstall: quit Atoll, `rm -rf ~/Applications/Atoll.app`, optionally `defaults delete com.Ebullioscopic.Atoll` and `~/Library/Application Support/<Atoll folders>`; revoke permissions in System Settings.
* Rebuild after pulling upstream changes: re-run `local/build.sh`. If upstream starts using a new asset-catalog colour/symbol, a new macro, or XCTest-only code in app sources, `prepare.py` or the compiler will tell you; see `docs/BUILD-ISSUES-AND-FIXES.md`.
* Free disk: `rm -rf local/.work/.build` removes build products (keep `local/.work` if you want incremental builds).

See `docs/BUILD-ISSUES-AND-FIXES.md` for every workaround, shim, and the list of features whose behaviour could not be verified.
