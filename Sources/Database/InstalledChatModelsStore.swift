import Foundation
import GRDB

// Persistence layer for user-installed local chat models (Phase F.3). Backs
// the v22 `installedChatModels` table. LocalChatModelRegistry reads from this
// at boot to populate its dynamic side; InstalledChatModelManager writes to it
// on install/delete.
//
// Synchronous reads/writes — used from the @MainActor view model and a
// lightweight install actor. GRDB's DatabasePool already serialises writes.

struct InstalledChatModel: FetchableRecord, Codable, Sendable {
    let id: String          // UUID string, stable per install
    let modelName: String   // short name used in `local/<modelName>` and --model arg
    let displayName: String // human-readable for the UI picker
    let sourceURL: String   // typically a HuggingFace resolve URL
    let sha256: String?     // optional integrity check; nil = trust the URL
    let port: Int           // monotonic loopback port assigned at install
    let ggufPath: String?   // nil while downloading; on-disk path once provisioned
    let installedAt: Int64  // epoch ms
}

enum InstalledChatModelsStore {

    static func loadAll(dbPool: DatabasePool) -> [InstalledChatModel] {
        do {
            return try dbPool.read { db in
                try InstalledChatModel.fetchAll(db, sql: """
                    SELECT id, modelName, displayName, sourceURL, sha256, port,
                           ggufPath, installedAt
                    FROM installedChatModels
                    ORDER BY installedAt ASC
                    """)
            }
        } catch {
            NSLog("[InstalledChatModelsStore] loadAll failed: \(error)")
            return []
        }
    }

    /// Insert a new row. Caller is responsible for picking a unique modelName
    /// and a unique port (use `nextAvailablePort` for the latter).
    static func insert(
        dbPool: DatabasePool,
        id: String,
        modelName: String,
        displayName: String,
        sourceURL: String,
        sha256: String?,
        port: Int,
        ggufPath: String?
    ) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO installedChatModels
                    (id, modelName, displayName, sourceURL, sha256, port,
                     ggufPath, installedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    id, modelName, displayName, sourceURL, sha256, port,
                    ggufPath, now,
                ])
        }
    }

    /// Update the on-disk path once BinaryProvisioner finishes the download.
    /// Stored separately from `insert` because the row is created first (so
    /// the UI can show "Downloading…") and the path is only known after.
    static func setGGUFPath(dbPool: DatabasePool, id: String, ggufPath: String) {
        do {
            try dbPool.write { db in
                try db.execute(sql:
                    "UPDATE installedChatModels SET ggufPath = ? WHERE id = ?",
                    arguments: [ggufPath, id])
            }
        } catch {
            NSLog("[InstalledChatModelsStore] setGGUFPath(\(id)) failed: \(error)")
        }
    }

    static func delete(dbPool: DatabasePool, id: String) {
        do {
            try dbPool.write { db in
                try db.execute(sql:
                    "DELETE FROM installedChatModels WHERE id = ?",
                    arguments: [id])
            }
        } catch {
            NSLog("[InstalledChatModelsStore] delete(\(id)) failed: \(error)")
        }
    }

    /// Monotonic port assignment. Returns one above the highest port currently
    /// in use (across both hardcoded registry entries and previously-installed
    /// user models, including deleted ones — we never re-cycle a port so a
    /// removed-then-re-added model doesn't inherit a former server's slot or
    /// any stale on-disk KV cache from that slot's lifetime.
    ///
    /// Falls back to `floor` (typically `LocalChatModelRegistry.basePort + 1`)
    /// when no rows exist yet.
    static func nextAvailablePort(dbPool: DatabasePool, floor: Int) -> Int {
        do {
            let maxUsed = try dbPool.read { db in
                try Int.fetchOne(db,
                    sql: "SELECT MAX(port) FROM installedChatModels") ?? 0
            }
            return max(floor, maxUsed + 1)
        } catch {
            NSLog("[InstalledChatModelsStore] nextAvailablePort failed: \(error)")
            return floor
        }
    }
}
