#!/usr/bin/env bash
#
# linux-build-libressl.sh — cross-compile LibreSSL for arm64-apple-ios on Linux.
#
# Adapted from scripts/build-libressl-ios.sh. The only difference is that
# xcrun and sysctl are replaced with direct tool references and $IOS_SDK_PATH.
#
# Prereqs (run in order):
#   export IOS_SDK_PATH=/path/to/iPhoneOS.sdk   (copied from a Mac — see linux-preflight.sh)
#   scripts/fetch-libressl.sh
#
# Optional overrides:
#   CC=clang-18   (default: clang)
#   NCPU=8        (default: nproc)
#
# Output (consumed by linux-build-fossil.sh):
#   build/libressl-ios/ios-arm64/lib/{libssl.a,libcrypto.a}
#   build/libressl-ios/include/openssl/*.h
#
set -euo pipefail

LIBRESSL_VERSION="4.1.0"
IOS_MIN="17.0"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${REPO_ROOT}/vendor/libressl-${LIBRESSL_VERSION}"
WORK="${REPO_ROOT}/build/libressl-ios"

# --- Prereq checks ---

if [[ -z "${IOS_SDK_PATH:-}" ]]; then
  echo "Error: IOS_SDK_PATH is not set." >&2
  echo "  Run: bash scripts/linux-preflight.sh  for setup instructions." >&2
  exit 1
fi
if [[ ! -d "${IOS_SDK_PATH}/usr/include" ]]; then
  echo "Error: IOS_SDK_PATH=${IOS_SDK_PATH} does not look like an iOS SDK (missing usr/include)." >&2
  exit 1
fi
if [[ ! -f "${SRC}/configure" ]]; then
  echo "LibreSSL source missing. Run scripts/fetch-libressl.sh first." >&2
  exit 1
fi

CC="${CC:-clang}"
if ! command -v "${CC}" &>/dev/null; then
  echo "Error: ${CC} not found. Install clang." >&2
  exit 1
fi

NCPU="${NCPU:-$(nproc 2>/dev/null || echo 4)}"

# --- Build ---

build_arch() {  # $1=label  $2=triple
  local label="$1" triple="$2"
  local bdir="${WORK}/src-${label}"
  local out="${WORK}/${label}"
  echo "==> Building LibreSSL for ${label} (${triple})"

  rm -rf "${bdir}" "${out}"
  mkdir -p "${out}/lib"
  cp -R "${SRC}" "${bdir}"

  (
    cd "${bdir}"
    # --host=aarch64-apple-darwin puts autoconf in cross mode so it never
    # executes test binaries against the target. CC/-target/-isysroot select
    # the iOS arm64 toolchain. Static only (iOS forbids dynamic loading).
    CC="${CC}" \
    CFLAGS="-isysroot ${IOS_SDK_PATH} -target ${triple} -Os -fno-common" \
    ./configure --host=aarch64-apple-darwin \
                --disable-shared --enable-static \
                --disable-dependency-tracking >/dev/null
    make -C crypto -j"${NCPU}" >/dev/null
    make -C ssl    -j"${NCPU}" >/dev/null
  )

  cp "${bdir}/ssl/.libs/libssl.a"       "${out}/lib/libssl.a"
  cp "${bdir}/crypto/.libs/libcrypto.a" "${out}/lib/libcrypto.a"
  echo "    -> ${out}/lib/{libssl,libcrypto}.a"

  # Headers are architecture-independent; capture once.
  if [[ ! -d "${WORK}/include/openssl" ]]; then
    mkdir -p "${WORK}/include"
    cp -R "${bdir}/include/openssl" "${WORK}/include/openssl"
    echo "    -> ${WORK}/include/openssl (shared)"
  fi
}

build_arch "ios-arm64" "arm64-apple-ios${IOS_MIN}"

echo "LibreSSL built under ${WORK}"
