import GRDB
import Foundation

// MARK: - Schema Creation

func createSchema(in db: Database) throws {

    // MARK: memories
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS memories (
            id             TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            content        TEXT NOT NULL,
            type           TEXT NOT NULL,
            tags           TEXT NOT NULL DEFAULT '[]',
            source         TEXT,
            importance     REAL NOT NULL DEFAULT 5,
            l0             TEXT,
            l1             TEXT,
            accessCount    INTEGER,
            lastAccessedAt INTEGER,
            status         TEXT,
            supersededBy   TEXT,
            revisionOf     TEXT,
            revisionNote   TEXT,
            validFrom      INTEGER,
            validUntil     INTEGER,
            project        TEXT,
            topic          TEXT,
            createdAt      INTEGER NOT NULL,
            updatedAt      INTEGER NOT NULL
        )
    """)

    try db.execute(sql: """
        CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts
        USING fts5(content, content='memories', content_rowid='rowid')
    """)

    try db.execute(sql: "CREATE INDEX IF NOT EXISTS memories_by_type        ON memories(type)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS memories_by_source      ON memories(source)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS memories_by_importance  ON memories(importance)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS memories_by_createdAt   ON memories(createdAt)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS memories_by_updatedAt   ON memories(updatedAt)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS memories_by_accessCount ON memories(accessCount)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS memories_by_status      ON memories(status)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS memories_by_validity    ON memories(validFrom, validUntil)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS memories_by_project     ON memories(project)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS memories_by_project_topic ON memories(project, topic)")

    // FTS triggers for memories
    try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
            INSERT INTO memories_fts(rowid, content) VALUES (new.rowid, new.content);
        END
    """)
    try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
            INSERT INTO memories_fts(memories_fts, rowid, content) VALUES ('delete', old.rowid, old.content);
        END
    """)
    try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
            INSERT INTO memories_fts(memories_fts, rowid, content) VALUES ('delete', old.rowid, old.content);
            INSERT INTO memories_fts(rowid, content) VALUES (new.rowid, new.content);
        END
    """)

    // MARK: entities
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS entities (
            id                 TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            name               TEXT NOT NULL,
            type               TEXT NOT NULL,
            description        TEXT NOT NULL,
            attributes         TEXT,
            referenceCount     INTEGER NOT NULL DEFAULT 0,
            lastReferencedAt   INTEGER,
            createdAt          INTEGER NOT NULL,
            updatedAt          INTEGER NOT NULL
        )
    """)

    try db.execute(sql: """
        CREATE VIRTUAL TABLE IF NOT EXISTS entities_fts
        USING fts5(name, description, type UNINDEXED, content='entities', content_rowid='rowid')
    """)

    try db.execute(sql: "CREATE INDEX IF NOT EXISTS entities_by_name       ON entities(name)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS entities_by_type       ON entities(type)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS entities_by_references ON entities(referenceCount)")

    try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS entities_ai AFTER INSERT ON entities BEGIN
            INSERT INTO entities_fts(rowid, name, description, type) VALUES (new.rowid, new.name, new.description, new.type);
        END
    """)
    try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS entities_ad AFTER DELETE ON entities BEGIN
            INSERT INTO entities_fts(entities_fts, rowid, name, description, type) VALUES ('delete', old.rowid, old.name, old.description, old.type);
        END
    """)
    try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS entities_au AFTER UPDATE ON entities BEGIN
            INSERT INTO entities_fts(entities_fts, rowid, name, description, type) VALUES ('delete', old.rowid, old.name, old.description, old.type);
            INSERT INTO entities_fts(rowid, name, description, type) VALUES (new.rowid, new.name, new.description, new.type);
        END
    """)

    // MARK: emails
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS emails (
            id          TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            messageId   TEXT NOT NULL UNIQUE,
            threadId    TEXT NOT NULL,
            fromAddr    TEXT NOT NULL,
            toAddr      TEXT NOT NULL,
            subject     TEXT NOT NULL,
            body        TEXT NOT NULL,
            status      TEXT NOT NULL DEFAULT 'unread',
            receivedAt  INTEGER NOT NULL,
            repliedAt   INTEGER
        )
    """)

    try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS emails_by_messageId ON emails(messageId)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS emails_by_status           ON emails(status)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS emails_by_receivedAt       ON emails(receivedAt)")

    // MARK: calendarEvents
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS calendarEvents (
            id             TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            title          TEXT NOT NULL,
            description    TEXT,
            prompt         TEXT,
            scheduledAt    INTEGER NOT NULL,
            recurrence     TEXT,
            lastRunAt      INTEGER,
            lastRunStatus  TEXT,
            runCount       INTEGER NOT NULL DEFAULT 0,
            enabled        INTEGER NOT NULL DEFAULT 1,
            project        TEXT,
            workingDir     TEXT,
            model          TEXT,
            maxTurns       INTEGER,
            taskType       TEXT NOT NULL,
            createdAt      INTEGER NOT NULL,
            updatedAt      INTEGER NOT NULL
        )
    """)

    try db.execute(sql: "CREATE INDEX IF NOT EXISTS calendarEvents_by_scheduledAt ON calendarEvents(enabled, scheduledAt)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS calendarEvents_by_taskType    ON calendarEvents(taskType)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS calendarEvents_by_project     ON calendarEvents(project)")

    // MARK: tasks
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS tasks (
            id                  TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            title               TEXT NOT NULL,
            description         TEXT,
            status              TEXT NOT NULL DEFAULT 'pending',
            priority            TEXT NOT NULL DEFAULT 'normal',
            prompt              TEXT,
            workingDir          TEXT,
            model               TEXT,
            maxTurns            INTEGER,
            project             TEXT,
            blockedBy           TEXT DEFAULT '[]',
            originalBlockedBy   TEXT DEFAULT '[]',
            parentTask          TEXT,
            source              TEXT NOT NULL,
            sourceRef           TEXT,
            result              TEXT,
            outputFiles         TEXT DEFAULT '[]',
            tags                TEXT NOT NULL DEFAULT '[]',
            assignedTo          TEXT,
            dueAt               INTEGER,
            startedAt           INTEGER,
            completedAt         INTEGER,
            retryCount          INTEGER NOT NULL DEFAULT 0,
            maxRetries          INTEGER,
            lastError           TEXT,
            tools               TEXT DEFAULT '[]',
            metadata            TEXT,
            createdAt           INTEGER NOT NULL,
            updatedAt           INTEGER NOT NULL
        )
    """)

    try db.execute(sql: """
        CREATE VIRTUAL TABLE IF NOT EXISTS tasks_fts
        USING fts5(title, content='tasks', content_rowid='rowid')
    """)

    try db.execute(sql: "CREATE INDEX IF NOT EXISTS tasks_by_status   ON tasks(status)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS tasks_by_priority ON tasks(priority)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS tasks_by_project  ON tasks(project)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS tasks_by_parent   ON tasks(parentTask)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS tasks_by_source   ON tasks(source)")

    try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS tasks_ai AFTER INSERT ON tasks BEGIN
            INSERT INTO tasks_fts(rowid, title) VALUES (new.rowid, new.title);
        END
    """)
    try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS tasks_ad AFTER DELETE ON tasks BEGIN
            INSERT INTO tasks_fts(tasks_fts, rowid, title) VALUES ('delete', old.rowid, old.title);
        END
    """)
    try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS tasks_au AFTER UPDATE ON tasks BEGIN
            INSERT INTO tasks_fts(tasks_fts, rowid, title) VALUES ('delete', old.rowid, old.title);
            INSERT INTO tasks_fts(rowid, title) VALUES (new.rowid, new.title);
        END
    """)

    // MARK: documents
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS documents (
            id               TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            title            TEXT NOT NULL,
            path             TEXT NOT NULL,
            content          TEXT NOT NULL,
            summary          TEXT,
            docType          TEXT NOT NULL,
            project          TEXT,
            tags             TEXT NOT NULL DEFAULT '[]',
            relatedEntities  TEXT DEFAULT '[]',
            relatedMemories  TEXT DEFAULT '[]',
            parentDoc        TEXT,
            source           TEXT NOT NULL,
            status           TEXT NOT NULL DEFAULT 'active',
            createdAt        INTEGER NOT NULL,
            updatedAt        INTEGER NOT NULL,
            lastIndexedAt    INTEGER NOT NULL
        )
    """)

    try db.execute(sql: """
        CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts
        USING fts5(content, content='documents', content_rowid='rowid')
    """)

    try db.execute(sql: "CREATE INDEX IF NOT EXISTS documents_by_path    ON documents(path)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS documents_by_project ON documents(project)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS documents_by_type    ON documents(docType)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS documents_by_status  ON documents(status)")

    try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS documents_ai AFTER INSERT ON documents BEGIN
            INSERT INTO documents_fts(rowid, content) VALUES (new.rowid, new.content);
        END
    """)
    try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS documents_ad AFTER DELETE ON documents BEGIN
            INSERT INTO documents_fts(documents_fts, rowid, content) VALUES ('delete', old.rowid, old.content);
        END
    """)
    try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS documents_au AFTER UPDATE ON documents BEGIN
            INSERT INTO documents_fts(documents_fts, rowid, content) VALUES ('delete', old.rowid, old.content);
            INSERT INTO documents_fts(rowid, content) VALUES (new.rowid, new.content);
        END
    """)

    // MARK: contacts
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS contacts (
            id             TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            name           TEXT NOT NULL,
            email          TEXT NOT NULL,
            type           TEXT NOT NULL,
            role           TEXT,
            provider       TEXT,
            model          TEXT,
            systemPrompt   TEXT,
            notes          TEXT,
            lastContactAt  INTEGER,
            messageCount   INTEGER NOT NULL DEFAULT 0,
            createdAt      INTEGER NOT NULL,
            updatedAt      INTEGER NOT NULL
        )
    """)

    try db.execute(sql: "CREATE INDEX IF NOT EXISTS contacts_by_email ON contacts(email)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS contacts_by_type  ON contacts(type)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS contacts_by_name  ON contacts(name)")

    // MARK: memoryStats
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS memoryStats (
            id              TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            totalMemories   INTEGER NOT NULL DEFAULT 0,
            totalImportance REAL NOT NULL DEFAULT 0,
            byType          TEXT NOT NULL DEFAULT '{}'
        )
    """)

    // backgroundJobs table intentionally absent — retired 2026-05-17 along with
    // BackgroundJobRunner + ClaudeProcessManager (Evan directive thread 1620020f).
    // v11_drop_backgroundjobs drops the table on existing installs. Do not re-add.

    // MARK: scheduledJobs
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS scheduledJobs (
            id            TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            name          TEXT NOT NULL UNIQUE,
            schedule      TEXT NOT NULL,
            command       TEXT NOT NULL,
            enabled       INTEGER NOT NULL DEFAULT 1,
            lastRunAt     REAL,
            lastResult    TEXT,
            lastError     TEXT,
            lastExitCode  REAL,
            nextRunAt     REAL,
            createdAt     REAL NOT NULL
        )
    """)

    try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS scheduledJobs_by_name     ON scheduledJobs(name)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS scheduledJobs_by_next_run        ON scheduledJobs(nextRunAt)")

    // MARK: coreBlocks
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS coreBlocks (
            id          TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            key         TEXT NOT NULL UNIQUE,
            category    TEXT NOT NULL,
            content     TEXT NOT NULL,
            priority    INTEGER NOT NULL DEFAULT 0,
            updatedAt   INTEGER NOT NULL,
            active      INTEGER NOT NULL DEFAULT 1,
            compressed  TEXT
        )
    """)

    try db.execute(sql: "CREATE INDEX IF NOT EXISTS coreBlocks_by_category ON coreBlocks(category)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS coreBlocks_by_priority ON coreBlocks(priority)")
    try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS coreBlocks_by_key ON coreBlocks(key)")

    // MARK: memoryEmbeddings
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS memoryEmbeddings (
            id           TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            memoryId     TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            embedding    BLOB NOT NULL,
            model        TEXT NOT NULL,
            dimensions   INTEGER NOT NULL,
            contentHash  TEXT NOT NULL,
            createdAt    INTEGER NOT NULL
        )
    """)

    try db.execute(sql: "CREATE INDEX IF NOT EXISTS memoryEmbeddings_by_memoryId ON memoryEmbeddings(memoryId)")

    // MARK: wikiPages
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS wikiPages (
            id             TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            slug           TEXT NOT NULL UNIQUE,
            title          TEXT NOT NULL,
            namespace      TEXT,
            pageType       TEXT,
            parentSlug     TEXT,
            topic          TEXT,
            lastCompiled   INTEGER NOT NULL,
            memoryCount    INTEGER NOT NULL DEFAULT 0,
            dirty          INTEGER NOT NULL DEFAULT 0,
            documentId     TEXT,
            filePath       TEXT NOT NULL,
            abstract       TEXT,
            createdAt      INTEGER NOT NULL,
            updatedAt      INTEGER NOT NULL
        )
    """)

    try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS wikiPages_by_slug             ON wikiPages(slug)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS wikiPages_by_dirty                   ON wikiPages(dirty)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS wikiPages_by_namespace               ON wikiPages(namespace)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS wikiPages_by_parentSlug              ON wikiPages(parentSlug)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS wikiPages_by_namespace_topic         ON wikiPages(namespace, topic)")

    // MARK: workers
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS workers (
            id               TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            workerId         TEXT NOT NULL UNIQUE,
            sessionLabel     TEXT NOT NULL,
            status           TEXT NOT NULL DEFAULT 'idle',
            capabilities     TEXT NOT NULL DEFAULT '[]',
            lastHeartbeat    INTEGER NOT NULL,
            currentEventId   TEXT,
            registeredAt     INTEGER NOT NULL
        )
    """)

    try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS workers_by_workerId ON workers(workerId)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS workers_by_status          ON workers(status)")

    // Migration: add lastProgressAt column (idempotent — silently fails if already exists)
    do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN lastProgressAt INTEGER") } catch { /* column exists */ }

    // Migration: add sessionId for worker cycling (idempotent)
    do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN sessionId TEXT") } catch { /* column exists */ }

    // Migration: live monitoring v0 — per-event token spend, slug, cache hit rate.
    // All NULL when idle; cleared by the 60s sweep alongside currentEventId.
    do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN currentEventTokens INTEGER") } catch { /* column exists */ }
    do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN currentSlug TEXT") } catch { /* column exists */ }
    do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN currentCacheReadTokens INTEGER") } catch { /* column exists */ }
    do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN currentInputTokens INTEGER") } catch { /* column exists */ }
    do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN currentPromptHash TEXT") } catch { /* column exists */ }

    // Migration: readable-name carry for prompt cache panel — bridge ships these in heartbeat,
    // roll-up writes them into promptCacheStats for display alongside the promptHash.
    do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN currentSessionLabel TEXT") } catch { /* column exists */ }
    do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN currentCwdBasename TEXT") } catch { /* column exists */ }

    // MARK: promptCacheStats — per-prompt-template cache hit-rate aggregation
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS promptCacheStats (
            promptKey            TEXT PRIMARY KEY,
            eventType            TEXT NOT NULL,
            promptHash           TEXT NOT NULL,
            totalInputTokens     INTEGER NOT NULL DEFAULT 0,
            totalCacheReadTokens INTEGER NOT NULL DEFAULT 0,
            sampleCount          INTEGER NOT NULL DEFAULT 0,
            lastSeenAt           INTEGER NOT NULL
        )
    """)
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS promptCacheStats_eventType ON promptCacheStats(eventType)")

    // Migration: readable-name display fields (sticky via COALESCE at roll-up time).
    do { try db.execute(sql: "ALTER TABLE promptCacheStats ADD COLUMN sessionLabel TEXT") } catch { /* column exists */ }
    do { try db.execute(sql: "ALTER TABLE promptCacheStats ADD COLUMN cwdBasename TEXT") } catch { /* column exists */ }

    // MARK: workerEvents
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS workerEvents (
            id           TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            type         TEXT NOT NULL,
            payload      TEXT NOT NULL,
            priority     INTEGER NOT NULL DEFAULT 5,
            assignedTo   TEXT,
            status       TEXT NOT NULL DEFAULT 'pending',
            result       TEXT,
            createdAt    INTEGER NOT NULL,
            assignedAt   INTEGER,
            completedAt  INTEGER
        )
    """)

    try db.execute(sql: "CREATE INDEX IF NOT EXISTS workerEvents_by_status     ON workerEvents(status)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS workerEvents_by_assignedTo ON workerEvents(assignedTo)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS workerEvents_by_createdAt  ON workerEvents(createdAt)")

    // Migration: add sessionId for worker cycling (idempotent)
    do { try db.execute(sql: "ALTER TABLE workerEvents ADD COLUMN sessionId TEXT") } catch { /* column exists */ }

    // MARK: supervisorMessages
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS supervisorMessages (
            id          TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            role        TEXT NOT NULL,
            content     TEXT NOT NULL,
            replyTo     TEXT,
            actions     TEXT,
            severity    TEXT,
            dismissedAt INTEGER,
            createdAt   INTEGER NOT NULL
        )
    """)
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS supervisorMessages_by_created ON supervisorMessages(createdAt)")

    // MARK: supervisorState
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS supervisorState (
            id              TEXT PRIMARY KEY DEFAULT 'singleton',
            lastHeartbeat   INTEGER NOT NULL,
            lastCheckAt     INTEGER,
            sessionId       TEXT
        )
    """)

    // MARK: supervisorEvents
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS supervisorEvents (
            id         TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            type       TEXT NOT NULL,
            payload    TEXT NOT NULL DEFAULT '{}',
            createdAt  INTEGER NOT NULL,
            claimedAt  INTEGER
        )
    """)
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS supervisorEvents_by_claimed ON supervisorEvents(claimedAt, createdAt)")

    // MARK: relations
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS relations (
            id          TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            sourceId    TEXT NOT NULL,
            sourceType  TEXT NOT NULL,
            targetId    TEXT NOT NULL,
            targetType  TEXT NOT NULL,
            relation    TEXT NOT NULL,
            createdAt   INTEGER NOT NULL
        )
    """)

    try db.execute(sql: "CREATE INDEX IF NOT EXISTS relations_by_source   ON relations(sourceId, sourceType)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS relations_by_target   ON relations(targetId, targetType)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS relations_by_relation ON relations(relation)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS relations_by_types    ON relations(sourceType, targetType)")

    // MARK: appState
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS appState (
            id         TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            app        TEXT NOT NULL,
            key        TEXT NOT NULL,
            value      TEXT NOT NULL DEFAULT 'null',
            updatedAt  INTEGER NOT NULL
        )
    """)

    try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS appState_by_app_key ON appState(app, key)")

    // MARK: emailInboxes
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS emailInboxes (
            id             TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            address        TEXT NOT NULL UNIQUE,
            role           TEXT NOT NULL,
            displayName    TEXT,
            enabled        INTEGER NOT NULL DEFAULT 1,
            autoReply      INTEGER NOT NULL DEFAULT 1,
            dispatchTo     TEXT,
            systemPrompt   TEXT,
            provider       TEXT NOT NULL DEFAULT 'agentmail',
            providerConfig TEXT,
            createdAt      INTEGER NOT NULL,
            updatedAt      INTEGER NOT NULL
        )
    """)

    try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS emailInboxes_by_address ON emailInboxes(address)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS emailInboxes_by_enabled ON emailInboxes(enabled)")

    // MARK: supervisorConfig (singleton row)
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS supervisorConfig (
            id               TEXT PRIMARY KEY DEFAULT 'singleton',
            dayIntervalSec   INTEGER NOT NULL DEFAULT 180,
            nightIntervalSec INTEGER NOT NULL DEFAULT 1800,
            nightStartHour   INTEGER NOT NULL DEFAULT 22,
            nightEndHour     INTEGER NOT NULL DEFAULT 7,
            enabled          INTEGER NOT NULL DEFAULT 1,
            updatedAt        INTEGER NOT NULL
        )
    """)

    // MARK: plugins
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS plugins (
            name        TEXT PRIMARY KEY,
            version     TEXT NOT NULL,
            description TEXT,
            port        INTEGER NOT NULL,
            status      TEXT NOT NULL DEFAULT 'installed',
            mode        TEXT NOT NULL DEFAULT 'managed',
            url         TEXT,
            config_json TEXT DEFAULT '{}',
            path        TEXT NOT NULL,
            pid         INTEGER,
            installedAt INTEGER NOT NULL,
            updatedAt   INTEGER NOT NULL
        )
    """)

    try db.execute(sql: "CREATE INDEX IF NOT EXISTS plugins_by_status ON plugins(status)")
}

/// Seed the supervisorConfig singleton row with defaults if not present.
/// Idempotent — safe to call at startup or from a migration.
func seedSupervisorConfigIfEmpty(in db: Database) throws {
    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM supervisorConfig") ?? 0
    guard count == 0 else { return }

    let now = Int64(Date().timeIntervalSince1970 * 1000)
    try db.execute(sql: """
        INSERT INTO supervisorConfig
            (id, dayIntervalSec, nightIntervalSec, nightStartHour, nightEndHour, enabled, updatedAt)
        VALUES
            ('singleton', 180, 1800, 22, 7, 1, ?)
    """, arguments: [now])
}

/// Seed the webviewSessionConfig singleton row with defaults if not present.
/// Idempotent — safe to call from the migration or at startup.
func seedWebviewSessionConfigIfEmpty(in db: Database) throws {
    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM webviewSessionConfig") ?? 0
    guard count == 0 else { return }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    try db.execute(sql: """
        INSERT INTO webviewSessionConfig
            (id, idleSuspendSec, hardCloseSec, maxLiveSessions, updatedAt)
        VALUES ('singleton', 300, 1800, 8, ?)
    """, arguments: [now])
}

/// Seed the emailInboxes table with the two historically hardcoded inboxes
/// if the table is empty. Idempotent — safe to call at startup or from a migration.
func seedEmailInboxesIfEmpty(in db: Database) throws {
    // No default inboxes — users configure via the dashboard (Email Config tab).
    // Existing installs already have their inboxes in the DB.
}

// MARK: - Migrator Registration

extension DatabaseMigrator {
    mutating func registerSonataSchema() {
        registerMigration("v1_initial_schema") { db in
            try createSchema(in: db)
        }

        // v2: emailInboxes table + seed data for existing installs.
        // CREATE TABLE uses IF NOT EXISTS so it's a no-op on new installs
        // (v1 already created it). Seed is idempotent via row count check.
        registerMigration("v2_email_inboxes") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS emailInboxes (
                    id            TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
                    address       TEXT NOT NULL UNIQUE,
                    role          TEXT NOT NULL,
                    displayName   TEXT,
                    enabled       INTEGER NOT NULL DEFAULT 1,
                    autoReply     INTEGER NOT NULL DEFAULT 1,
                    dispatchTo    TEXT,
                    systemPrompt  TEXT,
                    createdAt     INTEGER NOT NULL,
                    updatedAt     INTEGER NOT NULL
                )
            """)
            try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS emailInboxes_by_address ON emailInboxes(address)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS emailInboxes_by_enabled ON emailInboxes(enabled)")
            try seedEmailInboxesIfEmpty(in: db)
        }

        // v3: supervisorConfig singleton table + seed default row.
        // CREATE TABLE uses IF NOT EXISTS so it's a no-op on new installs
        // (v1 already created it). Seed is idempotent via row count check.
        registerMigration("v3_supervisor_config") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS supervisorConfig (
                    id               TEXT PRIMARY KEY DEFAULT 'singleton',
                    dayIntervalSec   INTEGER NOT NULL DEFAULT 180,
                    nightIntervalSec INTEGER NOT NULL DEFAULT 1800,
                    nightStartHour   INTEGER NOT NULL DEFAULT 22,
                    nightEndHour     INTEGER NOT NULL DEFAULT 7,
                    enabled          INTEGER NOT NULL DEFAULT 1,
                    updatedAt        INTEGER NOT NULL
                )
            """)
            try seedSupervisorConfigIfEmpty(in: db)
        }

        // v4: add sessionId columns for worker cycling/resume.
        registerMigration("v4_worker_session_id") { db in
            do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN sessionId TEXT") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE workerEvents ADD COLUMN sessionId TEXT") } catch { /* column exists */ }
        }

        registerMigration("v5_plugins") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS plugins (
                    name        TEXT PRIMARY KEY,
                    version     TEXT NOT NULL,
                    description TEXT,
                    port        INTEGER NOT NULL,
                    status      TEXT NOT NULL DEFAULT 'installed',
                    mode        TEXT NOT NULL DEFAULT 'managed',
                    url         TEXT,
                    config_json TEXT DEFAULT '{}',
                    path        TEXT NOT NULL,
                    pid         INTEGER,
                    installedAt INTEGER NOT NULL,
                    updatedAt   INTEGER NOT NULL
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS plugins_by_status ON plugins(status)")
        }

        // v6: live worker monitoring + per-prompt cache hit-rate aggregation.
        // The earlier LWM v0 build added this SQL to `createSchema(in:)` directly,
        // which only runs as part of the v1 migration on FRESH databases — so
        // existing installs never got the promptCacheStats table or some of the
        // worker columns. Promote those changes to their own migration so every
        // existing install picks them up on next launch.
        registerMigration("v6_live_monitoring_v0") { db in
            // Worker columns for in-flight token/cache telemetry. Idempotent —
            // some installs already have these from the createSchema body.
            do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN currentEventTokens INTEGER") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN currentSlug TEXT") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN currentCacheReadTokens INTEGER") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN currentInputTokens INTEGER") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN currentPromptHash TEXT") } catch { /* column exists */ }

            // Per-prompt-template cache hit-rate aggregation.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS promptCacheStats (
                    promptKey            TEXT PRIMARY KEY,
                    eventType            TEXT NOT NULL,
                    promptHash           TEXT NOT NULL,
                    totalInputTokens     INTEGER NOT NULL DEFAULT 0,
                    totalCacheReadTokens INTEGER NOT NULL DEFAULT 0,
                    sampleCount          INTEGER NOT NULL DEFAULT 0,
                    lastSeenAt           INTEGER NOT NULL
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS promptCacheStats_eventType ON promptCacheStats(eventType)")
        }

        // v7: per-event token + model attribution. Lets the Dashboard's token
        // usage card sum spend by day/model/worker without re-parsing payload
        // JSON. Populated by worker_event_complete / worker_event_fail when
        // the worker row's currentEventTokens are still around.
        registerMigration("v7_event_token_attribution") { db in
            do { try db.execute(sql: "ALTER TABLE workerEvents ADD COLUMN model TEXT") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE workerEvents ADD COLUMN totalTokens INTEGER") } catch { /* column exists */ }
            // completedAt index is already created in createSchema for new installs;
            // ensure existing installs that predate it get one for fast daily rollups.
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS workerEvents_by_completedAt ON workerEvents(completedAt)")
        }

        // v8: tasks.acknowledgedAt for soft-archive of failed/blocked items the user
        // has seen and dismissed from the dashboard's attention zone. The status field
        // stays untouched ('failed' / 'pending' with blockedBy) so the Tasks tab can
        // still show what happened — `acknowledgedAt IS NOT NULL` just means the user
        // has triaged it. Stuck-tasks count and the AttentionTasksCard filter on this.
        registerMigration("v8_task_acknowledged_at") { db in
            do { try db.execute(sql: "ALTER TABLE tasks ADD COLUMN acknowledgedAt INTEGER") } catch { /* column exists */ }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS tasks_by_acknowledgedAt ON tasks(acknowledgedAt)")
        }

        // v9: dm_messages — durable inbox for session-addressed Sonar DMs.
        // dm_send always persists here, then attempts a live SSE push via
        // MCPSessionRegistry. Recipients pull missed messages via
        // /api/dm/inbox?since=<ms>. 7-day TTL on `deliveredAtMs IS NOT NULL`
        // rows is enforced by the nightly maintenance task; undelivered rows
        // are retained until the recipient picks them up.
        registerMigration("v9_dm_messages") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS dm_messages (
                    messageId        TEXT PRIMARY KEY,
                    targetSessionId  TEXT NOT NULL,
                    fromSessionId    TEXT,
                    fromPubkey       TEXT,
                    fromPeerId       TEXT,
                    body             TEXT NOT NULL,
                    context          TEXT,
                    metaJson         TEXT,
                    sentAtMs         INTEGER NOT NULL,
                    receivedAtMs     INTEGER NOT NULL,
                    deliveredAtMs    INTEGER,
                    deliveryStatus   TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS dm_messages_target_received
                    ON dm_messages(targetSessionId, receivedAtMs DESC)
            """)
        }

        // v10: readable-name carry for the prompt cache panel. Bridge ships
        // sessionLabel + cwdBasename in every heartbeat; the server stores the
        // live values on workers and rolls them into promptCacheStats so the UI
        // can render "task · sona-worker-6 @ memory" instead of an opaque hash.
        // Purely additive; rolls forward by leaving NULL for historical rows.
        registerMigration("v10_prompt_cache_readable_names") { db in
            do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN currentSessionLabel TEXT") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE workers ADD COLUMN currentCwdBasename TEXT") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE promptCacheStats ADD COLUMN sessionLabel TEXT") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE promptCacheStats ADD COLUMN cwdBasename TEXT") } catch { /* column exists */ }
        }

        // v11: drop the `backgroundJobs` table. Retired 2026-05-17 along with
        // BackgroundJobRunner + ClaudeProcessManager (commits 1e74c68, b9cea03)
        // per Evan directive thread 1620020f. Zero writers, zero readers — the
        // 5 enqueue sites in CompositeActions now insert into `tasks` instead.
        // Safe to DROP: the table sat empty on every live install after b9cea03.
        registerMigration("v11_drop_backgroundjobs") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS backgroundJobs")
        }

        // v12: task_watchers — push-vs-poll primitive. Callers register interest
        // in a task's status transitions; on any status update, the writer fans
        // out a sonar_dm_send to each registered watcher whose on_mask matches.
        // Dead watchers are swept passively at fan-out time against the MCP
        // session registry (no separate timer). PK (taskId, target_session_id)
        // makes registration idempotent.
        registerMigration("v12_task_watchers") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS task_watchers (
                    taskId            TEXT NOT NULL,
                    target_session_id TEXT NOT NULL,
                    on_mask           TEXT NOT NULL,
                    createdAt         INTEGER NOT NULL,
                    PRIMARY KEY (taskId, target_session_id)
                )
            """)
            try db.execute(sql:
                "CREATE INDEX IF NOT EXISTS task_watchers_by_task ON task_watchers(taskId)")
        }

        // v13: MCP unify side effects —
        //   * workerToolDenials: empty-by-default table the HTTP-MCP transport
        //     consults to deny specific tool names per session role. Default
        //     empty so behavior matches pre-unify (all tools callable). The
        //     Settings UI (Phase 2) populates this; ships with no rows.
        //   * contacts.autoAllowEmail / blockEmail: sender-allowlist gating
        //     for EmailHandler. Existing trusted contacts get autoAllowEmail=1
        //     during this migration.
        //   * contacts.peerKind / peerEndpoint / peerPubkey: support federated
        //     peers (Scout) whose AI Details fields don't apply. Existing AI
        //     contacts default to peerKind='invoked' so the UI still shows the
        //     Provider/Model/SystemPrompt form for them.
        registerMigration("v13_mcp_unify_side_effects") { db in
            // Worker tool denylist — empty default, see plan
            // mcp-unify-worker-surface.md § "Surface alignment".
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS workerToolDenials (
                    toolName  TEXT PRIMARY KEY,
                    appliesTo TEXT NOT NULL DEFAULT 'worker',
                    reason    TEXT,
                    addedAt   INTEGER NOT NULL,
                    addedBy   TEXT
                )
            """)
            try db.execute(sql:
                "CREATE INDEX IF NOT EXISTS workerToolDenials_by_role ON workerToolDenials(appliesTo)")

            // Contacts schema additions. Each ALTER is wrapped in do/catch
            // so re-running the migration on a partially-applied DB is safe.
            do { try db.execute(sql: "ALTER TABLE contacts ADD COLUMN autoAllowEmail INTEGER NOT NULL DEFAULT 0") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE contacts ADD COLUMN blockEmail INTEGER NOT NULL DEFAULT 0") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE contacts ADD COLUMN peerKind TEXT") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE contacts ADD COLUMN peerEndpoint TEXT") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE contacts ADD COLUMN peerPubkey TEXT") } catch { /* column exists */ }

            try db.execute(sql:
                "CREATE INDEX IF NOT EXISTS contacts_by_auto_allow ON contacts(autoAllowEmail) WHERE autoAllowEmail = 1")
            try db.execute(sql:
                "CREATE INDEX IF NOT EXISTS contacts_by_block ON contacts(blockEmail) WHERE blockEmail = 1")

            // Seed existing trusted addresses (idempotent — UPDATE WHERE).
            // Scout is included so that if the row was added by hand before
            // this migration runs, it still gets allow-listed. New installs
            // won't have these rows yet — no-op until rows exist.
            try db.execute(sql: """
                UPDATE contacts SET autoAllowEmail = 1
                WHERE LOWER(email) IN (
                    'evan108108@gmail.com',
                    'campbell.hyers@enginable.com',
                    'allison.formicola@enginable.com',
                    'sloan.mercer@agentmail.to',
                    'scoutleader@agentmail.to'
                )
            """)

            // Backfill peerKind for existing AI contacts to 'invoked' so the
            // form still shows the right section. Federated peers (Scout) are
            // set explicitly when their row is created / updated.
            try db.execute(sql:
                "UPDATE contacts SET peerKind = 'invoked' WHERE type = 'ai' AND peerKind IS NULL")
        }

        // v14: persist Interactive Sessions across Sonata restarts. Each
        // session in the in-rail "Sessions" tab gets a row here. On launch
        // the tabs are restored in `position` order via Claude Code's
        // `--resume <sessionId>` flag, which re-attaches to the prior
        // session file at ~/.claude/sessions/<sessionId>.json. If a session
        // row exists but the underlying file was pruned, the spawn fails
        // and the user gets a Restart button.
        //
        // Closing a tab via the rail's context menu deletes the row;
        // process termination does NOT (so users can hit Restart). The
        // "Sonata Default" auto-spawn only fires when the table is empty.
        registerMigration("v14_interactive_sessions") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS interactiveSessions (
                    id         TEXT PRIMARY KEY,
                    sessionId  TEXT NOT NULL,
                    name       TEXT NOT NULL,
                    cwd        TEXT NOT NULL,
                    position   INTEGER NOT NULL DEFAULT 0,
                    wasActive  INTEGER NOT NULL DEFAULT 0,
                    createdAt  INTEGER NOT NULL,
                    updatedAt  INTEGER NOT NULL
                )
            """)
            try db.execute(sql:
                "CREATE INDEX IF NOT EXISTS interactiveSessions_by_position ON interactiveSessions(position)")
        }

        // v15: session type. Each interactive session is either the full
        // Claude Code subprocess ('sona', the default and prior behavior) or a
        // plain interactive shell ('terminal'). Existing rows backfill to
        // 'sona' so restored sessions keep behaving exactly as before.
        registerMigration("v15_session_kind") { db in
            try db.execute(sql:
                "ALTER TABLE interactiveSessions ADD COLUMN kind TEXT NOT NULL DEFAULT 'sona'")
        }

        // v16: web session URL. For kind='webview' the session renders this URL
        // in a WKWebView instead of running a subprocess; NULL for sona/terminal.
        registerMigration("v16_session_url") { db in
            try db.execute(sql:
                "ALTER TABLE interactiveSessions ADD COLUMN url TEXT")
        }

        // v17: per-inbox email provider. `provider` selects the EmailProvider
        // backend ('agentmail' default, or 'imap' for SwiftMail IMAP/SMTP);
        // `providerConfig` is JSON connection config for non-AgentMail providers
        // (host/ports + a SecretStore key ref for the password).
        registerMigration("v17_email_provider") { db in
            // do/catch ADD COLUMN idiom (matches v13/v18): the full-schema
            // baseline `CREATE TABLE emailInboxes` already includes these two
            // columns, so on a FRESH DB they exist before this migration runs
            // and a bare ALTER would fail with "duplicate column name". Older
            // installs (table predates the columns) still get them added here.
            do { try db.execute(sql: "ALTER TABLE emailInboxes ADD COLUMN provider TEXT NOT NULL DEFAULT 'agentmail'") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE emailInboxes ADD COLUMN providerConfig TEXT") } catch { /* column exists */ }
        }

        // v18: webview session governance + ownership fields. All additive,
        // all nullable / defaulted so restored pre-v18 rows are valid:
        //   ownerAgentId  — the bridge sessionKey of the agent that created
        //                   the session (drives the Agent Webviews tree
        //                   grouping + the owning-agent-death auto-close).
        //   partition     — cookie/data-store partition NAME (NULL = shared
        //                   WKWebsiteDataStore.default()). Immutable per session.
        //   status        — 'live' | 'suspended' | 'closed' (rows are deleted
        //                   on close, so persisted values are live|suspended).
        //   lastActivityAt— epoch ms of the last drive/navigation; the sweeper
        //                   reads this to decide idle-suspend / hard-close.
        //   background    — 1 = headless (driveable, not auto-mounted/selected).
        // The existing `url` column (v16) doubles as "last URL": the nav
        // delegate writes the committed URL back so resume reloads it.
        registerMigration("v18_webview_session_fields") { db in
            do { try db.execute(sql: "ALTER TABLE interactiveSessions ADD COLUMN ownerAgentId TEXT") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE interactiveSessions ADD COLUMN partition TEXT") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE interactiveSessions ADD COLUMN status TEXT NOT NULL DEFAULT 'live'") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE interactiveSessions ADD COLUMN lastActivityAt INTEGER") } catch { /* column exists */ }
            do { try db.execute(sql: "ALTER TABLE interactiveSessions ADD COLUMN background INTEGER NOT NULL DEFAULT 0") } catch { /* column exists */ }
            try db.execute(sql:
                "CREATE INDEX IF NOT EXISTS interactiveSessions_by_owner ON interactiveSessions(ownerAgentId)")
        }

        // v19: webview session governance config — a singleton row, exactly
        // like supervisorConfig (v3). Defaults: idle-suspend 5 min, hard-close
        // 30 min, max 8 concurrent live WKWebViews.
        registerMigration("v19_webview_session_config") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS webviewSessionConfig (
                    id              TEXT PRIMARY KEY DEFAULT 'singleton',
                    idleSuspendSec  INTEGER NOT NULL DEFAULT 300,
                    hardCloseSec    INTEGER NOT NULL DEFAULT 1800,
                    maxLiveSessions INTEGER NOT NULL DEFAULT 8,
                    updatedAt       INTEGER NOT NULL
                )
            """)
            try seedWebviewSessionConfigIfEmpty(in: db)
        }

        // v20: per-row pith-generation attempt counter. PithBackfill used to
        // re-select any row with NULL l0/l1 every batch, so a row whose
        // generation deterministically failed (truncated JSON, dead-letter
        // content) would loop forever — eventually crowding the SELECT and
        // grinding throughput to ~zero. Track attempts and skip rows past a
        // ceiling. NULL-by-default since legacy rows haven't been attempted.
        registerMigration("v20_pith_attempts") { db in
            do { try db.execute(sql: "ALTER TABLE memories ADD COLUMN pithAttempts INTEGER NOT NULL DEFAULT 0") } catch { /* column exists */ }
            try db.execute(sql:
                "CREATE INDEX IF NOT EXISTS memories_pith_backfill ON memories(pithAttempts) WHERE l0 IS NULL OR l1 IS NULL")
        }

        // v21: per-session model override for interactive sessions. Lets a tab
        // remember "this Sona session runs against Llama 3.1 8B" across
        // restarts — without it the model would silently revert to the
        // hardcoded Anthropic default on every --resume. NULL = default model.
        // Non-NULL values starting with `local/` are interpreted by spawnSona
        // as a local-server redirect (Phase F.4).
        registerMigration("v21_interactive_session_model") { db in
            do { try db.execute(sql: "ALTER TABLE interactiveSessions ADD COLUMN model TEXT") } catch { /* column exists */ }
        }

        // v22: user-installed local chat models (Phase F.3). Sonata ships with
        // a hardcoded LocalChatModelRegistry entry for Llama 3.1 8B; this
        // table lets users add arbitrary GGUF URLs (typically HuggingFace
        // resolve links) and have them appear as additional options in the
        // worker/session model pickers. Port assignment is monotonic — never
        // re-cycled on delete — so a removed-then-re-added model doesn't
        // inherit an unrelated server's port. ggufPath is on-disk location
        // populated by BinaryProvisioner; nil during in-flight downloads.
        registerMigration("v22_installed_chat_models") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS installedChatModels (
                    id           TEXT PRIMARY KEY,
                    modelName    TEXT NOT NULL UNIQUE,
                    displayName  TEXT NOT NULL,
                    sourceURL    TEXT NOT NULL,
                    sha256       TEXT,
                    port         INTEGER NOT NULL UNIQUE,
                    ggufPath     TEXT,
                    installedAt  INTEGER NOT NULL
                )
            """)
        }

        // v23: per-model extra llama-server spawn args. Some models need
        // model-specific flags that llama-server can't infer from the GGUF
        // metadata alone — most commonly RoPE/YaRN scaling for long context
        // (Qwen 2.5 32B trains at 32K and extends to 128K only when spawned
        // with `--rope-scaling yarn --rope-scale 4 --yarn-orig-ctx 32768`).
        // Without those, llama-server silently clamps n_ctx to the trained
        // size regardless of our --ctx-size request. Stored as a single
        // whitespace-separated string; split at spawn time.
        registerMigration("v23_installed_chat_models_extra_args") { db in
            do { try db.execute(sql: "ALTER TABLE installedChatModels ADD COLUMN extraArgs TEXT") } catch { /* column exists */ }
        }

        // v24: single-row table that holds the Global AFK toggle state. The
        // CHECK (id=1) constraint makes it impossible to have more than one
        // row — there's only ever one global flag. enabled stored as INTEGER
        // 0/1 (SQLite-native bool). enabledAt is the unix-ms timestamp of
        // the most recent flip. flippedBy records the surface that did it
        // (ui|mcp|api) for telemetry and the persistent banner copy.
        registerMigration("v24_global_afk") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS globalAFK (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    enabled INTEGER NOT NULL DEFAULT 0,
                    enabledAt INTEGER,
                    flippedBy TEXT
                )
                """)
            try db.execute(sql: "INSERT OR IGNORE INTO globalAFK (id, enabled) VALUES (1, 0)")
        }

        // v25: cached catalog of Anthropic models extracted from the user's
        // `claude` CLI binary. Rows upserted at boot + on Settings refresh;
        // `enabled` drives whether the entry appears in the Sessions/Workers
        // pickers. New extractions default enabled=1 (per Evan: any model we
        // discover is on by default, user can untick it). Rows never deleted —
        // if a future Claude Code drops a model we tombstone via lastSeenAt
        // rather than yanking it out from under sessions that reference it.
        registerMigration("v25_anthropic_models") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS anthropicModels (
                    id           TEXT PRIMARY KEY,
                    tier         TEXT NOT NULL,
                    version      TEXT NOT NULL,
                    isDated      INTEGER NOT NULL DEFAULT 0,
                    releaseDate  TEXT,
                    displayName  TEXT,
                    enabled      INTEGER NOT NULL DEFAULT 1,
                    firstSeenAt  INTEGER NOT NULL,
                    lastSeenAt   INTEGER NOT NULL
                )
                """)
            try db.execute(sql:
                "CREATE INDEX IF NOT EXISTS anthropicModels_by_tier ON anthropicModels(tier, enabled)")
        }
    }
}
