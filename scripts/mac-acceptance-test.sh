#!/usr/bin/env bash
#
# mac-acceptance-test.sh — end-to-end acceptance test for the Stone iOS build,
# run on a Mac. Prints PASS/FAIL and exits 0/1 accordingly.
#
# What it proves:
#   - The full C dependency chain (LibreSSL + Fossil core) still builds clean
#     for both the iOS device and simulator arm64 slices.
#   - The Stone.app binary links successfully for BOTH iOS Simulator and a
#     real iOS device, with the Fossil core genuinely statically linked in
#     (checked by symbol, not just "the build didn't error").
#   - No code signing / Apple ID / provisioning profile is required to prove
#     any of this — CODE_SIGNING_ALLOWED=NO is used throughout, since final
#     signing for distribution/install is a separate, later step.
#
# What it does NOT cover (out of scope for a build acceptance check):
#   - Installing/launching on a real device — see scripts/run-on-device.sh.
#   - Signing, archiving, or App Store submission.
#   - UI/runtime behavior — this only proves the binary links; it does not
#     run it. (scripts/mac-demo.sh exercises the Fossil engine at runtime,
#     natively on macOS, if you want that kind of check too.)
#
# Usage:
#   scripts/mac-acceptance-test.sh           # fast: skips steps already up to date
#   scripts/mac-acceptance-test.sh --clean   # forces every step to redo its work
#                                             # from scratch (the real "prove it
#                                             # builds clean" run -- do this before
#                                             # actually merging/shipping)
#
# The underlying fetch/generate/build scripts are individually idempotent
# (each skips its own work if already up to date; --clean sets FORCE=1 to
# override that on all of them). xcodebuild itself also gets `clean` added
# to its action under --clean.
#
# Every step's full output is captured under build/acceptance-logs/ so a
# failure points straight at the relevant log instead of a wall of xcodebuild
# noise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

CLEAN=false
XCODE_ACTIONS=(build)
if [[ "${1:-}" == "--clean" ]]; then
  CLEAN=true
  export FORCE=1
  XCODE_ACTIONS=(clean build)
fi

PROJECT="${REPO_ROOT}/ios/Stone.xcodeproj"
SCHEME="Stone"
LOG_DIR="${REPO_ROOT}/build/acceptance-logs"
rm -rf "${LOG_DIR}"
mkdir -p "${LOG_DIR}"

STEP_NUM=0

fail_and_exit() {
  echo ""
  echo "=================================="
  echo " ACCEPTANCE: FAIL"
  echo " Logs: ${LOG_DIR}"
  echo "=================================="
  exit 1
}

# step NAME CMD...  — runs CMD, output captured to a log file. On failure,
# prints the tail of the log and aborts the whole test immediately (every
# later step depends on this one's output, so there is nothing to gain by
# continuing).
step() {
  local name="$1"; shift
  STEP_NUM=$((STEP_NUM + 1))
  local slug; slug="$(printf '%02d-%s' "${STEP_NUM}" "${name}" | tr ' /' '--')"
  local log="${LOG_DIR}/${slug}.log"
  printf '==> [%d] %s\n' "${STEP_NUM}" "${name}"
  local t0=${SECONDS}
  if "$@" >"${log}" 2>&1; then
    printf '    OK (%ds)\n' "$((SECONDS - t0))"
  else
    printf '    FAIL (%ds) -- log: %s\n' "$((SECONDS - t0))" "${log}" >&2
    echo "    ---- last 30 lines ----" >&2
    tail -30 "${log}" >&2
    fail_and_exit
  fi
}

# require NAME CHECK_FN ARGS... — runs a short verification function whose
# stdout is a one-line status message. Same fail-fast behavior as step(), but
# for cheap in-process checks that don't need their own log file.
require() {
  local name="$1"; shift
  STEP_NUM=$((STEP_NUM + 1))
  printf '==> [%d] %s\n' "${STEP_NUM}" "${name}"
  local msg
  if msg="$("$@" 2>&1)"; then
    printf '    OK: %s\n' "${msg}"
  else
    printf '    FAIL: %s\n' "${msg}" >&2
    fail_and_exit
  fi
}

check_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || { echo "this script must run on macOS (found $(uname -s))"; return 1; }
  echo "macOS $(sw_vers -productVersion 2>/dev/null || echo unknown)"
}

check_xcode_tools() {
  for t in xcodebuild xcrun lipo file nm; do
    command -v "${t}" >/dev/null 2>&1 || { echo "${t} not found"; return 1; }
  done
  xcodebuild -version | head -1
}

verify_xcframework() {
  local fw="${REPO_ROOT}/ios/Frameworks/FossilCore.xcframework"
  local dev="${fw}/ios-arm64/libfossil.a"
  local sim="${fw}/ios-arm64-simulator/libfossil.a"
  [[ -f "${dev}" ]] || { echo "missing ${dev}"; return 1; }
  [[ -f "${sim}" ]] || { echo "missing ${sim}"; return 1; }
  lipo -info "${dev}" 2>&1 | grep -q arm64 || { echo "device slice missing arm64: $(lipo -info "${dev}" 2>&1)"; return 1; }
  lipo -info "${sim}" 2>&1 | grep -q arm64 || { echo "simulator slice missing arm64: $(lipo -info "${sim}" 2>&1)"; return 1; }
  local sz; sz=$(stat -f%z "${dev}")
  [[ "${sz}" -gt 5000000 ]] || { echo "device libfossil.a suspiciously small (${sz} bytes) -- Fossil may not have linked in fully"; return 1; }
  echo "device + simulator arm64 slices present ($((sz / 1024 / 1024)) MB device slice)"
}

