#!/bin/bash
# Publish a Jack build to every Microsoft Intune tenant that deploys Jack as a managed app.
# Managed Macs run Jack with Sparkle silenced (standard users can't approve its admin prompt), so Intune
# is their update channel: run this after every release, right after `gh release create`.
#
#   ./intune.sh             # publishes build/Jack-mac.dmg (run dmg.sh first)
#   ./intune.sh v3.4.0      # publishes the Jack-mac.dmg attached to that GitHub release
#   DRY=1 ./intune.sh       # verify + dry run, no Intune writes
#
# The tenant list lives OUTSIDE this public repo (it names clients):
#   ${JACK_INTUNE_TENANTS:-~/Ccode/onboarding/intune/jack-tenants.conf}
# Each tenant's catalog script re-verifies the DMG (Developer ID 7C63B47XSL + notarization) before uploading,
# and skips the upload if that version is already published.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="${JACK_INTUNE_TENANTS:-$HOME/Ccode/onboarding/intune/jack-tenants.conf}"
[ -f "$CONF" ] || { echo "No tenant list at $CONF: nothing to publish."; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/jack"
if [ $# -ge 1 ]; then
  echo "==> Download Jack-mac.dmg from release $1"
  gh release download "$1" --repo jackarkcreator/jack --pattern Jack-mac.dmg --dir "$WORK/jack"
else
  [ -f "$DIR/build/Jack-mac.dmg" ] || { echo "build/Jack-mac.dmg not found (run dmg.sh, or pass a release tag)"; exit 1; }
  cp "$DIR/build/Jack-mac.dmg" "$WORK/jack/"
fi

echo "==> Refuse anything that isn't notarized + stapled"
xcrun stapler validate "$WORK/jack/Jack-mac.dmg"
spctl -a -t open --context context:primary-signature "$WORK/jack/Jack-mac.dmg"

fail=0
while IFS='|' read -r name py script; do
  [[ -z "${name// }" || "$name" == \#* ]] && continue
  py="${py/#\~/$HOME}"; script="${script/#\~/$HOME}"
  args=(--work "$WORK" --only Jack --reupload Jack)
  [ "${DRY:-0}" = 1 ] || args+=(--apply)
  echo "==> Intune tenant: $name"
  if ! (cd "$(dirname "$script")" && "$py" -I "$script" "${args[@]}" 2>&1 | grep -v -i deprecat); then
    echo "!! $name FAILED"; fail=1
  fi
done < "$CONF"
[ $fail = 0 ] && echo "==> Done: every tenant is current." || echo "!! One or more tenants failed (see above)."
exit $fail
