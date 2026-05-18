import Foundation
import GRDB
import Logging

actor MCPSessionSweeper {
    private let registry: MCPSessionRegistry
    private let dbPool: DatabasePool
    private let logger: Logger
    private var task: Task<Void, Never>?

    private let tickInterval: TimeInterval = 15.0
    private let staleThresholdMs: Int64 = 30_000

    init(registry: MCPSessionRegistry, dbPool: DatabasePool, logger: Logger) {
        self.registry = registry
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
        await registry.tickKeepAlives()

        let snapshots = await registry.snapshot()
        let now = nowMs()

        for snap in snapshots {
            let age = now - snap.lastContactedAt
            // SSE attached → the session is provably alive on this tick;
            // refresh heartbeat to `now`. (Idle workers never make MCP
            // calls, so `lastContactedAt` would otherwise freeze at the
            // init/tools-list timestamp and the sweeper would write the
            // same stale value forever.)
            // No SSE but recent traffic → use lastContactedAt.
            // No SSE and stale → skip; let downstream stale checks evict.
            let heartbeatAt: Int64
            if snap.hasSSE {
                heartbeatAt = now
            } else if age < staleThresholdMs {
                heartbeatAt = snap.lastContactedAt
            } else {
                continue
            }
            switch snap.role {
            case .worker:
                await updateWorkerHeartbeat(
                    workerId: snap.sessionKey,
                    at: heartbeatAt,
                    inFlightEventId: snap.inFlightEventId
                )
            case .supervisor:
                await updateSupervisorHeartbeat(at: heartbeatAt)
            case .interactive:
                break
            }
        }
    }

    private func updateWorkerHeartbeat(
        workerId: String,
        at heartbeatAt: Int64,
        inFlightEventId: String?
    ) async {
        let usage = inFlightEventId == nil ? nil : await readWorkerTranscriptUsage(workerId: workerId)
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
                    inFlightEventId == nil ? nil : heartbeatAt,
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
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
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
                  let usage = msg["usage"] as? [String: Any]
            else { continue }
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
        return TranscriptUsage(
            totalTokens: totalTokens,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens
        )
    }

    private func mostRecentJSONL(in dir: String) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        var best: (String, Date)?
        for entry in entries where entry.hasSuffix(".jsonl") {
            let p = "\(dir)/\(entry)"
            let attrs = try? fm.attributesOfItem(atPath: p)
            let m = attrs?[.modificationDate] as? Date ?? Date.distantPast
            if best == nil || m > best!.1 {
                best = (p, m)
            }
        }
        return best?.0
    }
}
