#!/usr/bin/env bash
# deploy-plugin-local.sh — build a managed plugin from source and install
# it into the local Sonata (~/.sonata/plugins/<name>/), disabling and
# re-enabling around the install so plugin_install accepts it.
#
# Requires:
#   • Sonata running locally on 3211 (needs disable + install + enable HTTP).
#   • Source repo mapped in ~/.sonata/scripts-config/plugin-sources.txt
#   • Source repo has .sonata-plugin-build.json declaring buildCommand/artifactDir
#
# Usage:
#   ./scripts/deploy-plugin-local.sh <name>
#   ./scripts/deploy-plugin-local.sh <name> --no-build   # use existing artifact
#   ./scripts/deploy-plugin-local.sh <name> --no-restart # install but leave disabled
#
# On success writes ~/.sonata/plugins/<name>/.deployed-sha so
# check-plugin-drift.sh knows to stop flagging it.

set -euo pipefail
SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/plugin-deploy-common.sh
source "$SCRIPT_DIR/lib/plugin-deploy-common.sh"

NAME=""
DO_BUILD=1
DO_RESTART=1

for arg in "$@"; do
    case "$arg" in
        --no-build)   DO_BUILD=0 ;;
        --no-restart) DO_RESTART=0 ;;
        -h|--help)    /usr/bin/sed -n '2,20p' "$0"; exit 0 ;;
        -*)           _die "unknown flag: $arg" ;;
        *)            [ -z "$NAME" ] && NAME="$arg" || _die "extra positional arg: $arg" ;;
    esac
done

[ -n "$NAME" ] || _die "usage: deploy-plugin-local.sh <name> [--no-build] [--no-restart]"

# ---- resolve source + manifest ----

SRC="$(plugin_source_path "$NAME")"
[ -n "$SRC" ] || _die "plugin '$NAME' not in $PLUGIN_SOURCES_FILE"
[ -d "$SRC" ] || _die "mapped source '$SRC' does not exist"
[ -f "$SRC/.sonata-plugin-build.json" ] || _die "$SRC/.sonata-plugin-build.json missing"

BUILD_CMD="$(plugin_manifest_field "$SRC" buildCommand)"
ARTIFACT_DIR="$(plugin_manifest_field "$SRC" artifactDir)"
EXCLUDES="$(plugin_manifest_field "$SRC" excludePatterns)"
MFR_NAME="$(plugin_manifest_field "$SRC" name)"

[ "$MFR_NAME" = "$NAME" ] || _die "manifest name '$MFR_NAME' != argument '$NAME' — check $SRC/.sonata-plugin-build.json"

HEAD_SHA="$(source_head_sha "$SRC")"
DIRTY="$(source_is_dirty "$SRC")"

echo "==> plugin: $NAME"
echo "==> source: $SRC (HEAD=$HEAD_SHA${DIRTY:+, dirty=$DIRTY})"
echo "==> build:  $BUILD_CMD"

# ---- reachable bridge ----
# Uses POST-with-init-JSON-RPC probe (matches deploy-local.sh's bridge_up).
# A plain GET to /mcp would hang on the SSE stream to max-time — the reason
# earlier revisions of this script false-negatived a healthy bridge.

if ! bridge_up_local "$BRIDGE_URL/mcp"; then
    _die "Sonata bridge ($BRIDGE_URL) unreachable — is Sonata.app running?"
fi

# ---- build ----

if [ "$DO_BUILD" = "1" ]; then
    echo "==> building..."
    ( cd "$SRC" && /bin/bash -lc "$BUILD_CMD" )
else
    echo "==> --no-build: reusing existing artifact"
fi

# ---- stage + tar ----

echo "==> staging artifact ($ARTIFACT_DIR)"
TARBALL="$(stage_and_tar "$SRC" "$ARTIFACT_DIR" "$NAME" "$EXCLUDES")"
echo "==> tarball: $TARBALL ($(/usr/bin/stat -f '%z' "$TARBALL") bytes)"

# Trap cleanup — leave tarball if we bail so it can be inspected
cleanup_ok() { /bin/rm -f "$TARBALL"; }

# ---- disable + install + enable ----

CUR_STATUS="$(plugin_status "$NAME")"
echo "==> current plugin status: $CUR_STATUS"

if [ "$CUR_STATUS" = "running" ] || [ "$CUR_STATUS" = "starting" ]; then
    echo "==> disabling $NAME"
    sonata_disable_plugin "$NAME" > /dev/null
    # Sonata's terminal disable status is "disabled" (not "stopped").
    # See PluginManager.disable() around line 817. plugin_install() accepts
    # anything that isn't "running"/"starting", so "disabled" is fine.
    if ! wait_for_plugin_status "$NAME" "disabled" 20; then
        LAST_STATUS="$(plugin_status "$NAME")"
        _die "plugin '$NAME' did not reach 'disabled' within 20s (last status: $LAST_STATUS)"
    fi
fi

echo "==> installing $NAME from $TARBALL"
INSTALL_RESP="$(sonata_install_plugin "$TARBALL")"
if ! printf '%s' "$INSTALL_RESP" | /usr/bin/grep -q '"ok":true'; then
    echo "install response: $INSTALL_RESP" >&2
    _die "plugin_install failed"
fi

if [ "$DO_RESTART" = "1" ]; then
    echo "==> enabling $NAME"
    sonata_enable_plugin "$NAME" > /dev/null
    wait_for_plugin_status "$NAME" "running" 30 || _die "plugin '$NAME' did not reach 'running' within 30s"
else
    echo "==> --no-restart: leaving disabled"
fi

# ---- record sha ----

if [ "$DIRTY" = "0" ] && [ -n "$HEAD_SHA" ]; then
    set_deployed_sha "$NAME" "$HEAD_SHA"
    echo "==> marked deployed at $HEAD_SHA"
else
    # Dirty tree: don't record a false-clean sha. Use HEAD-dirty sentinel.
    if [ -n "$HEAD_SHA" ]; then
        set_deployed_sha "$NAME" "${HEAD_SHA}-dirty-$(/bin/date +%s)"
        echo "==> marked deployed at ${HEAD_SHA}-dirty (working tree had uncommitted changes)"
    fi
fi

cleanup_ok
echo "==> deploy-plugin-local done: $NAME"
