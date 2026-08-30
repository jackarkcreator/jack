#!/bin/bash
# Notarize + staple Jack.app so it runs cleanly on any Mac (Tahoe Gatekeeper).
# Run build.sh first. Credentials are tried in this order:
#
#   A) App Store Connect API key (DEFAULT — what ThinkOpen actually uses).
#      Needs no password and no app-specific password: just the .p8 on disk at
#      ~/Ccode/.secrets/AuthKey_<KEYID>.p8. The key id is read from the filename.
#      Override with NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER.
#      (Only the .p8 is secret. The key id and issuer are identifiers, useless without it —
#      same reasoning as TEAM_ID already being in build.sh.)
#
#   B) Keychain profile:
#        xcrun notarytool store-credentials thinkopen-notary \
#          --apple-id luis.ramos@thinkopen.net --team-id 7C63B47XSL
#
#   C) Env vars for a one-off:
#        APPLE_ID=luis.ramos@thinkopen.net APP_PW=xxxx-xxxx-xxxx-xxxx \
#        TEAM_ID=7C63B47XSL ./notarize.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$DIR/build/Jack.app"
ZIP="$DIR/build/Jack-notarize.zip"
PROFILE="${NOTARY_PROFILE:-thinkopen-notary}"
NOTARY_KEY="${NOTARY_KEY:-$HOME/Ccode/.secrets/AuthKey_J4574BB8M5.p8}"
NOTARY_ISSUER="${NOTARY_ISSUER:-62cc9a04-f542-4e0d-9814-ba7aa3b3f8ec}"
# AuthKey_ABC123.p8 -> ABC123, so a rotated key needs no edit here.
NOTARY_KEY_ID="${NOTARY_KEY_ID:-$(basename "$NOTARY_KEY" .p8 | sed 's/^AuthKey_//')}"

[ -d "$APPDIR" ] || { echo "Jack.app not found — run ./build.sh first."; exit 1; }

echo "==> Zip for submission"
ditto -c -k --keepParent "$APPDIR" "$ZIP"

echo "==> Submit to Apple notary (this waits for the verdict)"
if [ -f "$NOTARY_KEY" ]; then
  echo "    (App Store Connect API key: $NOTARY_KEY_ID)"
  xcrun notarytool submit "$ZIP" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER" --wait
elif security find-generic-password -s "com.apple.gke.notary.tool" -a "$PROFILE" >/dev/null 2>&1; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
else
  echo "No API key at $NOTARY_KEY and no keychain profile '$PROFILE'." >&2
  : "${APPLE_ID:?set APPLE_ID, or put the .p8 at $NOTARY_KEY, or store a keychain profile}"
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
