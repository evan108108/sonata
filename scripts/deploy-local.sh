#!/usr/bin/env bash
# deploy-local.sh — rebuild Sonata and deploy the new binary into the local
# /Applications/Sonata.app, then relaunch.
#
# Why this isn't just `cp`: SwiftPM puts the resource bundle (Sonata_Sonata.bundle)
# as a SIBLING of Contents/ at the .app root. That makes a naive in-place
# `codesign` fail with "unsealed contents present in the bundle root", and
# swapping the Mach-O without re-sealing leaves Contents/_CodeSignature pointing
# at the OLD binary's page hashes -> AMFI does cs_invalid_page -> SIGKILL the
# moment the app launches (POSIX 162 "Launchd job spawn failed", no stderr).
#
# Fix (mirrors deploy-scout's codesign discipline): move the resource bundle out
# of the app root, re-sign the whole .app (re-signs the main exec to plain adhoc
# AND regenerates CodeResources to match), then move the resource bundle back.
#
# Bridge port race: after a restart the in-app MCP server must re-bind :3211. If
# we relaunch before the old instance fully releases the port, the new instance
# comes up degraded ("Cannot reach Sonata server" in the Plugins tab). So we wait
# for :3211 to free before relaunch, and after launch poll :3211 and auto-restart
# once if it didn't bind.
#
# Live progress: when run in a terminal, the build phase shows an animated bar.
# When run non-interactively (backgrounded to a log), it prints plain build output.
# To watch a backgrounded run from another terminal:
#   ! /Users/evan/memory/Sonata/scripts/build-status.sh
#
# Usage:
#   ./scripts/deploy-local.sh             # swift build -c release + deploy + relaunch
#   ./scripts/deploy-local.sh --no-build  # deploy the existing .build/release binary
#   ./scripts/deploy-local.sh --no-launch # swap the binary but don't relaunch
set -euo pipefail

REPO="/Users/evan/memory/Sonata"
APP="/Applications/Sonata.app"
BIN_DST="$APP/Contents/MacOS/Sonata"
BIN_SRC="$REPO/.build/release/Sonata"
RESOURCE_BUNDLE="$APP/Sonata_Sonata.bundle"
TMP_BUNDLE="/tmp/Sonata_Sonata.bundle.deploytmp"
BRIDGE_URL="http://localhost:3211/mcp"

BUILD=1; LAUNCH=1; BAR=0
for a in "$@"; do
  case "$a" in
    --no-build)  BUILD=0 ;;
    --no-launch) LAUNCH=0 ;;
    --bar|--live) BAR=1 ;;   # force the animated build bar even without a TTY
    -h|--help)   sed -n '1,34p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

# Always restore the resource bundle to the app root, even if signing aborts,
# so a failed run never leaves the .app structurally broken.
restore_bundle() { [ -d "$TMP_BUNDLE" ] && mv "$TMP_BUNDLE" "$RESOURCE_BUNDLE" 2>/dev/null || true; }
trap restore_bundle EXIT

port_3211_bound() { lsof -nP -iTCP:3211 -sTCP:LISTEN >/dev/null 2>&1; }

# Server-up check: the bridge answering with ANY http code (even 401 for a bad
# token) means it bound :3211. Connection-refused (000) means it didn't.
bridge_up() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 -X POST "$BRIDGE_URL" \
    -H "Authorization: Bearer ${SONA_SESSION_ID:-probe}" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"deploy-local","version":"1"}}}' \
    2>/dev/null) || true
  [ -n "$code" ] && [ "$code" != "000" ]
}

quit_app() {
  osascript -e 'tell application "Sonata" to quit' 2>/dev/null || true
  for _ in $(seq 1 15); do pgrep -f "$BIN_DST" >/dev/null || break; sleep 1; done
  pkill -KILL -f "$BIN_DST" 2>/dev/null || true
  for _ in $(seq 1 20); do port_3211_bound || break; sleep 1; done
}

