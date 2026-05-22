import Foundation
import GRDB

// Persistence layer for the in-rail Interactive Sessions tab. Backs migration
// v14's `interactiveSessions` table. The view model (singleton) talks to
// this on every mutation so the next Sonata launch can reconstruct the tab
// list and reattach to each session via Claude Code's `--resume <sessionId>`.
//
// Synchronous reads/writes — used from the @MainActor view model. GRDB's
// DatabasePool serialises writes already, and these calls are tiny so we
// don't bother with an actor.

struct PersistedInteractiveSession: FetchableRecord, Codable {
    let id: String          // matches InteractiveSessionTab.id (UUID string)
    let sessionId: String   // Claude session id for --resume
    let name: String
    let cwd: String
    let position: Int
    let wasActive: Int
    let kind: String        // SessionKind.rawValue ("sona" | "terminal" | "webview")
    let url: String?        // target URL for webview sessions; nil otherwise
    let createdAt: Int64
    let updatedAt: Int64
}

enum InteractiveSessionsStore {

    static func loadAll(dbPool: DatabasePool) -> [PersistedInteractiveSession] {
        do {
            return try dbPool.read { db in
                try PersistedInteractiveSession.fetchAll(db, sql: """
                    SELECT id, sessionId, name, cwd, position, wasActive, kind, url, createdAt, updatedAt
                    FROM interactiveSessions
                    ORDER BY position ASC, createdAt ASC
                    """)
            }
        } catch {
            NSLog("[InteractiveSessionsStore] loadAll failed: \(error)")
            return []
        }
    }

    static func upsert(
        dbPool: DatabasePool,
        id: String,
        sessionId: String,
        name: String,
        cwd: String,
        position: Int,
        wasActive: Bool,
        kind: String,
        url: String?
    ) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO interactiveSessions
                        (id, sessionId, name, cwd, position, wasActive, kind, url, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        sessionId = excluded.sessionId,
                        name      = excluded.name,
                        cwd       = excluded.cwd,
                        position  = excluded.position,
                        wasActive = excluded.wasActive,
                        kind      = excluded.kind,
                        url       = excluded.url,
                        updatedAt = excluded.updatedAt
                    """, arguments: [
                        id, sessionId, name, cwd, position, wasActive ? 1 : 0, kind, url, now, now
                    ])
            }
        } catch {
            NSLog("[InteractiveSessionsStore] upsert(\(id)) failed: \(error)")
        }
    }

    static func updateName(dbPool: DatabasePool, id: String, name: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try dbPool.write { db in
                try db.execute(sql: """
                    UPDATE interactiveSessions
                    SET name = ?, updatedAt = ?
                    WHERE id = ?
                    """, arguments: [name, now, id])
            }
        } catch {
            NSLog("[InteractiveSessionsStore] updateName(\(id)) failed: \(error)")
        }
    }

    /// Re-write every row's `position` in one transaction to match the
    /// order of `ids`. Called whenever the tab list is reordered or when
    /// a tab is closed (renumbers the survivors to a contiguous range).
    static func updatePositions(dbPool: DatabasePool, ids: [String]) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try dbPool.write { db in
                for (i, id) in ids.enumerated() {
                    try db.execute(sql: """
                        UPDATE interactiveSessions
                        SET position = ?, updatedAt = ?
                        WHERE id = ?
                        """, arguments: [i, now, id])
                }
            }
        } catch {
            NSLog("[InteractiveSessionsStore] updatePositions failed: \(error)")
        }
    }

    /// Mark exactly one row as active and clear `wasActive` on every other
    /// row. Used so the next launch restores selection along with tabs.
    static func setActive(dbPool: DatabasePool, id: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try dbPool.write { db in
                try db.execute(sql:
                    "UPDATE interactiveSessions SET wasActive = 0, updatedAt = ?",
                    arguments: [now])
                try db.execute(sql:
                    "UPDATE interactiveSessions SET wasActive = 1, updatedAt = ? WHERE id = ?",
                    arguments: [now, id])
            }
        } catch {
            NSLog("[InteractiveSessionsStore] setActive(\(id)) failed: \(error)")
        }
    }

    static func delete(dbPool: DatabasePool, id: String) {
        do {
            try dbPool.write { db in
                try db.execute(sql:
                    "DELETE FROM interactiveSessions WHERE id = ?",
                    arguments: [id])
            }
        } catch {
            NSLog("[InteractiveSessionsStore] delete(\(id)) failed: \(error)")
        }
    }
}
