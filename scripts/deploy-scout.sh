#!/usr/bin/env bash
# deploy-scout.sh — deploy the local Sonata binary + resources to Scout,
# codesign, restart, and (by default) sync every drifted managed plugin.
#
# Counterpart to deploy-local.sh. Encapsulates every gotcha the deploy-scout
# skill's markdown documents (codesign-in-/tmp, dual-bundle resource paths,
# stale-failed recovery, plugin drift) so the deploy is one command.
#
# Usage:
#   ./scripts/deploy-scout.sh                # ship Sonata + rebuild drifted plugins on Scout
#   ./scripts/deploy-scout.sh --skip-restart # ship files, don't restart Sonata on Scout
#   ./scripts/deploy-scout.sh --skip-plugins # ship Sonata only, skip plugin drift check
#
# Managed-plugin drift: after Scout's Sonata is healthy, this script calls
# scripts/deploy-plugin-scout.sh for each plugin whose source is ahead of
# its installed release. Failure of a single plugin WARNS but doesn't fail
# the overall deploy (Sonata itself is already up).

set -euo pipefail

REPO="/Users/evan/memory/Sonata"
BIN_SRC_RELEASE="$REPO/.build/release/Sonata"
BIN_SRC_DEBUG="$REPO/.build/debug/Sonata"
SCOUT_HOST="scout@192.168.0.17"
SCOUT_SSH_ID="$HOME/.ssh/scout_ed25519"
SCOUT_BRIDGE_URL="http://127.0.0.1:3211"
SCOUT_APP="/Applications/Sonata.app"
BRIDGE_STARTUP_TIMEOUT=25

DO_RESTART=1
SKIP_PLUGINS=0
for a in "$@"; do
  case "$a" in
    --skip-restart) DO_RESTART=0 ;;
    --skip-plugins) SKIP_PLUGINS=1 ;;
    -h|--help)      sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

_ssh() { /usr/bin/ssh -o IdentitiesOnly=yes -i "$SCOUT_SSH_ID" -o ConnectTimeout=5 "$SCOUT_HOST" "$@"; }
_scp() { /usr/bin/scp -o IdentitiesOnly=yes -i "$SCOUT_SSH_ID" "$@"; }
_rsync() { /usr/bin/rsync -az -e "ssh -o IdentitiesOnly=yes -i $SCOUT_SSH_ID" "$@"; }

# ---- pick binary: prefer release, fall back to debug ----

if [ -f "$BIN_SRC_RELEASE" ]; then
  BIN_SRC="$BIN_SRC_RELEASE"
  BUILD_KIND="release"
elif [ -f "$BIN_SRC_DEBUG" ]; then
  BIN_SRC="$BIN_SRC_DEBUG"
  BUILD_KIND="debug"
else
  echo "ERROR: no Sonata binary found at .build/release/Sonata or .build/debug/Sonata" >&2
  echo "       run: cd $REPO && swift build -c release" >&2
  exit 1
fi
echo "==> local binary: $BIN_SRC ($BUILD_KIND, $(stat -f '%z' "$BIN_SRC") bytes)"
echo "==> HEAD: $(git -C "$REPO" log -1 --format='%h %s')"

# ---- ssh probe ----

if ! _ssh "echo ok" > /dev/null 2>&1; then
  echo "ERROR: cannot ssh $SCOUT_HOST — check ~/.ssh/scout_ed25519 and connectivity" >&2
  exit 1
fi

# ---- scp binary + rsync resources ----

echo "==> scp binary to $SCOUT_HOST:/tmp/Sonata.new"
_scp "$BIN_SRC" "$SCOUT_HOST:/tmp/Sonata.new"

# Resources go into BOTH bundle paths — Bundle.main.resourcePath resolves
# to Contents/Resources/ (web assets), Bundle.module resolves to
# Sonata_Sonata.bundle/ (sonata-bridge.ts). Stale in either causes silent
# bugs — broken Resume button (2026-05-05) or workers on old bridge
# (2026-05-06). Keep both in lockstep.
echo "==> rsync resources → Contents/Resources/ AND Sonata_Sonata.bundle/"
_rsync "$REPO/Sources/Sonata/Resources/" "$SCOUT_HOST:$SCOUT_APP/Contents/Resources/"
_rsync "$REPO/Sources/Sonata/Resources/" "$SCOUT_HOST:$SCOUT_APP/Sonata_Sonata.bundle/"

# ---- codesign in /tmp then mv (critical) ----

# scp's chunked write breaks the adhoc page-hash signature even though the
# bytes match. Without re-signing, AMFI does cs_invalid_page → SIGKILL on
# launch with no stderr. Sign the standalone Mach-O in /tmp first (codesign
# refuses to sign IN PLACE inside the SwiftPM-malformed .app bundle root),
# THEN mv into position. Confirmed 2026-05-12.
echo "==> codesign in /tmp then mv into bundle"
_ssh "codesign --remove-signature /tmp/Sonata.new 2>/dev/null || true
      codesign --force --sign - /tmp/Sonata.new
      mv /tmp/Sonata.new $SCOUT_APP/Contents/MacOS/Sonata
      # Re-sign plugin binaries in place too — they're standalone Mach-Os,
      # not bundled, so in-place signing works for them.
      codesign --remove-signature ~/.sonata/plugins/sonata-studio/bin/sonata-studio 2>/dev/null || true
      codesign --force --sign - ~/.sonata/plugins/sonata-studio/bin/sonata-studio 2>/dev/null || true
      codesign --force --sign - ~/.sonata/plugins/sonar/bin/sonar 2>/dev/null || true
      echo resigned"

