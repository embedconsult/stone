#!/bin/sh
# Bundles each app pinned in ios/apps.pin into ios/Stone/Apps/NAME/
# (app.wasm and release.txt, which PluginHost reads), for Xcode Cloud's
# ci_post_clone.sh. Stops with an error unless every download matches its
# pin: the module's SHA-256, and an inventory that lists that SHA-256 for
# app.wasm and the pinned check-in.
#
#   scripts/fetch-apps.sh [PIN [APPS_DIR]]
#
# Plan: stone forum df2aca7b58 step 2. Tested by scripts/test-fetch-apps.sh.
set -eu
pin=${1:-ios/apps.pin}
apps=${2:-ios/Stone/Apps}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fail() { echo "fetch-apps: $*" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
count=0
while read -r name project checkin sum module inventory extra; do
  case "$name" in ''|'#'*) continue ;; esac
  [ -n "$inventory" ] && [ -z "${extra:-}" ] || fail "$name: a pin line has six fields"
  echo "$name" | grep -Eq '^[a-z][a-z0-9-]*$' || fail "$name: not an app name"
  echo "$checkin" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$' || fail "$name: check-in is not a full hash"
  echo "$sum" | grep -Eq '^[0-9a-f]{64}$' || fail "$name: sha256 is not a SHA-256"
  curl -fsSL --proto '=https,file' --proto-redir '=https' -o "$work/app.wasm" "$module" || fail "$name: couldn't download $module"
  curl -fsSL --proto '=https,file' --proto-redir '=https' -o "$work/inventory" "$inventory" || fail "$name: couldn't download $inventory"
  got=$(sha256 "$work/app.wasm")
  [ "$got" = "$sum" ] || fail "$name: app.wasm is $got, the pin says $sum"
  grep -Eq "^$sum[[:space:]]+\*?(.*/)?app\.wasm\$" "$work/inventory" \
    || fail "$name: the inventory doesn't list $sum for app.wasm"
  grep -Fq "$checkin" "$work/inventory" || fail "$name: the inventory doesn't name check-in $checkin"
  mkdir -p "$apps/$name"
  cp "$work/app.wasm" "$apps/$name/app.wasm"
  printf 'project %s\ncheck-in %s\n%s  app.wasm\n' "$project" "$checkin" "$sum" > "$apps/$name/release.txt"
  echo "fetch-apps: $name $sum from $project $checkin"
  count=$((count + 1))
done < "$pin"
echo "fetch-apps: $count app(s) bundled"
