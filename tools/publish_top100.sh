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

# EVERY REQUEST SAYS WHAT FAILED (NEXT.md DROP 135). Runs 2 and 3 died with
# nothing but "exit code 22" (curl -f on an HTTP 4xx/5xx) and no way to tell
# which request. call <step> <curl args...>: the response body goes to a file,
# the status is checked here, and on a failure the step, the HTTP status and
# the first 300 characters of the reply are printed - never a request header,
# never the key, never a token (a failed reply carries an error, not a token;
# and GitHub masks every secret's value in the log regardless). Passing server
# errors are retried three times. On success it prints the body to stdout.
BODY=$(mktemp)
call() {
  local step="$1"; shift
  local code
  code=$(curl -sS -o "$BODY" -w '%{http_code}' --retry 3 --retry-all-errors --retry-delay 2 "$@") || code="${code:-000}"
  if [ "${code:0:1}" != "2" ]; then
    echo "FAILED: $step - HTTP $code - $(head -c 300 "$BODY" | tr '\n' ' ')" >&2
    return 22
  fi
  cat "$BODY"
}

# THE EMPTY BODY IS THE FIX FOR RUNS 2 AND 3 (29 Sep). A bare "-X POST" sends
# no Content-Length, and Unity's front end now refuses that before it even
# reads the credentials: measured from King's PC with dummy credentials, the
# bare POST answers HTTP 411 "POST requests require a Content-length header",
# the same POST with -d '' answers HTTP 401 "Authentication failed" - it gets
# through to the login check. This is the job's first request, which is why
# it failed in 5 seconds with curl's exit 22.
token=$(call "token exchange" -X POST -d '' -u "${UGS_KEY_ID}:${UGS_SECRET_KEY}" \
  "https://services.api.unity.com/auth/v1/token-exchange?projectId=${UGS_PROJECT_ID}&environmentId=${UGS_ENV_ID}" \
  | jq -er '.accessToken')

get() {   # get <leaderboardId> <offset> <limit>
  call "scores $1 offset $2" -H "Authorization: Bearer ${token}" \
    "https://leaderboards.services.api.unity.com/v1/projects/${UGS_PROJECT_ID}/leaderboards/$1/scores?offset=$2&limit=$3&includeMetadata=true"
}

# THE PURGE IS AN ADMIN API CALL, AND THE ADMIN API TAKES THE SERVICE ACCOUNT
# ITSELF (HTTP Basic, key id : secret) - Unity's own example for this endpoint
# ("Delete Player Score From All Live Leaderboards", scope
# live_ops.leaderboards.scores.delete). It used to send the Bearer token from
# the token exchange, which is proven only for the game-side scores reads; the
# purge had never run (run 1's boards were empty) until the -1 test entry of
# 29 Sep. Switched to the documented form before it gets the chance to fail.
# A player already gone (404) is not a failure: that is the state we want.
purge() {   # purge <playerId>: from every live board (Admin API, 204 expected)
  local code
  code=$(curl -sS -o "$BODY" -w '%{http_code}' --retry 3 --retry-all-errors --retry-delay 2 \
    -X DELETE -u "${UGS_KEY_ID}:${UGS_SECRET_KEY}" \
    "https://services.api.unity.com/leaderboards/v1/projects/${UGS_PROJECT_ID}/environments/${UGS_ENV_ID}/leaderboards/scores/players/$1/purge") || code="${code:-000}"
  case "$code" in
    2*) return 0 ;;
    404) echo "purge: player already has no live scores (HTTP 404) - nothing to do" ;;
    *) echo "FAILED: purge - HTTP $code - $(head -c 300 "$BODY" | tr '\n' ' ')" >&2; return 22 ;;
  esac
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
rm -f "$tmp" "$BODY"
echo "wrote $OUT ($(wc -c < "$OUT") bytes)"
