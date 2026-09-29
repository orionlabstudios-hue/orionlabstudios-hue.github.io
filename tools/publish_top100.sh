#!/usr/bin/env bash
# THE PUBLIC TOP 100 (NEXT.md DROP 110 item 1).
#
# Players under 16, and anyone not signed in, read the world ranking from a
# plain file - ranking/top100.json on the studio's GitHub Pages site - so
# nothing about them (no sign-in, no player ID, no score) leaves their phone.
# This script writes that file from Unity Leaderboards. It runs as a scheduled
# GitHub Action in the orionlabstudios-hue.github.io repository
# (publish-ranking.yml, beside this file); FOR-KING-AND-PEP has the steps.
#
# WHAT THE FILE HOLDS, AND WHAT IT DOES NOT: for each board, the place, the
# typed name and the distance of the top 100, the board's total, and the
# distance at a few deeper places (200, 500, 1,000 ...) so a phone can say
# "You'd be about #500". NO PLAYER ID. The names are the ones 16+ players chose
# to show to the world; the game cleans and filters them again when it shows
# them.
#
# FIRST, IT FINISHES DELETIONS. A player who uses "Delete my Cloud Duel data"
# cannot delete their own scores (the game's Leaderboards client has no call
# for it, and deleting the account does not remove them), so the game
# overwrites their scores with -1 and no name just before the account goes
# (RankingService.MarkForDeletionAsync). Every run, this purges each player
# found below zero from every board through the Leaderboards Admin API, and a
# player below zero is never written to the file.
#
# Needs: bash, curl, jq (all on GitHub's ubuntu runners). Reads four secrets
# from the environment: UGS_KEY_ID, UGS_SECRET_KEY (a service account with the
# "Leaderboards Admin" role and nothing else - Admin, not Viewer, because of
# the purge), UGS_PROJECT_ID, UGS_ENV_ID. Writes to $1 (default
# ranking/top100.json). Exits non-zero, writing nothing, on any failure, so a
# bad run never replaces a good file with an empty one.
set -euo pipefail

OUT="${1:-ranking/top100.json}"
: "${UGS_KEY_ID:?}" "${UGS_SECRET_KEY:?}" "${UGS_PROJECT_ID:?}" "${UGS_ENV_ID:?}"

BOARDS=("endless_weekly:weekly" "endless_alltime:alltime")
MARKS=(200 500 1000 2000 5000 10000 20000 50000 100000)

token=$(curl -sf -X POST -u "${UGS_KEY_ID}:${UGS_SECRET_KEY}" \
  "https://services.api.unity.com/auth/v1/token-exchange?projectId=${UGS_PROJECT_ID}&environmentId=${UGS_ENV_ID}" \
  | jq -er '.accessToken')

get() {   # get <leaderboardId> <offset> <limit>
  curl -sf -H "Authorization: Bearer ${token}" \
    "https://leaderboards.services.api.unity.com/v1/projects/${UGS_PROJECT_ID}/leaderboards/$1/scores?offset=$2&limit=$3&includeMetadata=true"
}

purge() {   # purge <playerId>: from every live board (Admin API, 204 expected)
  curl -sf -X DELETE -H "Authorization: Bearer ${token}" \
    "https://services.api.unity.com/leaderboards/v1/projects/${UGS_PROJECT_ID}/environments/${UGS_ENV_ID}/leaderboards/scores/players/$1/purge" > /dev/null
}

# ---- deletions first: every player below zero, read from each board's end ----
purged=0
for pair in "${BOARDS[@]}"; do
  id="${pair%%:*}"
  for round in 1 2 3 4 5 6 7 8 9 10; do
    total=$(get "$id" 0 1 | jq -er '.total // 0')
    [ "$total" -gt 0 ] || break
    from=$(( total > 100 ? total - 100 : 0 ))
    marked=$(get "$id" "$from" 100 | jq -r '.results[] | select(.score < 0) | .playerId')
    [ -n "$marked" ] || break
    for p in $marked; do purge "$p"; purged=$((purged + 1)); done
  done
done
echo "deletions finished: $purged purge call(s)"

tmp=$(mktemp)
echo "{\"updated\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$tmp"

for pair in "${BOARDS[@]}"; do
  id="${pair%%:*}"; key="${pair##*:}"
  page=$(get "$id" 0 100 | jq -c '.results |= map(select(.score >= 0))')
  total=$(echo "$page" | jq -er '.total // (.results | length)')
  # Place, name (from the metadata the game posts: {"n": "<name>"}), whole
  # metres. The player ID is dropped here and never written.
  entries=$(echo "$page" | jq -c '[.results[] | {r: (.rank + 1), n: ((.metadata | if type == "string" then (fromjson? // {}) else (. // {}) end).n // ""), s: (.score | floor)}]')
  marks="[]"
  for m in "${MARKS[@]}"; do
    [ "$m" -le "$total" ] || break
    s=$(get "$id" $((m - 1)) 1 | jq -er '.results[0].score | floor')
    marks=$(echo "$marks" | jq -c --argjson r "$m" --argjson s "$s" '. + [{r: $r, s: $s}]')
  done
  jq --arg k "$key" --argjson t "$total" --argjson e "$entries" --argjson m "$marks" \
    '.[$k] = {total: $t, entries: $e, marks: $m}' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
  echo "$key: $(echo "$entries" | jq length) entries of $total, $(echo "$marks" | jq length) marks"
done

# Nothing in the file may carry a player ID - checked, not assumed.
if grep -q '"playerId"' "$tmp"; then echo "REFUSED: a player ID reached the file" >&2; exit 1; fi
mkdir -p "$(dirname "$OUT")"
# Pretty-printed, so the "updated" time sits on a line of its own and the
# workflow can tell a real change from a new timestamp.
jq . "$tmp" > "$OUT"
rm -f "$tmp"
echo "wrote $OUT ($(wc -c < "$OUT") bytes)"
