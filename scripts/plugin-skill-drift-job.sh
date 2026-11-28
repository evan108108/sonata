#!/usr/bin/env bash
# plugin-skill-drift-job.sh — daily Sonata scheduler job (name:
# plugin-skill-drift-daily). Two checks, each filing at most ONE pending
# mem_task:
#
# 1. Plugin skill drift. Runs check-plugin-drift.sh --skills-only --quiet
#    and, when a plugin-owned skill in ~/.claude/skills differs from its
#    plugin source, files "Plugin skill drift: <slugs>".
#    Why: PluginManager.installPluginSkills copies skills at install time, and
#    only deploy-local runs the drift check. On 2026-11-03 a prStar prompt rule
#    was committed and recorded "done", and the live copy lacked it until 11/04
#    (learning b6928022). Nobody knew. This makes the gap file a task instead.
#
# 2. Served-from-checkout liveness. Runs served-checkout-check.sh, which prints
#    one line per service that runs straight from a git checkout (prStar :4100,
#    eyebrowse :7890; studio and lead-tracker read NOT-CHECKOUT) and flags
#    ARMED-BRANCH / PENDING-RESTART / DIRTY / BEHIND-ORIGIN. When any service is
#    flagged it files "Served checkout flagged: <service (flags)>".
#    Why: from 11/24 to 11/27 the prStar checkout sat on unmerged PR #11's
#    branch, armed for the next restart, and only a manual check found it
#    (memory d70cc811). Its output goes last so the scheduler's tail keeps it.
#
# Edge-triggered: if a pending OR active task whose title starts with the
# check's prefix already exists, it files nothing. The open task already tells
# someone to reconcile; a second one would be noise. The worker re-runs the
# check (step 1 of its prompt) and sees the current set.
#
# Exit codes: 0 clean or handled (task filed / already open), non-zero when
# a check, its self-test or the task API failed — so the scheduler's
# lastExitCode means "the watcher is broken", never "there is drift".
#
# Env (for tests only):
#   PLUGIN_SKILL_DRIFT_DRY_RUN=1      print tasks instead of filing them
#   PLUGIN_SKILL_DRIFT_TITLE_PREFIX   drift dedup prefix (default "Plugin skill drift:")
#   SERVED_CHECKOUT_TITLE_PREFIX      served dedup prefix (default "Served checkout flagged:")
#   PLUGIN_DRIFT_SKILLS_DIR           live skills dir (read by the check itself)
#   SERVED_CHECKOUT_SERVICES          "name:port ..." (read by the check itself)

set -euo pipefail
SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
MEM=/Users/evan/memory/bin/mem
PREFIX="${PLUGIN_SKILL_DRIFT_TITLE_PREFIX:-Plugin skill drift:}"
SERVED_PREFIX="${SERVED_CHECKOUT_TITLE_PREFIX:-Served checkout flagged:}"
LIST_LIMIT=1000

# open_task_line <prefix>: prints the first pending/active task line whose title
# starts with <prefix> (empty if none). Returns 4 when a page is full (a sample,
# not the set: refuse rather than risk a dup), 5 when the task API failed.
open_task_line() {
    local prefix="$1" status rows n open_tasks=""
    for status in pending active; do
        rows="$("$MEM" task list --status "$status" --limit "$LIST_LIMIT")" || {
            echo "mem task list --status $status failed" >&2; return 5; }
        n="$(printf '%s' "$rows" | /usr/bin/grep -c . || true)"
        if [ "$n" -ge "$LIST_LIMIT" ]; then
            echo "task list for status=$status returned $n rows (= limit $LIST_LIMIT); can't dedup safely" >&2
            return 4
        fi
        open_tasks="$open_tasks$rows"$'\n'
    done
    printf '%s\n' "$open_tasks" | /usr/bin/grep -F "] $prefix" | /usr/bin/head -1 || true
}

# file_task <title> <prompt> <tags>
file_task() {
    if [ "${PLUGIN_SKILL_DRIFT_DRY_RUN:-0}" = "1" ]; then
        printf 'DRY RUN — would file pending task:\n  title: %s\n  prompt:\n%s\n' "$1" "$2"
        return 0
    fi
    "$MEM" task add "$1" --prompt "$2" --project sonata --tags "$3"
}

