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

# Build identity (BuildCommit/BuildDate, read by BuildIdentityView.swift) is
# stamped into the BUILT app's Info.plist by the "Stamp Build Identity" Run
# Script build phase on the Stone target (scripts/stamp-build-identity.sh),
# which runs as part of every xcodebuild invocation Xcode Cloud makes --
# nothing needed here. An earlier version of this file stamped the values
# directly into the checked-in ios/Stone/Info.plist instead; that's the same
# mistake the maintainer had already flagged in scripts/run-on-device.sh
# (commit 7171e0bf49: "Junk. This should be in some kind of ignore list or
# be made not to change"), just not yet made here too.
