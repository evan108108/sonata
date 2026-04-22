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

    // MARK: backgroundJobs
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS backgroundJobs (
            id           TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
            name         TEXT NOT NULL,
            status       TEXT NOT NULL DEFAULT 'pending',
            prompt       TEXT NOT NULL,
            model        TEXT,
            maxTurns     INTEGER,
            result       TEXT,
            error        TEXT,
            createdAt    INTEGER NOT NULL,
            startedAt    INTEGER,
            completedAt  INTEGER
        )
    """)

    try db.execute(sql: "CREATE INDEX IF NOT EXISTS backgroundJobs_by_status      ON backgroundJobs(status)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS backgroundJobs_by_name_status ON backgroundJobs(name, status)")

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

/// Seed the emailInboxes table with the two historically hardcoded inboxes
/// if the table is empty. Idempotent — safe to call at startup or from a migration.
func seedEmailInboxesIfEmpty(in db: Database) throws {
    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM emailInboxes") ?? 0
    guard count == 0 else { return }

    let now = Int64(Date().timeIntervalSince1970 * 1000)
    try db.execute(sql: """
        INSERT INTO emailInboxes
            (id, address, role, displayName, enabled, autoReply, dispatchTo, createdAt, updatedAt)
        VALUES
            (lower(hex(randomblob(16))), 'sona@agentmail.to',        'sona',        'Sona (Primary)', 1, 1, 'worker', ?, ?),
            (lower(hex(randomblob(16))), 'scoutleader@agentmail.to', 'scoutleader', 'Scout Leader',    1, 1, 'worker', ?, ?)
    """, arguments: [now, now, now, now])
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
    }
}
