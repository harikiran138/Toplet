#!/bin/bash
# One-shot local build: prepare overlay -> swift build -> assemble dist/Toplet.app
#   local/build.sh [debug|release]      (default: release)
set -euo pipefail
CONFIG="${1:-release}"
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 "$HERE/prepare.py"
( cd "$HERE/.work" && nice -n 15 swift build -c "$CONFIG" --product Atoll ${JOBS:+-j $JOBS} )
python3 "$HERE/assemble.py" --config "$CONFIG"
codesign --verify --strict --verbose=1 "$HERE/../dist/Toplet.app"
echo "built: $HERE/../dist/Toplet.app"
