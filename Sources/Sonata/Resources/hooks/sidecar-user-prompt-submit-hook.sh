#!/bin/bash
# Sidecar UserPromptSubmit hook — dumb pipe to Sonata.
#
# Claude Code fires this on every user prompt with a JSON blob on stdin
# (session_id, prompt, cwd, transcript_path, hook_event_name). We forward
# the raw blob to Sonata's synchronous synthesize endpoint. Sonata does
# distillation + recall + filter + format server-side and returns the
# hint block (or empty). Whatever we print here gets prepended to the
# user's prompt by Claude Code.
#
# Fail-silent design: any curl/jq/Sonata failure emits nothing and exits
# 0. A broken sidecar must never break a prompt.
#
# --max-time 2 caps latency at 2s; Claude Code's own hook timeout is set
# to 3s in ~/.claude/settings.json, so we always exit before that.

set +e
input=$(cat)
curl -sS --max-time 2 \
  -X POST -H 'Content-Type: application/json' \
  --data-binary "$input" \
  http://127.0.0.1:${SONATA_PORT:-3211}/api/sidecar/hint/synthesize 2>/dev/null \
  | /usr/bin/jq -r '.content // ""' 2>/dev/null
exit 0
