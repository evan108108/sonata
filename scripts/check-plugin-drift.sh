#!/usr/bin/env bash
# check-plugin-drift.sh — report managed plugins whose source is ahead of
# what's actually installed at ~/.sonata/plugins/<name>/, or whose declared
# Claude Code skills differ from the live copies in ~/.claude/skills/.
# Never modifies state; purely diagnostic.
#
# Exit codes:
#   0 — no drift (all clean or unmapped-but-clean)
#   1 — drift detected on at least one managed plugin
#   2 — hard error (missing DB, unreadable registry, etc.)
#
# Usage:
#   ./scripts/check-plugin-drift.sh              # human-readable report
#   ./scripts/check-plugin-drift.sh --names-only # newline-separated drifted names
#   ./scripts/check-plugin-drift.sh --quiet      # suppress "clean" plugins in report
#   ./scripts/check-plugin-drift.sh --skills-only --quiet
#                                                # ONLY the live-skill diff; prints one
#                                                # "<plugin> — skills drift: <slug>" line
#                                                # per drifted skill, exit 1 on any. Cheap
#                                                # (no git), so it runs on a schedule:
#                                                # scripts/plugin-skill-drift-job.sh
#   ./scripts/check-plugin-drift.sh --no-skills  # sha/dirty checks only (deploy-scout:
#                                                # ~/.claude/skills is per-machine)
#
# Drift is defined as:
#   • The plugin's source directory differs between ~/.sonata/plugins/<name>/.deployed-sha
#     and HEAD (missing or unresolvable .deployed-sha counts as drift — "never
#     deployed via this flow"). Commits elsewhere in the repo don't count.
#   • OR the plugin's source directory has uncommitted changes
#     (compilation would pick these up, so the installed release is stale
#     even if HEAD sha matches).
#   • OR a skill the plugin declares in <name>.plugin.json "skills" differs
#     between <source>/skills/<slug>/ and ~/.claude/skills/<slug>/ (ignoring
#     the .plugin-owner tag). PluginManager.installPluginSkills COPIES skills
#     at install time; a committed prompt edit is not what agents read until
#     the plugin is reinstalled. (2026-11-03: prStar review rule 9 was
#     committed and recorded "done", and the live copy lacked it for a day.)

set -euo pipefail
SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/plugin-deploy-common.sh
source "$SCRIPT_DIR/lib/plugin-deploy-common.sh"

NAMES_ONLY=0
QUIET=0
SKILLS_ONLY=0
NO_SKILLS=0
# Overridable so a positive control can point the check at an edited COPY
# of the skills dir instead of touching the live one agents read.
LIVE_SKILLS_DIR="${PLUGIN_DRIFT_SKILLS_DIR:-$HOME/.claude/skills}"
for arg in "$@"; do
    case "$arg" in
        --names-only)  NAMES_ONLY=1 ;;
        --quiet)       QUIET=1 ;;
        --skills-only) SKILLS_ONLY=1 ;;
        --no-skills)   NO_SKILLS=1 ;;
        -h|--help)     /usr/bin/sed -n '2,45p' "$0"; exit 0 ;;
        *) _die "unknown arg: $arg" ;;
    esac
done

[ "$SKILLS_ONLY" = "1" ] && [ "$NO_SKILLS" = "1" ] && _die "--skills-only and --no-skills are exclusive"

drifted=()
report_lines=()

_report() {
    report_lines+=("$1")
}

# declared_skills <source-dir> <name> → newline-separated slugs from the
# manifest's "skills" array (empty if none). plutil ships with macOS, so the
# scheduled run needs nothing on PATH.
declared_skills() {
    local manifest="$1/$2.plugin.json" i=0 slug
    [ -f "$manifest" ] || return 0
    while slug="$(/usr/bin/plutil -extract "skills.$i" raw -o - "$manifest" 2>/dev/null)"; do
        printf '%s\n' "$slug"
        i=$((i + 1))
    done
}

# skill_drift_reasons <source-dir> <name> → one "skills drift: <slug>[ (why)]"
# line per declared skill whose live copy differs from source.
skill_drift_reasons() {
    local src="$1" name="$2" slug live owner
    for slug in $(declared_skills "$src" "$name"); do
        live="$LIVE_SKILLS_DIR/$slug"
        if [ ! -d "$src/skills/$slug" ]; then
            printf 'skills drift: %s (declared but no %s/skills/%s)\n' "$slug" "$src" "$slug"
        elif [ ! -d "$live" ]; then
            printf 'skills drift: %s (not installed at %s)\n' "$slug" "$live"
        elif ! /usr/bin/diff -rq --exclude=.plugin-owner --exclude=.DS_Store "$live" "$src/skills/$slug" >/dev/null 2>&1; then
            owner="$(/bin/cat "$live/.plugin-owner" 2>/dev/null | /usr/bin/tr -d '[:space:]')"
            if [ "$owner" = "$name" ]; then
                printf 'skills drift: %s\n' "$slug"
            else
                # installPluginSkills skips a slot it doesn't own, so a
                # reinstall will NOT fix this one; say so.
                printf "skills drift: %s (live copy owned by '%s', reinstall won't overwrite)\n" "$slug" "${owner:-nobody}"
            fi
        fi
    done
}

