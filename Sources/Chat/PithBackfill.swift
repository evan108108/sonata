import Foundation
import GRDB
import Logging

/// One-shot pith L0/L1 backfill for memories created before pith-on-insert
/// landed. Long-running: each row costs one chat-server roundtrip (~3-5s on
/// Llama 3.1 8B), so a fresh DB with ~15k NULL rows takes ~16 hours.
///
/// Idempotent: each UPDATE is atomic per row, and the WHERE filter naturally
/// resumes from where a prior run left off. Errors per-row are logged but
/// don't stop the run (the row stays NULL and gets picked up next launch).
///
/// Trigger: `SonataApp.swift` kicks off `run(dbPool:)` in a detached Task on
/// startup so it doesn't block boot. The first batch lazily starts the chat
/// server (downloading the 4.6 GB GGUF on absolute first run).
actor PithBackfill {
    static let shared = PithBackfill()

    private let logger: Logger
    private var isRunning = false
    private var totalNeeded = 0
    private var processed = 0
    private var succeeded = 0
    private var failed = 0

    init() {
        var log = Logger(label: "sonata.pithbackfill")
        log.logLevel = .info
        self.logger = log
    }

    /// Tunable batch size — small batches let progress logs land regularly and
    /// shorten the "wasted work on quit" window.
    private static let batchSize = 50

    /// Log a progress line every N rows.
    private static let progressInterval = 25

    struct Status: Sendable {
        let isRunning: Bool
        let totalNeeded: Int
        let processed: Int
        let succeeded: Int
        let failed: Int
    }

    func status() -> Status {
        Status(
            isRunning: isRunning,
            totalNeeded: totalNeeded,
            processed: processed,
            succeeded: succeeded,
            failed: failed
        )
    }

    /// Process all memories with NULL `l0` or `l1`. Safe to call repeatedly;
    /// only one run executes at a time.
    ///
    /// Kill switch: set `SONATA_PITH_BACKFILL=0` in the environment to skip the
    /// run entirely (the count is still logged for visibility). Use this when
    /// the chat server is misbehaving and you want to launch Sonata without it
    /// thrashing in the background.
    func run(dbPool: DatabasePool) async {
        if ProcessInfo.processInfo.environment["SONATA_PITH_BACKFILL"] == "0" {
            logger.info("backfill disabled via SONATA_PITH_BACKFILL=0; skipping")
            return
        }
        guard !isRunning else {
            logger.info("backfill already in progress; skipping")
            return
        }
        isRunning = true
        defer { isRunning = false }

        let needed: Int
        do {
            needed = try await dbPool.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM memories WHERE l0 IS NULL OR l1 IS NULL"
                ) ?? 0
            }
        } catch {
            logger.error("backfill: count query failed: \(error)")
            return
        }

        guard needed > 0 else {
            logger.info("nothing to backfill (no memories with NULL l0/l1)")
            return
        }

        totalNeeded = needed
        processed = 0
        succeeded = 0
        failed = 0
        logger.info("starting pith backfill: \(needed) memories with NULL l0/l1")

        while !Task.isCancelled {
            let batch: [(id: String, content: String)]
            do {
                batch = try await dbPool.read { db in
                    try Row.fetchAll(
                        db,
                        sql: """
                            SELECT id, content FROM memories
                            WHERE l0 IS NULL OR l1 IS NULL
                            ORDER BY createdAt DESC
                            LIMIT ?
                            """,
                        arguments: [Self.batchSize]
                    ).map { (id: $0["id"] as String, content: $0["content"] as String) }
                }
            } catch {
                logger.error("backfill: fetch failed: \(error)")
                break
            }

            if batch.isEmpty { break }

            for row in batch {
                if Task.isCancelled { break }
                await processOne(id: row.id, content: row.content, dbPool: dbPool)
                processed += 1
                if processed % Self.progressInterval == 0 {
                    logger.info("backfill progress: \(processed)/\(totalNeeded) (succeeded=\(succeeded), failed=\(failed))")
                }
            }
        }

        logger.info("backfill complete: processed=\(processed), succeeded=\(succeeded), failed=\(failed)")
    }

    private func processOne(id: String, content: String, dbPool: DatabasePool) async {
        guard let pith = await Pith.generateOrNil(content: content, logger: logger) else {
            failed += 1
            return
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE memories SET l0 = ?, l1 = ?, updatedAt = ? WHERE id = ?",
                    arguments: [pith.l0, pith.l1, now, id]
                )
            }
            succeeded += 1
        } catch {
            logger.error("backfill: UPDATE failed for \(id): \(error)")
            failed += 1
        }
    }
}
