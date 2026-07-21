import Foundation
import GRDB
import Logging

/// Periodic sweeper that:
///   1. Pumps SSE keep-alive frames on live connections.
///   2. Refreshes workers.lastHeartbeat and supervisorState.lastHeartbeat for
///      every currently-attached session.
///
/// Staleness eviction is trivial now: SSE close is the ONLY eviction signal
/// (handled by MCPHTTPRouter's onClose callback). No registry entries to
/// prune — the connection dict is the only in-memory state.
actor MCPSessionSweeper {
    private let dbPool: DatabasePool
    private let logger: Logger
    private var task: Task<Void, Never>?
    private let tickInterval: TimeInterval = 15.0

    init(dbPool: DatabasePool, logger: Logger) {
        self.dbPool = dbPool
        self.logger = logger
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64((self?.tickInterval ?? 15.0) * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() async {
        await MCPConnections.shared.tickKeepAlives()

        let liveKeys = await MCPConnections.shared.liveSessionKeys()
        let now = nowMs()

        for key in liveKeys {
            if key == "supervisor" {
                await updateSupervisorHeartbeat(at: now)
                continue
            }
            // Workers first (workerId lookup); interactive sessions don't
            // update lastHeartbeat anywhere durable, so we skip them.
            let isWorker: Bool = (try? await dbPool.read { db in
                let n = try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM workers WHERE workerId = ?",
                    arguments: [key]) ?? 0
                return n > 0
            }) ?? false
            if isWorker {
                await updateWorkerHeartbeat(workerId: key, at: now)
            }
        }
    }

    private func updateWorkerHeartbeat(workerId: String, at heartbeatAt: Int64) async {
        // Transcript-usage sampling (from old sweeper) preserved verbatim.
        // Determines if there's an in-flight event by reading currentEventId
        // from DB instead of registry snapshot.
        //
        // Deliberately does NOT write `currentContextTokens`: readWorkerTranscriptUsage
        // resolves the most-recently-modified JSONL in the SHARED worker project
        // dir, so with several workers running it can sample a different session's
        // transcript than `workerId`. That is survivable for the cumulative
        // columns (display + cost roll-ups) but not for a context reading, which
        // SidecarLifecycle rotates sessions on — a borrowed number would rotate
        // the wrong sidecar. The bridge knows its own transcript and owns that
        // field.
        let inFlight: String? = (try? await dbPool.read { db in
            try String.fetchOne(db, sql:
                "SELECT currentEventId FROM workers WHERE workerId = ?",
                arguments: [workerId])
        }) ?? nil

        let usage = inFlight == nil ? nil : await readWorkerTranscriptUsage(workerId: workerId)
        do {
            try await dbPool.write { db in
                try db.execute(sql: """
                    UPDATE workers
                    SET lastHeartbeat = ?,
                        lastProgressAt = COALESCE(?, lastProgressAt),
                        currentEventTokens = COALESCE(?, currentEventTokens),
                        currentInputTokens = COALESCE(?, currentInputTokens),
                        currentCacheReadTokens = COALESCE(?, currentCacheReadTokens)
                    WHERE workerId = ?
                """, arguments: [
                    heartbeatAt,
                    inFlight == nil ? nil : heartbeatAt,
                    usage?.totalTokens,
                    usage?.inputTokens,
                    usage?.cacheReadTokens,
                    workerId,
                ])
            }
        } catch {
            logger.warning("Sweeper worker-heartbeat write failed for \(workerId): \(error)")
        }
    }

    private func updateSupervisorHeartbeat(at heartbeatAt: Int64) async {
        do {
            try await dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO supervisorState (id, lastHeartbeat, sessionId)
                    VALUES ('singleton', ?, 'supervisor')
                    ON CONFLICT(id) DO UPDATE SET lastHeartbeat = excluded.lastHeartbeat
                """, arguments: [heartbeatAt])
            }
        } catch {
            logger.warning("Sweeper supervisor-heartbeat write failed: \(error)")
        }
    }

    // Transcript-usage helper — unchanged from the old sweeper.

    private struct TranscriptUsage {
        let totalTokens: Int64
        let inputTokens: Int64
        let cacheReadTokens: Int64
    }

    private func readWorkerTranscriptUsage(workerId: String) async -> TranscriptUsage? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd = "\(home)/.sonata/worker"
        let encoded = cwd.replacingOccurrences(
            of: #"[\/.]"#, with: "-", options: .regularExpression)
        let projectsDir = "\(home)/.claude/projects/\(encoded)"

        guard let path = mostRecentJSONL(in: projectsDir) else { return nil }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var totalTokens: Int64 = 0
        var inputTokens: Int64 = 0
        var cacheReadTokens: Int64 = 0
        var sawAssistant = false
        for line in text.split(separator: "\n") {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }
            sawAssistant = true
            let input = (usage["input_tokens"] as? Int64) ?? 0
            let cacheCreate = (usage["cache_creation_input_tokens"] as? Int64) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int64) ?? 0
            let output = (usage["output_tokens"] as? Int64) ?? 0
            totalTokens += input + cacheCreate + cacheRead + output
            inputTokens += input + cacheCreate + cacheRead
            cacheReadTokens += cacheRead
        }
        if !sawAssistant { return nil }
        return TranscriptUsage(totalTokens: totalTokens, inputTokens: inputTokens, cacheReadTokens: cacheReadTokens)
    }

    private func mostRecentJSONL(in dir: String) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        var best: (String, Date)?
        for entry in entries where entry.hasSuffix(".jsonl") {
            let p = "\(dir)/\(entry)"
            let attrs = try? fm.attributesOfItem(atPath: p)
            let m = attrs?[.modificationDate] as? Date ?? Date.distantPast
            if best == nil || m > best!.1 { best = (p, m) }
        }
        return best?.0
    }
}