for name in $(managed_plugins); do
    src="$(plugin_source_path "$name")"

    if [ "$SKILLS_ONLY" = "1" ]; then
        # Read-only and git-free: diff declared skills against live copies.
        if [ -z "$src" ] || [ ! -d "$src" ]; then
            [ "$QUIET" = "0" ] && _report "  $name — source unmapped or missing, skills not checked"
            continue
        fi
        skill_lines="$(skill_drift_reasons "$src" "$name")"
        if [ -n "$skill_lines" ]; then
            drifted+=("$name")
            while IFS= read -r l; do _report "  $name — $l"; done <<< "$skill_lines"
        else
            if [ "$QUIET" = "0" ]; then
                if [ -n "$(declared_skills "$src" "$name")" ]; then
                    _report "  $name — skills clean"
                else
                    _report "  $name — no skills declared"
                fi
            fi
        fi
        continue
    fi

    if [ -z "$src" ]; then
        _report "  $name — unmapped (not in $PLUGIN_SOURCES_FILE, skipping check)"
        continue
    fi
    if [ ! -d "$src" ]; then
        _report "  $name — mapped source missing at $src ⚠"
        continue
    fi
    if [ ! -f "$src/.sonata-plugin-build.json" ]; then
        _report "  $name — no .sonata-plugin-build.json at $src ⚠"
        continue
    fi

    head_sha="$(source_head_sha "$src")"
    deployed_sha="$(get_deployed_sha "$name")"
    dirty="$(source_is_dirty "$src")"

    short_head="${head_sha:0:10}"
    short_deployed="${deployed_sha:0:10}"

    is_drift=0
    reasons=()

    if [ -z "$deployed_sha" ]; then
        is_drift=1
        reasons+=("no .deployed-sha (never deployed via drift-aware flow)")
    elif [ "$head_sha" != "$deployed_sha" ] && [ "$(source_changed_since "$src" "$deployed_sha")" = "1" ]; then
        is_drift=1
        reasons+=("source HEAD=$short_head, deployed=$short_deployed")
    fi

    if [ "$dirty" = "1" ]; then
        is_drift=1
        reasons+=("uncommitted changes in $src")
    fi

    if [ "$NO_SKILLS" = "0" ]; then
        while IFS= read -r l; do
            [ -z "$l" ] && continue
            is_drift=1
            reasons+=("$l")
        done <<< "$(skill_drift_reasons "$src" "$name")"
    fi

    if [ "$is_drift" = "1" ]; then
        drifted+=("$name")
        _report "  $name — DRIFT: $(printf '%s; ' "${reasons[@]}")"
    else
        [ "$QUIET" = "0" ] && _report "  $name — clean ($short_deployed)"
    fi
done

# ---- output ----

if [ "$NAMES_ONLY" = "1" ]; then
    [ "${#drifted[@]}" -gt 0 ] && printf '%s\n' "${drifted[@]}"
elif [ "$SKILLS_ONLY" = "1" ]; then
    if [ "${#report_lines[@]}" -gt 0 ]; then
        printf '%s\n' "${report_lines[@]}"
    fi
    if [ "${#drifted[@]}" -eq 0 ] && [ "$QUIET" = "0" ]; then
        echo "==> plugin skills: no drift"
    fi
else
    if [ "${#drifted[@]}" -eq 0 ]; then
        echo "==> managed plugins: no drift"
    else
        echo "==> managed plugins: ${#drifted[@]} drifted"
    fi
    for line in "${report_lines[@]}"; do
        echo "$line"
    done
    if [ "${#drifted[@]}" -gt 0 ]; then
        echo
        echo "To deploy each drifted plugin locally:"
        for d in "${drifted[@]}"; do
            echo "  ./scripts/deploy-plugin-local.sh $d"
        done
        echo
        echo "Or on scout: ./scripts/deploy-plugin-scout.sh <name>"
    fi
fi

[ "${#drifted[@]}" -eq 0 ]
