#!/usr/bin/env bash
#
# build-fossil-xcframework.sh — compile the vendored Fossil core (plus the
# StoneFossil bridge) into FossilCore.xcframework for iOS device + simulator.
#
# Why an xcframework instead of dumping 150 C files into the Xcode target:
#   - Fossil's generated command dispatch table references EVERY translation
#     unit, so we must mirror Fossil's exact object set, each compiled with its
#     own flag group (sqlite3.c, shell.c and pikchr.c each need different -D's).
#   - Reusing Fossil's own flag groups here (copied verbatim from src/main.mk)
#     keeps us faithful to upstream and prevents drift.
#   - The app target then just links one artifact: clean, loosely coupled.
#
# Prereqs (run once, in order):
#   scripts/fetch-fossil.sh           # vendor the pinned source
#   scripts/gen-fossil-sources.sh     # configure + generate bld/ + autoconfig.h
#
set -euo pipefail

FOSSIL_VERSION="2.26"
IOS_MIN="17.0"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${REPO_ROOT}/vendor/fossil-src-${FOSSIL_VERSION}"
BRIDGE="${REPO_ROOT}/ios/FossilBridge"
OUT="${REPO_ROOT}/ios/Frameworks"
WORK="${REPO_ROOT}/build/fossil-ios"

if [[ ! -f "${SRC}/bld/page_index.h" || ! -f "${SRC}/autoconfig.h" ]]; then
  echo "Generated sources missing. Run scripts/gen-fossil-sources.sh first." >&2
  exit 1
fi

# --- Flag groups copied verbatim from src/main.mk -----------------------------

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
-DSQLITE_SHELL_DBNAME_PROC=sqlcmd_get_dbname \
-DSQLITE_SHELL_INIT_PROC=sqlcmd_init_proc"

PIKCHR_OPTIONS="-DPIKCHR_TOKEN_LIMIT=10000"

# Flags Fossil uses for its own translation units (from the make log).
# -Dexit=stone_exit redirects Fossil's per-request process teardown into the
# shim's longjmp (see ios/FossilBridge/StoneFossil.c) so the in-process server
# survives each request. Applied to Fossil units only, never to sqlite/shell.
FOSSIL_OPTIONS="-DFOSSIL_ENABLE_JSON -DFOSSIL_DYNAMIC_BUILD=1 -DHAVE_AUTOCONFIG_H -Dexit=stone_exit"
INCLUDES="-I${SRC} -I${SRC}/src -I${SRC}/extsrc -I${SRC}/bld -I${BRIDGE}"
# -D__IOS_PROHIBITED= drops the compile-time "unavailable on iOS" attribute from
# system()/popen() etc. The symbols exist at runtime; these process-spawning
# code paths (external diff/editor) are never reached via the web-UI flow.
# (Acceptable for personal/sideload builds; would need revisiting for App Store.)
COMMON="-g -Os -fno-common -Wno-everything -D__IOS_PROHIBITED= ${INCLUDES}"

# --- Per-arch compilation -----------------------------------------------------

build_lib() {            # $1 = label  $2 = sdk  $3 = clang target triple
  local label="$1" sdk="$2" triple="$3"
  local sysroot; sysroot="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  local cc; cc="$(xcrun --sdk "${sdk}" --find clang)"
  local objdir="${WORK}/${label}"
  rm -rf "${objdir}"; mkdir -p "${objdir}"

  local base=("${cc}" -target "${triple}" -isysroot "${sysroot}")
  echo "==> Compiling Fossil for ${label} (${triple})"

  # Special-flag extsrc units.
  "${base[@]}" ${COMMON} ${SQLITE_OPTIONS} -c "${SRC}/extsrc/sqlite3.c"          -o "${objdir}/sqlite3.o"
  "${base[@]}" ${COMMON} ${SHELL_OPTIONS}  -c "${SRC}/extsrc/shell.c"            -o "${objdir}/shell.o"
  "${base[@]}" ${COMMON} ${PIKCHR_OPTIONS} -c "${SRC}/extsrc/pikchr.c"           -o "${objdir}/pikchr.o"
  "${base[@]}" ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/extsrc/cson_amalgamation.c" -o "${objdir}/cson.o"
  "${base[@]}" ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/extsrc/linenoise.c"        -o "${objdir}/linenoise.o"

  # TH1 scripting engine (th_tcl is a stub without Tcl).
  "${base[@]}" ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/src/th.c"      -o "${objdir}/th.o"
  "${base[@]}" ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/src/th_lang.c" -o "${objdir}/th_lang.o"
  "${base[@]}" ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/src/th_tcl.c"  -o "${objdir}/th_tcl.o"

  # All translated Fossil application units. main_.c defines the CLI entry
  # point main(); rename it away so it doesn't collide with the app's @main
  # (same -Dmain= technique Fossil uses for the bundled sqlite shell). We call
  # fossil_main() directly, so the renamed CLI wrapper is simply never used.
  for f in "${SRC}"/bld/*_.c; do
    local extra=""
    [[ "$(basename "${f}")" == "main_.c" ]] && extra="-Dmain=fossil_cli_main"
    "${base[@]}" ${COMMON} ${FOSSIL_OPTIONS} ${extra} -c "${f}" -o "${objdir}/$(basename "${f}" .c).o"
  done

  # The StoneFossil bridge.
  "${base[@]}" ${COMMON} ${FOSSIL_OPTIONS} -c "${BRIDGE}/StoneFossil.c" -o "${objdir}/StoneFossil.o"

  rm -f "${objdir}/libfossil.a"
  "$(xcrun --sdk "${sdk}" --find ar)" rcs "${objdir}/libfossil.a" "${objdir}"/*.o
  echo "    -> ${objdir}/libfossil.a"
}

build_lib "ios-arm64"     "iphoneos"        "arm64-apple-ios${IOS_MIN}"
build_lib "ios-arm64-sim" "iphonesimulator" "arm64-apple-ios${IOS_MIN}-simulator"

# --- Assemble the xcframework -------------------------------------------------
#
# Built by hand (instead of `xcodebuild -create-xcframework`) so the script has
# no dependency on the CoreSimulator toolchain — it is just a directory layout
# plus an Info.plist describing each slice.

FW="${OUT}/FossilCore.xcframework"
rm -rf "${FW}"
mkdir -p "${FW}/ios-arm64" "${FW}/ios-arm64-simulator"
cp "${WORK}/ios-arm64/libfossil.a"     "${FW}/ios-arm64/libfossil.a"
cp "${WORK}/ios-arm64-sim/libfossil.a" "${FW}/ios-arm64-simulator/libfossil.a"

cat > "${FW}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AvailableLibraries</key>
  <array>
    <dict>
      <key>LibraryIdentifier</key><string>ios-arm64</string>
      <key>LibraryPath</key><string>libfossil.a</string>
      <key>SupportedArchitectures</key><array><string>arm64</string></array>
      <key>SupportedPlatform</key><string>ios</string>
    </dict>
    <dict>
      <key>LibraryIdentifier</key><string>ios-arm64-simulator</string>
      <key>LibraryPath</key><string>libfossil.a</string>
      <key>SupportedArchitectures</key><array><string>arm64</string></array>
      <key>SupportedPlatform</key><string>ios</string>
      <key>SupportedPlatformVariant</key><string>simulator</string>
    </dict>
  </array>
  <key>CFBundlePackageType</key><string>XFWK</string>
  <key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
PLIST

echo "Built ${FW}"
