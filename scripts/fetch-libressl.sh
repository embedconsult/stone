#!/usr/bin/env bash
#
# fetch-libressl.sh — download and unpack the pinned LibreSSL source tree.
#
# Single purpose: place a clean LibreSSL portable source tree under vendor/.
# LibreSSL provides Fossil's TLS layer (src/http_ssl.c uses the OpenSSL API,
# which LibreSSL implements) so clone/sync over https:// works. Idempotent:
# re-running re-extracts a fresh tree.
#
set -euo pipefail

LIBRESSL_VERSION="4.1.0"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor"
SRC_DIR="${VENDOR_DIR}/libressl-${LIBRESSL_VERSION}"
TARBALL="${VENDOR_DIR}/libressl-src.tar.gz"
URL="https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${LIBRESSL_VERSION}.tar.gz"

mkdir -p "${VENDOR_DIR}"

if [[ ! -f "${TARBALL}" ]]; then
  echo "Downloading LibreSSL ${LIBRESSL_VERSION} source..."
  curl -fsSL --max-time 300 -o "${TARBALL}" "${URL}"
fi

echo "Extracting into ${SRC_DIR}..."
rm -rf "${SRC_DIR}"
tar -xzf "${TARBALL}" -C "${VENDOR_DIR}"

echo "Done. LibreSSL source at: ${SRC_DIR}"
