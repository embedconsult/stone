#!/bin/sh
# Checks scripts/fetch-apps.sh against a local fixture (file:// addresses,
# Hello's module as the bytes): a matching pin bundles the app as
# PluginHost reads it, and each kind of mismatch stops with an error and
# bundles nothing. Runs on Linux and macOS: scripts/test-fetch-apps.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
fetch="$here/fetch-apps.sh"
module="$here/../ios/Stone/Apps/hello/app.wasm"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
sum=$(sha256 "$module")
checkin=63b787002ebcb67be940cee22096c28b4a610979
cp "$module" "$t/app.wasm"
printf 'project stone\ncheck-in %s\n%s  app.wasm\n' "$checkin" "$sum" > "$t/release.txt"
printf 'not wasm' > "$t/other.wasm"
printf 'check-in %s\n%s  other.wasm\n' "$checkin" "$sum" > "$t/wrong-file.txt"
printf 'check-in %s\n%s  app.wasm\n' 0000000000000000000000000000000000000000 "$sum" > "$t/wrong-checkin.txt"

failures=0
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; failures=$((failures + 1)); }

# expect NAME ok|fail PINLINE
expect() {
  rm -rf "$t/apps"; mkdir "$t/apps"
  printf '# a comment\n\n%s\n' "$3" > "$t/pin"
  if "$fetch" "$t/pin" "$t/apps" > "$t/log" 2>&1; then got=ok; else got=fail; fi
  if [ "$got" != "$2" ]; then bad "$1 (expected $2, got $got)"; sed 's/^/     /' "$t/log"; return; fi
  if [ "$2" = fail ] && [ -n "$(ls -A "$t/apps")" ]; then bad "$1 (bundled something anyway)"; return; fi
  pass "$1"
}

expect "matching pin bundles the app" ok \
  "hello stone $checkin $sum file://$t/app.wasm file://$t/release.txt"
if cmp -s "$t/apps/hello/app.wasm" "$module" \
   && grep -qx "project stone" "$t/apps/hello/release.txt" \
   && grep -qx "check-in $checkin" "$t/apps/hello/release.txt" \
   && grep -qx "$sum  app.wasm" "$t/apps/hello/release.txt"; then
  pass "bundled app.wasm and release.txt are what PluginHost reads"
else
  bad "bundled app.wasm and release.txt are what PluginHost reads"
fi
expect "module bytes differ from the pin" fail \
  "hello stone $checkin $sum file://$t/other.wasm file://$t/release.txt"
expect "inventory lists the hash for another file" fail \
  "hello stone $checkin $sum file://$t/app.wasm file://$t/wrong-file.txt"
expect "inventory names another check-in" fail \
  "hello stone $checkin $sum file://$t/app.wasm file://$t/wrong-checkin.txt"
expect "module address missing" fail \
  "hello stone $checkin $sum file://$t/missing.wasm file://$t/release.txt"
expect "short check-in" fail \
  "hello stone 63b787002e $sum file://$t/app.wasm file://$t/release.txt"
expect "plain http refused" fail \
  "hello stone $checkin $sum http://127.0.0.1:9/app.wasm file://$t/release.txt"
grep -q 'Protocol "http" disabled' "$t/log" && pass "http refused by protocol, not by a failed connection" || bad "http refused by protocol, not by a failed connection"
expect "five fields" fail \
  "hello stone $checkin $sum file://$t/app.wasm"
expect "the pin file as committed bundles nothing" ok "# nothing pinned"
cp "$here/../ios/apps.pin" "$t/pin"
rm -rf "$t/apps"; mkdir "$t/apps"
if "$fetch" "$t/pin" "$t/apps" > "$t/log" 2>&1 && [ -z "$(ls -A "$t/apps")" ]; then
  pass "ios/apps.pin parses"
else
  bad "ios/apps.pin parses"; sed 's/^/     /' "$t/log"
fi

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
