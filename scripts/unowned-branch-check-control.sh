#!/usr/bin/env bash
# unowned-branch-check-control.sh — planted-case control for
# unowned-branch-check.mjs. Run it before trusting a "0 unowned".
#
# Builds a throwaway origin + clone in a temp dir and plants:
#   control/unowned-old     old commit, no owner          → MUST be reported
#   control/owned-by-task   old commit, its sha7 is in a REAL pending mem_task
#                                                         → must NOT be reported
#   control/owned-by-cal    old commit, its branch name is in a REAL upcoming
#                           calendar event                → must NOT be reported
#   control/fresh           commit from now               → must NOT be reported
#   control/merged-old      old commit, merged into main  → must NOT be reported
#   control/picked-old      old commit, cherry-picked onto main (new sha, same
#                           patch)                        → must NOT be reported
# Then dismisses control/unowned-old and checks that the run reports
# "0 unowned" with 1 dismissed and exits 0.
#
# The owner task and event go through Sonata's real HTTP API, so the owner
# lookup is tested against the same surface the daily job reads. The task is
# created pending but blockedBy a placeholder id, so the dispatcher
# (TaskDispatcher: blockedBy must be empty) never hands it to a worker. The
# event is scheduled a year out. Both are removed on exit, pass or fail.
#
# Exit: 0 all assertions passed, 1 an assertion failed, 2 setup failed.

set -euo pipefail
SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/unowned-branch-check.mjs"
NODE="${NODE:-/opt/homebrew/bin/node}"
MEM=/Users/evan/memory/bin/mem
API="${SONATA_API:-http://localhost:3211}"
OLD_DATE="$(/bin/date -u -v-3d '+%Y-%m-%dT%H:%M:%SZ')"
CAL_AHEAD_MS=$((365 * 24 * 3600 * 1000))

WORK="$(/usr/bin/mktemp -d -t unowned-branch-control)"
TASK_ID=""
CAL_ID=""
cleanup() {
    [ -n "$TASK_ID" ] && "$MEM" task cancel "$TASK_ID" >/dev/null 2>&1 && echo "cleanup: cancelled task $TASK_ID"
    [ -n "$CAL_ID" ] && /usr/bin/curl -sf --max-time 10 -X DELETE "$API/api/calendar/" \
        -H 'Content-Type: application/json' -d "{\"id\":\"$CAL_ID\"}" >/dev/null && echo "cleanup: deleted calendar event $CAL_ID"
    /bin/rm -rf "${WORK:?}"
}
trap cleanup EXIT

fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

