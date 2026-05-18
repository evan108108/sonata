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
    /// Eviction threshold for sessions with no SSE attached. Once
    /// lastContactedAt is older than this AND hasSSE is false AND no
    /// backing live PID exists, the entry is removed from the registry.
    /// Conservative — must be longer than the typical reconnect window
    /// for a session restarting itself.
    private let evictNoSSEAfterMs: Int64 = 120_000

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

        // Snapshot the registry first, then snapshot the supporting
        // truth tables (workers, claude PID files). After that we can
        // make eviction + heartbeat decisions per session.
        let snapshots = await registry.snapshot()
        let now = nowMs()
        let liveWorkerIds = await fetchLiveWorkerIds()
        let livePIDs: Set<Int>? = livePIDsFromClaudeSessionsDir()

        for snap in snapshots {
            // ─── Ghost-prevention eviction pass ───
            // 2026-05-18 — observed 3 ghost worker rows in the
            // All-Sessions dashboard from prior worker generations
            // that the registry kept forever. The sweeper now removes
            // any registry entry that no longer corresponds to a live
            // session.
            let age = now - snap.lastContactedAt
            switch snap.role {
            case .worker:
                // Workers must exist in the workers DB table (in a
                // non-terminal status). If the row's gone, the worker
                // was recycled and this entry is a ghost — evict.
                if !liveWorkerIds.contains(snap.sessionKey) {
                    await registry.evict(snap.sessionKey)
                    continue
                }
            case .supervisor:
                break  // supervisor session is a singleton, no ghost case
            case .interactive:
                // Interactive sessions (sona-launched + anon-XXX) are
                // backed by a claude process. Evict if all of:
                //   * SSE is gone
                //   * idle past the eviction window
                //   * EITHER we know the session's pid and it's no
                //     longer alive, OR the session never identified
                //     itself (anon-XXX that didn't call sonata_identify)
                // If `livePIDs` is nil (~/.claude/sessions unreadable),
                // skip eviction entirely so a transient hiccup doesn't
                // kill live sessions.
                if !snap.hasSSE, age >= evictNoSSEAfterMs, let livePIDs {
                    let state = await registry.get(snap.sessionKey)
                    let pid = await state?.pid
                    let shouldEvict: Bool
                    if let pid {
                        shouldEvict = !livePIDs.contains(pid)
                    } else {
                        shouldEvict = true
                    }
                    if shouldEvict {
                        await registry.evict(snap.sessionKey)
                        continue
                    }
                }
            }

            // ─── Heartbeat refresh ───
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

    /// Returns the set of workerIds from the `workers` DB table whose
    /// status is non-terminal (not 'offline' / 'stale'). Used by the
    /// sweeper to drop registry ghosts (entries with no DB backing).
    private func fetchLiveWorkerIds() async -> Set<String> {
        let rows: [String]
        do {
            rows = try await dbPool.read { db -> [String] in
                try String.fetchAll(db, sql: """
                    SELECT workerId FROM workers
                    WHERE status != 'offline' AND status != 'stale'
                """)
            }
        } catch {
            // If we can't read, assume everything is live (safe failure
            // — don't accidentally evict on a transient DB hiccup).
            return Set<String>()
        }
        return Set(rows)
    }

    /// Returns the PIDs of every live claude process per
    /// `~/.claude/sessions/<pid>.json`, cross-checked against `kill(pid, 0)`.
    /// Returns nil if the directory is unreadable so the caller can skip
    /// eviction (better safe than killing live sessions on a transient
    /// filesystem hiccup).
    private func livePIDsFromClaudeSessionsDir() -> Set<Int>? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: dir.path) else {
            return nil
        }
        var pids: Set<Int> = []
        for entry in entries where entry.hasSuffix(".json") {
            let stem = String(entry.dropLast(".json".count))
            guard let pid = Int(stem) else { continue }
            if kill(pid_t(pid), 0) == 0 {
                pids.insert(pid)
            }
        }
        return pids
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