# Animated build bar (terminal only). $1=build pid, $2=build log.
render_build() {
  local bpid=$1 log=$2 start si=0 maxm=0 bw=34
  start=$(date +%s)
  local SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' C_C=$'\033[36m' C_G=$'\033[32m' C_D=$'\033[2m' C_R=$'\033[0m'
  while kill -0 "$bpid" 2>/dev/null; do
    local sp=${SPIN:si++%${#SPIN}:1} e=$(( $(date +%s) - start ))
    local nm n m label
    nm=$(grep -oE '\[[0-9]+/[0-9]+\]' "$log" 2>/dev/null | tail -1 | tr -d '[]' || true)
    n=${nm%/*}; m=${nm#*/}
    label=$(grep -oE '\[[0-9]+/[0-9]+\][^[]*' "$log" 2>/dev/null | tail -1 | sed -E 's/\[[0-9]+\/[0-9]+\] *//' | cut -c1-36 || true)
    local pct=0 tag="compiling"
    if [ -n "${n:-}" ] && [ -n "${m:-}" ] && [ "$m" -gt 0 ]; then
      if [ "$m" -ge "$maxm" ]; then maxm=$m; pct=$(( n * 100 / m ));
      else pct=99; tag="linking"; fi      # small counter after the big build = final link
    fi
    local fill=$(( pct * bw / 100 )) bar="" i
    for ((i=0;i<bw;i++)); do [ $i -lt $fill ] && bar+="█" || bar+="░"; done
    printf '\r\033[K  %s building %s[%s]%s %s%3d%%%s %02d:%02d %s%s%s' \
      "$sp" "$C_C" "$bar" "$C_R" "$C_G" "$pct" "$C_R" $((e/60)) $((e%60)) "$C_D" "${label:-$tag}" "$C_R"
    sleep 2
  done
  printf '\r\033[K'
}

cd "$REPO"

if [ "$BUILD" -eq 1 ]; then
  if [ -t 1 ] || [ "$BAR" -eq 1 ]; then
    # Interactive terminal: build in the background and animate a progress bar.
    BLOG="/tmp/sonata-build.$$.log"; : > "$BLOG"
    swift build -c release > "$BLOG" 2>&1 &
    bpid=$!
    render_build "$bpid" "$BLOG"
    if ! wait "$bpid"; then echo "ERROR: swift build failed:"; tail -25 "$BLOG"; exit 1; fi
    echo "==> $(grep -aE 'Build complete' "$BLOG" | tail -1 | sed 's/^ *//' || true)"
  else
    # Non-interactive (backgrounded to a log): plain streaming output.
    echo "==> swift build -c release"
    swift build -c release
  fi
fi
[ -f "$BIN_SRC" ] || { echo "ERROR: $BIN_SRC not found — build first (drop --no-build)"; exit 1; }

echo "==> HEAD: $(git -C "$REPO" log -1 --format='%h %s')"
[ -f "$BIN_DST" ] && cp "$BIN_DST" "/tmp/Sonata.binary.backup.$$" 2>/dev/null || true

echo "==> quitting Sonata.app (and waiting for :3211 to free)"
quit_app

echo "==> swapping binary ($(stat -f '%z' "$BIN_SRC") bytes)"
cp "$BIN_SRC" "$BIN_DST"

echo "==> re-sealing bundle (move resource bundle out, sign .app, move back)"
mv "$RESOURCE_BUNDLE" "$TMP_BUNDLE"
codesign --force --sign - "$APP"
mv "$TMP_BUNDLE" "$RESOURCE_BUNDLE"

if [ "$LAUNCH" -eq 0 ]; then
  echo "==> binary swapped (--no-launch); not relaunching"
  echo "==> deploy-local done"
  exit 0
fi

# Launch, then verify the bridge actually bound :3211. If not (port-bind race),
# restart once. This is the failure that otherwise needs a manual restart.
for attempt in 1 2; do
  echo "==> launch attempt $attempt"
  open "$APP"
  ok=0
  for _ in $(seq 1 25); do
    if bridge_up; then ok=1; break; fi
    sleep 1
  done
  if [ "$ok" -eq 1 ]; then
    echo "==> bridge up on :3211; pid $(pgrep -f "$BIN_DST" | head -1)"
    break
  fi
  echo "WARN: bridge not reachable on :3211 after launch attempt $attempt (port-bind race) — restarting"
  quit_app
done

if ! bridge_up; then
  echo "ERROR: Sonata bridge (:3211) not reachable after 2 launch attempts — check the Plugins tab / Console" >&2
  exit 1
fi
echo "==> deploy-local done (bridge healthy)"
