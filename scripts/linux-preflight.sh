#!/usr/bin/env bash
#
# linux-preflight.sh — verify this Linux machine is ready for iOS cross-compilation.
#
# Run before the build scripts to catch missing tools early.
# Nothing is installed or changed; this is read-only.
#
# Usage:
#   IOS_SDK_PATH=/path/to/iPhoneOS.sdk bash scripts/linux-preflight.sh
#
# IOS_SDK_PATH must point to an iPhoneOS.sdk directory copied from a Mac.
# On the Mac:
#   SDK=$(xcrun --sdk iphoneos --show-sdk-path)
#   tar -czf iPhoneOS.sdk.tar.gz -C "$(dirname "$SDK")" "$(basename "$SDK")"
#   scp iPhoneOS.sdk.tar.gz user@linux-host:
# On Linux:
#   tar -xzf iPhoneOS.sdk.tar.gz
#   export IOS_SDK_PATH="$PWD/iPhoneOSNN.sdk"

set -euo pipefail

OK=true
fail() { echo "  MISSING: $*" >&2; OK=false; }
ok()   { echo "  OK:      $*"; }
warn() { echo "  WARN:    $*"; }

echo "=== Stone iOS build — Linux preflight ==="
echo ""

echo "--- C cross-compilation tools ---"
if command -v clang &>/dev/null; then
  ok "clang: $(clang --version 2>&1 | head -1)"
else
  fail "clang not found  (debian/ubuntu: apt install clang  |  rhel/amzn: dnf install clang)"
fi

if command -v llvm-ar &>/dev/null; then
  ok "llvm-ar: $(llvm-ar --version 2>&1 | head -1)"
elif command -v ar &>/dev/null; then
  warn "ar found ($(ar --version 2>&1 | head -1)); llvm-ar preferred (apt install llvm)"
else
  fail "ar not found  (debian/ubuntu: apt install binutils  |  rhel/amzn: dnf install binutils)"
fi

echo ""
echo "--- iOS SDK (required — must be copied from a Mac with Xcode) ---"
if [[ -n "${IOS_SDK_PATH:-}" ]]; then
  if [[ -d "${IOS_SDK_PATH}/usr/include" ]]; then
    # Extract the SDK version from SDKSettings.plist with grep (no plutil on Linux).
    SDK_VER="$(grep -A1 '<key>Version</key>' "${IOS_SDK_PATH}/SDKSettings.plist" 2>/dev/null \
               | grep -m1 string | sed 's|.*<string>\(.*\)</string>.*|\1|' || echo unknown)"
    ok "IOS_SDK_PATH=${IOS_SDK_PATH}  (SDK version: ${SDK_VER})"
  else
    fail "IOS_SDK_PATH=${IOS_SDK_PATH} set but missing usr/include — does not look like a valid iOS SDK"
  fi
else
  fail "IOS_SDK_PATH not set"
  echo ""
  echo "  Copy the SDK from your Mac (run these commands ON THE MAC):"
  echo '    SDK=$(xcrun --sdk iphoneos --show-sdk-path)'
  echo '    tar -czf iPhoneOS.sdk.tar.gz -C "$(dirname "$SDK")" "$(basename "$SDK")"'
  echo '    scp iPhoneOS.sdk.tar.gz user@this-linux-host:~/'
  echo ""
  echo "  Then on this Linux machine:"
  echo '    cd ~/'
  echo '    tar -xzf iPhoneOS.sdk.tar.gz'
  echo '    export IOS_SDK_PATH="$HOME/iPhoneOS17.x.sdk"   # adjust version'
fi

echo ""
echo "--- Build tools ---"
for tool in make curl tar patch; do
  if command -v "${tool}" &>/dev/null; then
    ok "${tool}"
  else
    fail "${tool} not found"
  fi
done

# Fossil's configure uses autosetup which needs either a system tclsh or
# compiles its own jimsh from autosetup/jimsh0.c (requires just a C compiler).
if command -v tclsh &>/dev/null; then
  ok "tclsh: $(tclsh <<< 'puts [info patchlevel]')"
else
  warn "tclsh not found; Fossil's autosetup will compile jimsh0.c as a fallback (usually fine)"
fi

echo ""
echo "--- Swift (optional — needed only for linux-swift-check.sh) ---"
if command -v swiftc &>/dev/null; then
  ok "swiftc: $(swiftc --version 2>&1 | head -1)"
else
  warn "swiftc not found  — install from https://www.swift.org/install/linux/ to enable Swift type-checking"
fi

echo ""
echo "=== Build sequence (once preflight passes) ==="
echo "  1.  scripts/fetch-libressl.sh"
echo "  2.  scripts/fetch-fossil.sh          (already have vendor/fossil-src.tar.gz)"
echo "  3.  scripts/gen-fossil-sources.sh    (generates bld/*_.c on the Linux host)"
echo "  4.  IOS_SDK_PATH=... scripts/linux-build-libressl.sh"
echo "  5.  IOS_SDK_PATH=... scripts/linux-build-fossil.sh"
echo "  6.  IOS_SDK_PATH=... scripts/linux-swift-check.sh  (optional)"
echo ""

if [[ "${OK}" == "true" ]]; then
  echo "Preflight: PASS"
else
  echo "Preflight: FAIL — fix the errors above before building" >&2
  exit 1
fi
