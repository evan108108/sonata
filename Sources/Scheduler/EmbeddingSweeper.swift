import Foundation
import GRDB
import Logging
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Keeps memoryEmbeddings in lockstep with memories.
///
/// Two jobs, one mechanism:
///   1. **Safety net** — any memory row that lands without an embedding
///      (mem_store's fire-and-forget embed failed, compression/ingestion
///      writers, the REST shim, historical backlog) gets picked up by the
///      periodic sweep and embedded via the local model.
///   2. **Backlog drain** — on boot it works through every missing row,
///      newest first, batch after batch with no idle pause until the
///      backlog is empty. (Discovered 2026-06-12: nothing had embedded
///      new memories since the 5/23 EmbeddingGemma cutover one-shot —
///      5.8K rows were invisible to vector recall.)
///
/// Archived memories are skipped — they're excluded from recall, so an
/// embedding would never be read.
actor EmbeddingSweeper {
    private let dbPool: DatabasePool
    private let logger: Logger
    private var task: Task<Void, Never>?

    /// Idle cadence once the backlog is drained. New memories normally get
    /// their embedding inline from mem_store; this is only the catch-up lag
    /// for writers that bypass it.
    private static let idleTickSeconds: TimeInterval = 60
    /// Rows per batch. EmbeddingGemma is local and fast; the batch bound
    /// exists so one tick never holds a DB read snapshot for minutes.
    private static let batchSize = 64

    init(dbPool: DatabasePool, logger: Logger) {
        self.dbPool = dbPool
        self.logger = logger
    }

    func start() {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                let processed = await self.tick()
                // Full batch ⇒ backlog remains ⇒ go straight to the next one.
                if processed < Self.batchSize {
                    try? await Task.sleep(nanoseconds: UInt64(Self.idleTickSeconds * 1_000_000_000))
                }
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    /// Embed up to one batch of missing rows. Returns the number processed
    /// (0 when nothing is missing or the embedding server is unavailable).
    private func tick() async -> Int {
        struct Pending { let id: String; let content: String }
        let pending: [Pending]
        do {
            pending = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT m.id, m.content FROM memories m
                    WHERE COALESCE(m.status, 'active') != 'archived'
                      AND NOT EXISTS (SELECT 1 FROM memoryEmbeddings e WHERE e.memoryId = m.id)
                    ORDER BY m.createdAt DESC
                    LIMIT \(Self.batchSize)
                    """).map { Pending(id: $0["id"], content: $0["content"]) }
            }
        } catch {
            logger.error("embedding sweep: pending query failed: \(error)")
            return 0
        }
        guard !pending.isEmpty else { return 0 }

        var done = 0
        for row in pending {
            do {
                try await embedMemoryIfMissing(dbPool: dbPool, memoryId: row.id, content: row.content)
                done += 1
            } catch {
                // Embedding server down/cold — abort the batch, retry next tick.
                logger.warning("embedding sweep: stopped after \(done)/\(pending.count): \(error)")
                break
            }
        }
        if done > 0 {
            logger.info("embedding sweep: embedded \(done) memories")
        }
        return done
    }
}

/// Generate and store the embedding for one memory, unless one already
/// exists. Shared by the sweeper and mem_store's embed-on-insert path;
/// the EXISTS guard inside the write makes the two safe to race.
func embedMemoryIfMissing(dbPool: DatabasePool, memoryId: String, content: String) async throws {
    let vector = try await embedText(content, isQuery: false)
    let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
    let hash = embeddingContentHash(content)
    let now = nowMs()
    try await dbPool.write { db in
        let exists = try Bool.fetchOne(db,
            sql: "SELECT EXISTS(SELECT 1 FROM memoryEmbeddings WHERE memoryId = ?)",
            arguments: [memoryId]) ?? false
        guard !exists else { return }
        try db.execute(
            sql: """
            INSERT INTO memoryEmbeddings
                (id, memoryId, embedding, model, dimensions, contentHash, createdAt)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                newUUID(), memoryId, blob,
                EmbeddingProvider.current.modelId, vector.count,
                hash, now,
            ]
        )
    }
}

/// SHA256 content hash — same format embedding_store writes (EmbeddingActions).
private func embeddingContentHash(_ string: String) -> String {
    let data = Data(string.utf8)
    var hash = [UInt8](repeating: 0, count: 32)
    data.withUnsafeBytes { buf in
        _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &hash)
    }
    return hash.map { String(format: "%02x", $0) }.joined()
}
