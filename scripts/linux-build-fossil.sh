#!/usr/bin/env bash
#
# linux-build-fossil.sh — cross-compile the Fossil C core for arm64-apple-ios on Linux.
#
# Adapted from scripts/build-fossil-xcframework.sh. Differences:
#   - xcrun replaced with direct $CC / $IOS_SDK_PATH references.
#   - libtool -static replaced with ar (GNU or llvm-ar) using object extraction.
#   - sysctl replaced with nproc.
#   - Builds only the ios-arm64 device slice (no simulator); the full
#     xcframework with the simulator slice is assembled on Mac.
#
# Prereqs (run in order):
#   export IOS_SDK_PATH=/path/to/iPhoneOS.sdk
#   scripts/fetch-fossil.sh
#   scripts/gen-fossil-sources.sh        (generates bld/*_.c + autoconfig.h)
#   scripts/linux-build-libressl.sh      (builds LibreSSL for ios-arm64)
#
# Optional overrides:
#   CC=clang-18     (default: clang)
#   AR=llvm-ar-18   (default: llvm-ar if available, else ar)
#
# Output:
#   ios/Frameworks/FossilCore.xcframework/ios-arm64/libfossil.a
#   (device slice only; simulator slice is added by Mac build)
#
set -euo pipefail

FOSSIL_VERSION="2.26"
IOS_MIN="17.0"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${REPO_ROOT}/vendor/fossil-src-${FOSSIL_VERSION}"
BRIDGE="${REPO_ROOT}/ios/FossilBridge"
OUT="${REPO_ROOT}/ios/Frameworks"
WORK="${REPO_ROOT}/build/fossil-ios"
FW="${OUT}/FossilCore.xcframework"

if [[ -z "${FORCE:-}" && -f "${FW}/ios-arm64/libfossil.a" ]]; then
  echo "FossilCore.xcframework (ios-arm64) already built at ${FW}; skipping (set FORCE=1 to rebuild)"
  exit 0
fi

# --- Prereq checks ---

# Default to the sandbox-mounted SDK when no explicit override was given.
if [[ -z "${IOS_SDK_PATH:-}" && -d /opt/iPhoneOS.sdk/usr/include ]]; then
  IOS_SDK_PATH=/opt/iPhoneOS.sdk
fi

if [[ -z "${IOS_SDK_PATH:-}" ]]; then
  echo "Error: IOS_SDK_PATH is not set. Run scripts/linux-preflight.sh for instructions." >&2
  exit 1
fi
if [[ ! -d "${IOS_SDK_PATH}/usr/include" ]]; then
  echo "Error: IOS_SDK_PATH=${IOS_SDK_PATH} does not look like an iOS SDK." >&2
  exit 1
fi
if [[ ! -f "${SRC}/bld/page_index.h" || ! -f "${SRC}/autoconfig.h" ]]; then
  echo "Generated sources missing. Run scripts/gen-fossil-sources.sh first." >&2
  exit 1
fi

SSL_DIR="${REPO_ROOT}/build/libressl-ios"
SSL_INC="${SSL_DIR}/include"
if [[ ! -d "${SSL_INC}/openssl" ]]; then
  echo "LibreSSL not built. Run scripts/linux-build-libressl.sh first." >&2
  exit 1
fi

CC="${CC:-clang}"
if ! command -v "${CC}" &>/dev/null; then
  echo "Error: ${CC} not found. Install clang." >&2
  exit 1
fi

# Prefer llvm-ar for full compatibility with Apple archive format.
AR="${AR:-}"
if [[ -z "${AR}" ]]; then
  if command -v llvm-ar &>/dev/null; then
    AR="llvm-ar"
  elif command -v ar &>/dev/null; then
    AR="ar"
  else
    echo "Error: ar not found. Install binutils or llvm." >&2
    exit 1
  fi
fi

# --- Flag groups (copied verbatim from build-fossil-xcframework.sh) ---

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

# FOSSIL_OMIT_DNS: src/smtp.c's DNS MX-lookup path (unused — Stone never sends
# mail) needs C_IN/T_MX from arpa/nameser_compat.h. The SDK's arpa/nameser.h
# only auto-includes that header when __APPLE__ is undefined, so it never
# fires for an arm64-apple-ios target and the file fails to compile without
# this. Applies to any Apple-target build, not just this Linux cross-compile.
FOSSIL_OPTIONS="-DFOSSIL_ENABLE_JSON -DFOSSIL_ENABLE_SSL -DFOSSIL_DYNAMIC_BUILD=1 \
-DHAVE_AUTOCONFIG_H -DFOSSIL_OMIT_DNS -Dexit=stone_exit"

