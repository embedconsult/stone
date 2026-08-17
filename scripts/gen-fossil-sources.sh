#!/usr/bin/env bash
#
# gen-fossil-sources.sh — run Fossil's own configure + code generators on the
# host (macOS) to produce everything the iOS build consumes:
#   - bld/*_.c            translated application sources
#   - bld/*.h             makeheaders output
#   - bld/VERSION.h, bld/page_index.h, bld/builtin_data.h
#   - autoconfig.h        (host feature detection; the iOS build reuses it)
#
# We configure WITHOUT OpenSSL/Tcl/FuseFS so the generated tree is
# self-contained. `make` also builds a host `fossil` binary as a side effect,
# which is a handy sanity check that the source tree is coherent.
#
# Skips configure+make entirely if the expected output already exists (set
# FORCE=1 to force regeneration) -- this is the slow step (autosetup's
# feature-probing), and scripts/fetch-fossil.sh no longer wipes ${SRC_DIR} on
# every run, so a prior run's output survives to make this skip meaningful.
#
set -euo pipefail

FOSSIL_VERSION="2.26"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="${REPO_ROOT}/vendor/fossil-src-${FOSSIL_VERSION}"
PATCH="${REPO_ROOT}/scripts/fossil-inprocess.patch"

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "Fossil source not found. Run scripts/fetch-fossil.sh first." >&2
  exit 1
fi

cd "${SRC_DIR}"

if [[ -z "${FORCE:-}" ]]; then
  ALREADY_GENERATED=true
  for required in bld/VERSION.h bld/page_index.h bld/builtin_data.h autoconfig.h; do
    [[ -f "${required}" ]] || ALREADY_GENERATED=false
  done
  # Only glob bld/*_.c once the required headers confirm bld/ exists -- on a
  # fresh checkout bld/ isn't there yet, and `ls` on a non-matching glob exits
  # non-zero, which combined with pipefail+errexit would otherwise abort the
  # whole script here with no output at all.
  EXISTING_COUNT=0
  if [[ "${ALREADY_GENERATED}" == "true" ]]; then
    EXISTING_COUNT="$(ls bld/*_.c 2>/dev/null | wc -l | tr -d ' ')" || true
  fi
  if [[ "${ALREADY_GENERATED}" == "true" && "${EXISTING_COUNT}" -ge 100 ]]; then
    echo "Fossil sources already generated (${EXISTING_COUNT} translated sources); skipping (set FORCE=1 to regenerate)."
    exit 0
  fi
fi

# Apply the in-process serving patch (idempotent). Fossil is process-per-request
# upstream; this patch resets request-scoped file-scope statics so fossil_main()
# can be called repeatedly in the long-lived embedded server. See the patch
# header and ios/FossilBridge/StoneFossil.c for the full rationale.
if [[ -f "${PATCH}" ]]; then
  # Idempotency by content marker, not by patch(1) exit codes: in non-interactive
  # mode patch auto-flips direction (answering its "[y]" prompts), so a dry-run
  # "succeeds" in BOTH directions and cannot tell applied from pristine. The
  # STONE marker the patch introduces is an unambiguous signal.
  if grep -q "STONE:" src/cgi.c; then
    echo "In-process serving patch already applied; skipping."
  elif patch -p1 --forward <"${PATCH}"; then
    echo "Applied in-process serving patch."
  else
    echo "ERROR: scripts/fossil-inprocess.patch does not apply cleanly." >&2
    echo "       (Did the pinned Fossil version change? Re-fetch and re-roll the patch.)" >&2
    exit 1
  fi
fi

echo "Configuring Fossil (host, no SSL/Tcl/FuseFS)..."
./configure --with-openssl=none --disable-fusefs >/dev/null

echo "Generating sources + autoconfig.h (also builds a host fossil binary)..."
make >/dev/null

GEN_COUNT="$(ls bld/*_.c 2>/dev/null | wc -l | tr -d ' ')" || true
for required in bld/VERSION.h bld/page_index.h bld/builtin_data.h autoconfig.h; do
  if [[ ! -f "${required}" ]]; then
    echo "ERROR: expected generated file missing: ${required}" >&2
    exit 1
  fi
done
if [[ "${GEN_COUNT}" -lt 100 ]]; then
  echo "ERROR: only ${GEN_COUNT} translated sources generated (expected ~148)." >&2
  exit 1
fi

echo "OK: ${GEN_COUNT} translated sources + headers + autoconfig.h ready in ${SRC_DIR}"
