#!/usr/bin/env bash
#
# linux-swift-check.sh — type-check the Stone Swift sources on Linux.
#
# Two modes, selected automatically:
#
#   Full type-check (recommended)
#     Requires: IOS_SDK_PATH set + a Swift Linux toolchain that supports the
#               arm64-apple-ios17.0 target. Catches type errors, missing API,
#               wrong signatures — the same class of errors Xcode would flag.
#
#   Parse-only fallback
#     When IOS_SDK_PATH is absent or Swift lacks iOS SDK support, falls back to
#     `swiftc -parse`, which catches syntax errors only.
#
# Install Swift for Linux: https://www.swift.org/install/linux/
#
# Install Swift iOS cross-compilation SDK (optional but recommended):
#   swift sdk install <bundle-url>
#   # e.g. for Swift 6.x on arm64-apple-ios17.0, check swift.org/download
#
# On Alpine/musl hosts: there is no official musl-hosted swiftc, and neither
# workaround pans out — confirmed by hand:
#   - Running the official glibc toolchain under gcompat gets past missing
#     libncurses/libtinfo, but swift-frontend itself aborts
#     (std::system_error, SIGABRT) on plain `-version`: a C++
#     exception/threading ABI mismatch gcompat can't paper over.
#   - Building the compiler from source targeting musl-as-host hits missing
#     build deps beyond libuuid (this isn't the officially supported
#     Static Linux SDK path, which cross-compiles musl *targets* from a
#     glibc host, not a musl-hosted compiler).
# If you need Swift type-checking on a non-glibc host, run this script
# inside an official Swift container instead (e.g. `swift:6.3.3-amazonlinux2`
# from Docker Hub) rather than chasing native Alpine support further.
#
# Usage:
#   IOS_SDK_PATH=/path/to/iPhoneOS.sdk bash scripts/linux-swift-check.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DIR="${REPO_ROOT}/ios"

if ! command -v swiftc &>/dev/null; then
  echo "Error: swiftc not found." >&2
  echo "  Install Swift for Linux: https://www.swift.org/install/linux/" >&2
  exit 1
fi

SWIFT_VER="$(swiftc --version 2>&1 | head -1)"
echo "Swift:    ${SWIFT_VER}"

# Default to the sandbox-mounted SDK when no explicit override was given.
if [[ -z "${IOS_SDK_PATH:-}" && -d /opt/iPhoneOS.sdk/usr/include ]]; then
  IOS_SDK_PATH=/opt/iPhoneOS.sdk
fi

# Collect Swift sources (StoneApp + models/services/views).
SWIFT_SOURCES=()
while IFS= read -r -d '' f; do
  SWIFT_SOURCES+=("$f")
done < <(find "${IOS_DIR}/Stone" -name '*.swift' -print0 | sort -z)

echo "Sources:  ${#SWIFT_SOURCES[@]} Swift files"

BRIDGING_HEADER="${IOS_DIR}/Stone/Stone-Bridging-Header.h"
FOSSIL_INC="${IOS_DIR}/FossilBridge"

if [[ -n "${IOS_SDK_PATH:-}" && -d "${IOS_SDK_PATH}/usr/include" ]]; then
  echo "Mode:     full type-check  (iOS SDK at ${IOS_SDK_PATH})"
  echo ""
  swiftc \
    -typecheck \
    -target arm64-apple-ios17.0 \
    -sdk "${IOS_SDK_PATH}" \
    -import-objc-header "${BRIDGING_HEADER}" \
    -I "${FOSSIL_INC}" \
    "${SWIFT_SOURCES[@]}"
else
  echo "Mode:     parse-only (IOS_SDK_PATH not set — syntax check only)"
  echo "  Set IOS_SDK_PATH to an iPhoneOS.sdk directory for full type-checking."
  echo ""
  # -parse validates syntax but does not resolve types or imports.
  swiftc \
    -parse \
    "${SWIFT_SOURCES[@]}"
fi

echo "Swift check passed."
