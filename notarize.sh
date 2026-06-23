#!/bin/bash
# Notarize + staple Jack.app so it runs cleanly on any Mac (Tahoe Gatekeeper).
# Run build.sh first. Requires Apple credentials — pick ONE of:
#
#   A) Keychain profile (recommended, store once):
#        xcrun notarytool store-credentials thinkopen-notary \
#          --apple-id luis.ramos@thinkopen.net --team-id 7C63B47XSL
#        (paste an app-specific password from appleid.apple.com)
#      then just:  ./notarize.sh
#
#   B) Env vars for a one-off:
#        APPLE_ID=luis.ramos@thinkopen.net APP_PW=xxxx-xxxx-xxxx-xxxx \
#        TEAM_ID=7C63B47XSL ./notarize.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$DIR/build/Jack.app"
ZIP="$DIR/build/Jack-notarize.zip"
PROFILE="${NOTARY_PROFILE:-thinkopen-notary}"

[ -d "$APPDIR" ] || { echo "Jack.app not found — run ./build.sh first."; exit 1; }

echo "==> Zip for submission"
ditto -c -k --keepParent "$APPDIR" "$ZIP"

echo "==> Submit to Apple notary (this waits for the verdict)"
if security find-generic-password -s "com.apple.gke.notary.tool" -a "$PROFILE" >/dev/null 2>&1; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
else
  : "${APPLE_ID:?set APPLE_ID or store a keychain profile}"
  : "${APP_PW:?set APP_PW (app-specific password)}"
  : "${TEAM_ID:?set TEAM_ID}"
  xcrun notarytool submit "$ZIP" --apple-id "$APPLE_ID" --password "$APP_PW" --team-id "$TEAM_ID" --wait
fi

echo "==> Staple the ticket"
xcrun stapler staple "$APPDIR"
xcrun stapler validate "$APPDIR"

echo "==> Gatekeeper assessment (expect: accepted)"
spctl -a -vvv "$APPDIR"

echo "==> Notarized & stapled: $APPDIR"
