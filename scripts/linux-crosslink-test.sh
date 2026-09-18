#!/usr/bin/env bash
#
# linux-crosslink-test.sh -- reproduces ticket 3a4b6c6bb8 (SIGABRT in
# manifest_crosslink_begin on the phone's second sync of a session) on
# Linux, without needing an iOS device or a live remote server.
#
# Linux counterpart to scripts/mac-demo.sh: compiles the same StoneFossil.c
# shim the iOS app embeds against a native Linux build of the vendored
# Fossil core (same source tree, same -Dexit=stone_exit embedding flags),
# then runs scripts/linux-crosslink-test-driver.c, which drives it through
# the exact reentry sequence that crashed: a manifest crosslink pass left
# dangling by an aborted invocation, followed by a normal invocation that
# also needs to crosslink. See that driver's own comments for why each step
# is there.
#
# Usage:
#   scripts/linux-crosslink-test.sh
#
# Exit 0 (and prints PASS) only if both post-leak fossil_main() invocations
# complete without aborting the process.
#
set -euo pipefail

FOSSIL_VERSION="2.26"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${REPO_ROOT}/vendor/fossil-src-${FOSSIL_VERSION}"
BRIDGE="${REPO_ROOT}/ios/FossilBridge"
WORK="${REPO_ROOT}/build/linux-crosslink-test"

if [[ ! -f "${SRC}/bld/page_index.h" || ! -f "${SRC}/autoconfig.h" ]]; then
  echo "Generated sources missing. Run scripts/gen-fossil-sources.sh first." >&2
  exit 1
fi
if ! grep -q "STONE:" "${SRC}/src/cgi.c"; then
  echo "scripts/fossil-inprocess.patch not applied to ${SRC}." >&2
  echo "Run scripts/gen-fossil-sources.sh (it applies the patch) first." >&2
  exit 1
fi

rm -rf "${WORK}"
mkdir -p "${WORK}/obj" "${WORK}/run"

# --- Flag groups (same as scripts/mac-demo.sh, verbatim from src/main.mk,
# minus the macOS-only -isysroot bits) -----------------------------------
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
# longjmp so the in-process server survives requests (see StoneFossil.c) --
# the same flag the real iOS build uses, so this test exercises the actual
# embedding mechanism, not a stand-in for it.
FOSSIL_OPTIONS="-DFOSSIL_ENABLE_JSON -DFOSSIL_DYNAMIC_BUILD=1 -DHAVE_AUTOCONFIG_H -Dexit=stone_exit"
INCLUDES="-I${SRC} -I${SRC}/src -I${SRC}/extsrc -I${SRC}/bld -I${BRIDGE}"
COMMON="-g -Os -fno-common -w ${INCLUDES}"

CC="${CC:-clang}"
OBJ="${WORK}/obj"

echo "Compiling Fossil core for Linux (patched, ~1 min)..."
${CC} ${COMMON} ${SQLITE_OPTIONS} -c "${SRC}/extsrc/sqlite3.c"           -o "${OBJ}/sqlite3.o"
${CC} ${COMMON} ${SHELL_OPTIONS}  -c "${SRC}/extsrc/shell.c"             -o "${OBJ}/shell.o"
${CC} ${COMMON} ${PIKCHR_OPTIONS} -c "${SRC}/extsrc/pikchr.c"            -o "${OBJ}/pikchr.o"
${CC} ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/extsrc/cson_amalgamation.c" -o "${OBJ}/cson.o"
${CC} ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/extsrc/linenoise.c"        -o "${OBJ}/linenoise.o"
${CC} ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/src/th.c"      -o "${OBJ}/th.o"
${CC} ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/src/th_lang.c" -o "${OBJ}/th_lang.o"
${CC} ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/src/th_tcl.c"  -o "${OBJ}/th_tcl.o"
for f in "${SRC}"/bld/*_.c; do
  extra=""
  [[ "$(basename "${f}")" == "main_.c" ]] && extra="-Dmain=fossil_cli_main"
  ${CC} ${COMMON} ${FOSSIL_OPTIONS} ${extra} -c "${f}" -o "${OBJ}/$(basename "${f}" .c).o"
done
${CC} ${COMMON} ${FOSSIL_OPTIONS} -c "${BRIDGE}/StoneFossil.c" -o "${OBJ}/StoneFossil.o"
ar rcs "${WORK}/libfossil_linux.a" "${OBJ}"/*.o

echo "Linking crosslink-test driver..."
${CC} ${COMMON} ${FOSSIL_OPTIONS} -c "${REPO_ROOT}/scripts/linux-crosslink-test-driver.c" -o "${OBJ}/driver.o"
${CC} -o "${WORK}/crosslink-test" "${OBJ}/driver.o" "${WORK}/libfossil_linux.a" -lz -ldl -lpthread -lm

echo "Running..."
"${WORK}/crosslink-test" "${WORK}/run"
