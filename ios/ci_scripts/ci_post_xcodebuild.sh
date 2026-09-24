#!/bin/sh
#
# ci_post_xcodebuild.sh -- reports Xcode Cloud build failures to the stone
# trunk-ops forum thread automatically, so a red build doesn't sit behind an
# App Store Connect login until the maintainer notices and pastes the error
# text by hand.
#
# Xcode Cloud runs this after every xcodebuild invocation, success or
# failure (CI_XCODEBUILD_EXIT_CODE is set either way). On success this does
# nothing: the git commit status ("Stone | Default") that ticket 60c7babba4's
# ollama poller already reads anonymously is enough signal for a green
# build. On failure it extracts the compiler error lines and posts one reply
# to the trunk-ops thread (fpid 10e283f93f6f08b6b0f4565691909f0043a9b1d5b26
# 43da9fc18efddb5e605b5), using an ordinary Fossil forum login and Fossil's
# own web reply form (the app itself no longer posts this way):
# POST /login (u/p, no CSRF -- named-user login is anonymous-only there) ->
# GET /forumedit?fpid=...&reply=1 (scrape the csrf token) -> POST /forume2
# (csrf, fpid, reply=1 as a mode flag, content, submit=Submit), checking the
# response body for a redisplayed "Enter Reply:" form since Fossil answers a
# rejected post with HTTP 200, not an error status. A post on that thread
# starts a trunk-ops turn on its own -- nothing else needs to relay it.
#
# Needs STONE_FORUM_PASSWORD, an Xcode Cloud environment secret for the
# "xcode-cloud" forum login the maintainer creates with forum-write
# capability. Best-effort throughout: failing to post here must never be
# mistaken for the xcodebuild failure it's reporting on, so nothing below
# uses `set -e` and every exit is 0.

FOSSIL_BASE="${STONE_FORUM_BASE:-https://ollama.openbeagle.org/stone}"
FORUM_USER="xcode-cloud"
TRUNK_OPS_FPID="10e283f93f6f08b6b0f4565691909f0043a9b1d5b2643da9fc18efddb5e605b5"
ERROR_PATTERN='[[:alnum:]_./+-]+:[0-9]+(:[0-9]+)?: error:.*'
MAX_ERROR_LINES=20

log() { echo "ci_post_xcodebuild.sh: $*" >&2; }

# Nothing to report on a green build.
[ "${CI_XCODEBUILD_EXIT_CODE:-0}" != "0" ] || exit 0

if [ -z "${STONE_FORUM_PASSWORD:-}" ]; then
  log "build failed but STONE_FORUM_PASSWORD is not set -- cannot report to trunk-ops"
  exit 0
fi

# Pull "path:line: error: message" (and "path:line:col: error: message")
# snippets out of whichever source has them: xcresulttool's JSON dump embeds
# the raw diagnostic text as unescaped substrings, and the build log Xcode
# Cloud leaves under CI_DERIVED_DATA_PATH has them as plain lines -- the
# same grep works on both. `grep -a` treats binary logs as text rather than
# refusing them; a strict text log still matches the same way.
extract_error_lines() {
  {
    if [ -n "${CI_RESULT_BUNDLE_PATH:-}" ] && [ -e "${CI_RESULT_BUNDLE_PATH}" ]; then
      xcrun xcresulttool get --format json --path "${CI_RESULT_BUNDLE_PATH}" 2>/dev/null
    fi
    if [ -n "${CI_DERIVED_DATA_PATH:-}" ] && [ -d "${CI_DERIVED_DATA_PATH}" ]; then
      find "${CI_DERIVED_DATA_PATH}" -type f -print0 2>/dev/null | xargs -0 cat 2>/dev/null
    fi
  } | grep -Eao "${ERROR_PATTERN}" | awk '!seen[$0]++' | head -n "${MAX_ERROR_LINES}"
}

ERROR_LINES="$(extract_error_lines)"
[ -n "${ERROR_LINES}" ] || ERROR_LINES='(no "file:line: error:" text found in the result bundle or build log)'

COMMIT="${CI_COMMIT:-unknown commit}"
WORKFLOW="${CI_WORKFLOW:-unknown workflow}"
BUILD_URL="${CI_BUILD_URL:-(no App Store Connect build URL available)}"

BODY="Xcode Cloud build failed for commit ${COMMIT} (workflow: ${WORKFLOW}).

App Store Connect: ${BUILD_URL}

First ${MAX_ERROR_LINES} error lines:
${ERROR_LINES}"

COOKIE_JAR="$(mktemp)"
trap 'rm -f "${COOKIE_JAR}"' EXIT

# 1. Log in as the xcode-cloud forum user. Named-user login needs no CSRF
# token and no captcha -- that path is anonymous-only in Fossil's login.c.
curl -sS -o /dev/null -c "${COOKIE_JAR}" \
  --data-urlencode "u=${FORUM_USER}" \
  --data-urlencode "p=${STONE_FORUM_PASSWORD}" \
  "${FOSSIL_BASE}/login"

if ! grep -q "fossil-" "${COOKIE_JAR}" 2>/dev/null; then
  log "login as ${FORUM_USER} did not set a fossil session cookie -- not posting"
  exit 0
fi

# 2. Scrape the CSRF token off the reply editor page.
EDITOR_HTML="$(curl -sS -b "${COOKIE_JAR}" -c "${COOKIE_JAR}" \
  "${FOSSIL_BASE}/forumedit?fpid=${TRUNK_OPS_FPID}&reply=1")"
CSRF="$(printf '%s' "${EDITOR_HTML}" | grep -o 'name="csrf" value="[^"]*"' | head -n1 | sed 's/.*value="\(.*\)"/\1/')"

if [ -z "${CSRF}" ]; then
  log "could not scrape a csrf token from forumedit -- not posting"
  exit 0
fi

# 3. Post the reply. forume2 wants all of these fields; `reply` here is a
# mode flag ("this is a reply"), not the reply body -- that's `content`.
RESULT_HTML="$(curl -sS -b "${COOKIE_JAR}" -c "${COOKIE_JAR}" \
  --data-urlencode "csrf=${CSRF}" \
  --data-urlencode "fpid=${TRUNK_OPS_FPID}" \
  --data-urlencode "reply=1" \
  --data-urlencode "content=${BODY}" \
  --data-urlencode "submit=Submit" \
  "${FOSSIL_BASE}/forume2")"

# On success Fossil redirects to /forumpost/<uuid>, which curl -sS follows
# silently; on a silent csrf/same-origin/permission rejection it redisplays
# this same "Enter Reply" form instead, still as HTTP 200 -- status code
# alone can't tell these apart, so check the body.
if printf '%s' "${RESULT_HTML}" | grep -q "Enter Reply:"; then
  log "forume2 redisplayed the reply form instead of confirming -- post rejected (csrf/same-origin/permission)"
  exit 0
fi

log "posted build failure to trunk-ops thread ${TRUNK_OPS_FPID}"
exit 0
