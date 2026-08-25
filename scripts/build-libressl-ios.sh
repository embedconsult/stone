#!/usr/bin/env bash
#
# build-libressl-ios.sh — build static LibreSSL (libssl.a + libcrypto.a) for the
# iOS device (arm64) and simulator (arm64) slices, plus a copy of the public
# headers. These provide Fossil's TLS layer (src/http_ssl.c uses the OpenSSL
# API, implemented by LibreSSL) so clone/sync over https:// works.
#
# Output layout (consumed by build-fossil-xcframework.sh):
#   build/libressl-ios/ios-arm64/lib/{libssl.a,libcrypto.a}
#   build/libressl-ios/ios-arm64-sim/lib/{libssl.a,libcrypto.a}
#   build/libressl-ios/include/openssl/*.h        (arch-independent public API)
#
# Prereq: scripts/fetch-libressl.sh  (vendor the pinned source)
#
set -euo pipefail

LIBRESSL_VERSION="4.1.0"
IOS_MIN="17.0"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${REPO_ROOT}/vendor/libressl-${LIBRESSL_VERSION}"
WORK="${REPO_ROOT}/build/libressl-ios"

if [[ ! -f "${SRC}/configure" ]]; then
  echo "LibreSSL source missing. Run scripts/fetch-libressl.sh first." >&2
  exit 1
fi

build_arch() {            # $1 = label  $2 = sdk  $3 = clang target triple
  local label="$1" sdk="$2" triple="$3"
  local bdir="${WORK}/src-${label}"
  local out="${WORK}/${label}"

  if [[ -z "${FORCE:-}" && -f "${out}/lib/libssl.a" && -f "${out}/lib/libcrypto.a" ]]; then
    echo "==> LibreSSL for ${label} already built; skipping (set FORCE=1 to rebuild)"
    return
  fi

  local sysroot; sysroot="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  local cc; cc="$(xcrun --sdk "${sdk}" --find clang)"
  echo "==> Building LibreSSL for ${label} (${triple})"

  rm -rf "${bdir}" "${out}"
  mkdir -p "${out}/lib"
  cp -R "${SRC}" "${bdir}"

  # cp -R does not preserve source mtimes, and per-file copy timing can leave
  # aclocal.m4/configure.ac looking "newer" than the generated configure/
  # Makefile.in purely by copy-order luck. That trips automake's
  # maintainer-mode auto-remake rules under `make`, which reruns the system's
  # (different, newer) autoconf/automake and can produce a libtool script
  # that fails to substitute its extended shell functions -- surfacing as
  # cascading conftest/libtoolT errors and "no rule to make target
  # .../libcrypto.la". Stamping every copied file to an identical mtime
  # means nothing ever looks newer than anything else, so the auto-remake
  # rules never fire.
  find "${bdir}" -exec touch -t 202001010000 {} +

  (
    cd "${bdir}"
    # Cross-compile via autotools: --host (different from build) puts configure
    # in cross mode so it never executes test binaries; CC/-target/-isysroot
    # select the iOS toolchain. Static only (iOS forbids dynamic loading).
    # --disable-dependency-tracking avoids automake's .Tpo→.Plo depmode, which
    # breaks under macOS's bash 3.2 (libtool can't substitute its extended shell
    # functions). We do a clean one-shot build, so per-file deps add nothing.
    CC="${cc}" \
    CFLAGS="-isysroot ${sysroot} -target ${triple} -Os -fno-common" \
    ./configure --host=aarch64-apple-darwin \
                --disable-shared --enable-static \
                --disable-dependency-tracking >/dev/null
    # Only the two libraries Fossil links — skip apps/tests/tls.
    make -C crypto -j"$(sysctl -n hw.ncpu)" >/dev/null
    make -C ssl    -j"$(sysctl -n hw.ncpu)" >/dev/null
  )

  cp "${bdir}/ssl/.libs/libssl.a"       "${out}/lib/libssl.a"
  cp "${bdir}/crypto/.libs/libcrypto.a" "${out}/lib/libcrypto.a"
  echo "    -> ${out}/lib/{libssl,libcrypto}.a"

  # Public headers are arch-independent for our two arm64 slices; capture once.
  if [[ ! -d "${WORK}/include/openssl" ]]; then
    mkdir -p "${WORK}/include"
    cp -R "${bdir}/include/openssl" "${WORK}/include/openssl"
    echo "    -> ${WORK}/include/openssl (shared)"
  fi
}

build_arch "ios-arm64"     "iphoneos"        "arm64-apple-ios${IOS_MIN}"
build_arch "ios-arm64-sim" "iphonesimulator" "arm64-apple-ios${IOS_MIN}-simulator"

# Sanity-check that each slice produced the expected arm64 architecture.
for slice in ios-arm64 ios-arm64-sim; do
  if ! lipo -info "${WORK}/${slice}/lib/libcrypto.a" 2>/dev/null | grep -q "arm64"; then
    echo "ERROR: ${slice} libcrypto.a is not arm64." >&2
    lipo -info "${WORK}/${slice}/lib/libcrypto.a" >&2 || true
    exit 1
  fi
done

echo "LibreSSL built under ${WORK}"