# ---- throwaway origin + clone ----
git init -q --bare -b main "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/repo" 2>/dev/null
R="$WORK/repo"
g() { git -C "$R" -c user.name=control -c user.email=control@example.invalid "$@"; }
old_commit() { GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" g commit -q --allow-empty -m "$1"; }
file_commit() { echo "$2" > "$R/$1"; g add "$1"; GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" g commit -q -m "$3"; }

g checkout -q -b main
file_commit base.txt base "base"
g push -q origin main
git -C "$R" remote set-head origin main

for b in unowned-old owned-by-task owned-by-cal merged-old picked-old; do
    g checkout -q -b "control/$b" main
    file_commit "$b.txt" "$b" "control: $b"
    g push -q origin "control/$b"
done
g checkout -q -b control/fresh main
echo fresh > "$R/fresh.txt"; g add fresh.txt; g commit -q -m "control: fresh"
g push -q origin control/fresh

g checkout -q main
g merge -q --no-ff -m "merge merged-old" control/merged-old
GIT_COMMITTER_DATE="$OLD_DATE" g cherry-pick control/picked-old >/dev/null
g push -q origin main

sha7() { git -C "$R" rev-parse --short=7 "$1"; }
TASK_SHA="$(sha7 control/owned-by-task)"
UNOWNED_SHA="$(sha7 control/unowned-old)"
[ "$(git -C "$R" rev-parse --short=7 main)" != "$(sha7 control/picked-old)" ] || { echo "setup: cherry-pick kept the sha"; exit 2; }

# ---- real owners through the Sonata API ----
resp="$("$MEM" task add "unowned-branch control: land $TASK_SHA (planted, auto-cancelled)" \
    --prompt "Planted by unowned-branch-check-control.sh. Owns commit $TASK_SHA. Never dispatched: blockedBy a placeholder; cancelled on exit." \
    --project sonata --blocked-by "unowned-branch-control-placeholder")"
TASK_ID="$(printf '%s\n' "$resp" | /usr/bin/jq -r '.id // empty')"
[ -n "$TASK_ID" ] || { echo "setup: task create failed: $resp"; exit 2; }
task="$(/usr/bin/curl -sf --max-time 10 "$API/api/task/get?id=$TASK_ID")"
st="$(printf '%s\n' "$task" | /usr/bin/jq -r '.status')"
[ "$st" = "pending" ] || { echo "setup: planted task is '$st', not pending"; exit 2; }
echo "setup: planted pending task $TASK_ID naming $TASK_SHA (blockedBy $(printf '%s\n' "$task" | /usr/bin/jq -c '.blockedBy'))"

now_ms=$(( $(/bin/date +%s) * 1000 ))
cal_body="$(/usr/bin/jq -n --argjson at $((now_ms + CAL_AHEAD_MS)) \
    '{title:"unowned-branch control (planted, auto-deleted)", description:"Owns branch control/owned-by-cal.", prompt:"Planted by unowned-branch-check-control.sh; deleted on exit.", scheduledAt:$at, taskType:"task", enabled:true}')"
resp="$(/usr/bin/curl -sf --max-time 10 -X POST "$API/api/calendar/" -H 'Content-Type: application/json' -d "$cal_body")"
CAL_ID="$(printf '%s\n' "$resp" | /usr/bin/jq -r '.id // empty')"
[ -n "$CAL_ID" ] || { echo "setup: calendar create failed: $resp"; exit 2; }
echo "setup: planted calendar event $CAL_ID naming control/owned-by-cal"

# ---- run 1: the planted unowned branch must be the only report ----
export UNOWNED_BRANCH_REPOS="$R" UNOWNED_BRANCH_DISMISSED="$WORK/dismissed.json"
set +e
out="$("$NODE" "$CHECK" 2>&1)"; rc=$?
set -e
echo "--- run 1 (exit $rc) ---"; printf '%s\n' "$out"; echo "---"
[ "$rc" -eq 0 ] && pass "run 1 exits 0" || fail "run 1 exit $rc"
printf '%s\n' "$out" | /usr/bin/grep -qF "control/unowned-old	$UNOWNED_SHA	3d" \
    && pass "control/unowned-old reported with sha $UNOWNED_SHA, age 3d" || fail "control/unowned-old not reported"
for b in owned-by-task owned-by-cal fresh merged-old picked-old; do
    printf '%s\n' "$out" | /usr/bin/grep -qF "	control/$b	" && fail "control/$b reported" || pass "control/$b not reported"
done
# stale unmerged = unowned-old + owned-by-task + owned-by-cal; 2 of them owned.
printf '%s\n' "$out" | /usr/bin/grep -q '^1 unowned (3 stale unmerged across 1 repo(s); 2 owned, 0 dismissed' \
    && pass "summary: 1 unowned, 3 stale, 2 owned" || fail "summary counts wrong"

# ---- run 2: dismiss the unowned one, expect a trusted "0 unowned" ----
"$NODE" "$CHECK" --dismiss "$R" control/unowned-old --why "control test" >/dev/null
set +e
out="$("$NODE" "$CHECK" 2>&1)"; rc=$?
set -e
echo "--- run 2 (exit $rc) ---"; printf '%s\n' "$out"; echo "---"
[ "$rc" -eq 0 ] && pass "run 2 exits 0" || fail "run 2 exit $rc"
printf '%s\n' "$out" | /usr/bin/grep -q '^0 unowned (3 stale unmerged across 1 repo(s); 2 owned, 1 dismissed' \
    && pass "0 unowned after dismiss, with the 3 stale still counted" || fail "run 2 summary wrong"

# ---- run 3: a new push re-arms the dismissed branch ----
g checkout -q control/unowned-old
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" g commit -q --allow-empty -m "control: new tip"
g push -q origin control/unowned-old
out="$("$NODE" "$CHECK" 2>&1)" || true
printf '%s\n' "$out" | /usr/bin/grep -qF "control/unowned-old	$(sha7 control/unowned-old)	" \
    && pass "dismissal re-arms on a new tip" || fail "dismissed branch stayed silent after a new push"

st="$(/usr/bin/curl -sf --max-time 10 "$API/api/task/get?id=$TASK_ID" | /usr/bin/jq -r '.status')"
[ "$st" = "pending" ] && pass "planted task was never dispatched (still pending)" || fail "planted task is '$st'"

echo "$fails failure(s)"
[ "$fails" -eq 0 ]
