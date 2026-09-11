#!/bin/sh
#
# stamp-build-identity.sh -- writes BuildCommit/BuildDate/BuildDirty into the
# BUILT app's Info.plist (read by ios/Stone/Views/BuildIdentityView.swift),
# never the tracked source at ios/Stone/Info.plist.
#
# This runs as the "Stamp Build Identity" Run Script build phase on the
# Stone target in ios/Stone.xcodeproj -- the last phase in that target, so
# it executes after Xcode has already processed Info.plist into the build
# product but before the automatic code-signing step that follows all
# explicit build phases, meaning the stamp ends up inside the signed
# artifact rather than invalidating its signature. Because it's a build
# phase, it fires for every xcodebuild invocation that builds the Stone
# target -- scripts/run-on-device.sh, scripts/testflight-upload.sh, and
# Xcode Cloud -- with no per-script duplication and no source-tree edits.
#
# Earlier versions of run-on-device.sh (and briefly, ci_post_clone.sh) wrote
# these same values straight into the checked-in ios/Stone/Info.plist. The
# maintainer caught the fallout from that (commit 7171e0bf49, describing the
# resulting dirtied Fossil checkout: "Junk. This should be in some kind of
# ignore list or be made not to change") -- this script exists so that
# `fossil changes` / `git status` stays empty after a stamped build.
#
# Best-effort only: a stamping failure must never fail the actual app
# build, so nothing here uses `set -e` and every step is allowed to no-op.

PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"

INFOPLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
[ -f "$INFOPLIST" ] || exit 0

# Xcode Cloud's checkout is the git mirror (Fossil trunk -> git export ->
# Forgejo -> GitLab -> GitHub -> Xcode Cloud), so CI_COMMIT is the only
# correct source of truth there; a local Mac build runs from the Fossil
# checkout directly, so it falls back to `fossil info`, then to `git
# rev-parse HEAD` for the rare case of building from a plain git clone.
BUILD_COMMIT="${CI_COMMIT:-}"
BUILD_DIRTY=false

if [ -z "$BUILD_COMMIT" ]; then
  if command -v fossil >/dev/null 2>&1 && fossil info >/dev/null 2>&1; then
    BUILD_COMMIT="$(fossil info 2>/dev/null | awk '/^checkout:/ {print $2}')"
    [ -n "$(fossil changes 2>/dev/null)" ] && BUILD_DIRTY=true
  elif command -v git >/dev/null 2>&1 && git rev-parse HEAD >/dev/null 2>&1; then
    BUILD_COMMIT="$(git rev-parse HEAD 2>/dev/null)"
    [ -n "$(git status --porcelain 2>/dev/null)" ] && BUILD_DIRTY=true
  fi
fi

[ -n "$BUILD_COMMIT" ] || exit 0
BUILD_COMMIT="$(printf '%s' "$BUILD_COMMIT" | cut -c1-12)"
BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

/usr/libexec/PlistBuddy -c "Set :BuildCommit ${BUILD_COMMIT}" "$INFOPLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :BuildCommit string ${BUILD_COMMIT}" "$INFOPLIST" 2>/dev/null
/usr/libexec/PlistBuddy -c "Set :BuildDate ${BUILD_DATE}" "$INFOPLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :BuildDate string ${BUILD_DATE}" "$INFOPLIST" 2>/dev/null
/usr/libexec/PlistBuddy -c "Set :BuildDirty ${BUILD_DIRTY}" "$INFOPLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :BuildDirty string ${BUILD_DIRTY}" "$INFOPLIST" 2>/dev/null

echo "==> Stamped build identity into built product: ${BUILD_COMMIT} (${BUILD_DATE}, dirty=${BUILD_DIRTY})"
exit 0
