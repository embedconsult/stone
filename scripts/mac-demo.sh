#!/usr/bin/env bash
#
# mac-demo.sh — run the StoneFossil loopback server natively on macOS so the
# Fossil engine + in-process web server can be exercised in a desktop browser
# without any iOS signing/Xcode. This links the SAME StoneFossil.c shim used by
# the iOS app against a macOS build of the vendored Fossil core, then starts the
# server on a repo and opens it in your browser.
#
# Usage:
#   scripts/mac-demo.sh [path-to-repo.fossil]
# If no repo is given, a fresh demo repo is created under build/mac-demo/.
#
set -euo pipefail

FOSSIL_VERSION="2.26"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${REPO_ROOT}/vendor/fossil-src-${FOSSIL_VERSION}"
BRIDGE="${REPO_ROOT}/ios/FossilBridge"
WORK="${REPO_ROOT}/build/mac-demo"

if [[ ! -f "${SRC}/bld/page_index.h" || ! -f "${SRC}/autoconfig.h" ]]; then
  echo "Generated sources missing. Run scripts/gen-fossil-sources.sh first." >&2
  exit 1
fi

mkdir -p "${WORK}/obj"

# --- Flag groups (verbatim from src/main.mk) ----------------------------------
SQLITE_OPTIONS="-DNDEBUG=1 -DSQLITE_DQS=0 -DSQLITE_THREADSAFE=0 \
-DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 \
-DSQLITE_LIKE_DOESNT_MATCH_BLOBS -DSQLITE_OMIT_DECLTYPE -DSQLITE_OMIT_DEPRECATED \
-DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_OMIT_SHARED_CACHE \
-DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_MAX_EXPR_DEPTH=0 \
-DSQLITE_ENABLE_LOCKING_STYLE=0 -DSQLITE_DEFAULT_FILE_FORMAT=4 \
-DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_EXPLAIN_COMMENTS \
-DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_MATH_FUNCTIONS \
-DSQLITE_ENABLE_STMTVTAB -DSQLITE_HAVE_ZLIB -DSQLITE_ENABLE_DBPAGE_VTAB \
-DSQLITE_TRUSTED_SCHEMA=0 -DHAVE_USLEEP"
SHELL_OPTIONS="${SQLITE_OPTIONS} -Dmain=sqlite3_shell -DSQLITE_SHELL_IS_UTF8=1 \
-DSQLITE_OMIT_LOAD_EXTENSION=1 -DUSE_SYSTEM_SQLITE=0 \
-DSQLITE_SHELL_DBNAME_PROC=sqlcmd_get_dbname -DSQLITE_SHELL_INIT_PROC=sqlcmd_init_proc"
PIKCHR_OPTIONS="-DPIKCHR_TOKEN_LIMIT=10000"
# -Dexit=stone_exit: redirect Fossil's per-request exit() into the shim's
# longjmp so the in-process server survives requests (see StoneFossil.c).
FOSSIL_OPTIONS="-DFOSSIL_ENABLE_JSON -DFOSSIL_DYNAMIC_BUILD=1 -DHAVE_AUTOCONFIG_H -Dexit=stone_exit"
INCLUDES="-I${SRC} -I${SRC}/src -I${SRC}/extsrc -I${SRC}/bld -I${BRIDGE}"
COMMON="-g -Os -fno-common -Wno-everything ${INCLUDES}"

CC="$(xcrun --find clang)"
SYSROOT="$(xcrun --show-sdk-path)"
COMMON="-isysroot ${SYSROOT} ${COMMON}"
OBJ="${WORK}/obj"

# Only rebuild objects if the archive is missing (keeps reruns fast).
if [[ ! -f "${WORK}/libfossil_mac.a" ]]; then
  echo "Compiling Fossil core for macOS (first run, ~1 min)..."
  ${CC} ${COMMON} ${SQLITE_OPTIONS} -c "${SRC}/extsrc/sqlite3.c"           -o "${OBJ}/sqlite3.o"
  ${CC} ${COMMON} ${SHELL_OPTIONS}  -c "${SRC}/extsrc/shell.c"             -o "${OBJ}/shell.o"
  ${CC} ${COMMON} ${PIKCHR_OPTIONS} -c "${SRC}/extsrc/pikchr.c"            -o "${OBJ}/pikchr.o"
  ${CC} ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/extsrc/cson_amalgamation.c" -o "${OBJ}/cson.o"
  ${CC} ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/extsrc/linenoise.c"         -o "${OBJ}/linenoise.o"
  ${CC} ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/src/th.c"      -o "${OBJ}/th.o"
  ${CC} ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/src/th_lang.c" -o "${OBJ}/th_lang.o"
  ${CC} ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/src/th_tcl.c"  -o "${OBJ}/th_tcl.o"
  for f in "${SRC}"/bld/*_.c; do
    extra=""
    [[ "$(basename "${f}")" == "main_.c" ]] && extra="-Dmain=fossil_cli_main"
    ${CC} ${COMMON} ${FOSSIL_OPTIONS} ${extra} -c "${f}" -o "${OBJ}/$(basename "${f}" .c).o"
  done
  ${CC} ${COMMON} ${FOSSIL_OPTIONS} -c "${BRIDGE}/StoneFossil.c" -o "${OBJ}/StoneFossil.o"
  ar rcs "${WORK}/libfossil_mac.a" "${OBJ}"/*.o
fi

echo "Linking demo driver..."
${CC} ${COMMON} ${FOSSIL_OPTIONS} -c "${REPO_ROOT}/scripts/mac-demo-driver.c" -o "${OBJ}/driver.o"
${CC} -isysroot "${SYSROOT}" -o "${WORK}/stone-demo" \
  "${OBJ}/driver.o" "${WORK}/libfossil_mac.a" -lz -liconv

# --- Prepare a repo -----------------------------------------------------------
REPO="${1:-}"
if [[ -z "${REPO}" ]]; then
  REPO="${WORK}/demo.fossil"
  if [[ ! -f "${REPO}" ]]; then
    echo "Creating demo repo at ${REPO}..."
    "${SRC}/fossil" init "${REPO}" >/dev/null
  fi
fi

echo
echo "Starting StoneFossil loopback server on ${REPO}"
echo "(Ctrl-C to stop.)"
exec "${WORK}/stone-demo" "${REPO}"
