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
        // One read for both facts we need about this worker: whether it holds an
        // event, and which transcript on disk is its own.
        let row: (eventId: String?, sessionId: String?)? = try? await dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT currentEventId, sessionId FROM workers WHERE workerId = ?",
                arguments: [workerId]
            ) else { return nil }
            return (row["currentEventId"], row["sessionId"])
        }
        let inFlight: String? = row?.eventId
        let sessionId: String? = row?.sessionId

        // Sampled whether or not an event is in flight. The cumulative columns
        // below are still gated on `inFlight` — they are event-scoped and get
        // NULLed on completion, so writing them at idle would resurrect a
        // finished event's numbers. `currentContextTokens` is the opposite: a
        // session's context does not empty when its event does, and an idle
        // session sitting on a nearly-full window is exactly what the sidecar
        // monitor needs to see.
        let usage = await readWorkerTranscriptUsage(workerId: workerId, sessionId: sessionId)

        // Feed the sidecar spend ledger from the same reading. This is the
        // live path: the `worker_heartbeat` action would be the intuitive home
        // for it, but nothing POSTs that endpoint since the sonata-bridge stdio
        // proxy was retired, and it carries no output-token field anyway. Here
        // the numbers are already in hand and already parsed from the
        // transcript that is the only real source for them.
        if let usage {
            await recordSidecarSpend(
                workerId: workerId, sessionId: sessionId, usage: usage, at: heartbeatAt
            )
        }

        do {
            try await dbPool.write { db in
                try db.execute(sql: """
                    UPDATE workers
                    SET lastHeartbeat = ?,
                        lastProgressAt = COALESCE(?, lastProgressAt),
                        currentEventTokens = COALESCE(?, currentEventTokens),
                        currentInputTokens = COALESCE(?, currentInputTokens),
                        currentCacheReadTokens = COALESCE(?, currentCacheReadTokens),
                        currentContextTokens = COALESCE(?, currentContextTokens)
                    WHERE workerId = ?
                """, arguments: [
                    heartbeatAt,
                    inFlight == nil ? nil : heartbeatAt,
                    inFlight == nil ? nil : usage?.totalTokens,
                    inFlight == nil ? nil : usage?.inputTokens,
                    inFlight == nil ? nil : usage?.cacheReadTokens,
                    usage?.contextTokens,
                    workerId,
                ])
            }
        } catch {
            logger.warning("Sweeper worker-heartbeat write failed for \(workerId): \(error)")
        }
    }

    // MARK: - Sidecar spend

    /// Cumulative transcript totals as of this worker's last sample, with the
    /// session they were read from.
    ///
    /// In-memory only, and deliberately so. Spend is a rolling-window guard,
    /// not an accounting record: a fresh process starts with an empty
    /// watermark and rebuilds it from the next sweep, costing at most one tick
    /// of under-counting per sidecar. Persisting it would buy very little and
    /// add a schema to keep in sync with a ledger that is itself in-memory.
    private var lastSpendSample: [String: (sessionId: String?, total: Int64, input: Int64)] = [:]

    /// Attribute the delta since the last sample to the sidecar that owns this
    /// worker row, if any.
    ///
    /// Transcript totals are cumulative and monotonic *within one session*, so
    /// the delta is what was spent since the previous 15s tick. A rotation
    /// starts a new transcript and resets them, which is why the session id is
    /// stored alongside: on a change, the new total counts in full rather than
    /// producing a nonsense negative.
    private func recordSidecarSpend(
        workerId: String, sessionId: String?, usage: TranscriptUsage, at: Int64
    ) async {
        // Resolve by live session key rather than by comparing `sessionLabel`
        // to the sidecar's name — those are not the same string (the memory
        // sidecar is named "memory" but labelled "sidecar-memory"), and the key
        // is what rotation actually republishes.
        guard let name = sidecarName(forWorkerId: workerId),
              let tracker = SidecarRuntime.shared.tracker else { return }

        let delta = sidecarSpendDelta(
            previous: lastSpendSample[workerId], sessionId: sessionId, usage: usage
        )
        lastSpendSample[workerId] = (sessionId, usage.totalTokens, usage.inputTokens)

        guard delta.input > 0 || delta.output > 0 else { return }
        await tracker.record(
            sidecar: name,
            inputTokens: Int(delta.input),
            outputTokens: Int(delta.output),
            at: at
        )
    }

    /// The sidecar whose live session is `workerId`, or nil for a pool slot.
    ///
    /// Linear over the registry rather than a maintained reverse index: there
    /// is one sidecar today and a handful at any plausible future point, and a
    /// second index would be one more thing rotation has to keep in step.
    private func sidecarName(forWorkerId workerId: String) -> String? {
        SidecarRegistry.shared.all().first {
            SidecarRegistry.shared.sessionKey(for: $0.name) == workerId
        }?.name
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

    // MARK: - Transcript usage

    /// Resolved transcript path per worker, so the directory scan runs once per
    /// session instead of on every 15s tick.
    private var transcriptPaths = TranscriptPathCache()

    /// Resolve this worker's own transcript and parse it.
    ///
    /// Resolution is by `workers.sessionId`, which the app records when it
    /// spawns the session, and which is the transcript's filename. It used to
    /// pick the most-recently-modified `.jsonl` in the shared worker project
    /// directory while ignoring its `workerId` argument entirely — so with
    /// several workers running, whichever session wrote last had its numbers
    /// copied onto every other worker's row. Two live workers were observed
    /// holding byte-identical readings (currentInputTokens=26,398,350) at the
    /// same instant. Nil sessionId means no transcript we can attribute, which
    /// reports as "no reading" rather than a borrowed one.
    ///
    /// ## Why this scans instead of building one path
    ///
    /// Keying on sessionId fixed the borrowing, but the *directory* stayed
    /// hardcoded to `~/.sonata/worker` — correct for every caller that existed
    /// at the time, and silently wrong the moment a session ran anywhere else.
    /// Sidecars do: the memory sidecar's cwd is `~/.sonata/sidecar-memory`, so
    /// its transcript lives under `-Users-evan--sonata-sidecar-memory/` and the
    /// single constructed path never matched. `readWorkerTranscriptUsage`
    /// returned nil for it forever, which cost more than a missing number:
    /// `currentContextTokens` stayed NULL, so the sidecar could never compute a
    /// context percentage, so it could never post rotate_me — and
    /// `recordSidecarSpend` is gated on a non-nil reading, so the spend ledger
    /// stayed at zero and throttling could never fire. Both features were inert
    /// on a shipped build, and nothing errored: nil reads as "no turns yet",
    /// which is exactly what a freshly-spawned session looks like.
    ///
    /// So the cwd is no longer assumed. We look for `<sessionId>.jsonl` across
    /// every project directory. The anti-borrowing property survives because
    /// resolution is still an exact match on a unique session id — see
    /// `resolveTranscriptPath`, which deliberately has no
    /// most-recently-modified fallback, since that fallback IS the original
    /// bug.
    private func readWorkerTranscriptUsage(
        workerId: String, sessionId: String?
    ) async -> TranscriptUsage? {
        guard let sessionId, !sessionId.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let projectsRoot = "\(home)/.claude/projects"

        // Cached hit still gets an existence check: a transcript can be moved
        // or cleaned up under a session that is otherwise unchanged, and
        // serving a path that no longer resolves would report "no reading"
        // permanently instead of rescanning once.
        var path = transcriptPaths.cached(workerId: workerId, sessionId: sessionId)
        if let cached = path, !FileManager.default.fileExists(atPath: cached) {
            transcriptPaths.forget(workerId: workerId)
            path = nil
        }
        if path == nil {
            guard let resolved = resolveTranscriptPath(
                projectsRoot: projectsRoot, sessionId: sessionId
            ) else { return nil }
            transcriptPaths.store(workerId: workerId, sessionId: sessionId, path: resolved)
            path = resolved
        }

        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return parseTranscriptUsage(jsonl: text)
    }
}

