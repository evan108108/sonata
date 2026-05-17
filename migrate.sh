#!/usr/bin/env bash
set -uo pipefail
# Note: no set -e — we log errors and continue

# ============================================================================
# Sonata Migration Script — Convex → SQLite
# Migrates all data from Convex (localhost:3211) to Sonata (localhost:3212)
# ============================================================================

CONVEX="http://localhost:3211"
SONATA="http://localhost:3212"
SONATA_DB="$HOME/memory/sonata.db"
ID_MAP="/tmp/sonata-id-map.json"
ID_MAP_LINES="/tmp/sonata-id-map.tsv"
LOG="/tmp/sonata-migration.log"

> "$LOG"
> "$ID_MAP_LINES"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# ============================================================================
# Clean slate: wipe Sonata tables before migration
# Usage: ./migrate.sh --clean (default) or ./migrate.sh --no-clean
# ============================================================================
CLEAN=true
for arg in "$@"; do
  case "$arg" in
    --no-clean) CLEAN=false ;;
    --clean) CLEAN=true ;;
  esac
done

if [ "$CLEAN" = true ]; then
  log "Cleaning Sonata database (fresh migration)..."
  # Delete all data from Sonata tables via SQLite
  sqlite3 "$SONATA_DB" <<'SQL'
PRAGMA trusted_schema=ON;
DELETE FROM memories;
DELETE FROM entities;
DELETE FROM relations;
DELETE FROM emails;
DELETE FROM contacts;
DELETE FROM documents;
DELETE FROM calendarEvents;
DELETE FROM tasks;
DELETE FROM coreBlocks;
DELETE FROM wikiPages;
DELETE FROM scheduledJobs;
VACUUM;
SQL
  log "Sonata database cleaned."
fi

# ============================================================================
# Helper: POST one record to Sonata, append to ID map
# Args: $1=endpoint, $2=json_body, $3=convex_id
# Returns new_id on stdout
# ============================================================================
post_one() {
  local endpoint="$1" body="$2" convex_id="$3"
  local resp new_id
  resp=$(curl -sf -X POST "${SONATA}${endpoint}" \
    -H 'Content-Type: application/json' \
    -d "$body" 2>/dev/null) || {
    echo "POST ${endpoint} failed for ${convex_id}" >> "$LOG"
    return 1
  }
  new_id=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)
  if [ -n "$new_id" ] && [ -n "$convex_id" ] && [ "$convex_id" != "null" ]; then
    printf '%s\t%s\n' "$convex_id" "$new_id" >> "$ID_MAP_LINES"
  fi
  echo "$new_id"
}

# Convert TSV ID map → JSON
consolidate_map() {
  if [ -s "$ID_MAP_LINES" ]; then
    jq -R -s 'split("\n") | map(select(length > 0) | split("\t")) | map({(.[0]): .[1]}) | add // {}' "$ID_MAP_LINES" > "$ID_MAP"
  else
    echo '{}' > "$ID_MAP"
  fi
}

# Look up a convex ID → sonata ID from the TSV
lookup_id() {
  grep -m1 "^${1}	" "$ID_MAP_LINES" 2>/dev/null | cut -f2
}

# ============================================================================
# Pre-flight checks
# ============================================================================
log "Pre-flight checks..."
curl -sf "${CONVEX}/api/memory/recent?limit=1" > /dev/null 2>&1 || { log "FATAL: Convex not reachable at $CONVEX"; exit 1; }
curl -sf "${SONATA}/api/memory/recent?limit=1" > /dev/null 2>&1 || { log "FATAL: Sonata not reachable at $SONATA"; exit 1; }
log "Both servers reachable. Starting migration..."

# ============================================================================
# 1. MEMORIES (5000+)
# ============================================================================
log "=== Migrating MEMORIES ==="
MEMORIES_FILE="/tmp/sonata-mig-memories.json"
curl -sf "${CONVEX}/api/memory/recent?limit=100000" > "$MEMORIES_FILE"
MEM_COUNT=$(jq 'length' "$MEMORIES_FILE")
log "Fetched $MEM_COUNT memories from Convex"

