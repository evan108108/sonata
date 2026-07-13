import Foundation
import GRDB

/// Manages the SQLite database lifecycle: path resolution, pool creation,
/// WAL configuration, and migration execution.
enum DatabaseManager {

    // MARK: - Path Configuration

    /// Data directory: ~/.sonata/, or `$SONATA_DATA_DIR` when set.
    /// Created automatically on first launch. See `SonataInstance.dataDirectory`
    /// — setting `$HOME` does NOT redirect this.
    static let dataDirectory: String = SonataInstance.dataDirectory

    /// Default database path: ~/.sonata/sonata.db
    static let defaultPath: String = {
        return "\(dataDirectory)/sonata.db"
    }()

    /// Create the full ~/.sonata/ directory structure on first launch
    static func ensureDataDirectory() throws {
        let fm = FileManager.default
        for subdir in ["", "wiki", "private", "documents", "logs", "backups"] {
            let path = subdir.isEmpty ? dataDirectory : "\(dataDirectory)/\(subdir)"
            if !fm.fileExists(atPath: path) {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
            }
        }
    }

    // MARK: - Database Initialization

    /// Opens (or creates) the SQLite database at the given path,
    /// runs all pending migrations, and returns a configured DatabasePool.
    ///
    /// DatabasePool uses WAL mode by default — no explicit PRAGMA needed.
    /// WAL enables concurrent reads during writes, which is critical since
    /// the HTTP server reads while background tasks write.
    ///
    /// - Parameter path: Full path to the .db file. Parent directory is
    ///   created automatically if missing.
    /// - Returns: A ready-to-use DatabasePool.
    /// - Throws: GRDB or filesystem errors.
    static func openDatabase(at path: String = defaultPath) throws -> DatabasePool {
        // Ensure ~/.sonata/ directory structure exists
        try ensureDataDirectory()

        // Open with default configuration.
        // DatabasePool automatically enables WAL mode.
        // Foreign keys are enabled by default in GRDB.
        let dbPool = try DatabasePool(path: path)

        // Run migrations — only unapplied migrations execute
        var migrator = DatabaseMigrator()

        // NEVER erase on schema change — we have real data.
        // Use proper migrations instead (registerMigration with version keys).
        // migrator.eraseDatabaseOnSchemaChange was here but destroyed
        // 5000+ memories on 2026-04-14 after a rebuild. Removed permanently.

        migrator.registerSonataSchema()
        try migrator.migrate(dbPool)

        return dbPool
    }
}