# ARCHS=arm64 on both: a `generic/...` destination isn't tied to a concrete
# booted simulator/device, so Xcode can't detect one "active" arch and
# defaults to building the project's whole ARCHS list instead (arm64 +
# x86_64 for the simulator SDK, via $(ARCHS_STANDARD)). FossilCore.xcframework
# only ships arm64 slices (device and simulator), so an x86_64 simulator
# link fails with undefined stone_fossil_* symbols otherwise. iOS device has
# no x86_64 arch anyway, so this is a no-op there -- kept for symmetry.
#
# ENABLE_DEBUG_DYLIB=NO: Xcode 15+ Debug builds split the app into a thin
# `Stone` loader binary plus the actual linked code in a separate
# `Stone.debug.dylib`, for faster incremental debugging. That breaks
# verify_app_binary()'s "Stone" symbol check below (it would need to look in
# the dylib instead), and isn't how a real Release/Archive build links
# anyway -- disabling it here makes Debug link like Release: one
# self-contained executable, which is what we actually want to verify.
build_simulator() {
  local derived="${REPO_ROOT}/ios/build/acceptance-sim"
  rm -rf "${derived}"
  xcodebuild \
    -project "${PROJECT}" -scheme "${SCHEME}" -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "${derived}" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO ENABLE_DEBUG_DYLIB=NO \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    "${XCODE_ACTIONS[@]}"
}

build_device() {
  local derived="${REPO_ROOT}/ios/build/acceptance-device"
  rm -rf "${derived}"
  xcodebuild \
    -project "${PROJECT}" -scheme "${SCHEME}" -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "${derived}" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO ENABLE_DEBUG_DYLIB=NO \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    "${XCODE_ACTIONS[@]}"
}

# verify_app_binary APP_BUNDLE WANT_ARCH
# Confirms a real, linked, non-trivial Mach-O binary was produced, and that
# Fossil's C core actually made it into the link (checked via a symbol that
# Swift calls directly, per ios/Stone/Services/FossilEngine.swift) -- so a
# silently-stubbed-out static lib wouldn't pass.
verify_app_binary() {
  local app="$1" want_arch="$2"
  local exe="${app}/Stone"
  [[ -d "${app}" ]] || { echo "app bundle missing: ${app}"; return 1; }
  [[ -x "${exe}" ]] || { echo "executable missing: ${exe}"; return 1; }
  file "${exe}" | grep -q "Mach-O" || { echo "not a Mach-O binary: $(file "${exe}")"; return 1; }
  lipo -info "${exe}" 2>&1 | grep -q "${want_arch}" || { echo "arch ${want_arch} not found: $(lipo -info "${exe}" 2>&1)"; return 1; }
  nm "${exe}" 2>/dev/null | grep -q "stone_fossil_run" || { echo "stone_fossil_run not found in binary -- Fossil core may not be statically linked in"; return 1; }
  local sz; sz=$(stat -f%z "${exe}")
  echo "${exe} -- Mach-O ${want_arch}, $((sz / 1024 / 1024)) MB, Fossil core linked"
}

echo "=== Stone iOS build — Mac acceptance test ==="
if ${CLEAN}; then
  echo "(--clean: every step forced to redo its work from scratch)"
else
  echo "(fast mode: steps already up to date are skipped -- use --clean to force a full rebuild)"
fi
echo ""

require "macOS host"            check_macos
require "Xcode command-line tools" check_xcode_tools

step "fetch LibreSSL source"          bash scripts/fetch-libressl.sh
step "fetch Fossil source"            bash scripts/fetch-fossil.sh
step "generate Fossil sources"        bash scripts/gen-fossil-sources.sh
step "build LibreSSL (device+sim)"    bash scripts/build-libressl-ios.sh
step "build FossilCore.xcframework"   bash scripts/build-fossil-xcframework.sh
require "xcframework slices"          verify_xcframework

step "xcodebuild: iOS Simulator (unsigned)" build_simulator
require "simulator app binary"        verify_app_binary "${REPO_ROOT}/ios/build/acceptance-sim/Build/Products/Debug-iphonesimulator/Stone.app" arm64

step "xcodebuild: iOS device (unsigned)"    build_device
require "device app binary"           verify_app_binary "${REPO_ROOT}/ios/build/acceptance-device/Build/Products/Debug-iphoneos/Stone.app" arm64

echo ""
echo "=================================="
echo " ACCEPTANCE: PASS"
echo " Simulator app: ios/build/acceptance-sim/Build/Products/Debug-iphonesimulator/Stone.app"
echo " Device app:    ios/build/acceptance-device/Build/Products/Debug-iphoneos/Stone.app (unsigned)"
echo ""
echo " Not covered here -- sign + install on a device via:"
echo "   scripts/run-on-device.sh"
echo "=================================="
exit 0
