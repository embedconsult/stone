#!/usr/bin/env bash
#
# run-on-device.sh — build, sign, install, and launch Stone on a tethered
# iPhone, entirely from the command line (no Xcode UI).
#
# Signing is automatic: -allowProvisioningUpdates lets xcodebuild create/refresh
# the Apple Development cert + development provisioning profile for the team set
# in the project (DEVELOPMENT_TEAM). Requires the matching Apple ID to be signed
# in to Xcode (Xcode > Settings > Accounts) once; after that this is hands-off.
#
# Prereq: FossilCore.xcframework must contain the ios-arm64 (device) slice —
# built by scripts/build-fossil-xcframework.sh.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${REPO_ROOT}/ios/Stone.xcodeproj"
SCHEME="Stone"
BUNDLE_ID="com.stone.app"
DERIVED="${REPO_ROOT}/ios/build/dd"

# Resolve the first connected device. Two identifiers are needed:
#   - hardware UDID  -> xcodebuild -destination id=
#   - CoreDevice id  -> devicectl install/launch
# Override either by exporting HW_UDID / CORE_ID.
DEVJSON="$(mktemp)"
xcrun devicectl list devices --json-output "${DEVJSON}" >/dev/null 2>&1
read -r CORE_ID HW_UDID DEV_NAME < <(/usr/bin/python3 - "${DEVJSON}" <<'PY'
import json, sys
devs = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devs:
    if d["connectionProperties"]["tunnelState"] == "connected":
        print(d["identifier"],
              d.get("hardwareProperties", {}).get("udid", ""),
              d.get("deviceProperties", {}).get("name", ""))
        break
PY
)
rm -f "${DEVJSON}"
CORE_ID="${CORE_ID:-}"; HW_UDID="${HW_UDID:-}"
if [[ -z "${HW_UDID}" || -z "${CORE_ID}" ]]; then
  echo "No connected device found. Plug in an unlocked, trusted iPhone." >&2
  exit 1
fi
echo "==> Target device: ${DEV_NAME} (${HW_UDID})"

echo "==> Building & signing for device (automatic provisioning)"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Debug \
  -destination "id=${HW_UDID}" \
  -derivedDataPath "${DERIVED}" \
  -allowProvisioningUpdates \
  build

APP="${DERIVED}/Build/Products/Debug-iphoneos/Stone.app"
[[ -d "${APP}" ]] || { echo "Build product missing: ${APP}" >&2; exit 1; }

echo "==> Installing ${APP##*/}"
xcrun devicectl device install app --device "${CORE_ID}" "${APP}"

echo "==> Launching ${BUNDLE_ID}"
xcrun devicectl device process launch --device "${CORE_ID}" "${BUNDLE_ID}"

echo "Done. Stone is running on ${DEV_NAME}."
