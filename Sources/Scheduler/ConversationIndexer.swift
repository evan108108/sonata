import Foundation
import GRDB
import Logging

/// Keeps the Meili `emails` and `sessions` indexes in lockstep with reality,
/// restoring the search subsystem's original purpose: conversation-log search
/// ("did we talk about it?"). Spotlight could never index `~/.claude/` or
/// `~/.sonata/` (dotfile dirs, hardcoded mds exclusion); Meili was adopted
/// 2026-04-20 to replace it but only ever got wiki/docs — this closes the gap.
///
/// Two feeds, one actor:
///   * **Emails** (every tick): rows from the `emails` table newer than the
///     in-memory high-water mark, plus a periodic count-drift resync.
///   * **Transcripts** (every 5th tick): `~/.claude/projects/**/*.jsonl`,
///     user + assistant text only (no thinking/tool noise), chunked. JSONL is
///     append-only, so per-file byte offsets (transcriptIndexState) let each
///     sweep read only the new bytes of active sessions.
actor ConversationIndexer {
    private let dbPool: DatabasePool
    private let search: any SearchService
    private let logger: Logger
    private var task: Task<Void, Never>?

    private static let tickSeconds: TimeInterval = 60
    private static let transcriptEveryNthTick = 5
    /// Target text size per session chunk doc. Each sweep's new text becomes
    /// its own chunk(s) — chunks are never rewritten, so active sessions
    /// accrete small tail chunks instead of churning existing docs.
    private static let chunkChars = 12_000
    /// Meili batch size per POST.
    private static let docBatch = 200
    /// First-pass time budget per transcript sweep; the state table makes the
    /// next sweep resume where this one stopped.
    private static let sweepBudgetSeconds: TimeInterval = 55

    private var emailHighWaterMs: Int64 = 0
    private var tickCount = 0
    /// Exposed for the recall health block.
    private(set) var lastTranscriptSweepMs: Int64 = 0

    /// A transcript sweep is running. indexTranscript posts a file's chunks in
    /// batches and records chunkCount only at the end, so mid-sweep the index
    /// can run ahead of SUM(chunkCount) with nothing wrong.
    private var sweepInProgress = false
    /// The launch convergence pass (prune / reset) is running. Sweeps stand
    /// down meanwhile, because the prune reads the index and the state table
    /// together and a half-written file would look like an over-count.
    private var maintenanceInProgress = false
    /// Work is known to be outstanding: set by a full reset or by a sweep that
    /// stopped at its time budget, cleared by a sweep that finishes within it.
    private var backlogPending = false

    private let projectsRoot: String

    init(dbPool: DatabasePool, search: any SearchService, logger: Logger,
         projectsRoot: String = NSHomeDirectory() + "/.claude/projects",
         settleTimeoutSeconds: TimeInterval = 120) {
        self.dbPool = dbPool
        self.search = search
        self.logger = logger
        self.projectsRoot = projectsRoot
        self.settleTimeoutSeconds = settleTimeoutSeconds
    }

    /// True while the sessions index is legitimately out of step with
    /// SUM(chunkCount): a sweep or the launch pass is running, or a backlog is
    /// still draining. HealthMonitor's index_sessions check holds its strike
    /// count while this is true.
    var isRebuilding: Bool { sweepInProgress || maintenanceInProgress || backlogPending }

    func start() {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(Self.tickSeconds * 1_000_000_000))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    /// What the launch convergence pass did, for logging and tests.
    struct BackfillOutcome: Sendable, Equatable {
        /// State rows dropped because their .jsonl is gone.
        var purgedRows = 0
        /// True when lost writes forced the full reset (the 9/16 recovery path).
        var fullReset = false
        var resetRows = 0
        /// Docs deleted because no state row accounts for them.
        var prunedDocs = 0
        /// The pass couldn't read a settled index, so it decided nothing.
        var skippedUnsettled = false
    }

    /// How long the launch pass waits for Meili's queue for `sessions` to
    /// drain before it decides anything from the doc count.
    private let settleTimeoutSeconds: TimeInterval

    /// Launch convergence pass for the `sessions` index. It runs once per
    /// launch, from a detached Task so it never blocks boot.
    ///
    /// Until 11/18 this reset EVERY state row on every launch: it deleted all
    /// chunks and re-indexed all ~310 transcripts from offset 0, multi-GB per
    /// relaunch (one transcript is 743 MB). Mid-rebuild the index runs ahead of
    /// SUM(chunkCount), because chunkCount is saved only when a file finishes,
    /// so two relaunches 15 min apart tripped index_sessions 3 times. Now:
    ///
    /// 1. Wait for a running sweep, then hold sweeps off.
    /// 2. Drop state rows whose .jsonl is gone, deleting their docs by session.
    /// 3. If the index is settled (no queued writes) and holds FEWER docs than
    ///    SUM(chunkCount) beyond the index_sessions tolerance, writes were
    ///    lost: full reset. This is the 9/16 recovery path. The 2026-09-16
    ///    .17→scout-cloud migration hit a SQLite corruption storm mid-write, so
    ///    785 rows / 9,031 chunks were recorded but never reached Meili. The
    ///    5-tick sweep skips unchanged files, so only a reset drains that.
    /// 4. Otherwise prune by session: docs whose session has no state row, and
    ///    docs at or above their session's chunkCount. Deletes by id range
    ///    0..<chunkCount can never reach those, so they used to leak forever.
    /// 5. Kick a sweep so any reset or backlog starts draining now.
    @discardableResult
    func backfillMissing() async -> BackfillOutcome {
        while sweepInProgress {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // No await between the check above and this line, so no sweep can
        // start in between (sweepTranscripts checks this flag first).
        maintenanceInProgress = true
        let outcome = await converge()
        maintenanceInProgress = false

        await sweepTranscripts()
        lastTranscriptSweepMs = nowMs()
        return outcome
    }

    private struct StateRow {
        let path: String
        let sessionId: String
        let chunkCount: Int
    }

    private func converge() async -> BackfillOutcome {
        var outcome = BackfillOutcome()
        let rows: [StateRow]
        do {
            rows = try await dbPool.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT path, sessionId, chunkCount FROM transcriptIndexState"
                ).map {
                    StateRow(path: $0["path"], sessionId: $0["sessionId"], chunkCount: $0["chunkCount"])
                }
            }
        } catch {
            logger.error("conversation index: backfill state read failed: \(error)")
            return outcome
        }

        let fm = FileManager.default
        var orphans: [StateRow] = []
        var live: [StateRow] = []
        for r in rows {
            if fm.fileExists(atPath: r.path) { live.append(r) } else { orphans.append(r) }
        }

        // 1. Drop orphan rows (source file gone; can never be re-chunked) and
        //    their docs. By session, not by id range, so docs above a stale
        //    chunkCount go too. Skip a session a live row still shares.
        if !orphans.isEmpty {
            let liveSessions = Set(live.map(\.sessionId))
            for sid in Set(orphans.map(\.sessionId)) where !liveSessions.contains(sid) {
                await search.removeSessionChunks(sessionId: sid)
            }
            let orphanPaths = orphans.map { $0.path }
            do {
                try await dbPool.write { db in
                    for chunk in stride(from: 0, to: orphanPaths.count, by: 500) {
                        let slice = Array(orphanPaths[chunk..<min(chunk + 500, orphanPaths.count)])
                        let ph = slice.map { _ in "?" }.joined(separator: ",")
                        try db.execute(
                            sql: "DELETE FROM transcriptIndexState WHERE path IN (\(ph))",
                            arguments: StatementArguments(slice))
                    }
                }
                outcome.purgedRows = orphans.count
                logger.info("conversation index: pruned \(orphans.count) orphan transcript rows (source file missing)")
            } catch {
                logger.error("conversation index: orphan prune failed: \(error)")
            }
        }

        // 2. Read the index only once its queue is empty. A count taken while
        //    writes are queued says nothing about lost writes.
        let deadline = Date().addingTimeInterval(settleTimeoutSeconds)
        var pending = await search.pendingTaskCount(index: "sessions")
        while pending > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            pending = await search.pendingTaskCount(index: "sessions")
        }
        let indexed = await search.documentCount(index: "sessions")
        guard pending == 0, indexed >= 0 else {
            outcome.skippedUnsettled = true
            logger.warning("conversation index: sessions index not settled (pending \(pending), count \(indexed)); skipping reset/prune this launch")
            return outcome
        }

        // 3. Lost writes → full reset (the 9/16 path).
        let source = live.reduce(0) { $0 + $1.chunkCount }
        if source - indexed > HealthMonitor.indexDriftTolerance(source: source) {
            await search.removeAllSessionChunks()
            do {
                try await dbPool.write { db in
                    try db.execute(sql: """
                        UPDATE transcriptIndexState
                        SET lastSize = 0, lastMtimeMs = 0, lastOffset = 0, chunkCount = 0
                        """)
                }
            } catch {
                logger.error("conversation index: state reset failed: \(error)")
                return outcome
            }
            backlogPending = true
            outcome.fullReset = true
            outcome.resetRows = live.count
            logger.warning("conversation index: sessions index has \(indexed) docs but state records \(source) — lost writes; reset \(live.count) transcript rows for a full re-index")
            return outcome
        }

        // 4. Prune docs no state row accounts for.
        guard let refs = await search.listSessionChunkRefs() else {
            logger.warning("conversation index: could not list sessions docs; orphan prune skipped")
            return outcome
        }
        var recorded: [String: Int] = [:]
        for r in live { recorded[r.sessionId] = max(recorded[r.sessionId] ?? 0, r.chunkCount) }
        var unknownSessions: [String: Int] = [:]
        var overCount: [String] = []
        for ref in refs {
            if let count = recorded[ref.sessionId] {
                if ref.chunk < 0 || ref.chunk >= count { overCount.append(ref.id) }
            } else {
                unknownSessions[ref.sessionId, default: 0] += 1
            }
        }
        for (sid, _) in unknownSessions {
            await search.removeSessionChunks(sessionId: sid)
        }
        if !overCount.isEmpty {
            await search.removeSessionChunks(ids: overCount)
        }
        outcome.prunedDocs = overCount.count + unknownSessions.values.reduce(0, +)
        if outcome.prunedDocs > 0 {
            logger.info("conversation index: pruned \(outcome.prunedDocs) orphan session docs (\(unknownSessions.count) sessions with no state row, \(overCount.count) above their chunkCount)")
        }
        return outcome
    }

    func healthSnapshot() async -> (lastSweepMs: Int64, filesIndexed: Int, rebuilding: Bool) {
        let files = (try? await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcriptIndexState") ?? 0
        }) ?? 0
        return (lastTranscriptSweepMs, files, isRebuilding)
    }

    /// Test seam: one transcript sweep, as tick() runs it.
    func sweepForTesting() async { await sweepTranscripts() }

    private func tick() async {
        tickCount += 1
        await syncEmails()
        // Drift self-heal: if the index lost docs (wiped index, failed posts),
        // reset the high-water mark so the next tick re-upserts everything.
        if tickCount % 30 == 1 {
            await checkEmailDrift()
        }
        if tickCount % Self.transcriptEveryNthTick == 1 {
            await sweepTranscripts()
            lastTranscriptSweepMs = nowMs()
        }
    }

    // MARK: - Emails

    private struct EmailDoc {
        let id: String, threadId: String, fromAddr: String, toAddr: String
        let subject: String, body: String, receivedAt: Int64
    }

    private func syncEmails() async {
        let mark = emailHighWaterMs
        let rows: [EmailDoc]
        do {
            rows = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, threadId, fromAddr, toAddr, subject, body, receivedAt
                    FROM emails WHERE receivedAt > ? ORDER BY receivedAt ASC
                    """, arguments: [mark]).map {
                    EmailDoc(id: $0["id"], threadId: $0["threadId"], fromAddr: $0["fromAddr"],
                             toAddr: $0["toAddr"], subject: $0["subject"], body: $0["body"],
                             receivedAt: $0["receivedAt"])
                }
            }
        } catch {
            logger.error("conversation index: email query failed: \(error)")
            return
        }
        guard !rows.isEmpty else { return }

        for start in stride(from: 0, to: rows.count, by: Self.docBatch) {
            let batch = rows[start..<min(start + Self.docBatch, rows.count)]
            let docs: [[String: String]] = batch.map { row in
                [
                    "id": row.id,
                    "threadId": row.threadId,
                    "fromAddr": row.fromAddr,
                    "toAddr": row.toAddr,
                    "subject": row.subject,
                    "body": String(row.body.prefix(50_000)),
                    "receivedAt": "\(row.receivedAt)",
                ]
            }
            await search.indexEmailDocs(docs)
        }
        emailHighWaterMs = rows.last!.receivedAt
        logger.info("conversation index: indexed \(rows.count) emails")
    }

    private func checkEmailDrift() async {
        let indexed = await search.documentCount(index: "emails")
        guard indexed >= 0 else { return }  // Meili unreachable; skip
        let table = (try? await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM emails") ?? 0
        }) ?? 0
        if indexed < table {
            logger.warning("conversation index: emails drift (index \(indexed) < table \(table)) — full resync")
            emailHighWaterMs = 0
        }
    }

    // MARK: - Transcripts

    private struct FileState {
        let lastSize: Int64
        let lastMtimeMs: Int64
        let lastOffset: Int64
        let chunkCount: Int
    }

    private func sweepTranscripts() async {
        // One sweep at a time, and none during the launch pass.
        guard !maintenanceInProgress, !sweepInProgress else { return }
        sweepInProgress = true
        defer { sweepInProgress = false }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: projectsRoot) else { return }

        var paths: [String] = []
        while let rel = enumerator.nextObject() as? String {
            if rel.hasSuffix(".jsonl") { paths.append(projectsRoot + "/" + rel) }
        }

        let deadline = Date().addingTimeInterval(Self.sweepBudgetSeconds)
        var filesTouched = 0
        var chunksWritten = 0
        var hitBudget = false
        for path in paths {
            if Date() > deadline {
                hitBudget = true
                logger.info("conversation index: sweep budget reached after \(filesTouched) files; resuming next sweep")
                break
            }
            do {
                let n = try await indexTranscript(path: path)
                if n > 0 { filesTouched += 1; chunksWritten += n }
            } catch {
                logger.warning("conversation index: \(path): \(error)")
            }
        }
        if chunksWritten > 0 {
            logger.info("conversation index: \(chunksWritten) session chunks from \(filesTouched) files")
        }
        // A sweep that reached every file has drained any backlog; one that
        // stopped at its budget leaves work for the next.
        backlogPending = hitBudget
    }

    /// Returns the number of chunks written (0 = file unchanged).
    private func indexTranscript(path: String) async throws -> Int {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return 0 }
        let mtimeMs = Int64(mtime.timeIntervalSince1970 * 1000)
        let sessionId = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        let project = relativeProject(of: path)

        let state: FileState? = try await dbPool.read { db in
            try Row.fetchOne(db,
                sql: "SELECT lastSize, lastMtimeMs, lastOffset, chunkCount FROM transcriptIndexState WHERE path = ?",
                arguments: [path]).map {
                FileState(lastSize: $0["lastSize"], lastMtimeMs: $0["lastMtimeMs"],
                          lastOffset: $0["lastOffset"], chunkCount: $0["chunkCount"])
            }
        }

        var startOffset: Int64 = 0
        var chunkIndex = 0
        if let s = state {
            if s.lastSize == size && s.lastMtimeMs == mtimeMs { return 0 }  // unchanged
            if size >= s.lastSize {
                // Append-only growth — read just the new bytes.
                startOffset = s.lastOffset
                chunkIndex = s.chunkCount
            } else {
                // File shrank: rewritten (e.g. resumed session rewrote history).
                // Drop ALL its docs and re-index from scratch. By session, not
                // by 0..<chunkCount: a recorded count below the real one (a run
                // that died mid-file) would leave the docs above it forever.
                await search.removeSessionChunks(sessionId: sessionId)
            }
        }

        let (text, endOffset) = try Self.extractText(path: path, from: startOffset)
        guard !text.isEmpty else {
            try await saveState(path: path, sessionId: sessionId, size: size,
                                mtimeMs: mtimeMs, offset: endOffset, chunkCount: chunkIndex)
            return 0
        }

        var docs: [[String: String]] = []
        var written = 0
        var idx = text.startIndex
        while idx < text.endIndex {
            let end = text.index(idx, offsetBy: Self.chunkChars, limitedBy: text.endIndex) ?? text.endIndex
            docs.append([
                "id": "\(sessionId)_\(chunkIndex)",
                "sessionId": sessionId,
                "project": project,
                "chunk": "\(chunkIndex)",
                "text": String(text[idx..<end]),
                "mtimeMs": "\(mtimeMs)",
            ])
            chunkIndex += 1
            idx = end
            if docs.count >= Self.docBatch {
                await search.indexSessionChunks(docs)
                written += docs.count
                docs.removeAll()
            }
        }
        if !docs.isEmpty {
            await search.indexSessionChunks(docs)
            written += docs.count
        }

        try await saveState(path: path, sessionId: sessionId, size: size,
                            mtimeMs: mtimeMs, offset: endOffset, chunkCount: chunkIndex)
        return written
    }

    private func saveState(path: String, sessionId: String, size: Int64,
                           mtimeMs: Int64, offset: Int64, chunkCount: Int) async throws {
        try await dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO transcriptIndexState
                    (path, sessionId, lastSize, lastMtimeMs, lastOffset, chunkCount, indexedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    lastSize = excluded.lastSize, lastMtimeMs = excluded.lastMtimeMs,
                    lastOffset = excluded.lastOffset, chunkCount = excluded.chunkCount,
                    indexedAt = excluded.indexedAt
                """, arguments: [path, sessionId, size, mtimeMs, offset, chunkCount, nowMs()])
        }
    }

    /// "<project-dir>" for ~/.claude/projects/<project-dir>/.../<file>.jsonl
    private func relativeProject(of path: String) -> String {
        let root = NSHomeDirectory() + "/.claude/projects/"
        guard path.hasPrefix(root) else { return "" }
        return String(path.dropFirst(root.count)).components(separatedBy: "/").first ?? ""
    }

    // MARK: - Text extraction

    /// Read complete JSONL lines from `offset`, returning searchable
    /// conversation text ("U:"/"A:" prefixed) and the byte offset after the
    /// last complete line (a partial trailing line is left for the next sweep).
    /// Keeps user prompts and assistant text blocks; drops thinking, tool
    /// calls/results, and harness wrappers — search should match what was
    /// SAID, not machinery.
    static func extractText(path: String, from offset: Int64) throws -> (text: String, endOffset: Int64) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return ("", offset) }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        var out = String()
        var consumed: Int64 = offset
        var carry = Data()
        let newline = UInt8(ascii: "\n")

        while true {
            guard let block = try handle.read(upToCount: 4 * 1024 * 1024), !block.isEmpty else { break }
            carry.append(block)
            while let nl = carry.firstIndex(of: newline) {
                let lineData = carry.subdata(in: carry.startIndex..<nl)
                let lineBytes = Int64(nl - carry.startIndex) + 1
                carry.removeSubrange(carry.startIndex...nl)
                consumed += lineBytes
                if let line = extractLineText(lineData) {
                    out += line
                    out += "\n"
                }
            }
        }
        return (out, consumed)
    }

    /// One JSONL line → "U: ..."/"A: ..." or nil for non-conversation lines.
    private static func extractLineText(_ data: Data) -> String? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String, type == "user" || type == "assistant",
              let msg = obj["message"] as? [String: Any] else { return nil }

        var text: String?
        if let s = msg["content"] as? String {
            text = s
        } else if let blocks = msg["content"] as? [[String: Any]] {
            let parts = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            if !parts.isEmpty { text = parts.joined(separator: " ") }
        }
        guard var t = text, !t.isEmpty else { return nil }

        // Same non-prompt wrappers the dashboard filters (harness machinery,
        // not conversation).
        let nonPromptPrefixes = [
            "<system-reminder>", "<local-command-caveat>", "<local-command-stdout>",
            "<command-name>", "<command-message>", "<command-args>",
            "<channel source=", "<task-notification>", "This session is being continued",
        ]
        for prefix in nonPromptPrefixes where t.hasPrefix(prefix) { return nil }

        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return (type == "user" ? "U: " : "A: ") + t
    }
}
