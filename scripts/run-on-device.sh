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
# This entire script is Apple-toolchain-only (xcodebuild, xcrun devicectl,
# plutil): it can only run on a Mac with Xcode installed, never on Linux/CI.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "run-on-device.sh requires macOS + Xcode command-line tools (xcodebuild, devicectl, plutil)." >&2
  echo "Found: $(uname -s). This step cannot run here -- build, sign, install, and launch all" >&2
  echo "require the Mac/Xcode side. Run this script on a Mac with the device tethered." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${REPO_ROOT}/ios/Stone.xcodeproj"
SCHEME="Stone"
BUNDLE_ID="com.stone.app"
DERIVED="${REPO_ROOT}/ios/build/dd"

# Resolve the connected device. Two identifiers are needed:
#   - hardware UDID  -> xcodebuild -destination id=
#   - CoreDevice id  -> devicectl install/launch
# Override both by exporting HW_UDID / CORE_ID (required if more than one
# device is connected -- this script refuses to guess which one you meant,
# since silently picking the wrong device is exactly how "it stays stale"
# reports happen).
DEVJSON="$(mktemp)"
xcrun devicectl list devices --json-output "${DEVJSON}" >/dev/null
mapfile -t CONNECTED < <(/usr/bin/python3 - "${DEVJSON}" <<'PY'
import json, sys
devs = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devs:
    if d.get("connectionProperties", {}).get("tunnelState") == "connected":
        core = d.get("identifier", "")
        udid = d.get("hardwareProperties", {}).get("udid", "")
        name = d.get("deviceProperties", {}).get("name", "")
        print(f"{core}\t{udid}\t{name}")
PY
)
rm -f "${DEVJSON}"

if [[ -n "${HW_UDID:-}" && -n "${CORE_ID:-}" ]]; then
  DEV_NAME="${DEV_NAME:-<override via HW_UDID/CORE_ID>}"
elif [[ "${#CONNECTED[@]}" -eq 0 ]]; then
  echo "No connected device found. Plug in an unlocked, trusted iPhone." >&2
  exit 1
elif [[ "${#CONNECTED[@]}" -gt 1 ]]; then
  echo "Multiple connected devices found -- refusing to guess which one to deploy to:" >&2
  for line in "${CONNECTED[@]}"; do
    IFS=$'\t' read -r core udid name <<<"${line}"
    echo "  ${name}  (HW_UDID=${udid} CORE_ID=${core})" >&2
  done
  echo "Re-run with HW_UDID=<udid> CORE_ID=<id> exported to pick one." >&2
  exit 1
else
  IFS=$'\t' read -r CORE_ID HW_UDID DEV_NAME <<<"${CONNECTED[0]}"
fi
echo "==> Target device: ${DEV_NAME} (${HW_UDID})"

# Stamp build identity: repo checkin hash, dirty flag, and build timestamp,
# written into Info.plist so the built app carries proof of exactly which
# checkout produced it.
BUILD_HASH="$(fossil info | awk '/^checkout:/ {print substr($2, 1, 7)}')"
BUILD_DATE="$(date -u "+%Y-%m-%d %H:%M:%S UTC")"
if [[ -n "$(fossil changes)" ]]; then
  BUILD_DIRTY=true
else
  BUILD_DIRTY=false
fi
BUILD_LABEL="${BUILD_HASH}"
[[ "${BUILD_DIRTY}" == "true" ]] && BUILD_LABEL="${BUILD_LABEL}-dirty"

echo "==> Stamping build identity: ${BUILD_LABEL} (${BUILD_DATE})"
plutil -replace BuildCommit -string "${BUILD_HASH}" "${REPO_ROOT}/ios/Stone/Info.plist"
plutil -replace BuildDate -string "${BUILD_DATE}" "${REPO_ROOT}/ios/Stone/Info.plist"
plutil -replace BuildDirty -string "${BUILD_DIRTY}" "${REPO_ROOT}/ios/Stone/Info.plist"

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
[[ -d "${APP}" ]] || { echo "Build product missing: ${APP} -- xcodebuild reported success but produced no app bundle." >&2; exit 1; }

# Verify the just-built bundle actually embeds the stamp we just wrote,
# instead of trusting that a "successful" xcodebuild produced fresh output.
# A build reusing a stale product (bad derived-data cache, skipped Info.plist
# processing, etc.) would otherwise install silently and look identical to a
# real deploy -- which is exactly the "app stays stale" failure mode this
# script needs to catch, rather than just declaring "Done" regardless.
EMBEDDED_COMMIT="$(plutil -extract BuildCommit raw "${APP}/Info.plist" 2>/dev/null || true)"
if [[ "${EMBEDDED_COMMIT}" != "${BUILD_HASH}" ]]; then
  echo "Build verification FAILED: built app reports BuildCommit='${EMBEDDED_COMMIT:-<missing>}'," >&2
  echo "expected '${BUILD_HASH}'. Refusing to install a build that may be stale." >&2
  exit 1
fi
echo "==> Verified build product embeds build ${BUILD_LABEL}"

echo "==> Installing ${APP##*/} to ${DEV_NAME}"
xcrun devicectl device install app --device "${CORE_ID}" "${APP}"

echo "==> Launching ${BUNDLE_ID}"
xcrun devicectl device process launch --device "${CORE_ID}" "${BUNDLE_ID}"

# Best-effort extra confirmation, sourced from the device itself rather than
# local state: ask devicectl what it thinks is installed. This is additive --
# if the subcommand/flags aren't available on the local Xcode version, skip
# it without failing the run, since install/launch above already exited 0.
echo "==> Confirming with the device directly"
APPS_JSON="$(mktemp)"
if xcrun devicectl device info apps --device "${CORE_ID}" --bundle-id "${BUNDLE_ID}" --json-output "${APPS_JSON}" >/dev/null 2>&1; then
  DEVICE_REPORT="$(/usr/bin/python3 - "${APPS_JSON}" "${BUNDLE_ID}" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    for a in data.get("result", {}).get("apps", []):
        if a.get("bundleIdentifier") == sys.argv[2]:
            print(f"{a.get('name', sys.argv[2])} version {a.get('bundleVersion', '?')}")
            break
except Exception:
    pass
PY
)"
  if [[ -n "${DEVICE_REPORT}" ]]; then
    echo "    Device confirms installed: ${DEVICE_REPORT}"
  else
    echo "    (devicectl returned no matching app entry for ${BUNDLE_ID} -- install/launch above still reported success)"
  fi
else
  echo "    (devicectl device info apps unavailable on this Xcode version -- skipping; install/launch above already reported success)"
fi
rm -f "${APPS_JSON}"

echo "=================================================="
echo "Deployed build ${BUILD_LABEL} (built ${BUILD_DATE}) to ${DEV_NAME}."
echo ""
echo "What was actually verified above: the built .app embeds BuildCommit=${BUILD_HASH}"
echo "in its Info.plist (checked before install, so it can't be a stale product), and"
echo "devicectl reported both 'install app' and 'process launch' as successful."
echo ""
echo "Device-visible confirmation step: on launch, Stone briefly overlays its build"
echo "identity; Settings > About retains the commit/date details. To confirm by hand:"
echo "  xcrun devicectl device info apps --device ${CORE_ID} --bundle-id ${BUNDLE_ID}"
echo "and check the reported version, or pull the installed bundle's Info.plist and"
echo "look for BuildCommit=${BUILD_HASH}. If Stone was already running before this"
echo "script launched it, force-quit and relaunch it once so the freshly installed"
echo "binary -- not the previous running process -- is what you're looking at."
echo "=================================================="
