#!/usr/bin/env bash
#
# linux-chat-poll-test.sh — check the Fossil behavior Stone's RemoteWake
# relies on (ios/Stone/Services/RemoteWake.swift, docs/chat-poll-wake.md):
#
#   1. /chat-poll without a same-origin Referer answers no JSON.
#   2. name=-1 answers at once with the newest row alone.
#   3. A waiting request is answered by a local timeline event.
#   4. A waiting request is answered by events arriving by push.
#   5. A request naming an older row answers at once with what it missed.
#   6. A login without the chat capability (C) gets a 200 with an isError row.
#   And: the first /chat-poll with a Referer makes the chat table; events
#   before it add no row.
#
# Needs fossil (or FOSSIL=/path/to/fossil) and curl. Uses a new scratch
# repository and a local server on a free port; leaves nothing behind.
#
# Usage: bash scripts/linux-chat-poll-test.sh

set -euo pipefail

FOSSIL=${FOSSIL:-fossil}
export FOSSIL_USER=admin   # who local commands write as
command -v "$FOSSIL" >/dev/null || { echo "SKIP: no fossil"; exit 0; }
command -v curl >/dev/null || { echo "SKIP: no curl"; exit 0; }

work=$(mktemp -d)
server_pid=
cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
cd "$work"

fail=0
check() { # name, condition result (0 = pass)
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi
}

"$FOSSIL" new --admin-user admin repo.fossil >/dev/null
"$FOSSIL" settings chat-timeline-user TIMELINE -R repo.fossil
"$FOSSIL" settings chat-poll-timeout 10 -R repo.fossil
"$FOSSIL" user new phone phone@example.org pw -R repo.fossil >/dev/null
"$FOSSIL" user capabilities phone ghjorzi2345C -R repo.fossil >/dev/null
"$FOSSIL" user new nochat nochat@example.org pw -R repo.fossil >/dev/null
"$FOSSIL" user capabilities nochat ghjorz -R repo.fossil >/dev/null

port=$(( 20000 + RANDOM % 20000 ))
"$FOSSIL" server repo.fossil --port "$port" --localhost >server.log 2>&1 &
server_pid=$!
base="http://127.0.0.1:$port"
for _ in $(seq 50); do curl -s -o /dev/null "$base/" && break; sleep 0.1; done

login() { # user jar
  curl -s -c "$2" -o /dev/null -d "u=$1&p=pw" "$base/login"
}
login phone phone.jar
login nochat nochat.jar

poll() { # jar name max-seconds [referer]
  curl -s -m "$3" -b "$1" ${4:+-H "Referer: $4"} "$base/chat-poll?name=$2" || true
}
ids() { grep -oE '"msgid":[0-9]+' | cut -d: -f2 | tr '\n' ' '; }

# 1. No Referer: an HTML error page, not JSON.
out=$(poll phone.jar 0 5)
case "$out" in '{"msgs"'*) r=1 ;; *) r=0 ;; esac
check "no Referer answers no JSON" $r

# Until a /chat-poll with a Referer has made the chat table, events add no
# rows: Fossil relays a timeline event only when the table exists.
"$FOSSIL" tag add before-table trunk -R repo.fossil >/dev/null
poll phone.jar 0 1 "$base/chat" >/dev/null
rows=$("$FOSSIL" sql -R repo.fossil "SELECT count(*) FROM chat" 2>/dev/null || echo none)
[ "$rows" = 0 ]; check "the first /chat-poll makes the chat table; earlier events add no row ($rows)" $?

# Two events so the chat table has rows.
"$FOSSIL" tag add first-tag trunk -R repo.fossil >/dev/null
"$FOSSIL" tag add second-tag trunk -R repo.fossil >/dev/null
newest=$("$FOSSIL" sql -R repo.fossil "SELECT max(msgid) FROM chat")

# 2. name=-1: the newest row alone, at once.
got=$(poll phone.jar -1 5 "$base/chat" | ids)
[ "$got" = "$newest " ]; check "name=-1 answers with the newest row alone ($got)" $?

# 3. A local event answers a waiting request.
poll phone.jar "$newest" 8 "$base/chat" >wait3.out &
waiter=$!
sleep 1
"$FOSSIL" tag add third-tag trunk -R repo.fossil >/dev/null
wait "$waiter"
[ -n "$(ids <wait3.out)" ]; check "a local event answers a waiting request" $?
newest=$("$FOSSIL" sql -R repo.fossil "SELECT max(msgid) FROM chat")

# 4. Events arriving by push answer a waiting request.
"$FOSSIL" clone "http://phone:pw@127.0.0.1:$port/" clone.fossil >/dev/null 2>&1
"$FOSSIL" ticket add title "pushed ticket" status Open -R clone.fossil >/dev/null 2>&1
echo "text" >page.txt
"$FOSSIL" wiki create "Pushed page" page.txt -R clone.fossil >/dev/null 2>&1
poll phone.jar "$newest" 8 "$base/chat" >wait4.out &
waiter=$!
sleep 1
"$FOSSIL" push "http://phone:pw@127.0.0.1:$port/" -R clone.fossil >/dev/null 2>&1
wait "$waiter"
got=$(ids <wait4.out)
[ "$(echo $got | wc -w)" -ge 2 ]; check "a push answers a waiting request, its events in one answer ($got)" $?

# 5. Naming an older row answers at once with what was missed.
start=$(date +%s)
got=$(poll phone.jar "$newest" 8 "$base/chat" | ids)
took=$(( $(date +%s) - start ))
[ -n "$got" ] && [ "$took" -le 2 ]; check "an older row answers at once with what was missed ($got)" $?

# 6. No chat capability: 200 with an isError row.
code=$(curl -s -m 5 -b nochat.jar -H "Referer: $base/chat" -o nochat.out -w '%{http_code}' "$base/chat-poll?name=0" || true)
[ "$code" = 200 ] && grep -q '"isError": *true' nochat.out
check "a login without C gets 200 with an isError row" $?

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