INCLUDES="-I${SRC} -I${SRC}/src -I${SRC}/extsrc -I${SRC}/bld -I${BRIDGE} -I${SSL_INC}"

# -Wno-everything: Fossil's own sources carry many upstream warnings; suppress
# to keep our signal-to-noise clean. The same flag is used in the Mac script.
# -D__IOS_PROHIBITED=: removes the compile-time "unavailable on iOS" attribute
# from system()/popen(); these paths are never reached via the web-UI flow.
COMMON="-g -Os -fno-common -Wno-everything -D__IOS_PROHIBITED= ${INCLUDES}"

# --- Compilation ---

build_lib() {  # $1=label  $2=triple
  local label="$1" triple="$2"
  local objdir="${WORK}/${label}"
  rm -rf "${objdir}"; mkdir -p "${objdir}"

  local base=("${CC}" -target "${triple}" -isysroot "${IOS_SDK_PATH}")
  echo "==> Compiling Fossil for ${label} (${triple})"

  # Special-flag extsrc units (same order as Mac script).
  "${base[@]}" ${COMMON} ${SQLITE_OPTIONS} -c "${SRC}/extsrc/sqlite3.c"             -o "${objdir}/sqlite3.o"
  "${base[@]}" ${COMMON} ${SHELL_OPTIONS}  -c "${SRC}/extsrc/shell.c"               -o "${objdir}/shell.o"
  "${base[@]}" ${COMMON} ${PIKCHR_OPTIONS} -c "${SRC}/extsrc/pikchr.c"              -o "${objdir}/pikchr.o"
  "${base[@]}" ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/extsrc/cson_amalgamation.c"   -o "${objdir}/cson.o"
  "${base[@]}" ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/extsrc/linenoise.c"           -o "${objdir}/linenoise.o"

  # TH1 scripting engine.
  "${base[@]}" ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/src/th.c"      -o "${objdir}/th.o"
  "${base[@]}" ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/src/th_lang.c" -o "${objdir}/th_lang.o"
  "${base[@]}" ${COMMON} ${FOSSIL_OPTIONS} -c "${SRC}/src/th_tcl.c"  -o "${objdir}/th_tcl.o"

  # All translated Fossil application units.
  for f in "${SRC}"/bld/*_.c; do
    local extra=""
    [[ "$(basename "${f}")" == "main_.c" ]] && extra="-Dmain=fossil_cli_main"
    "${base[@]}" ${COMMON} ${FOSSIL_OPTIONS} ${extra} -c "${f}" -o "${objdir}/$(basename "${f}" .c).o"
  done

  # The StoneFossil bridge.
  "${base[@]}" ${COMMON} ${FOSSIL_OPTIONS} -c "${BRIDGE}/StoneFossil.c" -o "${objdir}/StoneFossil.o"

  # Combine Fossil .o files with LibreSSL static archives into a single libfossil.a.
  #
  # ar does not merge .a files directly; extract each archive's objects into a
  # temporary subdirectory first (separate dirs prevent name collisions between
  # libssl.a and libcrypto.a), then pack everything into one archive.
  local ssl_lib="${SSL_DIR}/${label}/lib"
  local tmpdir; tmpdir="$(mktemp -d)"
  mkdir -p "${tmpdir}/ssl" "${tmpdir}/crypto"
  (cd "${tmpdir}/ssl"    && "${AR}" x "${ssl_lib}/libssl.a")
  (cd "${tmpdir}/crypto" && "${AR}" x "${ssl_lib}/libcrypto.a")

  rm -f "${objdir}/libfossil.a"
  "${AR}" rcs "${objdir}/libfossil.a" \
    "${objdir}"/*.o \
    "${tmpdir}/ssl"/*.o \
    "${tmpdir}/crypto"/*.o
  rm -rf "${tmpdir}"
  echo "    -> ${objdir}/libfossil.a (incl. LibreSSL)"
}

build_lib "ios-arm64" "arm64-apple-ios${IOS_MIN}"

# --- xcframework layout (device slice only) ---
#
# Writes the ios-arm64 slice in the same directory structure the Mac script
# produces. When the Mac build runs later it will add ios-arm64-simulator and
# rewrite Info.plist. For Linux CI purposes the device slice alone confirms the
# C code compiles cleanly.

rm -rf "${FW}"
mkdir -p "${FW}/ios-arm64"
cp "${WORK}/ios-arm64/libfossil.a" "${FW}/ios-arm64/libfossil.a"

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
  </array>
  <key>CFBundlePackageType</key><string>XFWK</string>
  <key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
PLIST

echo "Built ${FW}  (ios-arm64 device slice)"
echo "Run scripts/build-fossil-xcframework.sh on Mac to add the simulator slice."
