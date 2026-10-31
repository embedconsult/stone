#!/bin/sh
set -eu
out=$1
source_dir=${0%/*}

finish_artifact() {
  set -- $(fossil md5sum "$file")
  printf 'Z %s\n' "$1" >> "$file"
}
artifact_hash() {
  set -- $(fossil sha3sum "$1")
  printf '%s' "$1"
}
current_hash() {
  (cd "$out/checkout" && fossil info current) | while read -r key hash rest; do
    case $key in hash:) printf '%s' "$hash"; break ;; esac
  done
}
forum_post() {
  file=$1 date=$2 title=$3 user=$4 body=$5 root=$6 parent=$7
  printf 'D %s\n' "$date" > "$file"
  if [ -n "$root" ]; then printf 'G %s\n' "$root" >> "$file"; fi
  if [ -n "$title" ]; then printf 'H %s\n' "$title" >> "$file"; fi
  if [ -n "$parent" ]; then printf 'I %s\n' "$parent" >> "$file"; fi
  printf 'N text/x-markdown\nU %s\nW %s\n%s\n' "$user" "${#body}" "$body" >> "$file"
  finish_artifact
}
ticket() {
  file=$1 date=$2 id=$3 title=$4 due=$5
  printf 'D %s\n' "$date" > "$file"
  if [ -n "$due" ]; then printf 'J due %s\n' "$due" >> "$file"; fi
  printf 'J status Open\nJ title %s\nJ type milestone\nK %s\nU agent\n' "$title" "$id" >> "$file"
  finish_artifact
}

mkdir "$out/a-artifacts" "$out/b-artifacts"
forum_post "$out/a-artifacts/first" 2026-10-28T10:00:00 'First\sask' agent 'First ask' '' ''
first=$(artifact_hash "$out/a-artifacts/first")
forum_post "$out/a-artifacts/reply" 2026-10-29T10:00:00 '' stone Answered "$first" "$first"
forum_post "$out/b-artifacts/second" 2026-10-29T11:00:00 'Second\sask' agent 'Second ask' '' ''
second=$(artifact_hash "$out/b-artifacts/second")
ticket "$out/a-artifacts/ticket" 2026-10-28T09:00:00 eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee 'No\sdue\scolumn' ''
ticket "$out/b-artifacts/ticket" 2026-10-29T09:00:00 1111111111111111111111111111111111111111 Demo 2026-11-05

fossil reconstruct "$out/a.fossil" "$out/a-artifacts" >/dev/null
fossil reconstruct "$out/b.fossil" "$out/b-artifacts" >/dev/null
fossil new "$out/empty.fossil" --project-name Empty --date-override 2026-10-20 >/dev/null
for project in a b; do
  case $project in a) name=Alpha ;; b) name=Beta ;; esac
  record="1793405271 'project-name' value '$name'"
  printf 'config /config %s\n%s\n' "$((${#record} + 1))" "$record" > "$out/project-config"
  fossil configuration import "$out/project-config" -R "$out/$project.fossil" >/dev/null
done

schema='CREATE TABLE ticket(
  tkt_id INTEGER PRIMARY KEY,
  tkt_uuid TEXT UNIQUE,
  tkt_mtime DATE,
  tkt_ctime DATE,
  type TEXT,
  status TEXT,
  title TEXT,
  milestone TEXT,
  due TEXT
);
CREATE TABLE ticketchng(
  tkt_id INTEGER REFERENCES ticket,
  tkt_rid INTEGER REFERENCES blob,
  tkt_mtime DATE,
  tkt_user TEXT
)'
record="1793405271 'ticket-table' value '$schema'"
printf 'config /config %s\n%s\n' "$((${#record} + 1))" "$record" > "$out/ticket-config"
fossil configuration import "$out/ticket-config" -R "$out/b.fossil" >/dev/null
fossil rebuild -R "$out/b.fossil" >/dev/null

(cd "$out" && fossil open a.fossil --empty --workdir checkout >/dev/null)
printf 'raw\n' > "$out/checkout/milestone.txt"
(cd "$out/checkout" && fossil add milestone.txt >/dev/null && fossil commit -m 'Raw milestone' --date-override 2026-10-27T10:00:00 --user-override agent --nosync >/dev/null)
raw=$(current_hash)
printf 'symbolic\n' > "$out/checkout/milestone.txt"
(cd "$out/checkout" && fossil commit -m 'Symbolic milestone' --date-override 2026-10-28T10:00:00 --user-override agent --nosync >/dev/null)
symbolic=$(current_hash)

fossil tag add --raw --date-override 2026-10-28T10:00:00 asks "$first" stone -R "$out/a.fossil" >/dev/null
fossil tag add --raw --date-override 2026-10-27T10:00:00 milestone "$raw" -R "$out/a.fossil" >/dev/null
fossil tag add --date-override 2026-10-28T10:00:00 milestone "$symbolic" -R "$out/a.fossil" >/dev/null
fossil tag add --raw --date-override 2026-10-29T11:00:00 asks "$second" stone -R "$out/b.fossil" >/dev/null

for card in "$source_dir"/cards/*.json; do
  case $card in *.schema.json) continue ;; esac
  name=${card##*/}
  name=${name%.json}
  fossil wiki create "card/$name" "$card" -R "$out/a.fossil" --mimetype plain >/dev/null
done
