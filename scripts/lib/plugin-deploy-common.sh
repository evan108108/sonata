#!/usr/bin/env bash
# plugin-deploy-common.sh — shared helpers for check-plugin-drift.sh and
# deploy-plugin-{local,scout}.sh. Never invoke directly; source it.
#
# Conventions:
#   • Managed-plugin table lives in ~/.sonata/sonata.db (plugins table).
#   • Source-repo registry: ~/.sonata/scripts-config/plugin-sources.txt
#       key=value pairs, "#" comments allowed.
#   • Per-plugin build recipe: <source-repo>/.sonata-plugin-build.json
#       { name, kind, buildCommand, artifactDir, excludePatterns? }
#   • Last-deployed sha: ~/.sonata/plugins/<name>/.deployed-sha
#   • Sonata bridge (local): http://127.0.0.1:3211  — plugin_install /
#       enable / disable endpoints.

set -euo pipefail

SONATA_DB="${HOME}/.sonata/sonata.db"
PLUGIN_SOURCES_FILE="${HOME}/.sonata/scripts-config/plugin-sources.txt"
INSTALLED_PLUGIN_DIR="${HOME}/.sonata/plugins"
BRIDGE_URL="${SONATA_BRIDGE_URL:-http://127.0.0.1:3211}"

# ---- logging ----

# We deliberately go to stderr for status so callers can capture stdout for data.
_log() { printf '%s\n' "$*" >&2; }
_die() { _log "ERROR: $*"; exit 1; }

# ---- registry ----

# managed_plugins → newline-separated plugin names from the plugins table
managed_plugins() {
    [ -f "$SONATA_DB" ] || _die "Sonata DB not found: $SONATA_DB"
    /usr/bin/sqlite3 -readonly "$SONATA_DB" \
        "SELECT name FROM plugins WHERE mode='managed' ORDER BY name"
}

# plugin_source_path <name> → prints source repo path from registry or empty
plugin_source_path() {
    local name="$1"
    [ -f "$PLUGIN_SOURCES_FILE" ] || return 0
    /usr/bin/awk -F= -v n="$name" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        $1 == n { print $2; exit }
    ' "$PLUGIN_SOURCES_FILE"
}

# plugin_manifest_field <source-dir> <field> → jq-lite via python; empty if missing
plugin_manifest_field() {
    local src="$1" field="$2"
    local manifest="$src/.sonata-plugin-build.json"
    [ -f "$manifest" ] || return 0
    /usr/bin/python3 -c "
import json, sys
try:
    d = json.load(open('$manifest'))
    v = d.get('$field', '')
    if isinstance(v, list):
        print(' '.join(v))
    else:
        print(v)
except Exception as e:
    sys.exit(0)
"
}

# ---- sha tracking ----

deployed_sha_file() {
    printf '%s/%s/.deployed-sha' "$INSTALLED_PLUGIN_DIR" "$1"
}

get_deployed_sha() {
    local f
    f="$(deployed_sha_file "$1")"
    [ -f "$f" ] && /bin/cat "$f" || printf ''
}

set_deployed_sha() {
    local name="$1" sha="$2"
    /bin/mkdir -p "$INSTALLED_PLUGIN_DIR/$name"
    printf '%s\n' "$sha" > "$(deployed_sha_file "$name")"
}

# source_head_sha <source-dir> → HEAD sha or empty if not a git repo
source_head_sha() {
    /usr/bin/git -C "$1" rev-parse HEAD 2>/dev/null || printf ''
}

# source_is_dirty <source-dir> → prints 1 if working tree has uncommitted changes, else 0
source_is_dirty() {
    local src="$1"
    if [ -n "$(/usr/bin/git -C "$src" status --porcelain 2>/dev/null)" ]; then
        printf '1'
    else
        printf '0'
    fi
}

# ---- tarball staging ----

