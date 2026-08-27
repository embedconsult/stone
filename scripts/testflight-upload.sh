#!/usr/bin/env bash
#
# testflight-upload.sh — archive, sign, and upload Stone to App Store Connect
# TestFlight in one command, no Xcode UI needed.
#
# Signing: automatic, same mechanism as scripts/run-on-device.sh —
# -allowProvisioningUpdates lets xcodebuild mint/refresh the Distribution
# certificate + App Store provisioning profile for the team set in the
# project (DEVELOPMENT_TEAM). Requires the matching Apple ID to be signed
# in to Xcode (Xcode > Settings > Accounts) with an App Store Connect role
# (App Manager or above) — a one-time step per Mac, not a per-build one.
#
# Upload: the generated ExportOptions.plist sets destination=upload, so
# `xcodebuild -exportArchive` performs the App Store Connect upload directly
# — no separate altool/Transporter step.
#
# One-time Apple-account setup this script does NOT do (see
# docs/ota-updates.md section 1): registering the org.beagleboard.stone bundle id,
# creating the App Store Connect app record, and creating a TestFlight
# Internal Testing group. Run this only after that setup exists.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${REPO_ROOT}/ios/Stone.xcodeproj"
SCHEME="Stone"
TEAM_ID="BWWLLRK896"
INFOPLIST="${REPO_ROOT}/ios/Stone/Info.plist"
BUILD_DIR="${REPO_ROOT}/ios/build/testflight"
ARCHIVE_PATH="${BUILD_DIR}/Stone.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"

mkdir -p "${BUILD_DIR}"

# App Store Connect rejects re-uploading a build number it has already seen
# for the current CFBundleShortVersionString, so every upload needs a fresh
# one. A UTC timestamp is monotonic without needing any committed/shared
# counter state. Info.plist is restored on exit so the working tree stays
# clean regardless of success or failure.
BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
ORIGINAL_INFOPLIST="$(mktemp)"
cp "${INFOPLIST}" "${ORIGINAL_INFOPLIST}"
restore_infoplist() { cp "${ORIGINAL_INFOPLIST}" "${INFOPLIST}"; rm -f "${ORIGINAL_INFOPLIST}"; }
trap restore_infoplist EXIT

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${INFOPLIST}"
echo "==> Build number: ${BUILD_NUMBER}"

echo "==> Archiving ${SCHEME} (Release, generic iOS device)"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "${ARCHIVE_PATH}" \
  -allowProvisioningUpdates \
  archive

cat > "${EXPORT_OPTIONS}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>upload</string>
</dict>
</plist>
PLIST

echo "==> Exporting & uploading to App Store Connect"
xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}" \
  -allowProvisioningUpdates

echo "Done. Build ${BUILD_NUMBER} uploaded."
echo "It'll show up under App Store Connect > Stone > TestFlight > iOS Builds"
echo "once processing finishes (usually a few minutes), then sync to phones in"
echo "the assigned Internal Testing group automatically."
