#!/usr/bin/env bash
#
# fetch-libressl.sh — download and unpack the pinned LibreSSL source tree.
#
# Single purpose: place a clean LibreSSL portable source tree under vendor/.
# LibreSSL provides Fossil's TLS layer (src/http_ssl.c uses the OpenSSL API,
# which LibreSSL implements) so clone/sync over https:// works.
#
# Skips re-extracting if ${SRC_DIR} already exists, since the version is
# pinned in the path -- a version bump gets a new SRC_DIR automatically, so an
# existing one is always the right content. Set FORCE=1 to re-extract anyway.
#
set -euo pipefail

LIBRESSL_VERSION="4.1.0"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor"
SRC_DIR="${VENDOR_DIR}/libressl-${LIBRESSL_VERSION}"
TARBALL="${VENDOR_DIR}/libressl-src.tar.gz"
URL="https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${LIBRESSL_VERSION}.tar.gz"

if [[ -d "${SRC_DIR}" && -z "${FORCE:-}" ]]; then
  echo "LibreSSL source already present at ${SRC_DIR}  (set FORCE=1 to re-extract)"
  exit 0
fi

mkdir -p "${VENDOR_DIR}"

if [[ ! -f "${TARBALL}" ]]; then
  echo "Downloading LibreSSL ${LIBRESSL_VERSION} source..."
  curl -fsSL --max-time 300 -o "${TARBALL}" "${URL}"
fi

echo "Extracting into ${SRC_DIR}..."
rm -rf "${SRC_DIR}"
tar -xzf "${TARBALL}" -C "${VENDOR_DIR}"

echo "Done. LibreSSL source at: ${SRC_DIR}"
