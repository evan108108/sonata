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

    init(dbPool: DatabasePool, search: any SearchService, logger: Logger) {
        self.dbPool = dbPool
        self.search = search
        self.logger = logger
    }

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

    func healthSnapshot() async -> (lastSweepMs: Int64, filesIndexed: Int) {
        let files = (try? await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcriptIndexState") ?? 0
        }) ?? 0
        return (lastTranscriptSweepMs, files)
    }

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
        let projectsRoot = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: projectsRoot) else { return }

        var paths: [String] = []
        while let rel = enumerator.nextObject() as? String {
            if rel.hasSuffix(".jsonl") { paths.append(projectsRoot + "/" + rel) }
        }

        let deadline = Date().addingTimeInterval(Self.sweepBudgetSeconds)
        var filesTouched = 0
        var chunksWritten = 0
        for path in paths {
            if Date() > deadline {
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
                // Drop its docs and re-index from scratch.
                await search.removeSessionChunks(ids: (0..<s.chunkCount).map { "\(sessionId)_\($0)" })
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
