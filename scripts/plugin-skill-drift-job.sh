#!/usr/bin/env bash
# plugin-skill-drift-job.sh — daily Sonata scheduler job (name:
# plugin-skill-drift-daily). Runs check-plugin-drift.sh --skills-only --quiet
# and, when a plugin-owned skill in ~/.claude/skills differs from its plugin
# source, files ONE pending mem_task "Plugin skill drift: <slugs>".
#
# Why: PluginManager.installPluginSkills copies skills at install time, and
# only deploy-local runs the drift check. On 2026-11-03 a prStar prompt rule
# was committed and recorded "done", and the live copy lacked it until 11/04
# (learning b6928022). Nobody knew. This makes the gap file a task instead.
#
# Edge-triggered: if a pending OR active task whose title starts with
# "Plugin skill drift:" already exists, it files nothing. The open task
# already tells someone to reconcile; a second one would be noise. When the
# drift set changes while a task is open, the worker re-runs the check (step 1
# of its prompt) and sees the current set.
#
# Exit codes: 0 clean or handled (task filed / already open), non-zero when
# the check or the task API failed — so the scheduler's lastExitCode means
# "the watcher is broken", never "there is drift".
#
# Env (for tests only):
#   PLUGIN_SKILL_DRIFT_DRY_RUN=1      print the task instead of filing it
#   PLUGIN_SKILL_DRIFT_TITLE_PREFIX   dedup prefix (default "Plugin skill drift:")
#   PLUGIN_DRIFT_SKILLS_DIR           live skills dir (read by the check itself)

set -euo pipefail
SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
MEM=/Users/evan/memory/bin/mem
PREFIX="${PLUGIN_SKILL_DRIFT_TITLE_PREFIX:-Plugin skill drift:}"
LIST_LIMIT=1000

set +e
report="$("$SCRIPT_DIR/check-plugin-drift.sh" --skills-only --quiet 2>&1)"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
    echo "plugin skills: no drift"
    exit 0
fi
if [ "$rc" -ne 1 ]; then
    printf 'check-plugin-drift.sh --skills-only failed (exit %s):\n%s\n' "$rc" "$report"
    exit "$rc"
fi

slugs="$(printf '%s\n' "$report" | /usr/bin/sed -n 's/.*skills drift: \([^ ]*\).*/\1/p' | /usr/bin/sort -u | /usr/bin/paste -sd, - | /usr/bin/sed 's/,/, /g')"
if [ -z "$slugs" ]; then
    printf 'drift reported but no slug parsed — check output format:\n%s\n' "$report"
    exit 3
fi
title="Plugin skill drift: $slugs"
printf '%s\n' "$report"

# ---- edge trigger: one open task at a time ----
open_tasks=""
for status in pending active; do
    rows="$("$MEM" task list --status "$status" --limit "$LIST_LIMIT")"
    n="$(printf '%s' "$rows" | /usr/bin/grep -c . || true)"
    if [ "$n" -ge "$LIST_LIMIT" ]; then
        # A full page is a sample, not the set: refuse rather than risk a dup.
        echo "task list for status=$status returned $n rows (= limit $LIST_LIMIT); can't dedup safely"
        exit 4
    fi
    open_tasks="$open_tasks$rows"$'\n'
done
existing="$(printf '%s\n' "$open_tasks" | /usr/bin/grep -F "] $PREFIX" | /usr/bin/head -1 || true)"
if [ -n "$existing" ]; then
    echo "skip: drift task already open: $existing"
    exit 0
fi

prompt="Plugin-owned Claude Code skills in ~/.claude/skills differ from their plugin source. Agents read the LIVE copy, so a committed skill or prompt edit is not in effect until the plugin is reinstalled (learning b6928022). Drift found by plugin-skill-drift-daily:
$report

Steps:
1. Re-run /Users/evan/memory/Sonata/scripts/check-plugin-drift.sh --skills-only. It may have been fixed since this task was filed. If it exits 0, complete this task saying so.
2. For each drifted skill, run diff -r ~/.claude/skills/<slug> <plugin source>/skills/<slug>. The source paths are in ~/.sonata/scripts-config/plugin-sources.txt. Decide which side is newer:
   - The source is newer (a committed edit): reinstall with /Users/evan/memory/Sonata/scripts/deploy-plugin-local.sh <plugin>. For prstar, call prstar_active first and wait for in-flight runs to finish, because the reinstall restarts the plugin.
   - The LIVE copy has an edit the source lacks (someone edited the install): port that edit into the source and commit it BEFORE any reinstall, or the reinstall erases it (memory e0f7de31).
   - The source has UNCOMMITTED skill edits: don't ship someone's work in progress. Ask the plugin's owner.
   - The line says \"owned by\" another plugin or nobody: a reinstall won't overwrite that slot. Report it; don't delete the live dir.
3. Re-run the check. It must exit 0. Report what differed and what you did."

if [ "${PLUGIN_SKILL_DRIFT_DRY_RUN:-0}" = "1" ]; then
    printf 'DRY RUN — would file pending task:\n  title: %s\n  prompt:\n%s\n' "$title" "$prompt"
    exit 0
fi

"$MEM" task add "$title" --prompt "$prompt" --project sonata --tags plugin-skill-drift,automated
