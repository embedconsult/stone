#!/usr/bin/env bash
#
# fetch-fossil.sh — download and unpack the pinned Fossil source tree.
#
# Single purpose: place a clean Fossil 2.26 source tree under vendor/.
#
# Skips re-extracting if ${SRC_DIR} already exists, since the version is
# pinned in the path -- a version bump gets a new SRC_DIR automatically, so an
# existing one is always the right content. This also preserves whatever
# scripts/gen-fossil-sources.sh already generated into it, so a re-run of the
# full pipeline doesn't discard that work. Set FORCE=1 to re-extract anyway.
#
set -euo pipefail

FOSSIL_VERSION="2.26"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor"
SRC_DIR="${VENDOR_DIR}/fossil-src-${FOSSIL_VERSION}"
TARBALL="${VENDOR_DIR}/fossil-src.tar.gz"
URL="https://fossil-scm.org/home/tarball/version-${FOSSIL_VERSION}/fossil-src-${FOSSIL_VERSION}.tar.gz"

if [[ -d "${SRC_DIR}" && -z "${FORCE:-}" ]]; then
  echo "Fossil source already present at ${SRC_DIR}  (set FORCE=1 to re-extract)"
  exit 0
fi

mkdir -p "${VENDOR_DIR}"

if [[ ! -f "${TARBALL}" ]]; then
  echo "Downloading Fossil ${FOSSIL_VERSION} source..."
  curl -fsSL --max-time 120 -o "${TARBALL}" "${URL}"
fi

echo "Extracting into ${SRC_DIR}..."
rm -rf "${SRC_DIR}"
tar -xzf "${TARBALL}" -C "${VENDOR_DIR}"

echo "Done. Fossil source at: ${SRC_DIR}"
