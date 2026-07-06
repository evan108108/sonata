#!/usr/bin/env bash
# deploy-plugin-scout.sh — build a managed plugin from source and install
# it into Scout's Sonata (/Users/scout/.sonata/plugins/<name>/).
#
# Runs the build on evan-mac (same architecture, same toolchain), scp's the
# resulting tarball to Scout, then drives Scout's local Sonata bridge to
# disable → install → enable. Also writes /Users/scout/.sonata/plugins/<name>/
# .deployed-sha on the remote so its check-plugin-drift stops flagging it.
#
# Assumes ~/.ssh/scout_ed25519 identity is already trusted at scout@192.168.0.17
# (same convention as deploy-scout skill).
#
# Usage:
#   ./scripts/deploy-plugin-scout.sh <name>
#   ./scripts/deploy-plugin-scout.sh <name> --no-build   # reuse existing local artifact
#   ./scripts/deploy-plugin-scout.sh <name> --no-restart # install but leave disabled on scout

set -euo pipefail
SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/plugin-deploy-common.sh
source "$SCRIPT_DIR/lib/plugin-deploy-common.sh"

SCOUT_HOST="scout@192.168.0.17"
SCOUT_SSH_ID="$HOME/.ssh/scout_ed25519"
SCOUT_BRIDGE_URL="http://127.0.0.1:3211"
SCOUT_TARBALL_DIR="/tmp"

_ssh() { /usr/bin/ssh -o IdentitiesOnly=yes -i "$SCOUT_SSH_ID" -o ConnectTimeout=5 "$SCOUT_HOST" "$@"; }
_scp() { /usr/bin/scp -o IdentitiesOnly=yes -i "$SCOUT_SSH_ID" "$@"; }

NAME=""
DO_BUILD=1
DO_RESTART=1

for arg in "$@"; do
    case "$arg" in
        --no-build)   DO_BUILD=0 ;;
        --no-restart) DO_RESTART=0 ;;
        -h|--help)    /usr/bin/sed -n '2,17p' "$0"; exit 0 ;;
        -*)           _die "unknown flag: $arg" ;;
        *)            [ -z "$NAME" ] && NAME="$arg" || _die "extra positional arg: $arg" ;;
    esac
done

[ -n "$NAME" ] || _die "usage: deploy-plugin-scout.sh <name> [--no-build] [--no-restart]"

# ---- resolve source ----

SRC="$(plugin_source_path "$NAME")"
[ -n "$SRC" ] || _die "plugin '$NAME' not in $PLUGIN_SOURCES_FILE"
[ -d "$SRC" ] || _die "mapped source '$SRC' does not exist"
[ -f "$SRC/.sonata-plugin-build.json" ] || _die "$SRC/.sonata-plugin-build.json missing"

BUILD_CMD="$(plugin_manifest_field "$SRC" buildCommand)"
ARTIFACT_DIR="$(plugin_manifest_field "$SRC" artifactDir)"
EXCLUDES="$(plugin_manifest_field "$SRC" excludePatterns)"

HEAD_SHA="$(source_head_sha "$SRC")"
DIRTY="$(source_is_dirty "$SRC")"

echo "==> plugin: $NAME"
echo "==> source: $SRC (HEAD=$HEAD_SHA${DIRTY:+, dirty=$DIRTY})"
echo "==> target: $SCOUT_HOST"

# ---- check ssh ----

if ! _ssh "echo ok" > /dev/null 2>&1; then
    _die "cannot ssh to $SCOUT_HOST — check ~/.ssh/scout_ed25519 and connectivity"
fi

# ---- build locally ----

if [ "$DO_BUILD" = "1" ]; then
    echo "==> building locally..."
    ( cd "$SRC" && /bin/bash -lc "$BUILD_CMD" )
fi

echo "==> staging artifact"
TARBALL="$(stage_and_tar "$SRC" "$ARTIFACT_DIR" "$NAME" "$EXCLUDES")"
REMOTE_TARBALL="$SCOUT_TARBALL_DIR/$(/usr/bin/basename "$TARBALL")"

echo "==> scp tarball to $REMOTE_TARBALL"
_scp "$TARBALL" "$SCOUT_HOST:$REMOTE_TARBALL"

# ---- scout-side status ----

echo "==> checking Scout's bridge"
# POST-with-init probe over ssh; GET /mcp would hang on the SSE stream.
_scout_bridge_check() {
    _ssh "curl -s -o /dev/null -w '%{http_code}' --max-time 4 -X POST '$SCOUT_BRIDGE_URL/mcp' \
        -H 'Authorization: Bearer probe' \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"deploy-plugin-scout\",\"version\":\"1\"}}}' 2>/dev/null"
}
SCOUT_CODE="$(_scout_bridge_check)"
if [ -z "$SCOUT_CODE" ] || [ "$SCOUT_CODE" = "000" ]; then
    /bin/rm -f "$TARBALL"
    _die "Scout's Sonata bridge unreachable — is Sonata running on Scout?"
