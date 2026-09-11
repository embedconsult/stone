#!/bin/sh
set -e
cd "$CI_PRIMARY_REPOSITORY_PATH"
scripts/fetch-fossil.sh
scripts/gen-fossil-sources.sh
scripts/fetch-libressl.sh
scripts/build-libressl-ios.sh
scripts/fetch-cacert.sh
scripts/build-fossil-xcframework.sh
test -d ios/Frameworks/FossilCore.xcframework

# Stamp build identity so About/Settings (BuildIdentityView.swift) shows
# exactly which commit produced this TestFlight build -- the end-to-end
# proof that the mirror chain (Fossil trunk -> git export -> Forgejo ->
# GitLab -> GitHub -> Xcode Cloud) actually delivered it.
#
# Xcode Cloud checks out the git mirror, not Fossil, so the commit here is a
# git SHA -- unlike scripts/run-on-device.sh, which stamps a Fossil checkin
# hash directly for tethered device builds. CI_COMMIT is Xcode Cloud's own
# env var for the commit that triggered the build; `git rev-parse HEAD`
# covers a manual run of this script outside Xcode Cloud.
BUILD_COMMIT="${CI_COMMIT:-}"
if [ -z "$BUILD_COMMIT" ]; then
  BUILD_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"
fi
BUILD_COMMIT="$(printf '%s' "$BUILD_COMMIT" | cut -c1-12)"
BUILD_DATE="$(date -u "+%Y-%m-%d %H:%M:%S UTC")"
INFOPLIST="ios/Stone/Info.plist"

if [ -n "$BUILD_COMMIT" ]; then
  echo "==> Stamping build identity: ${BUILD_COMMIT} (${BUILD_DATE})"
  /usr/libexec/PlistBuddy -c "Set :BuildCommit ${BUILD_COMMIT}" "$INFOPLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :BuildCommit string ${BUILD_COMMIT}" "$INFOPLIST"
  /usr/libexec/PlistBuddy -c "Set :BuildDate ${BUILD_DATE}" "$INFOPLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :BuildDate string ${BUILD_DATE}" "$INFOPLIST"
else
  echo "==> No commit identifier available (CI_COMMIT unset, not a git checkout) -- Info.plist stays unstamped" >&2
fi
