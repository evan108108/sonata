#!/usr/bin/env bash
# served-checkout-check.sh — answers "is X live?" for services that run
# straight from a git checkout, as a measured daily reading. Called by
# plugin-skill-drift-job.sh (scheduler job plugin-skill-drift-daily).
#
# Why: the prStar server (node /Users/evan/enginable/prstar/src/server.js,
# :4100) loads whatever the checkout holds at its next restart. From 11/24 to
# 11/27 that checkout sat on unmerged PR #11's branch: armed, not live, and
# found only by a manual check (memory d70cc811).
#
# For each service (by listening port) it reads:
#   - the process start time (ps -o lstart);
#   - the code source: the first argv path inside a git checkout, else the
#     process cwd (lsof -d cwd). prStar's cwd is the plugin install dir, its
#     argv[1] is the checkout, so argv must come first;
#   - the checkout's branch, HEAD, origin/main and tracked-file edits;
#   - the sha HEAD held when the process started, from the reflog
#     (HEAD@{<start epoch>}). A fast-forward pull of commits dated before the
#     start moves HEAD without any commit dated after it, so the reflog is
#     the authority; `git log --since=<start>` is printed beside it.
#
# Flags (one line per service):
#   ARMED-BRANCH     branch != main: a restart ships unmerged code
#   PENDING-RESTART  HEAD moved since the process started: the running code
#                    is not what the checkout holds
#   DIRTY            tracked files edited: a restart ships uncommitted code
#   BEHIND-ORIGIN    origin/main has commits the checkout lacks: merged, but
#                    neither live nor loaded by a restart
#   NOT-CHECKOUT     code source isn't a git checkout (an installed build);
#                    informational, never flagged
#   DOWN             nothing listening on the port; informational
#
# Self-test: three fixture repos with known answers (on main = OK, a branch =
# ARMED-BRANCH, a commit after start = PENDING-RESTART) run through the same
# probe. Its CONTROL lines prove the lookup can say both OK and a flag.
#
# Exit: 0 all OK, 1 at least one service flagged, 2 self-test failed (the
# watcher is broken; don't trust the service lines).
#
# Env (tests only): SERVED_CHECKOUT_SERVICES  "name:port ..." overrides the list.

set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C

# name:port. sonata-studio (:4200) runs an installed bun binary and
# lead-tracker (:4110) an installed copy; they stay listed so a move to a
# checkout shows up here.
SERVICES="${SERVED_CHECKOUT_SERVICES:-prstar:4100 eyebrowse:7890 sonata-studio:4200 lead-tracker:4110}"
MAIN_BRANCH=main

flagged=0

# probe <name> <start_epoch> <start_label> <repo> [label-prefix]
# Prints one line; returns 0 OK, 1 flagged.
probe() {
    local name="$1" start="$2" start_label="$3" repo="$4" prefix="${5:-}"
    local branch head origin dirty at_start moved since behind flags="" warn
    branch="$(git -C "$repo" branch --show-current 2>/dev/null)"
    [ -n "$branch" ] || branch="(detached)"
    head="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)"
    origin="$(git -C "$repo" rev-parse --short "refs/remotes/origin/$MAIN_BRANCH" 2>/dev/null || echo '?')"
    dirty="$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null | grep -c . || true)"
    since="$(git -C "$repo" log --oneline --since="@$start" HEAD 2>/dev/null | grep -c . || true)"

    warn="$(git -C "$repo" rev-parse --short "HEAD@{$start}" 2>&1 >/dev/null || true)"
    if printf '%s' "$warn" | grep -q 'only goes back'; then
        at_start="?"
        moved="$since(by-commit-date;reflog-short)"
    else
        at_start="$(git -C "$repo" rev-parse --short "HEAD@{$start}" 2>/dev/null || echo '?')"
        if [ "$at_start" = "?" ]; then
            moved="$since(by-commit-date)"
        else
            moved="$(git -C "$repo" rev-list --count "$at_start..HEAD" 2>/dev/null || echo '?')"
            [ "$at_start" = "$head" ] || [ "$moved" != "0" ] || moved="1(branch-switch)"
        fi
    fi
    if [ "$origin" != "?" ]; then
        behind="$(git -C "$repo" rev-list --count "HEAD..refs/remotes/origin/$MAIN_BRANCH" 2>/dev/null || echo 0)"
    else
        behind=0
    fi

    [ "$branch" = "$MAIN_BRANCH" ] || flags="$flags ARMED-BRANCH"
    case "$moved" in 0|0\(*) ;; *) flags="$flags PENDING-RESTART" ;; esac
    [ "$dirty" = "0" ] || flags="$flags DIRTY($dirty)"
    [ "$behind" = "0" ] || flags="$flags BEHIND-ORIGIN($behind)"

    flags="${flags# }"
    printf '%s%s: %s | started %s | %s@%s (at start %s) | origin/main %s | moved-since-start %s, log-since %s\n' \
        "$prefix" "${flags:-OK}" "$name" "$start_label" "$branch" "$head" "$at_start" "$origin" "$moved" "$since"
    [ -z "$flags" ]
}

