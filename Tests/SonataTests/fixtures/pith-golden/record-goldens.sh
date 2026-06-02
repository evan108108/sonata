#!/bin/bash
# Records Llama 3.1 8B golden outputs for PithRegressionTests.swift.
#
# Run only when an explicit human review decided current goldens are no
# longer canonical (model upgrade, prompt change, etc.).
#
# Prereqs:
#   1. llama-server running on 127.0.0.1:7713 with Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf
#      llama-server -m <gguf> --host 127.0.0.1 --port 7713 \
#        --ctx-size 8192 --n-predict 256 --temp 0.3 -ngl 99
#   2. ~/.sonata/sonata.db readable (memory content is pulled by ID)
#   3. jq + curl + sqlite3 on PATH
#
# Writes:
#   pith-corpus.json   — 5 memory test cases (frozen; do not edit)
#   <memory_id>.json   — per-memory golden L0/L1 + locked config metadata
#
# Idempotent: re-running overwrites all goldens with current llama-server output.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly FIXTURES_DIR="$(dirname "$SCRIPT_DIR")"
readonly DB="$HOME/.sonata/sonata.db"
readonly CHAT_URL="http://127.0.0.1:7713/v1/chat/completions"

readonly MODEL_LABEL="llama-3.1-8b-instruct-Q4_K_M"
readonly TEMP=0.3
readonly SEED=42

readonly SYSTEM_PROMPT="You generate LOD summaries for memories. Return STRICT JSON with two fields: l0 and l1. l0 = one sentence, max ~15 words, the thesis or essence. l1 = 2-3 sentences, max ~60 words, the argument arc or key facts. Be abstractive — distill, don't quote. Match the voice of the source (first-person for reflections, third-person for technical notes). For very short input, l0/l1 may equal input. Output ONLY the JSON. No preamble, no markdown fences."

# 5 frozen memory IDs spanning reflection/code_pattern/decision/learning types
readonly MEMORY_IDS=(
  "ac0dbea881a322798ccf447d2748d0ca"
  "e2a9b42dfe26a2d8eed25a0aff23bdc1"
  "51bfa74be546415ea0a1600cb8529192"
  "9f7eae53676c6caa79af0fa02e9598e3"
  "c29e6a90ef61c0b187e256a58e4e65c2"
)

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }
}
require jq
require curl
require sqlite3

[ -r "$DB" ] || { echo "sonata.db not readable at $DB" >&2; exit 1; }

if ! curl -fs "${CHAT_URL%/v1/chat/completions}/health" >/dev/null 2>&1; then
  echo "llama-server not reachable at ${CHAT_URL%/v1/chat/completions}/health" >&2
  echo "start it with the command in the file header" >&2
  exit 1
fi

# Build corpus JSON
echo "building pith-corpus.json (${#MEMORY_IDS[@]} memories)..."
corpus_memories=()
for id in "${MEMORY_IDS[@]}"; do
  row=$(sqlite3 -separator $'\x1f' "$DB" \
    "SELECT id, type, content FROM memories WHERE id = '$id';")
  [ -n "$row" ] || { echo "memory $id not found in $DB" >&2; exit 1; }
  mem_type="${row#*$'\x1f'}"; mem_type="${mem_type%%$'\x1f'*}"
  content="${row#*$'\x1f'*$'\x1f'}"
  entry=$(jq -n \
    --arg id "$id" \
    --arg type "$mem_type" \
    --arg content "$content" \
    --argjson length "${#content}" \
    '{id: $id, type: $type, content_length: $length, content: $content}')
  corpus_memories+=("$entry")
done

jq -n \
  --arg desc "5-memory test corpus for PithRegressionTests. Frozen; do not edit content." \
  --argjson mems "$(printf '%s\n' "${corpus_memories[@]}" | jq -s '.')" \
  '{description: $desc, memories: $mems}' \
  > "$FIXTURES_DIR/pith-corpus.json"

# Record golden L0/L1 per memory
strip_fences() {
  # Strip leading ```json / ``` and trailing ```
  sed -E 's/^[[:space:]]*```(json)?[[:space:]]*//; s/[[:space:]]*```[[:space:]]*$//'
}

for id in "${MEMORY_IDS[@]}"; do
  mem=$(jq --arg id "$id" '.memories[] | select(.id == $id)' "$FIXTURES_DIR/pith-corpus.json")
  mem_type=$(echo "$mem" | jq -r .type)
  content_length=$(echo "$mem" | jq -r .content_length)
  echo "recording golden for ${id:0:12} ($mem_type, $content_length chars)..."

  content=$(echo "$mem" | jq -r .content)
  req=$(jq -n \
    --arg system "$SYSTEM_PROMPT" \
    --arg user "$content" \
    --argjson temp "$TEMP" \
    --argjson seed "$SEED" \
    '{messages: [{role:"system", content:$system}, {role:"user", content:$user}],
      max_tokens: 400, temperature: $temp, seed: $seed,
      response_format: {type: "json_object"}}')

  raw=$(curl -fs -X POST "$CHAT_URL" \
    -H 'Content-Type: application/json' \
    -d "$req" \
    | jq -r '.choices[0].message.content')

  cleaned=$(printf '%s' "$raw" | strip_fences)
  l0=$(printf '%s' "$cleaned" | jq -r .l0)
  l1=$(printf '%s' "$cleaned" | jq -r .l1)

  if [ -z "$l0" ] || [ "$l0" = "null" ] || [ -z "$l1" ] || [ "$l1" = "null" ]; then
    echo "  ERROR: parsed l0/l1 missing or null for $id" >&2
    echo "  raw response: $raw" >&2
    exit 1
  fi

  jq -n \
    --arg memory_id "$id" \
    --arg memory_type "$mem_type" \
    --arg model "$MODEL_LABEL" \
    --arg system_prompt "$SYSTEM_PROMPT" \
    --argjson temperature "$TEMP" \
    --argjson seed "$SEED" \
    --arg l0 "$l0" \
    --arg l1 "$l1" \
    --argjson l0_length "${#l0}" \
    --argjson l1_length "${#l1}" \
    '{memory_id: $memory_id, memory_type: $memory_type, model: $model,
      system_prompt: $system_prompt, temperature: $temperature, seed: $seed,
      l0: $l0, l1: $l1, l0_length: $l0_length, l1_length: $l1_length}' \
    > "$SCRIPT_DIR/$id.json"

  l0_preview="${l0:0:80}"; [ "${#l0}" -gt 80 ] && l0_preview+="..."
  l1_preview="${l1:0:80}"; [ "${#l1}" -gt 80 ] && l1_preview+="..."
  echo "  l0 (${#l0}): $l0_preview"
  echo "  l1 (${#l1}): $l1_preview"
done

echo
echo "Done. Goldens in $SCRIPT_DIR/"
echo "Verify the change is intentional, then commit."
