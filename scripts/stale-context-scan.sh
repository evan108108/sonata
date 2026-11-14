#!/usr/bin/env bash
# stale-context-scan.sh — find a name in every file that loads into a Claude
# session WITHOUT a recall, so retiring something edits all of them at once.
#
# Usage: stale-context-scan.sh <term> [<term>...]
#   Each term is matched case-insensitively as a fixed string (no regex).
#   Example: stale-context-scan.sh 192.168.0.17 '.17 '
#   Prefer the bare identifier: '.17 ' (trailing space) misses ".17," ".17)" ".17."
#   On 11/14 that was 5 of the 8 .17 lines in the worker MEMORY.md; '.17' found all 8.
#
# Why: a stale line in always-loaded context beats any recalled correction,
# because the stale line is already in context and recall never runs (11/13:
# a ".17" line in the worker MEMORY.md beat the importance-9 "retired" memory).
# Retiring X means: run this with X, then edit every hit in the same change.
#
# Scanned, in this order:
#   1. ~/.claude/CLAUDE.md
#   2. ~/.sonata/*/CLAUDE.md                     (worker, supervisor, sidecar…)
#   3. ~/.claude/projects/*/memory/MEMORY.md     (harness auto-memory indexes)
#   4. ~/.claude/skills/**/SKILL.md              (installed: personal, Sonata-bundled,
#                                                 plugin-installed, synced)
#   5. <Sonata repo>/Sources/Sonata/Resources/skills/*/SKILL.md (bundled-skill SOURCE:
#        ensureBundledSkills() copies these over ~/.claude/skills on every launch)
#   6. ~/.sonata/plugins/*/skills/*/SKILL.md     (plugin-skill SOURCE: PluginManager
#        copies these over ~/.claude/skills on plugin install)
# An edit to an installed copy of a bundled or plugin skill is reverted on the
# next launch/install; the per-file summary names the source to edit instead.
#
# Output: file:line:text for each matching line, then a count per file, then
# the number of files scanned (so an empty result is distinguishable from a
# scan that read nothing).
# Exit: 0 = hits found, 1 = no hits, 2 = usage error or nothing to scan
# (grep's convention).
#
# NOTE: ~/.claude/projects/* directory names start with '-'. Every grep here
# passes the file after `--`, or grep would read the path as options and
# print nothing for it (learning f8a61fd5).

set -u

if [ $# -lt 1 ]; then
  echo "usage: $(basename "$0") <term> [<term>...]" >&2
  exit 2
fi

SONATA_REPO="${SONATA_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
BUNDLED_SKILLS_SRC="$SONATA_REPO/Sources/Sonata/Resources/skills"
PLUGINS_DIR="$HOME/.sonata/plugins"
SKILLS_DIR="$HOME/.claude/skills"

# One -e per term: a term beginning with '-' stays a pattern, never an option.
PATTERN_ARGS=()
for term in "$@"; do
  PATTERN_ARGS+=(-e "$term")
done

list_files() {
  local f
  [ -f "$HOME/.claude/CLAUDE.md" ] && printf '%s\n' "$HOME/.claude/CLAUDE.md"
  for f in "$HOME"/.sonata/*/CLAUDE.md "$HOME"/.claude/projects/*/memory/MEMORY.md; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  # Any depth (synced skills nest one level down); skip dot-dirs like .staging.
  if [ -d "$SKILLS_DIR" ]; then
    find "$SKILLS_DIR" -type f -name SKILL.md | grep -v -- '/skills/.*/\.' | sort
  fi
  if [ -d "$BUNDLED_SKILLS_SRC" ]; then
    find "$BUNDLED_SKILLS_SRC" -mindepth 2 -maxdepth 2 -type f -name SKILL.md | sort
  fi
  if [ -d "$PLUGINS_DIR" ]; then
    find "$PLUGINS_DIR" -mindepth 4 -maxdepth 4 -type f -path '*/skills/*' -name SKILL.md | sort
  fi
}

# For an installed skill that gets overwritten from a source, say where the source is.
source_note() {
  local f="$1" dir slug owner
  case "$f" in
    "$SKILLS_DIR"/*/SKILL.md) ;;
    *) return 0 ;;
  esac
  dir="$(dirname "$f")"
  slug="$(basename "$dir")"
  if [ -f "$dir/.plugin-owner" ]; then
    owner="$(head -n 1 "$dir/.plugin-owner")"
    printf '  (installed by plugin %s; edit %s/%s/skills/%s/SKILL.md)' "$owner" "$PLUGINS_DIR" "$owner" "$slug"
  elif [ -f "$BUNDLED_SKILLS_SRC/$slug/SKILL.md" ]; then
    printf '  (bundled; overwritten on launch, edit %s/%s/SKILL.md)' "$BUNDLED_SKILLS_SRC" "$slug"
  fi
}

SCANNED=0
TOTAL=0
SUMMARY=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  SCANNED=$((SCANNED + 1))
  n="$(grep -c -i -F "${PATTERN_ARGS[@]}" -- "$f" 2>/dev/null)"
  n="${n:-0}"
  if [ "$n" -gt 0 ]; then
    grep -H -n -i -F "${PATTERN_ARGS[@]}" -- "$f"
    TOTAL=$((TOTAL + n))
    SUMMARY="${SUMMARY}$(printf '%6d  %s%s' "$n" "$f" "$(source_note "$f")")"$'\n'
  fi
done < <(list_files)

echo
echo "== hits per file =="
if [ -n "$SUMMARY" ]; then
  printf '%s' "$SUMMARY"
else
  echo "  (none)"
fi
echo "== $TOTAL matching line(s) in $SCANNED file(s) scanned; terms: $* =="

if [ "$SCANNED" -eq 0 ]; then
  echo "error: no files found to scan — check \$HOME and SONATA_REPO ($SONATA_REPO)" >&2
  exit 2
fi
[ "$TOTAL" -gt 0 ]
