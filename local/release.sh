#!/bin/bash
# Package dist/Toplet.app for a GitHub Release: DMG + ZIP + SHA-256 checksums.
#
#   local/release.sh                    # package the existing dist/Toplet.app (ad-hoc signed)
#   BUILD=1 local/release.sh            # build first (release configuration)
#
# Optional, only when you have an Apple Developer ID (never commit these values):
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"   re-sign app + DMG with hardened runtime
#   NOTARY_PROFILE="toplet-notary"      notarize + staple, using a keychain profile created once with
#                                       `xcrun notarytool store-credentials toplet-notary ...`
#
# Without SIGN_IDENTITY the artifacts are ad-hoc signed: they run on the builder's Mac, and other Macs
# show a Gatekeeper warning. The script says so instead of pretending the release is signed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP="$ROOT/dist/Toplet.app"
OUT="$ROOT/dist/release"

[ "${BUILD:-0}" = "1" ] && "$HERE/build.sh" release
[ -d "$APP" ] || { echo "missing $APP: run local/build.sh release (or BUILD=1 $0)"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILDNUM="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
NAME="Toplet-$VERSION"
mkdir -p "$OUT"
rm -f "$OUT/$NAME.dmg" "$OUT/$NAME.zip" "$OUT/$NAME.sha256"

signed="ad-hoc (not Developer ID; Gatekeeper will warn on other Macs)"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "Signing with: $SIGN_IDENTITY"
  ENT="$ROOT/local/.work/Atoll.local.entitlements"
  codesign --force --deep --options runtime --timestamp ${ENT:+--entitlements "$ENT"} --sign "$SIGN_IDENTITY" "$APP"
  signed="Developer ID ($SIGN_IDENTITY)"
fi
codesign --verify --strict --deep "$APP"

# ZIP (ditto keeps extended attributes and symlinks inside frameworks).
ditto -c -k --keepParent "$APP" "$OUT/$NAME.zip"

# DMG with an Applications shortcut for drag-to-install.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Toplet.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Toplet $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT/$NAME.dmg" >/dev/null
[ -n "${SIGN_IDENTITY:-}" ] && codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUT/$NAME.dmg"

notarized="no"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  [ -n "${SIGN_IDENTITY:-}" ] || { echo "NOTARY_PROFILE needs SIGN_IDENTITY (Apple only notarizes Developer ID builds)"; exit 1; }
  xcrun notarytool submit "$OUT/$NAME.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT/$NAME.dmg"
  notarized="yes (stapled)"
fi

( cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > "$NAME.sha256" )

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Toplet")"
cat <<EOF

Toplet $VERSION ($BUILDNUM)
  architectures: $ARCHS
  signing:       $signed
  notarized:     $notarized
  artifacts:     $OUT/$NAME.dmg
                 $OUT/$NAME.zip
                 $OUT/$NAME.sha256
EOF