// MARK: - Transcript location (pure)

/// Locate a session's transcript under the Claude projects root.
///
/// Claude Code names a transcript after its session id and files it under a
/// directory derived from the session's cwd, so the only stable fact is the
/// filename. Rather than reconstruct the directory — which means assuming a
/// cwd, and assuming wrong for anything that isn't a pool worker — this scans
/// for an exact `<sessionId>.jsonl` match.
///
/// There is deliberately **no** most-recently-modified fallback. That fallback
/// is what the original implementation did, and it copied one session's token
/// numbers onto every other worker's row. A miss must stay a miss: reporting
/// "no reading" is recoverable, reporting someone else's reading is not.
///
/// Directories are visited in sorted order so a miss costs the same scan every
/// time and a hit is deterministic. Session ids are UUIDs, so at most one
/// directory can match in practice.
func resolveTranscriptPath(
    projectsRoot: String,
    sessionId: String,
    fileManager: FileManager = .default
) -> String? {
    guard !sessionId.isEmpty else { return nil }
    guard let dirs = try? fileManager.contentsOfDirectory(atPath: projectsRoot) else { return nil }

    let filename = "\(sessionId).jsonl"
    for dir in dirs.sorted() {
        let candidate = "\(projectsRoot)/\(dir)/\(filename)"
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            return candidate
        }
    }
    return nil
}

/// Remembers where a worker's transcript was found, so the scan is once per
/// session rather than once per tick.
///
/// Entries are keyed by worker and validated against the session id they were
/// resolved for. Rotation is the only thing that changes a worker's session id,
/// so an entry's useful life IS its session's life and there is no separate
/// invalidation step to forget to run. A stale entry cannot be served: the
/// session id is compared before the path is handed back, and a changed id
/// simply misses.
///
/// Keying by worker rather than by session also bounds the dictionary to the
/// number of live workers instead of growing by one entry per rotation.
struct TranscriptPathCache {
    private var entries: [String: (sessionId: String, path: String)] = [:]