# ---- self-test on fixtures with known answers ----
selftest() {
    local d now t0 t1 t2 pass=0 total=3 out
    d="$(mktemp -d /tmp/served-checkout-selftest.XXXXXX)" || return 2
    # selftest runs in $(...), so EXIT is the subshell's exit
    # shellcheck disable=SC2064
    trap "rm -rf '${d:?}'" EXIT
    now="$(date +%s)"; t0=$((now - 300)); t1=$((now - 200)); t2=$((now - 100))
    g() { git -C "$d/repo" -c user.name=selftest -c user.email=selftest@invalid "$@"; }
    git init -q -b "$MAIN_BRANCH" "$d/repo" || return 2
    GIT_COMMITTER_DATE="@$t0 +0000" GIT_AUTHOR_DATE="@$t0 +0000" g commit -q --allow-empty -m one || return 2
    g update-ref "refs/remotes/origin/$MAIN_BRANCH" HEAD

    # 1. on main, nothing since start -> OK (the known-on-main control)
    out="$(probe ctl-on-main "$t1" "fixture" "$d/repo" "CONTROL ")" && pass=$((pass + 1))
    printf '%s\n' "$out"

    # 2. a feature branch checked out -> ARMED-BRANCH
    GIT_COMMITTER_DATE="@$t0 +0000" g checkout -q -b feature
    out="$(probe ctl-branch "$t1" "fixture" "$d/repo" "CONTROL ")"
    case "$out" in *PENDING-RESTART*) ;; *ARMED-BRANCH*) pass=$((pass + 1)) ;; esac
    GIT_COMMITTER_DATE="@$t0 +0000" g checkout -q "$MAIN_BRANCH"

    # 3. a commit landed after the start -> PENDING-RESTART (and, since the
    #    fixture's origin/main stays put, nothing BEHIND-ORIGIN)
    GIT_COMMITTER_DATE="@$t2 +0000" GIT_AUTHOR_DATE="@$t2 +0000" g commit -q --allow-empty -m two
    g update-ref "refs/remotes/origin/$MAIN_BRANCH" HEAD
    out="$(probe ctl-moved "$t1" "fixture" "$d/repo" "CONTROL ")"
    case "$out" in *ARMED-BRANCH*) ;; *PENDING-RESTART*) pass=$((pass + 1)) ;; esac

    echo "self-test $pass/$total (on-main=OK, branch=ARMED-BRANCH, commit-after-start=PENDING-RESTART)"
    [ "$pass" -eq "$total" ]
}

# code_source <pid>: first argv word that is a path inside a git checkout,
# else the cwd if it is one; prints "<toplevel>" or "NOT:<path>".
code_source() {
    local pid="$1" word top cwd
    for word in $(ps -ww -o command= -p "$pid"); do
        case "$word" in /*) ;; *) continue ;; esac
        [ -e "$word" ] || continue
        top="$(git -C "$(dirname "$word")" rev-parse --show-toplevel 2>/dev/null)" || continue
        # /opt/homebrew is itself a git checkout (Homebrew), so the
        # interpreter /opt/homebrew/bin/node would otherwise win.
        case "$top" in /opt/homebrew|/opt/homebrew/*|/usr/*) continue ;; esac
        [ -n "$top" ] && { echo "$top"; return; }
    done
    cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
    if [ -n "$cwd" ] && top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"; then
        echo "$top"
    else
        echo "NOT:$(ps -ww -o command= -p "$pid" | cut -c1-90)"
    fi
}

selftest_out="$(selftest)"; st=$?
if [ "$st" -eq 0 ]; then
    printf '%s\n' "$selftest_out" | grep -E '^CONTROL [^:]*: ctl-on-main' || true
    printf '%s\n' "$selftest_out" | tail -1
else
    printf '%s\n' "$selftest_out"
    echo "served-checkout self-test FAILED: service lines below are not trustworthy"
fi

for entry in $SERVICES; do
    name="${entry%%:*}"; port="${entry##*:}"
    pid="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)"
    if [ -z "$pid" ]; then
        echo "DOWN: $name | nothing listening on :$port"
        continue
    fi
    lstart="$(ps -o lstart= -p "$pid" | tr -s ' ' | sed 's/ $//')"
    start="$(date -j -f '%a %b %d %T %Y' "$lstart" +%s 2>/dev/null)"
    label="$(date -j -r "$start" '+%Y-%m-%d %H:%M' 2>/dev/null) pid $pid"
    src="$(code_source "$pid")"
    case "$src" in
        NOT:*) echo "NOT-CHECKOUT: $name | started $label | runs ${src#NOT:} (not in a git checkout)"; continue ;;
    esac
    git -C "$src" fetch -q origin "$MAIN_BRANCH" 2>/dev/null || echo "WARN: $name | fetch origin failed; origin/main may be stale"
    probe "$name" "$start" "$label" "$src" || flagged=1
done

[ "$st" -eq 0 ] || exit 2
exit "$flagged"
