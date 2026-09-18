#!/usr/bin/env bash
#
# linux-ticket-cache-setup.sh -- builds the two repos
# scripts/linux-ticket-cache-driver.c needs for ticket 11018cb484's
# reproduction: repoA with a real "complexity" ticket column and a ticket
# using it, and repoB with the stock schema but the SAME ticket-change
# artifact (simulating one that arrived via sync from a newer schema,
# into a clone whose local table was never rebuilt).
#
# Uses the standalone host `fossil` binary (built as a side effect of
# gen-fossil-sources.sh's ./configure && make) for all of this -- ordinary,
# one-shot CLI commands that exit normally, no embedding needed. The
# driver itself is what exercises the STONE-embedded, repeated-fossil_main
# code path under test.
#
# Usage: scripts/linux-ticket-cache-setup.sh <out-dir>
# Produces <out-dir>/repoA.fossil and <out-dir>/repoB.fossil.
#
set -euo pipefail

FOSSIL_VERSION="2.26"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${REPO_ROOT}/vendor/fossil-src-${FOSSIL_VERSION}"
FOSSIL_CLI="${SRC}/fossil"
OUT="${1:?usage: $0 <out-dir>}"

mkdir -p "${OUT}"
REPO_A="${OUT}/repoA.fossil"
REPO_B="${OUT}/repoB.fossil"
rm -f "${REPO_A}" "${REPO_B}"

# This sandbox has no resolvable OS user identity; the standalone CLI,
# unlike StoneFossil.c's stone_init_env(), doesn't default one on its own.
export USER=stone

"${FOSSIL_CLI}" init "${REPO_A}" >/dev/null

"${FOSSIL_CLI}" sql -R "${REPO_A}" <<'SQL'
REPLACE INTO config(name,value,mtime) VALUES('ticket-table',
'CREATE TABLE ticket(
  tkt_id INTEGER PRIMARY KEY,
  tkt_uuid TEXT UNIQUE,
  tkt_mtime DATE,
  tkt_ctime DATE,
  type TEXT,
  status TEXT,
  subsystem TEXT,
  priority TEXT,
  severity TEXT,
  foundin TEXT,
  private_contact TEXT,
  resolution TEXT,
  title TEXT,
  comment TEXT,
  complexity TEXT
);
CREATE TABLE ticketchng(
  tkt_id INTEGER REFERENCES ticket,
  tkt_rid INTEGER REFERENCES blob,
  tkt_mtime DATE,
  tkt_user TEXT,
  login TEXT,
  username TEXT,
  mimetype TEXT,
  icomment TEXT
);
CREATE INDEX ticketchng_idx1 ON ticketchng(tkt_id, tkt_mtime);
', strftime('%s','now'));
SQL
"${FOSSIL_CLI}" rebuild "${REPO_A}" >/dev/null

"${FOSSIL_CLI}" ticket add complexity medium title "Repo A ticket" \
  type task status open -R "${REPO_A}" >/dev/null

TKT_UUID="$("${FOSSIL_CLI}" sql -R "${REPO_A}" <<'SQL'
SELECT uuid FROM blob WHERE rid=(SELECT max(rid) FROM blob);
SQL
)"
TKT_UUID="${TKT_UUID//\'/}"
TAG_NAME="$("${FOSSIL_CLI}" sql -R "${REPO_A}" <<'SQL'
SELECT tagname FROM tag WHERE tagname LIKE 'tkt-%' ORDER BY tagid DESC LIMIT 1;
SQL
)"
TAG_NAME="${TAG_NAME//\'/}"

"${FOSSIL_CLI}" init "${REPO_B}" >/dev/null
"${FOSSIL_CLI}" sql -R "${REPO_B}" <<SQL
ATTACH '${REPO_A}' AS a;
INSERT INTO blob(rcvid, size, uuid, content)
  SELECT rcvid, size, uuid, content FROM a.blob WHERE uuid='${TKT_UUID}';
INSERT OR IGNORE INTO tag(tagname)
  SELECT tagname FROM a.tag WHERE tagname='${TAG_NAME}';
INSERT INTO tagxref(tagid, tagtype, srcid, origid, value, mtime, rid)
  SELECT (SELECT tagid FROM tag WHERE tagname='${TAG_NAME}'),
         x.tagtype, x.srcid, x.origid, x.value, x.mtime,
         (SELECT rid FROM blob WHERE uuid='${TKT_UUID}')
  FROM a.tagxref x JOIN a.tag t ON t.tagid=x.tagid
  WHERE t.tagname='${TAG_NAME}'
    AND x.rid=(SELECT rid FROM a.blob WHERE uuid='${TKT_UUID}');
DETACH a;
SQL

echo "repoA (complexity column, real): ${REPO_A}"
echo "repoB (stock schema, same artifact copied in): ${REPO_B}"