# ---- restart ----

if [ "$DO_RESTART" -eq 1 ]; then
  echo "==> quit + relaunch Sonata on Scout"
  _ssh "osascript -e 'tell application \"Sonata\" to quit' 2>/dev/null || true
        for i in \$(seq 1 15); do pgrep -f '/Applications/Sonata.app/Contents/MacOS/Sonata' > /dev/null || break; sleep 1; done
        pkill -KILL -f '/Applications/Sonata.app/Contents/MacOS/Sonata' 2>/dev/null || true
        sleep 2
        open $SCOUT_APP"

  echo "==> waiting up to ${BRIDGE_STARTUP_TIMEOUT}s for Scout's bridge on :3211"
  # POST-with-init probe over ssh; a plain GET to /mcp would hang on the
  # SSE stream and false-negative even against a healthy bridge.
  BRIDGE_PROBE="curl -s -o /dev/null -w '%{http_code}' --max-time 3 -X POST '$SCOUT_BRIDGE_URL/mcp' \
    -H 'Authorization: Bearer probe' \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"deploy-scout\",\"version\":\"1\"}}}' 2>/dev/null"
  ok=0
  for i in $(seq 1 "$BRIDGE_STARTUP_TIMEOUT"); do
    CODE="$(_ssh "$BRIDGE_PROBE" 2>/dev/null || true)"
    if [ -n "$CODE" ] && [ "$CODE" != "000" ]; then
      ok=1; break
    fi
    sleep 1
  done
  if [ "$ok" -eq 0 ]; then
    echo "ERROR: Scout's Sonata bridge (:3211) not reachable after ${BRIDGE_STARTUP_TIMEOUT}s" >&2
    exit 1
  fi
  echo "==> Scout bridge healthy"

  # Recover stale status=failed rows caused by the healthcheck timing out
  # before slow plugins (like sonar's Elixir/Erlang VM) finish booting.
  # The process is alive; the row is just wrong.
  _ssh "sqlite3 ~/.sonata/sonata.db \"UPDATE plugins SET status='running' WHERE status='failed';\""
fi

# ---- plugin drift ----

if [ "$SKIP_PLUGINS" -eq 1 ]; then
  echo "==> --skip-plugins: not touching Scout's plugins"
  echo "==> deploy-scout done"
  exit 0
fi

if [ "$DO_RESTART" -eq 0 ]; then
  echo "==> --skip-restart: Scout's Sonata bridge may not be up; skipping plugin drift"
  echo "==> deploy-scout done"
  exit 0
fi

# Drift is measured LOCALLY (against local source). If the local plugin
# tree has changes that Scout should also have, ship them. Local drift
# is the right signal because Scout's installed .deployed-sha will lag
# any local commit until we push.
echo "==> checking managed plugin drift (local source vs local installed sha)"
DRIFTED=$("$REPO/scripts/check-plugin-drift.sh" --names-only --quiet 2>/dev/null || true)
if [ -z "$DRIFTED" ]; then
  echo "==> managed plugins: clean locally — Scout inherits"
  echo "==> deploy-scout done"
  exit 0
fi

echo "==> local plugins with drift:"
while IFS= read -r p; do [ -n "$p" ] && echo "     - $p"; done <<< "$DRIFTED"

# Filter against what's ACTUALLY installed on Scout — never force-install a
# plugin Scout doesn't already have. A plugin can be intentionally absent on
# one host (e.g. prstar isn't on Scout, only on evan-mac).
SCOUT_INSTALLED="$(_ssh "sqlite3 -readonly ~/.sonata/sonata.db \"SELECT name FROM plugins WHERE mode='managed'\"")"
echo "==> Scout's installed managed plugins:"
while IFS= read -r p; do [ -n "$p" ] && echo "     - $p"; done <<< "$SCOUT_INSTALLED"

TO_SYNC=""
SKIPPED=()
while IFS= read -r p; do
  [ -z "$p" ] && continue
  if printf '%s\n' "$SCOUT_INSTALLED" | /usr/bin/grep -qxF "$p"; then
    TO_SYNC="${TO_SYNC:+$TO_SYNC$'\n'}$p"
  else
    SKIPPED+=("$p")
  fi
done <<< "$DRIFTED"

if [ "${#SKIPPED[@]}" -gt 0 ]; then
  echo "==> skipping plugins not installed on Scout:"
  for p in "${SKIPPED[@]}"; do echo "     - $p (drifted locally, not present on Scout)"; done
fi

if [ -z "$TO_SYNC" ]; then
  echo "==> nothing to sync to Scout"
  echo "==> deploy-scout done"
  exit 0
fi

echo "==> syncing drifted plugins to Scout:"
while IFS= read -r p; do [ -n "$p" ] && echo "     - $p"; done <<< "$TO_SYNC"

FAILED=()
while IFS= read -r p; do
  [ -z "$p" ] && continue
  if ! "$REPO/scripts/deploy-plugin-scout.sh" "$p"; then
    FAILED+=("$p")
  fi
done <<< "$TO_SYNC"

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo >&2
  echo "==> WARN: Scout's Sonata is deployed, but ${#FAILED[@]} plugin(s) FAILED on Scout:" >&2
  for p in "${FAILED[@]}"; do echo "     - $p" >&2; done
  echo "==> retry each with:  ./scripts/deploy-plugin-scout.sh <name>" >&2
else
  echo "==> Scout plugin sync complete"
fi

echo "==> deploy-scout done"
