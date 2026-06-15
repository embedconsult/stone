#!/usr/bin/env bash
#
# fetch-cacert.sh — download the Mozilla CA certificate bundle (curl's PEM
# export) into vendor/. iOS ships no OpenSSL-readable trust store, so the app
# bundles this PEM and points SSL_CERT_FILE at it for https clone/sync.
#
# Pinned by date for reproducibility. Idempotent: re-running re-downloads.
#
set -euo pipefail

CACERT_DATE="2025-05-20"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor"
OUT="${VENDOR_DIR}/cacert.pem"
URL="https://curl.se/ca/cacert-${CACERT_DATE}.pem"

mkdir -p "${VENDOR_DIR}"
echo "Downloading Mozilla CA bundle (${CACERT_DATE})..."
curl -fsSL --max-time 120 -o "${OUT}" "${URL}"
echo "Done. CA bundle at: ${OUT}"
