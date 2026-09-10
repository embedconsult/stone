#!/bin/sh
set -e
cd "$CI_PRIMARY_REPOSITORY_PATH"
scripts/fetch-fossil.sh
scripts/gen-fossil-sources.sh
scripts/fetch-libressl.sh
scripts/build-libressl-ios.sh
scripts/build-fossil-xcframework.sh
test -d ios/Frameworks/FossilCore.xcframework
