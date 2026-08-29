#!/bin/bash
# Regenerate appcast.xml over build/updates/*.zip using the Jack EdDSA key (keychain account
# net.thinkopen.jack; offsite backup: ~/Ccode/.secrets/sparkle_jack_eddsa_private.key).
# Run after notarize.sh on each Mac release, then commit+push appcast.xml — the app reads it from
# https://raw.githubusercontent.com/jackarkcreator/jack/main/appcast.xml (SUFeedURL).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATES="$DIR/build/updates"

[ -d "$UPDATES" ] || { echo "No $UPDATES — put the release zip(s) there first (Jack-mac-universal-vX.Y.Z.zip)"; exit 1; }

"$DIR/tools/sparkle/generate_appcast" --account net.thinkopen.jack \
  --link "https://github.com/jackarkcreator/jack" \
  -o "$DIR/appcast.xml" "$UPDATES"

# GitHub hosts each zip under its own tag path; rewrite enclosure URLs accordingly.
/usr/bin/sed -i '' -E 's#url="[^"]*/(Jack-mac-universal-(v[0-9]+\.[0-9]+\.[0-9]+)\.zip)"#url="https://github.com/jackarkcreator/jack/releases/download/\2/\1"#g' "$DIR/appcast.xml"

echo "==> appcast.xml updated:"
grep -o 'url="[^"]*"' "$DIR/appcast.xml" || true
echo "==> Now: git add appcast.xml && commit && push (raw URL serves it), and upload the zip to the tagged release."