fi

CUR_STATUS="$(_ssh "sqlite3 -readonly ~/.sonata/sonata.db \"SELECT COALESCE(status, 'not-installed') FROM plugins WHERE name='$NAME'\"")"

# Never install a plugin on Scout that isn't already installed there.
# Fresh installs on a remote host must be explicit; the deploy scripts
# sync EXISTING plugins.
if [ "$CUR_STATUS" = "not-installed" ] || [ -z "$CUR_STATUS" ]; then
    /bin/rm -f "$TARBALL"
    _die "plugin '$NAME' is NOT installed on Scout — this script only syncs existing plugins. Install it manually first if you actually want it there."
fi
echo "==> Scout's plugin status: $CUR_STATUS"

if [ "$CUR_STATUS" = "running" ] || [ "$CUR_STATUS" = "starting" ]; then
    echo "==> disabling on Scout"
    _ssh "curl -sS --max-time 30 -X POST '$SCOUT_BRIDGE_URL/api/plugins/$NAME/disable' -H 'Content-Type: application/json'" > /dev/null

    # Sonata's terminal disable status is "disabled" (not "stopped").
    LAST_SCOUT_STATUS=""
    for _ in $(seq 1 20); do
        LAST_SCOUT_STATUS="$(_ssh "sqlite3 -readonly ~/.sonata/sonata.db \"SELECT COALESCE(status,'?') FROM plugins WHERE name='$NAME'\"")"
        [ "$LAST_SCOUT_STATUS" = "disabled" ] && break
        /bin/sleep 1
    done
    if [ "$LAST_SCOUT_STATUS" != "disabled" ]; then
        /bin/rm -f "$TARBALL"
        _die "plugin '$NAME' did not reach 'disabled' on Scout within 20s (last: $LAST_SCOUT_STATUS)"
    fi
fi

echo "==> installing on Scout from $REMOTE_TARBALL"
# NB: action param is named "path" (see Sources/Actions/PluginActions.swift).
INSTALL_RESP="$(_ssh "curl -sS --max-time 120 -X POST '$SCOUT_BRIDGE_URL/api/plugins/install' -H 'Content-Type: application/json' -d '{\"path\":\"$REMOTE_TARBALL\"}'")"
if ! printf '%s' "$INSTALL_RESP" | /usr/bin/grep -q '"ok":true'; then
    echo "Scout install response: $INSTALL_RESP" >&2
    /bin/rm -f "$TARBALL"
    _die "plugin_install on Scout failed"
fi

if [ "$DO_RESTART" = "1" ]; then
    echo "==> enabling on Scout"
    _ssh "curl -sS --max-time 30 -X POST '$SCOUT_BRIDGE_URL/api/plugins/$NAME/enable' -H 'Content-Type: application/json'" > /dev/null

    for _ in $(seq 1 30); do
        s="$(_ssh "sqlite3 -readonly ~/.sonata/sonata.db \"SELECT COALESCE(status,'?') FROM plugins WHERE name='$NAME'\"")"
        [ "$s" = "running" ] && break
        /bin/sleep 1
    done
    FINAL_STATUS="$(_ssh "sqlite3 -readonly ~/.sonata/sonata.db \"SELECT COALESCE(status,'?') FROM plugins WHERE name='$NAME'\"")"
    [ "$FINAL_STATUS" = "running" ] || _die "plugin '$NAME' did not reach 'running' on Scout within 30s (last status: $FINAL_STATUS)"
fi

# ---- record sha on Scout ----

if [ "$DIRTY" = "0" ] && [ -n "$HEAD_SHA" ]; then
    _ssh "mkdir -p ~/.sonata/plugins/$NAME && echo '$HEAD_SHA' > ~/.sonata/plugins/$NAME/.deployed-sha"
    echo "==> marked Scout deployed at $HEAD_SHA"
else
    if [ -n "$HEAD_SHA" ]; then
        _ssh "mkdir -p ~/.sonata/plugins/$NAME && echo '${HEAD_SHA}-dirty-$(/bin/date +%s)' > ~/.sonata/plugins/$NAME/.deployed-sha"
        echo "==> marked Scout deployed at ${HEAD_SHA}-dirty"
    fi
fi

# ---- cleanup ----

_ssh "rm -f $REMOTE_TARBALL"
/bin/rm -f "$TARBALL"
echo "==> deploy-plugin-scout done: $NAME"
