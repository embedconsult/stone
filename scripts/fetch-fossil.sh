#!/usr/bin/env bash
#
# fetch-fossil.sh — download and unpack the pinned Fossil source tree.
#
# Single purpose: place a clean Fossil 2.26 source tree under vendor/.
# Idempotent: re-running re-extracts a fresh tree.
#
set -euo pipefail

FOSSIL_VERSION="2.26"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor"
SRC_DIR="${VENDOR_DIR}/fossil-src-${FOSSIL_VERSION}"
TARBALL="${VENDOR_DIR}/fossil-src.tar.gz"
URL="https://fossil-scm.org/home/tarball/version-${FOSSIL_VERSION}/fossil-src-${FOSSIL_VERSION}.tar.gz"

mkdir -p "${VENDOR_DIR}"

if [[ ! -f "${TARBALL}" ]]; then
  echo "Downloading Fossil ${FOSSIL_VERSION} source..."
  curl -fsSL --max-time 120 -o "${TARBALL}" "${URL}"
fi

echo "Extracting into ${SRC_DIR}..."
rm -rf "${SRC_DIR}"
tar -xzf "${TARBALL}" -C "${VENDOR_DIR}"

echo "Done. Fossil source at: ${SRC_DIR}"
