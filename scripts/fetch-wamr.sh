#!/usr/bin/env bash
#
# fetch-wamr.sh — download and unpack the pinned WAMR source tree.
#
# WAMR (WebAssembly Micro Runtime, Bytecode Alliance) runs Stone's
# WebAssembly plugins (ios/FossilBridge/StoneWasm.h). Only the sources in
# scripts/wamr-sources.txt are built. The tarball's SHA-256 is checked.
#
set -euo pipefail

WAMR_VERSION="2.4.4"
SHA256="03ad51037f06235577b765ee042a462326d8919300107af4546719c35525b298"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor"
SRC_DIR="${VENDOR_DIR}/wasm-micro-runtime-WAMR-${WAMR_VERSION}"
TARBALL="${VENDOR_DIR}/wamr-src.tar.gz"
URL="https://github.com/bytecodealliance/wasm-micro-runtime/archive/refs/tags/WAMR-${WAMR_VERSION}.tar.gz"

if [[ -d "${SRC_DIR}" && -z "${FORCE:-}" ]]; then
  echo "WAMR source already present at ${SRC_DIR}  (set FORCE=1 to re-extract)"
  exit 0
fi

mkdir -p "${VENDOR_DIR}"
if [[ ! -f "${TARBALL}" ]]; then
  echo "Downloading WAMR ${WAMR_VERSION} source..."
  curl -fsSL --max-time 300 -o "${TARBALL}" "${URL}"
fi

GOT="$( (shasum -a 256 "${TARBALL}" 2>/dev/null || sha256sum "${TARBALL}") | awk '{print $1}')"
if [[ "${GOT}" != "${SHA256}" ]]; then
  echo "WAMR tarball SHA-256 is ${GOT}, expected ${SHA256}" >&2
  exit 1
fi

echo "Extracting into ${SRC_DIR}..."
rm -rf "${SRC_DIR}"
tar -xzf "${TARBALL}" -C "${VENDOR_DIR}"
echo "Done. WAMR source at: ${SRC_DIR}"
