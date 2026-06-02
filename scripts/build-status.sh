#!/usr/bin/env bash
# build-status.sh — live progress bar for a deploy-local.sh run.
# Watch a deploy in real time:   ! /Users/evan/memory/Sonata/scripts/build-status.sh
# (parses swift build's [N/M] step counter from the deploy log and animates a bar)

LOG="${1:-/tmp/deploy-local.log}"
BW=34                          # bar width
START=$(date +%s)
SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'; si=0
C_G=$'\033[32m'; C_C=$'\033[36m'; C_Y=$'\033[33m'; C_D=$'\033[2m'; C_R=$'\033[0m'

bar() {                        # $1=filled-count
  local f=$1 s="" i
  for ((i=0;i<BW;i++)); do [ $i -lt "$f" ] && s+="█" || s+="░"; done
  printf '%s' "$s"
}

elapsed() { local e=$(( $(date +%s) - START )); printf '%02d:%02d' $((e/60)) $((e%60)); }

while true; do
  sp=${SPIN:si++%${#SPIN}:1}

  if [ -f "$LOG" ] && grep -q "deploy-local done" "$LOG"; then
    printf '\r\033[K  %s✅ deploy complete%s  (%s)\n' "$C_G" "$C_R" "$(elapsed)"
    grep -E '^==>|^WARN' "$LOG" | tail -10 | sed 's/^/    /'
    exit 0
  fi
  if [ -f "$LOG" ] && grep -qE '^ERROR' "$LOG"; then
    printf '\r\033[K  ❌ deploy failed  (%s)\n' "$(elapsed)"
    tail -6 "$LOG" | sed 's/^/    /'
    exit 1
  fi

  # In the deploy phase (build finished, swapping/relaunching)?
  if [ -f "$LOG" ] && grep -qE '^==> (quitting|swapping|re-sealing|launch)' "$LOG"; then
    phase=$(grep -E '^==>|^WARN' "$LOG" | tail -1 | sed -E 's/^==> //')
    printf '\r\033[K  %s %sdeploy%s  %s  %s' "$sp" "$C_Y" "$C_R" "$(elapsed)" "$phase"
  else
    # Build phase — latest [N/M].
    nm=$(grep -oE '\[[0-9]+/[0-9]+\]' "$LOG" 2>/dev/null | tail -1 | tr -d '[]')
    n=${nm%/*}; m=${nm#*/}
    label=$(grep -oE '\[[0-9]+/[0-9]+\][^[]*' "$LOG" 2>/dev/null | tail -1 | sed -E 's/\[[0-9]+\/[0-9]+\] *//' | cut -c1-38)
    if [ -n "$n" ] && [ -n "$m" ] && [ "$m" -gt 0 ]; then
      pct=$(( n * 100 / m )); fill=$(( pct * BW / 100 ))
      printf '\r\033[K  %s [%s%s%s] %s%3d%%%s  %s%s/%s%s  %s  %s%s%s' \
        "$sp" "$C_C" "$(bar $fill)" "$C_R" "$C_G" "$pct" "$C_R" \
        "$C_D" "$n" "$m" "$C_R" "$(elapsed)" "$C_D" "${label:-compiling}" "$C_R"
    else
      printf '\r\033[K  %s %sstarting build…%s  %s' "$sp" "$C_D" "$C_R" "$(elapsed)"
    fi
  fi

  # Safety: bail if nothing's running and no log progress for a while.
  if ! pgrep -f 'swift-build|deploy-local.sh' >/dev/null 2>&1 \
     && [ -f "$LOG" ] && ! grep -qE '^==>' "$LOG"; then
    printf '\r\033[K  %s⚠ no active build/deploy — is one running?%s\n' "$C_Y" "$C_R"; exit 2
  fi
  sleep 1
done