# stage_and_tar <source-dir> <artifact-dir-relative-to-source> <plugin-name> <excludes-space-separated>
# → prints path to the tarball on stdout; stages under /tmp/plugin-stage-<pid>/
# The tarball unpacks into a wrapper dir named <plugin-name>/ so plugin_install
# finds .plugin.json exactly where it expects it.
stage_and_tar() {
    local src="$1" art="$2" name="$3" excludes="${4-}"
    local stage="/tmp/plugin-stage-$$-$name"
    local wrapper="$stage/$name"
    /bin/rm -rf "$stage"
    /bin/mkdir -p "$wrapper"

    local artpath
    if [ "$art" = "." ] || [ -z "$art" ]; then
        artpath="$src"
    else
        artpath="$src/$art"
    fi
    [ -d "$artpath" ] || _die "artifact dir not found: $artpath"

    # rsync into wrapper so we can honor excludes without changing the source tree.
    local rsync_excludes=""
    if [ -n "$excludes" ]; then
        for e in $excludes; do
            rsync_excludes="$rsync_excludes --exclude=$e"
        done
    fi
    # shellcheck disable=SC2086
    /usr/bin/rsync -a $rsync_excludes "$artpath/" "$wrapper/"

    # Manifest sanity: the artifact must include <name>.plugin.json somewhere,
    # or plugin_install will reject the tarball.
    if [ ! -f "$wrapper/$name.plugin.json" ]; then
        # Fall back: search source repo for the manifest and copy it in.
        local mfound
        mfound="$(/usr/bin/find "$src" -maxdepth 3 -name "$name.plugin.json" -not -path "*/node_modules/*" -not -path "*/_build/*" 2>/dev/null | /usr/bin/head -1)"
        if [ -n "$mfound" ]; then
            /bin/cp "$mfound" "$wrapper/$name.plugin.json"
        else
            _die "$name.plugin.json not found in artifact or source"
        fi
    fi

    local tarball="/tmp/${name}-release-$$.tar.gz"
    /usr/bin/tar -czf "$tarball" -C "$stage" "$name"
    /bin/rm -rf "$stage"
    printf '%s\n' "$tarball"
}

# ---- Sonata HTTP calls ----

# bridge_up_local → return 0 if Sonata's MCP bridge on 127.0.0.1:3211 answers.
# Uses the same POST /mcp initialize probe deploy-local.sh uses — a GET to
# /mcp opens an SSE stream that never closes (curl hangs to max-time and
# returns non-zero even when the bridge is healthy). "Any HTTP code" is
# proof the bridge bound the port; 401 for a bogus bearer is fine.
bridge_up_local() {
    local url="${1:-$BRIDGE_URL/mcp}"
    local code
    code=$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 4 -X POST "$url" \
        -H "Authorization: Bearer probe" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"deploy-plugin","version":"1"}}}' \
        2>/dev/null) || true
    [ -n "$code" ] && [ "$code" != "000" ]
}

# plugin_status <name> → prints one of: running | stopped | error | not-installed
plugin_status() {
    /usr/bin/sqlite3 -readonly "$SONATA_DB" \
        "SELECT COALESCE(status, 'not-installed') FROM plugins WHERE name='$1'" 2>/dev/null
}

sonata_disable_plugin() {
    local name="$1"
    /usr/bin/curl -sS --max-time 30 -X POST "$BRIDGE_URL/api/plugins/$name/disable" \
        -H "Content-Type: application/json"
}

sonata_enable_plugin() {
    local name="$1"
    /usr/bin/curl -sS --max-time 30 -X POST "$BRIDGE_URL/api/plugins/$name/enable" \
        -H "Content-Type: application/json"
}

sonata_install_plugin() {
    local tarball="$1"
    # NB: action param is named "path" (see Sources/Actions/PluginActions.swift).
    /usr/bin/curl -sS --max-time 120 -X POST "$BRIDGE_URL/api/plugins/install" \
        -H "Content-Type: application/json" \
        -d "{\"path\":\"$tarball\"}"
}

# Poll until plugin.status == expected, or timeout in seconds
wait_for_plugin_status() {
    local name="$1" expected="$2" timeout="${3:-30}"
    local i=0
    while [ "$i" -lt "$timeout" ]; do
        if [ "$(plugin_status "$name")" = "$expected" ]; then
            return 0
        fi
        /bin/sleep 1
        i=$((i + 1))
    done
    return 1
}
