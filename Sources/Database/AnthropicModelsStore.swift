import Foundation
import GRDB
import os

// Persistence + in-memory snapshot for the catalog of Anthropic models the
// user's `claude` CLI accepts. Backs the v25 `anthropicModels` table.
//
// On boot the store extracts the model list from the resolved Claude Code
// binary, upserts into the table (new rows enabled=1, existing rows keep
// their `enabled` flag so user-untickings persist across launches), and
// publishes the snapshot for the Sessions / Workers pickers and the
// Settings → Anthropic Models checklist to observe.
//
// Re-extraction is gated by the binary's mtime — launching Sonata when the
// CLI hasn't been updated is a no-op beyond a single stat() call.

struct AnthropicModelRow: FetchableRecord, Codable, Sendable, Identifiable, Hashable {
    let id: String
    let tier: String
    let version: String
    let isDated: Bool
    let releaseDate: String?
    let displayName: String?
    let enabled: Bool
    let firstSeenAt: Int64
    let lastSeenAt: Int64

    init(row: Row) {
        self.id          = row["id"]
        self.tier        = row["tier"]
        self.version     = row["version"]
        self.isDated     = (row["isDated"] as Int? ?? 0) != 0
        self.releaseDate = row["releaseDate"]
        self.displayName = row["displayName"]
        self.enabled     = (row["enabled"] as Int? ?? 1) != 0
        self.firstSeenAt = row["firstSeenAt"]
        self.lastSeenAt  = row["lastSeenAt"]
    }
}

@MainActor
final class AnthropicModelStore: ObservableObject {
    static let shared = AnthropicModelStore()

    /// All known rows, sorted tier-canonical → version desc → dated last.
    /// Pickers filter to `enabled`; Settings shows everything.
    @Published private(set) var entries: [AnthropicModelRow] = []

    /// Last successful extraction's source binary mtime — cached to skip
    /// repeat scans when the CLI hasn't changed.
    private var lastExtractedMtime: Date?

    private var dbPool: DatabasePool?
    private let log = Logger(subsystem: "app.sonata", category: "AnthropicModels")

    private init() {}

    /// Convenience snapshot for callers that don't observe — `enabled` rows
    /// only, in display order.
    var enabledEntries: [AnthropicModelRow] {
        entries.filter(\.enabled)
    }

    /// Group enabled rows by tier in canonical order. Useful for the picker
    /// menus which want a divider between Opus / Sonnet / Haiku / Fable.
    var enabledByTier: [(tier: String, rows: [AnthropicModelRow])] {
        let grouped = Dictionary(grouping: enabledEntries, by: \.tier)
        return AnthropicModelExtractor.tiers.compactMap { tier in
            guard let rows = grouped[tier], !rows.isEmpty else { return nil }
            return (tier, rows)
        }
    }

    /// Boot-time bootstrap. Loads the cached rows from SQLite, then kicks
    /// off a fresh extraction in the background (skipped if mtime unchanged).
    func bootstrap(dbPool: DatabasePool, binaryPath: String) async {
        self.dbPool = dbPool
        await reloadFromDB()
        await refreshFromBinary(binaryPath: binaryPath, force: false)
    }

    /// Manual refresh — wired to the Settings → Anthropic Models "Refresh"
    /// button. Forces re-extraction even when the binary hasn't changed.
    func refresh(binaryPath: String) async {
        await refreshFromBinary(binaryPath: binaryPath, force: true)
    }

    /// Flip the `enabled` flag for a single row. Persists then re-renders.
    func setEnabled(_ enabled: Bool, for id: String) async {
        guard let dbPool else { return }
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE anthropicModels SET enabled = ? WHERE id = ?",
                    arguments: [enabled ? 1 : 0, id]
                )
            }
            await reloadFromDB()
        } catch {
            log.error("setEnabled(\(id, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Internals

    private func reloadFromDB() async {
        guard let dbPool else { return }
        do {
            let rows: [AnthropicModelRow] = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, tier, version, isDated, releaseDate, displayName,
                           enabled, firstSeenAt, lastSeenAt
                    FROM anthropicModels
                    """).map(AnthropicModelRow.init(row:))
            }
            let sorted = Self.sort(rows)
            await MainActor.run { self.entries = sorted }
        } catch {
            log.error("reloadFromDB failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshFromBinary(binaryPath: String, force: Bool) async {
        guard let dbPool else { return }
        let mtime = AnthropicModelExtractor.binaryMtime(binaryPath)
        if !force, let mtime, mtime == lastExtractedMtime {
            return
        }
        do {
            let extracted = try AnthropicModelExtractor.extract(binaryPath: binaryPath)
            guard !extracted.isEmpty else {
                log.warning("Extractor returned no entries for \(binaryPath, privacy: .public); skipping upsert")
                return
            }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            try await dbPool.write { db in
                for entry in extracted {
                    try db.execute(sql: """
                        INSERT INTO anthropicModels
                            (id, tier, version, isDated, releaseDate,
                             displayName, enabled, firstSeenAt, lastSeenAt)
                        VALUES (?, ?, ?, ?, ?, NULL, 1, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            tier        = excluded.tier,
                            version     = excluded.version,
                            isDated     = excluded.isDated,
                            releaseDate = excluded.releaseDate,
                            lastSeenAt  = excluded.lastSeenAt
                        """, arguments: [
                            entry.id, entry.tier, entry.version,
                            entry.isDated ? 1 : 0, entry.date,
                            now, now,
                        ])
                }
            }
            lastExtractedMtime = mtime
            await reloadFromDB()
            log.info("Refreshed \(extracted.count) Anthropic models from \(binaryPath, privacy: .public)")
        } catch {
            log.error("Extraction failed for \(binaryPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func sort(_ rows: [AnthropicModelRow]) -> [AnthropicModelRow] {
        let tierOrder = Dictionary(
            uniqueKeysWithValues: AnthropicModelExtractor.tiers.enumerated().map { ($1, $0) }
        )
        return rows.sorted { a, b in
            let ta = tierOrder[a.tier] ?? Int.max
            let tb = tierOrder[b.tier] ?? Int.max
            if ta != tb { return ta < tb }
            if a.version != b.version {
                return a.version.compare(b.version, options: .numeric) == .orderedDescending
            }
            return !a.isDated && b.isDated
        }
    }
}
