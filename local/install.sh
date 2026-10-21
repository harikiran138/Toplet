#!/bin/bash
# Copy dist/Toplet.app to ~/Applications (does not launch it).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/../dist/Toplet.app"
[ -d "$APP" ] || { echo "run local/build.sh first"; exit 1; }
if pgrep -x Toplet >/dev/null || pgrep -x Atoll >/dev/null; then echo "Toplet (or the old Atoll) is running; quit it first"; exit 1; fi
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Toplet.app"
ditto "$APP" "$HOME/Applications/Toplet.app"
codesign --verify --strict "$HOME/Applications/Toplet.app"
# The build folder holds a second copy with the SAME bundle id; keep it out of Launch Services so macOS (and the
# login item) can only ever resolve "Toplet" to the installed one.
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -u "$APP" >/dev/null 2>&1 || true
touch "$HERE/../dist/.metadata_never_index"
echo "installed: $HOME/Applications/Toplet.app"