drift_check() {
    local report rc slugs title existing prompt
    set +e
    report="$("$SCRIPT_DIR/check-plugin-drift.sh" --skills-only --quiet 2>&1)"
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        echo "plugin skills: no drift"
        return 0
    fi
    if [ "$rc" -ne 1 ]; then
        printf 'check-plugin-drift.sh --skills-only failed (exit %s):\n%s\n' "$rc" "$report"
        return "$rc"
    fi

    slugs="$(printf '%s\n' "$report" | /usr/bin/sed -n 's/.*skills drift: \([^ ]*\).*/\1/p' | /usr/bin/sort -u | /usr/bin/paste -sd, - | /usr/bin/sed 's/,/, /g')"
    if [ -z "$slugs" ]; then
        printf 'drift reported but no slug parsed — check output format:\n%s\n' "$report"
        return 3
    fi
    title="Plugin skill drift: $slugs"
    printf '%s\n' "$report"

    existing="$(open_task_line "$PREFIX")" || return $?
    if [ -n "$existing" ]; then
        echo "skip: drift task already open: $existing"
        return 0
    fi

    prompt="Plugin-owned Claude Code skills in ~/.claude/skills differ from their plugin source. Agents read the LIVE copy, so a committed skill or prompt edit is not in effect until the plugin is reinstalled (learning b6928022). Drift found by plugin-skill-drift-daily:
$report

Steps:
1. Re-run /Users/evan/memory/Sonata/scripts/check-plugin-drift.sh --skills-only. It may have been fixed since this task was filed. If it exits 0, complete this task saying so.
2. For each drifted plugin, run git -C <plugin source> branch --show-current FIRST. The check compares against the source's WORKING TREE, so a checkout on a feature branch can show drift that isn't there or hide drift that is, and deploy-plugin-local.sh would ship that branch's unmerged code to every session. If it isn't main, never reinstall from it. Compare the live copy against git -C <source> show origin/main:skills/<slug>/SKILL.md instead. To clear the check, merge origin/main into that local branch WITHOUT pushing it (11/26 prfix: 4014ecd on main + local merge f09cb43, no reinstall; learning 7d9f6dc3).
   Then, for each drifted skill, run diff -r ~/.claude/skills/<slug> <plugin source>/skills/<slug>. The source paths are in ~/.sonata/scripts-config/plugin-sources.txt. Decide which side is newer:
   - The source is newer (a committed edit): reinstall with /Users/evan/memory/Sonata/scripts/deploy-plugin-local.sh <plugin>. For prstar, call prstar_active first and wait for in-flight runs to finish, because the reinstall restarts the plugin.
   - The LIVE copy has an edit the source lacks (someone edited the install): port that edit into the source and commit it BEFORE any reinstall, or the reinstall erases it (memory e0f7de31).
   - The source has UNCOMMITTED skill edits: don't ship someone's work in progress. Ask the plugin's owner.
   - The line says \"owned by\" another plugin or nobody: a reinstall won't overwrite that slot. Report it; don't delete the live dir.
3. Re-run the check. It must exit 0. Report what differed and what you did."

    file_task "$title" "$prompt" plugin-skill-drift,automated
}

served_check() {
    local out rc names title existing prompt
    set +e
    out="$("$SCRIPT_DIR/served-checkout-check.sh" 2>&1)"
    rc=$?
    set -e
    printf '%s\n' "$out"

    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -ne 1 ]; then
        echo "served-checkout-check.sh failed (exit $rc)"
        return "$rc"
    fi

    # Flagged lines look like "ARMED-BRANCH DIRTY(2): prstar | started ...".
    names="$(printf '%s\n' "$out" \
        | /usr/bin/grep -vE '^(OK|NOT-CHECKOUT|DOWN|WARN|CONTROL[^:]*|self-test[^:]*):' \
        | /usr/bin/sed -n 's/^\([A-Z][A-Z0-9() -]*\): \([^ |]*\) |.*/\2 (\1)/p' \
        | /usr/bin/paste -sd, - | /usr/bin/sed 's/,/, /g')"
    if [ -z "$names" ]; then
        echo "served check exited 1 but no flagged line parsed — check output format"
        return 3
    fi
    title="$SERVED_PREFIX $names"

    existing="$(open_task_line "$SERVED_PREFIX")" || return $?
    if [ -n "$existing" ]; then
        echo "skip: served-checkout task already open: $existing"
        return 0
    fi

    prompt="A service that runs straight from a git checkout does not run what that checkout holds (memory d70cc811: prStar's checkout sat on unmerged PR #11's branch 11/24-11/27, armed for the next restart). Reading from plugin-skill-drift-daily:
$out

Flags: ARMED-BRANCH = checkout not on main, so a restart ships unmerged code. PENDING-RESTART = HEAD moved since the process started, so merged code is not live yet. DIRTY = tracked files edited, so a restart ships uncommitted code. BEHIND-ORIGIN = origin/main has commits the checkout lacks.

Steps:
1. Re-run /Users/evan/memory/Sonata/scripts/served-checkout-check.sh. It may have cleared since this task was filed (a restart or a pull). If it exits 0, complete this task saying so.
2. ARMED-BRANCH or DIRTY: do NOT restart the service. Find who owns the branch or the edits (worker_list, the branch's commits, unowned-branch-check). Never discard commits or edits. If the branch's commits are all on main or pushed and the tree is clean, return the checkout to main: git -C <checkout> checkout main && git -C <checkout> merge --ff-only origin/main. Otherwise ask the owner to move that work to a worktree (e.g. /Users/evan/enginable/prstar-wt-*).
3. BEHIND-ORIGIN on a clean main checkout: git -C <checkout> merge --ff-only origin/main. It then reads PENDING-RESTART.
4. PENDING-RESTART: the merged code is not live. For prstar, call prstar_active first and restart only when no run is in flight. For any other service, report it instead of restarting.
5. Re-run the check and paste its output. It must exit 0, or say which flag remains and who owns it."

    file_task "$title" "$prompt" served-checkout,automated
}

drift_rc=0
drift_check || drift_rc=$?
served_rc=0
served_check || served_rc=$?

[ "$drift_rc" -eq 0 ] || exit "$drift_rc"
exit "$served_rc"