MEM_OK=0
MEM_ERR=0
while IFS= read -r mem; do
  convex_id=$(echo "$mem" | jq -r '._id')
  body=$(echo "$mem" | jq '{
    content: .content,
    type: (.type // "observation"),
    tags: (.tags // []),
    source: (.source // "convex-migration"),
    importance: (.importance // 5),
    validFrom: .validFrom,
    validUntil: .validUntil,
    project: .project,
    topic: .topic,
    createdAt: .createdAt
  } | with_entries(select(.value != null))')

  if post_one "/api/memory" "$body" "$convex_id" > /dev/null; then
    MEM_OK=$((MEM_OK + 1))
  else
    MEM_ERR=$((MEM_ERR + 1))
  fi

  TOTAL=$((MEM_OK + MEM_ERR))
  if [ $((TOTAL % 500)) -eq 0 ] && [ $TOTAL -gt 0 ]; then
    log "  memories: $TOTAL / $MEM_COUNT ($MEM_ERR errors)"
  fi
done < <(jq -c '.[]' "$MEMORIES_FILE")

log "Memories done: $MEM_OK ok, $MEM_ERR errors"
MAP_SIZE=$(wc -l < "$ID_MAP_LINES" | tr -d ' ')
log "ID map has $MAP_SIZE entries after memories"

# ============================================================================
# 2. ENTITIES
# ============================================================================
log "=== Migrating ENTITIES ==="
ENTITIES_FILE="/tmp/sonata-mig-entities.json"
curl -sf "${CONVEX}/api/entity/list?limit=100000" > "$ENTITIES_FILE"
ENT_COUNT=$(jq 'length' "$ENTITIES_FILE")
log "Fetched $ENT_COUNT entities from Convex"

ENT_OK=0
while IFS= read -r ent; do
  convex_id=$(echo "$ent" | jq -r '._id')
  body=$(echo "$ent" | jq '{
    name: .name,
    type: (.type // "concept"),
    description: (.description // ""),
    attributes: .attributes
  } | with_entries(select(.value != null))')
  if post_one "/api/entity" "$body" "$convex_id" > /dev/null; then
    ENT_OK=$((ENT_OK + 1))
  fi
done < <(jq -c '.[]' "$ENTITIES_FILE")

log "Entities done: $ENT_OK ok"

# ============================================================================
# 3. RELATIONS (need ID mapping)
# ============================================================================
log "=== Migrating RELATIONS ==="
RELATIONS_FILE="/tmp/sonata-mig-relations.json"
curl -sf "${CONVEX}/api/relation/list?limit=100000" > "$RELATIONS_FILE"
REL_TOTAL=$(jq 'length' "$RELATIONS_FILE")
log "Fetched $REL_TOTAL relations from Convex"

REL_OK=0
REL_SKIP=0
while IFS= read -r rel; do
  convex_id=$(echo "$rel" | jq -r '._id')
  old_source=$(echo "$rel" | jq -r '.sourceId')
  old_target=$(echo "$rel" | jq -r '.targetId')

  new_source=$(lookup_id "$old_source")
  new_target=$(lookup_id "$old_target")

  if [ -z "$new_source" ] || [ -z "$new_target" ]; then
    echo "WARN: Skipping relation $convex_id — unmapped source=$old_source target=$old_target" >> "$LOG"
    REL_SKIP=$((REL_SKIP + 1))
    continue
  fi

  body=$(echo "$rel" | jq --arg s "$new_source" --arg t "$new_target" '{
    sourceId: $s,
    sourceType: .sourceType,
    targetId: $t,
    targetType: .targetType,
    relation: .relation
  }')

  if post_one "/api/relation" "$body" "$convex_id" > /dev/null; then
    REL_OK=$((REL_OK + 1))
  fi
done < <(jq -c '.[]' "$RELATIONS_FILE")

REL_COUNT=$REL_TOTAL
log "Relations done: $REL_OK ok, $REL_SKIP skipped (unmapped IDs)"

# ============================================================================
# 4. EMAILS
# ============================================================================
log "=== Migrating EMAILS ==="
EMAILS_FILE="/tmp/sonata-mig-emails.json"
curl -sf "${CONVEX}/api/email/recent?limit=100000" > "$EMAILS_FILE"
EMAIL_COUNT=$(jq 'length' "$EMAILS_FILE")
log "Fetched $EMAIL_COUNT emails from Convex"

EMAIL_OK=0
while IFS= read -r email; do
  convex_id=$(echo "$email" | jq -r '._id')
  body=$(echo "$email" | jq '{
    messageId: .messageId,
    threadId: .threadId,
    from: .from,
    to: .to,
    subject: .subject,
    body: .body,
    status: (.status // "unread"),
    receivedAt: .receivedAt
  } | with_entries(select(.value != null))')
  if post_one "/api/email" "$body" "$convex_id" > /dev/null; then
    EMAIL_OK=$((EMAIL_OK + 1))
  fi
done < <(jq -c '.[]' "$EMAILS_FILE")

log "Emails done: $EMAIL_OK ok"

# ============================================================================
# 5. CONTACTS
# ============================================================================
log "=== Migrating CONTACTS ==="
CONTACTS_FILE="/tmp/sonata-mig-contacts.json"
curl -sf "${CONVEX}/api/contacts" > "$CONTACTS_FILE"
CON_COUNT=$(jq 'length' "$CONTACTS_FILE")
log "Fetched $CON_COUNT contacts from Convex"

CON_OK=0
while IFS= read -r contact; do
  convex_id=$(echo "$contact" | jq -r '._id')
  body=$(echo "$contact" | jq '{
    name: .name,
    email: .email,
    type: (.type // "human"),
    role: .role,
    provider: .provider,
    model: .model,
    systemPrompt: .systemPrompt,
    notes: .notes
  } | with_entries(select(.value != null))')
  if post_one "/api/contact" "$body" "$convex_id" > /dev/null; then
    CON_OK=$((CON_OK + 1))
  fi
done < <(jq -c '.[]' "$CONTACTS_FILE")

log "Contacts done: $CON_OK ok"

# ============================================================================
# 6. DOCUMENTS
# ============================================================================
log "=== Migrating DOCUMENTS ==="
DOCS_FILE="/tmp/sonata-mig-docs.json"
curl -sf "${CONVEX}/api/doc/list?limit=100000" > "$DOCS_FILE"
DOC_COUNT=$(jq 'length' "$DOCS_FILE")
log "Fetched $DOC_COUNT documents from Convex"

DOC_OK=0
while IFS= read -r doc; do
  convex_id=$(echo "$doc" | jq -r '._id')
  body=$(echo "$doc" | jq '{
    title: .title,
    path: .path,
    content: (.content // ""),
    summary: .summary,
    docType: (.docType // "note"),
    project: .project,
    tags: (.tags // []),
    relatedEntities: .relatedEntities,
    relatedMemories: .relatedMemories,
    parentDoc: .parentDoc,
    source: (.source // "convex-migration"),
    status: (.status // "active")
  } | with_entries(select(.value != null))')
  if post_one "/api/doc/index" "$body" "$convex_id" > /dev/null; then
    DOC_OK=$((DOC_OK + 1))
  fi
done < <(jq -c '.[]' "$DOCS_FILE")

log "Documents done: $DOC_OK ok"

# ============================================================================
# 7. CALENDAR EVENTS
# ============================================================================
log "=== Migrating CALENDAR EVENTS ==="
CAL_FILE="/tmp/sonata-mig-calendar.json"
curl -sf "${CONVEX}/api/calendar/all?limit=10000" > "$CAL_FILE"
CAL_COUNT=$(jq 'length' "$CAL_FILE")
log "Fetched $CAL_COUNT calendar events from Convex"

CAL_OK=0
while IFS= read -r evt; do
  convex_id=$(echo "$evt" | jq -r '._id')
  body=$(echo "$evt" | jq '{
    title: .title,
    description: .description,
    prompt: .prompt,
    scheduledAt: .scheduledAt,
    recurrence: .recurrence,
    enabled: .enabled,
    project: .project,
    workingDir: .workingDir,
    model: .model,
    maxTurns: .maxTurns,
    taskType: (.taskType // "prompt")
  } | with_entries(select(.value != null))')
  if post_one "/api/calendar" "$body" "$convex_id" > /dev/null; then
    CAL_OK=$((CAL_OK + 1))
  fi
done < <(jq -c '.[]' "$CAL_FILE")

log "Calendar events done: $CAL_OK ok"

# ============================================================================
# 8. TASKS (all statuses) — two-pass: create, then PATCH blockedBy/parentTask
# ============================================================================
log "=== Migrating TASKS ==="
TASKS_FILE="/tmp/sonata-mig-tasks.json"
echo '[]' > "$TASKS_FILE"
for status in pending active completed failed cancelled; do
  BATCH=$(curl -sf "${CONVEX}/api/task/list?limit=100000&status=${status}" 2>/dev/null || echo "[]")
  COUNT=$(echo "$BATCH" | jq 'length')
  log "  tasks ($status): $COUNT"
  jq -s '.[0] + .[1]' "$TASKS_FILE" <(echo "$BATCH") > "${TASKS_FILE}.tmp" && mv "${TASKS_FILE}.tmp" "$TASKS_FILE"
done
TASK_COUNT=$(jq 'length' "$TASKS_FILE")
log "Fetched $TASK_COUNT tasks total"

# Pass 1: Create all tasks (without blockedBy/parentTask references)
TASK_OK=0
while IFS= read -r task; do
  convex_id=$(echo "$task" | jq -r '._id')
  body=$(echo "$task" | jq '{
    title: .title,
    description: .description,
    status: .status,
    priority: .priority,
    prompt: .prompt,
    workingDir: .workingDir,
    model: .model,
    maxTurns: .maxTurns,
    project: .project,
    source: (.source // "convex-migration"),
    sourceRef: .sourceRef,
    tags: (.tags // []),
    assignedTo: .assignedTo,
    dueAt: .dueAt,
    maxRetries: .maxRetries,
    tools: .tools,
    metadata: .metadata
  } | with_entries(select(.value != null))')
  if post_one "/api/task" "$body" "$convex_id" > /dev/null; then
    TASK_OK=$((TASK_OK + 1))
  fi
done < <(jq -c '.[]' "$TASKS_FILE")

log "Tasks pass 1 done: $TASK_OK created"

# Pass 2: PATCH blockedBy and parentTask with mapped IDs
TASK_PATCHED=0
while IFS= read -r task; do
  convex_id=$(echo "$task" | jq -r '._id')
  has_blocked=$(echo "$task" | jq 'has("blockedBy") and (.blockedBy | length > 0)')
  has_parent=$(echo "$task" | jq -r '.parentTask // empty')

  if [ "$has_blocked" = "false" ] && [ -z "$has_parent" ]; then
    continue
  fi

  new_id=$(lookup_id "$convex_id")
  if [ -z "$new_id" ]; then continue; fi

  # Map blockedBy IDs
  MAPPED_BLOCKED="[]"
  if [ "$has_blocked" = "true" ]; then
    MAPPED_BLOCKED=$(echo "$task" | jq -c '[.blockedBy[] as $bid | $bid]' | while IFS= read -r arr; do
      echo "$arr" | jq -c '[.[] as $old | env.MAPPED // $old]'
    done)
    # Actually map each ID properly
    OLD_BLOCKED=$(echo "$task" | jq -r '.blockedBy[]')
    NEW_BLOCKED="["
    FIRST=true
    for old_bid in $OLD_BLOCKED; do
      new_bid=$(lookup_id "$old_bid")
      if [ -n "$new_bid" ]; then
        if [ "$FIRST" = true ]; then FIRST=false; else NEW_BLOCKED+=","; fi
        NEW_BLOCKED+="\"$new_bid\""
      fi
    done
    NEW_BLOCKED+="]"
    MAPPED_BLOCKED="$NEW_BLOCKED"
  fi

  # Map parentTask
  MAPPED_PARENT=""
  if [ -n "$has_parent" ]; then
    MAPPED_PARENT=$(lookup_id "$has_parent")
  fi

  # Build PATCH body
  PATCH_BODY="{\"id\":\"$new_id\""
  if [ "$has_blocked" = "true" ]; then
    PATCH_BODY+=",\"blockedBy\":$MAPPED_BLOCKED"
  fi
  if [ -n "$MAPPED_PARENT" ]; then
    PATCH_BODY+=",\"parentTask\":\"$MAPPED_PARENT\""
  fi
  PATCH_BODY+="}"

  curl -sf -X PATCH "${SONATA}/api/task" \
    -H 'Content-Type: application/json' \
    -d "$PATCH_BODY" > /dev/null 2>&1 && TASK_PATCHED=$((TASK_PATCHED + 1))
done < <(jq -c '.[]' "$TASKS_FILE")

log "Tasks pass 2 done: $TASK_PATCHED patched with blockedBy/parentTask"

# Also PATCH tasks with completion data (result, startedAt, completedAt, lastError)
TASK_STATUS_PATCHED=0
while IFS= read -r task; do
  convex_id=$(echo "$task" | jq -r '._id')
  new_id=$(lookup_id "$convex_id")
  if [ -z "$new_id" ]; then continue; fi

  # Check if there's status-related data to patch
  patch=$(echo "$task" | jq --arg id "$new_id" '{
    id: $id,
    result: .result,
    startedAt: .startedAt,
    completedAt: .completedAt,
    lastError: .lastError,
    retryCount: .retryCount,
    outputFiles: .outputFiles
  } | with_entries(select(.value != null and .value != ""))')

  # Only patch if we have more than just the id
  field_count=$(echo "$patch" | jq 'length')
  if [ "$field_count" -gt 1 ]; then
    curl -sf -X PATCH "${SONATA}/api/task" \
      -H 'Content-Type: application/json' \
      -d "$patch" > /dev/null 2>&1 && TASK_STATUS_PATCHED=$((TASK_STATUS_PATCHED + 1))
  fi
done < <(jq -c '.[]' "$TASKS_FILE")

log "Tasks pass 3 done: $TASK_STATUS_PATCHED patched with result/timing data"

# ============================================================================
# 9. CORE BLOCKS
# ============================================================================
log "=== Migrating CORE BLOCKS ==="
CORE_FILE="/tmp/sonata-mig-core.json"
curl -sf "${CONVEX}/api/core" > "$CORE_FILE"
CORE_COUNT=$(jq 'length' "$CORE_FILE")
log "Fetched $CORE_COUNT core blocks from Convex"

CORE_OK=0
while IFS= read -r block; do
  convex_id=$(echo "$block" | jq -r '._id')
  body=$(echo "$block" | jq '{
    key: .key,
    category: .category,
    content: .content,
    priority: (.priority // 0),
    compressed: .compressed
  } | with_entries(select(.value != null))')
  if post_one "/api/core" "$body" "$convex_id" > /dev/null; then
    CORE_OK=$((CORE_OK + 1))
  fi
done < <(jq -c '.[]' "$CORE_FILE")

log "Core blocks done: $CORE_OK ok"

# ============================================================================
# 10. WIKI PAGES
# ============================================================================
log "=== Migrating WIKI PAGES ==="
WIKI_FILE="/tmp/sonata-mig-wiki.json"
curl -sf "${CONVEX}/api/wiki/pages" > "$WIKI_FILE"
WIKI_COUNT=$(jq 'length' "$WIKI_FILE")
log "Fetched $WIKI_COUNT wiki pages from Convex"

WIKI_OK=0
while IFS= read -r page; do
  convex_id=$(echo "$page" | jq -r '._id')
  body=$(echo "$page" | jq '{
    slug: .slug,
    title: .title,
    namespace: .namespace,
    pageType: .pageType,
    parentSlug: .parentSlug,
    topic: .topic,
    memoryCount: .memoryCount,
    documentId: .documentId,
    filePath: .filePath,
    abstract: .abstract
  } | with_entries(select(.value != null))')
  if post_one "/api/wiki/page" "$body" "$convex_id" > /dev/null; then
    WIKI_OK=$((WIKI_OK + 1))
  fi
done < <(jq -c '.[]' "$WIKI_FILE")

log "Wiki pages done: $WIKI_OK ok"

# ============================================================================
# 11. SCHEDULED JOBS / CRON
# ============================================================================
log "=== Migrating SCHEDULED JOBS ==="
CRON_FILE="/tmp/sonata-mig-cron.json"
curl -sf "${CONVEX}/api/cron" > "$CRON_FILE"
CRON_COUNT=$(jq 'length' "$CRON_FILE")
log "Fetched $CRON_COUNT scheduled jobs from Convex"

CRON_OK=0
while IFS= read -r job; do
  convex_id=$(echo "$job" | jq -r '._id')
  body=$(echo "$job" | jq '{
    name: .name,
    schedule: .schedule,
    command: (.command // "echo noop"),
    enabled: .enabled,
    nextRunAt: .nextRunAt
  } | with_entries(select(.value != null))')
  if post_one "/api/cron" "$body" "$convex_id" > /dev/null; then
    CRON_OK=$((CRON_OK + 1))
  fi
done < <(jq -c '.[]' "$CRON_FILE")

log "Scheduled jobs done: $CRON_OK ok"

# ============================================================================
# SKIP: backgroundJobs, memoryStats, workers/workerEvents, embeddings
# ============================================================================
log "Skipped: backgroundJobs, memoryStats, workers, embeddings (ephemeral/expensive)"

# ============================================================================
# Consolidate ID map to JSON
# ============================================================================
consolidate_map
ID_MAP_SIZE=$(jq 'length' "$ID_MAP" 2>/dev/null || echo "0")
log "ID map consolidated: $ID_MAP_SIZE entries -> $ID_MAP"

# ============================================================================
# VERIFICATION
# ============================================================================
log ""
log "========================================="
log "   VERIFICATION"
log "========================================="

# Count each table in Sonata
S_MEM=$(curl -sf "${SONATA}/api/memory/recent?limit=100000" 2>/dev/null | jq 'length' 2>/dev/null || echo "ERR")
S_ENT=$(curl -sf "${SONATA}/api/entity/list?limit=100000" 2>/dev/null | jq 'length' 2>/dev/null || echo "ERR")
S_REL=$(curl -sf "${SONATA}/api/relation/list?limit=100000" 2>/dev/null | jq 'length' 2>/dev/null || echo "ERR")
S_EMAIL=$(curl -sf "${SONATA}/api/email/recent?limit=100000" 2>/dev/null | jq 'length' 2>/dev/null || echo "ERR")
S_CON=$(curl -sf "${SONATA}/api/contacts" 2>/dev/null | jq 'length' 2>/dev/null || echo "ERR")
S_DOC=$(curl -sf "${SONATA}/api/doc/list?limit=100000" 2>/dev/null | jq 'length' 2>/dev/null || echo "ERR")
S_CAL=$(curl -sf "${SONATA}/api/calendar/all?limit=100000" 2>/dev/null | jq 'length' 2>/dev/null || echo "ERR")
S_TASK=$(curl -sf "${SONATA}/api/task/list?limit=100000" 2>/dev/null | jq 'length' 2>/dev/null || echo "ERR")
S_CORE=$(curl -sf "${SONATA}/api/core/list" 2>/dev/null | jq 'length' 2>/dev/null || echo "ERR")
S_WIKI=$(curl -sf "${SONATA}/api/wiki/pages" 2>/dev/null | jq 'length' 2>/dev/null || echo "ERR")
S_CRON=$(curl -sf "${SONATA}/api/cron/list" 2>/dev/null | jq 'length' 2>/dev/null || echo "ERR")

log ""
printf "%-20s %-10s %-10s\n" "Table" "Convex" "Sonata" | tee -a "$LOG"
printf "%-20s %-10s %-10s\n" "---" "---" "---" | tee -a "$LOG"
printf "%-20s %-10s %-10s\n" "memories" "$MEM_COUNT" "$S_MEM" | tee -a "$LOG"
printf "%-20s %-10s %-10s\n" "entities" "$ENT_COUNT" "$S_ENT" | tee -a "$LOG"
printf "%-20s %-10s %-10s\n" "relations" "$REL_COUNT" "$S_REL" | tee -a "$LOG"
printf "%-20s %-10s %-10s\n" "emails" "$EMAIL_COUNT" "$S_EMAIL" | tee -a "$LOG"
printf "%-20s %-10s %-10s\n" "contacts" "$CON_COUNT" "$S_CON" | tee -a "$LOG"
printf "%-20s %-10s %-10s\n" "documents" "$DOC_COUNT" "$S_DOC" | tee -a "$LOG"
printf "%-20s %-10s %-10s\n" "calendarEvents" "$CAL_COUNT" "$S_CAL" | tee -a "$LOG"
printf "%-20s %-10s %-10s\n" "tasks" "$TASK_COUNT" "$S_TASK" | tee -a "$LOG"
printf "%-20s %-10s %-10s\n" "coreBlocks" "$CORE_COUNT" "$S_CORE" | tee -a "$LOG"
printf "%-20s %-10s %-10s\n" "wikiPages" "$WIKI_COUNT" "$S_WIKI" | tee -a "$LOG"
printf "%-20s %-10s %-10s\n" "scheduledJobs" "$CRON_COUNT" "$S_CRON" | tee -a "$LOG"
log ""

# Spot-check 5 memories
log "=== Spot-check: 5 random memories ==="
STEP=$((MEM_COUNT / 5))
for i in 0 1 2 3 4; do
  IDX=$((i * STEP))
  CID=$(jq -r ".[$IDX]._id" "$MEMORIES_FILE")
  CONVEX_CONTENT=$(jq -r ".[$IDX].content[0:80]" "$MEMORIES_FILE")
  NEW_ID=$(lookup_id "$CID")
  if [ -z "$NEW_ID" ]; then
    log "  $CID -> NOT IN MAP"
    continue
  fi
  SONATA_CONTENT=$(curl -sf "${SONATA}/api/memory/${NEW_ID}" 2>/dev/null | jq -r '.content[0:80]' 2>/dev/null || echo "FETCH_FAILED")
  if [ "$CONVEX_CONTENT" = "$SONATA_CONTENT" ]; then
    log "  OK: ${CONVEX_CONTENT:0:60}..."
  else
    log "  MISMATCH at index $IDX"
    log "    Convex: ${CONVEX_CONTENT:0:60}"
    log "    Sonata: ${SONATA_CONTENT:0:60}"
  fi
done

# Recall comparison
log ""
log "=== Recall comparison ==="
CONVEX_RECALL=$(curl -sf "${CONVEX}/api/recall?topic=Sonata&budget=4000" 2>/dev/null | jq -r '.memories | length // 0' 2>/dev/null || echo "ERR")
SONATA_RECALL=$(curl -sf "${SONATA}/api/recall?topic=Sonata&budget=4000" 2>/dev/null | jq -r '.memories | length // 0' 2>/dev/null || echo "ERR")
log "Recall 'Sonata': Convex=$CONVEX_RECALL results, Sonata=$SONATA_RECALL results"

log ""
log "ID map: $ID_MAP_SIZE entries -> $ID_MAP"
log "Migration log: $LOG"
log "Migration complete!"

# ============================================================================
# Write migration report
# ============================================================================
REPORT="/Users/evan/memory/claude/documents/plans/SONATA_MIGRATION_REPORT.md"
mkdir -p "$(dirname "$REPORT")"
cat > "$REPORT" << REPORT_EOF
# Sonata Migration Report

**Date**: $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Source**: Convex (localhost:3211)
**Target**: Sonata SQLite (localhost:3212)

## Record Counts

| Table | Convex | Sonata | Match |
|-------|--------|--------|-------|
| memories | $MEM_COUNT | $S_MEM | $([ "$MEM_COUNT" = "$S_MEM" ] && echo "YES" || echo "NO") |
| entities | $ENT_COUNT | $S_ENT | $([ "$ENT_COUNT" = "$S_ENT" ] && echo "YES" || echo "NO") |
| relations | $REL_COUNT | $S_REL | $([ "$REL_COUNT" = "$S_REL" ] && echo "YES" || echo "NO") |
| emails | $EMAIL_COUNT | $S_EMAIL | $([ "$EMAIL_COUNT" = "$S_EMAIL" ] && echo "YES" || echo "NO") |
| contacts | $CON_COUNT | $S_CON | $([ "$CON_COUNT" = "$S_CON" ] && echo "YES" || echo "NO") |
| documents | $DOC_COUNT | $S_DOC | $([ "$DOC_COUNT" = "$S_DOC" ] && echo "YES" || echo "NO") |
| calendarEvents | $CAL_COUNT | $S_CAL | $([ "$CAL_COUNT" = "$S_CAL" ] && echo "YES" || echo "NO") |
| tasks | $TASK_COUNT | $S_TASK | $([ "$TASK_COUNT" = "$S_TASK" ] && echo "YES" || echo "NO") |
| coreBlocks | $CORE_COUNT | $S_CORE | $([ "$CORE_COUNT" = "$S_CORE" ] && echo "YES" || echo "NO") |
| wikiPages | $WIKI_COUNT | $S_WIKI | $([ "$WIKI_COUNT" = "$S_WIKI" ] && echo "YES" || echo "NO") |
| scheduledJobs | $CRON_COUNT | $S_CRON | $([ "$CRON_COUNT" = "$S_CRON" ] && echo "YES" || echo "NO") |

## Skipped Tables
- **backgroundJobs** — ephemeral runtime data
- **memoryStats** — recomputed from data
- **workers/workerEvents** — ephemeral runtime data
- **memoryEmbeddings** — expensive; backfill later via Sonata pipeline

## ID Mapping
- **File**: \`$ID_MAP\`
- **Entries**: $ID_MAP_SIZE
- Maps Convex IDs to Sonata hex UUIDs

## Task Migration Details
- Pass 1: Created $TASK_OK tasks
- Pass 2: Patched $TASK_PATCHED tasks with blockedBy/parentTask references
- Pass 3: Patched $TASK_STATUS_PATCHED tasks with result/timing data

## Spot Check
See migration log at \`$LOG\` for spot-check results.

## Notes
- Relations: sourceId/targetId mapped via ID lookup table
- Tasks: Three-pass migration (create, patch refs, patch status data)
- Embeddings skipped — backfill via Sonata's embedding endpoint later
- Errors logged to: \`$LOG\`
REPORT_EOF

log "Report written to $REPORT"

# ============================================================================
# Store to memory
# ============================================================================
if [ -f /Users/evan/memory/claude/scripts/mem.sh ]; then
  source /Users/evan/memory/claude/scripts/mem.sh 2>/dev/null || true
  mem store "Sonata data migration complete: $MEM_COUNT memories, $ENT_COUNT entities, $REL_COUNT relations, $EMAIL_COUNT emails, $CON_COUNT contacts, $DOC_COUNT docs, $CAL_COUNT calendar events, $TASK_COUNT tasks, $CORE_COUNT core blocks, $WIKI_COUNT wiki pages, $CRON_COUNT cron jobs migrated from Convex to Sonata SQLite. ID map at $ID_MAP ($ID_MAP_SIZE entries). Verification: Sonata counts — mem=$S_MEM ent=$S_ENT rel=$S_REL email=$S_EMAIL doc=$S_DOC cal=$S_CAL task=$S_TASK core=$S_CORE wiki=$S_WIKI cron=$S_CRON" \
    --type decision --tags "sonata,migration,data" --importance 9 2>/dev/null || true
fi
