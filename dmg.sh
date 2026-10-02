#!/bin/bash
# Package a notarized Jack.app into a signed + notarized + stapled Jack-mac.dmg — the file to hand
# to clients. A DMG is a single disk image, so no unzip tool / cloud drive / USB stick can mangle
# the Sparkle.framework symlinks inside the app (which breaks the signature → "Open Anyway").
# The .zip stays on each release because Sparkle auto-update consumes it (appcast.xml).
#
#   ./dmg.sh                    # packages build/Jack.app (run build.sh + notarize.sh first)
#   ./dmg.sh /path/to/Jack.app  # packages a specific copy, e.g. extracted from a release zip
#
# Unversioned name so https://github.com/jackarkcreator/jack/releases/latest/download/Jack-mac.dmg
# is an evergreen link (same convention as Jack-win-x64.exe). Notary creds: same API key as notarize.sh.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APPDIR="${1:-$DIR/build/Jack.app}"
DMG="$DIR/build/Jack-mac.dmg"
SIGN_ID="Developer ID Application: ThinkOpen LLC (7C63B47XSL)"
PROFILE="${NOTARY_PROFILE:-thinkopen-notary}"
NOTARY_KEY="${NOTARY_KEY:-$HOME/Ccode/.secrets/AuthKey_J4574BB8M5.p8}"
NOTARY_ISSUER="${NOTARY_ISSUER:-62cc9a04-f542-4e0d-9814-ba7aa3b3f8ec}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-$(basename "$NOTARY_KEY" .p8 | sed 's/^AuthKey_//')}"

[ -d "$APPDIR" ] || { echo "Jack.app not found at $APPDIR"; exit 1; }

echo "==> Refuse to package an app that isn't notarized+stapled"
xcrun stapler validate "$APPDIR"
codesign --verify --deep --strict "$APPDIR"

echo "==> Stage: Jack.app + Applications shortcut (drag-to-install)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APPDIR" "$STAGE/Jack.app"   # ditto keeps symlinks + xattrs intact
ln -s /Applications "$STAGE/Applications"

echo "==> Build compressed DMG"
rm -f "$DMG"
hdiutil create -volname "Jack" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

echo "==> Sign DMG"
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"

echo "==> Submit DMG to Apple notary (waits for the verdict)"
if [ -f "$NOTARY_KEY" ]; then
  xcrun notarytool submit "$DMG" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER" --wait
else
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
fi

echo "==> Staple the ticket to the DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Gatekeeper assessment (expect: accepted / Notarized Developer ID)"
spctl -a -vvv -t open --context context:primary-signature "$DMG"

echo "==> Done: $DMG"
