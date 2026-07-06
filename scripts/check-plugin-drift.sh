#!/usr/bin/env bash
# check-plugin-drift.sh — report managed plugins whose source is ahead of
# what's actually installed at ~/.sonata/plugins/<name>/. Never modifies
# state; purely diagnostic.
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
#
# Drift is defined as:
#   • Source repo HEAD sha != ~/.sonata/plugins/<name>/.deployed-sha
#     (missing .deployed-sha counts as drift — "never deployed via this flow")
#   • OR the source repo has uncommitted changes in the working tree
#     (compilation would pick these up, so the installed release is stale
#     even if HEAD sha matches).

set -euo pipefail
SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/plugin-deploy-common.sh
source "$SCRIPT_DIR/lib/plugin-deploy-common.sh"

NAMES_ONLY=0
QUIET=0
for arg in "$@"; do
    case "$arg" in
        --names-only) NAMES_ONLY=1 ;;
        --quiet)      QUIET=1 ;;
        -h|--help)    /usr/bin/sed -n '2,20p' "$0"; exit 0 ;;
        *) _die "unknown arg: $arg" ;;
    esac
done

drifted=()
report_lines=()

_report() {
    report_lines+=("$1")
}

for name in $(managed_plugins); do
    src="$(plugin_source_path "$name")"

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
    elif [ "$head_sha" != "$deployed_sha" ]; then
        is_drift=1
        reasons+=("source HEAD=$short_head, deployed=$short_deployed")
    fi

    if [ "$dirty" = "1" ]; then
        is_drift=1
        reasons+=("uncommitted changes in $src")
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
    printf '%s\n' "${drifted[@]}"
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