    /// The path cached for this exact (worker, session) pair, or nil when the
    /// caller must resolve it afresh.
    func cached(workerId: String, sessionId: String) -> String? {
        guard let entry = entries[workerId], entry.sessionId == sessionId else { return nil }
        return entry.path
    }

    mutating func store(workerId: String, sessionId: String, path: String) {
        entries[workerId] = (sessionId: sessionId, path: path)
    }

    mutating func forget(workerId: String) {
        entries[workerId] = nil
    }
}

// MARK: - Transcript parsing (pure)

/// Token usage read out of a session transcript.
///
/// Two different questions, two different numbers, and conflating them is the
/// bug this type exists to keep separated:
///
/// - `totalTokens` / `inputTokens` / `cacheReadTokens` are SUMS across every
///   assistant turn. They answer "what has this event cost?" and are what the
///   prompt-cache panel and HealthMonitor consume.
/// - `contextTokens` is the LAST non-sidechain turn only. It answers "how full
///   is the window right now?"
///
/// A sum cannot answer the second question: every turn re-sends the whole
/// conversation, so the total climbs without bound and passes a 200K window
/// within a few turns — six real transcripts read 2,217%–17,475% when their
/// sums were used this way. Only the last turn tracks actual occupancy, and
/// only the last turn correctly DROPS after a compaction.
struct TranscriptUsage: Equatable, Sendable {
    let totalTokens: Int64
    let inputTokens: Int64
    let cacheReadTokens: Int64
    /// Last non-sidechain assistant turn's `input + cacheCreate + cacheRead`.
    let contextTokens: Int64
}

/// Spend to attribute to a sidecar for one sweep, given the previous sample.
///
/// Free function rather than a method so the arithmetic — the part that would
/// be wrong in a way nobody notices until a sidecar has quietly eaten its
/// weekly budget four times over — is testable without an actor or a database.
///
/// Transcript totals are cumulative over a session, so the ordinary case is a
/// simple subtraction. Two cases are not ordinary:
///
/// - **A different session id.** Rotation starts a fresh transcript whose
///   totals restart near zero. Subtracting the old watermark would produce a
///   large negative; the new total counts in full instead.
/// - **The same id, but smaller numbers.** Shouldn't happen, but a truncated or
///   replaced file on disk would do it, and the honest reading of "cumulative
///   went backwards" is that this is a different run of the session. Treated
///   the same as a rotation, and specifically NOT clamped to zero per field:
///   clamping would let a shrink silently re-bill the whole new total as delta
///   on the *following* sweep.
///
/// `usage.inputTokens` is input+cacheCreate+cacheRead; output is whatever
/// `totalTokens` carries beyond that. They are split back apart because
/// `SidecarSpendTracker.record` takes them separately, even though it sums them.
func sidecarSpendDelta(
    previous: (sessionId: String?, total: Int64, input: Int64)?,
    sessionId: String?,
    usage: TranscriptUsage
) -> (input: Int64, output: Int64) {
    let continues = previous.map {
        $0.sessionId == sessionId && $0.total <= usage.totalTokens && $0.input <= usage.inputTokens
    } ?? false

    let baseTotal = continues ? (previous?.total ?? 0) : 0
    let baseInput = continues ? (previous?.input ?? 0) : 0

    return (
        input: max(0, usage.inputTokens - baseInput),
        output: max(0, (usage.totalTokens - usage.inputTokens) - (baseTotal - baseInput))
    )
}

/// Parse transcript JSONL into cumulative usage plus current context occupancy.
///
/// Nil when the transcript carries no assistant turn yet — a freshly-spawned
/// session that hasn't answered. Callers treat that as "no reading", never as
/// zero, because zero would read as an empty context window.
///
/// Malformed lines are SKIPPED, not thrown on. A transcript is a file being
/// appended to by another process, so a torn final line is an ordinary race,
/// not corruption — failing the whole read would drop a good reading for every
/// worker mid-write. Lines that parse but aren't assistant turns are skipped by
/// the same path.
///
/// `isSidechain` turns are excluded. A sub-agent's usage describes ITS window,
/// not its parent's, and a sidecar is a dispatcher that spawns agents
/// constantly — counting one would report an agent's context as the sidecar's
/// and rotate the wrong session.
///
/// `cacheRead` is deliberately counted ONCE, inside `input + cacheCreate +
/// cacheRead`. It is not added again on top; doing so double-counts it, which
/// is half of what made the original rotation signal read 15,890%.
func parseTranscriptUsage(jsonl: String) -> TranscriptUsage? {
    var totalTokens: Int64 = 0
    var inputTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var contextTokens: Int64 = 0
    var sawAssistant = false

    for line in jsonl.split(separator: "\n") {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "assistant",
              obj["isSidechain"] as? Bool != true,
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
        // Overwritten each turn — the last assignment wins.
        contextTokens = input + cacheCreate + cacheRead
    }

    guard sawAssistant else { return nil }
    return TranscriptUsage(
        totalTokens: totalTokens,
        inputTokens: inputTokens,
        cacheReadTokens: cacheReadTokens,
        contextTokens: contextTokens
    )
}
