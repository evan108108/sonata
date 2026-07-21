import Foundation
import GRDB
import Logging

/// The minimum surface `SidecarLifecycle` needs to stand a session down and
/// find it again.
///
/// Deliberately not a process, a `WorkerManager` slot, or anything else
/// concrete: whether sidecars end up as pooled workers or direct subprocesses
/// is a later decision. A handle only has to answer "where do this sidecar's
/// events go?" and "stop it."
struct SidecarSessionHandle: Sendable {
    /// Key events route to. Also the `workers.workerId` the context monitor
    /// reads usage from, so the spawner must use the same identifier for both.
    let sessionKey: String

    /// Stand the session down. Must be idempotent — rotation may terminate a
    /// session that has already exited on its own after posting `rotate_me`.
    let terminate: @Sendable () async -> Void

    init(sessionKey: String, terminate: @escaping @Sendable () async -> Void) {
        self.sessionKey = sessionKey
        self.terminate = terminate
    }
}

/// Owns sidecar sessions: spawning them, watching how full their context is,
/// and rotating them before they run out of room.
///
/// The concrete "start a Claude Code session" step is injected as `spawner`
/// rather than implemented here, which keeps this type testable and leaves the
/// spawn mechanism to a later phase without blocking monitoring and rotation.
///
/// An actor, unlike `SidecarRegistry`: every entry point here is already async
/// and the handle table is mutated from a background timer, so serialized
/// access is what we want.
actor SidecarLifecycle {

    /// Supplies a live session for a sidecar. Throwing fails the spawn loudly.
    typealias Spawner = @Sendable (Sidecar) async throws -> SidecarSessionHandle

    enum LifecycleError: Error, CustomStringConvertible {
        case skillMissing(sidecar: String, path: String)
        case alreadyRunning(String)

        var description: String {
            switch self {
            case .skillMissing(let sidecar, let path):
                return "Sidecar '\(sidecar)' has no SKILL.md at '\(path)' — refusing to spawn a session with no instructions."
            case .alreadyRunning(let name):
                return "Sidecar '\(name)' already has a live session. Rotate it instead of spawning a second one."
            }
        }
    }

    /// How often the monitor samples context usage.
    static let monitorTickSeconds: TimeInterval = 30

    /// How long `rotate` waits for in-flight work to finish before terminating
    /// anyway. A sidecar dispatches to headless agents and returns immediately,
    /// so a normal drain is fast; this bounds the pathological case rather than
    /// letting a wedged session block its own replacement forever.
    static let drainTimeoutSeconds: TimeInterval = 120
    static let drainPollSeconds: TimeInterval = 2

    /// Priority for the posted `rotate_me` event. Above routine work — a
    /// sidecar near its context ceiling should rotate before it picks up more.
    static let rotateEventPriority = 9

    private let dbPool: DatabasePool
    private let logger: Logger
    private let spawner: Spawner

    /// Live session per sidecar name.
    private var handles: [String: SidecarSessionHandle] = [:]
    /// Names currently mid-rotation — guards against a second rotation
    /// starting while one is draining.
    private var rotating: Set<String> = []
    /// Names a `rotate_me` has already been posted for. Without this the
    /// monitor would re-post every tick for as long as the session sits above
    /// threshold, since context only drops once the session is replaced.
    private var rotateRequested: Set<String> = []
    private var monitorTask: Task<Void, Never>?

    init(dbPool: DatabasePool, logger: Logger, spawner: @escaping Spawner) {
        self.dbPool = dbPool
        self.logger = logger
        self.spawner = spawner
    }

    // MARK: - Spawn

    /// Start a session for `sidecar` and publish its key so routing can find it.
    func spawn(_ sidecar: Sidecar) async throws {
        guard handles[sidecar.name] == nil else {
            throw LifecycleError.alreadyRunning(sidecar.name)
        }
        guard sidecar.skillFileExists else {
            // Fail loudly per the spec's launch behavior — no silent failures.
            throw LifecycleError.skillMissing(sidecar: sidecar.name, path: sidecar.skillPath)
        }

        let handle = try await spawner(sidecar)
        handles[sidecar.name] = handle
        rotateRequested.remove(sidecar.name)
        SidecarRegistry.shared.setSessionKey(handle.sessionKey, for: sidecar.name)
        logger.info("sidecar '\(sidecar.name)' spawned as session \(handle.sessionKey)")
    }

    /// Spawn every registered sidecar that isn't `.off`. Failures are logged
    /// and skipped rather than aborting the rest — one misconfigured sidecar
    /// shouldn't keep the others from booting.
    func spawnAllRegistered() async {
        for sidecar in SidecarRegistry.shared.all() where sidecar.budgetTier != .off {
            do {
                try await spawn(sidecar)
            } catch {
                logger.error("sidecar '\(sidecar.name)' failed to spawn: \(error)")
            }
        }
    }

    // MARK: - Rotation

    /// Replace a sidecar's session: stop routing to it, let in-flight work
    /// finish, terminate, then spawn a fresh one.
    ///
    /// Call this when a `rotate_me` event for `sidecar` is observed. Wiring
    /// that event through to this method is the deferred call site — the same
    /// follow-up phase that wires `SidecarRegistry.assignee(forEventType:)`
    /// into the enqueue path.
    func rotate(_ sidecar: Sidecar) async {
        guard !rotating.contains(sidecar.name) else {
            logger.debug("sidecar '\(sidecar.name)' is already rotating; ignoring duplicate request")
            return
        }
        guard let old = handles[sidecar.name] else {
            logger.warning("sidecar '\(sidecar.name)' has no live session to rotate")
            return
        }

        rotating.insert(sidecar.name)
        defer { rotating.remove(sidecar.name) }

        // Withdraw the key first so nothing new is routed at a session that is
        // about to go away. Events arriving during the gap fall through to
        // normal routing rather than queueing for a dead session.
        SidecarRegistry.shared.setSessionKey(nil, for: sidecar.name)

        await drain(sessionKey: old.sessionKey, name: sidecar.name)
        await old.terminate()
        handles[sidecar.name] = nil
        logger.info("sidecar '\(sidecar.name)' session \(old.sessionKey) terminated; respawning")

        do {
            try await spawn(sidecar)
        } catch {
            // Leaves the sidecar with no session. assignee() returns nil, so
            // its events route normally instead of vanishing.
            logger.error("sidecar '\(sidecar.name)' failed to respawn after rotation: \(error)")
        }
    }

    /// Stand a sidecar down for good: withdraw its routing key, terminate the
    /// session, forget the handle. Unlike `rotate`, nothing is respawned.
    ///
    /// This is what `.off` means operationally — the sidecar stays registered
    /// and keeps its config (so the settings panel can still show it and the
    /// user can turn it back on), it just has no session and receives no
    /// events. `assignee(forEventType:)` returns nil the moment the key is
    /// withdrawn, so its event types fall back to normal worker routing rather
    /// than queueing for a session that is gone.
    ///
    /// Idempotent: stopping an already-stopped sidecar withdraws the key again
    /// and returns. The throttle callback can fire `.off` more than once for
    /// the same sidecar across a restart, and a spend ceiling is not somewhere
    /// to be throwing.
    ///
    /// No drain, deliberately — unlike `rotate`, which waits so in-flight work
    /// survives into the replacement session. There is no replacement here, so
    /// waiting would only delay the stop.
    func stop(_ sidecar: Sidecar) async {
        // Withdraw first, so nothing is routed at the session while it is
        // being torn down. Done unconditionally: a sidecar with no handle can
        // still hold a stale key if a previous spawn published one and then
        // failed.
        SidecarRegistry.shared.setSessionKey(nil, for: sidecar.name)
        rotateRequested.remove(sidecar.name)

        guard let handle = handles.removeValue(forKey: sidecar.name) else {
            logger.debug("sidecar '\(sidecar.name)' has no live session to stop")
            return
        }

        await handle.terminate()
        logger.info("sidecar '\(sidecar.name)' session \(handle.sessionKey) stopped")
    }

    /// Wait for the session to finish whatever it is holding, bounded by
    /// `drainTimeoutSeconds`.
    private func drain(sessionKey: String, name: String) async {
        let deadline = Date().addingTimeInterval(Self.drainTimeoutSeconds)
        while Date() < deadline {
            guard let busy = await isBusy(sessionKey: sessionKey) else { return }
            if !busy { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.drainPollSeconds * 1_000_000_000))
        }
        logger.warning("sidecar '\(name)' did not drain within \(Int(Self.drainTimeoutSeconds))s; terminating anyway")
    }

    /// Whether the session is holding an event. Nil when the worker row is
    /// gone — the session is already down, so there is nothing to drain.
    private func isBusy(sessionKey: String) async -> Bool? {
        do {
            return try await dbPool.read { db -> Bool? in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT currentEventId FROM workers WHERE workerId = ?",
                    arguments: [sessionKey]
                ) else { return nil }
                let current: String? = row["currentEventId"]
                return !(current ?? "").isEmpty
            }
        } catch {
            logger.error("sidecar drain check failed for \(sessionKey): \(error)")
            return nil
        }
    }

    // MARK: - Context monitoring

    func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64(Self.monitorTickSeconds * 1_000_000_000))
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Sample every live sidecar and post `rotate_me` for any that crossed its
    /// threshold.
    private func tick() async {
        for sidecar in SidecarRegistry.shared.all() {
            guard sidecar.budgetTier != .off else { continue }
            guard let handle = handles[sidecar.name] else { continue }
            guard !rotating.contains(sidecar.name),
                  !rotateRequested.contains(sidecar.name) else { continue }
            guard let pct = await contextPercent(
                sessionKey: handle.sessionKey,
                windowTokens: sidecar.contextWindowTokens
            ) else { continue }
            guard pct >= sidecar.rotationThreshold else { continue }

            rotateRequested.insert(sidecar.name)
            logger.info("sidecar '\(sidecar.name)' at \(pct)% of context (threshold \(sidecar.rotationThreshold)%) — posting rotate_me")
            await postRotateMe(sidecar: sidecar, sessionKey: handle.sessionKey, contextPct: pct)
        }
    }

    /// Percent of `windowTokens` this session is currently carrying.
    ///
    /// ## What `currentContextTokens` is
    ///
    /// The bridge writes it on every heartbeat as the LAST assistant turn's
    /// `input + cacheCreate + cacheRead` — the prompt the model just read, which
    /// is what the session drags into its next turn. Four properties matter
    /// here, all of them deliberate:
    ///
    /// - **Last turn only, never a sum.** Every turn re-sends the whole
    ///   conversation, so a running total grows without bound and says nothing
    ///   about occupancy.
    /// - **Cache reads counted once.** They occupy the window exactly like fresh
    ///   input, just cheaper — and they are already inside that sum.
    /// - **Sub-agent turns skipped** (`isSidechain`). A sidecar is a dispatcher
    ///   that spawns agents constantly; an agent's window is not its parent's.
    /// - **Session-scoped, not event-scoped.** Reported between events too, and
    ///   nothing clears it when an event completes, so an idle sidecar sitting
    ///   on a full context is still visible here.
    ///
    /// ## What it is not
    ///
    /// Explicitly NOT `currentInputTokens (+ currentCacheReadTokens)`, which
    /// this used to read. Those are per-event sums that climb without bound —
    /// a live worker showed 16.08M against a 200K window — and adding the two
    /// double-counts cache reads on top of that.
    ///
    /// That proxy is also why a "readings >= 100% are garbage" filter once
    /// looked reasonable. Do not add one back. With a real signal and a correct
    /// `windowTokens`, a reading over 100% means a session genuinely past its
    /// window, which is the single most important case to act on. Measured
    /// against the WRONG denominator it means the sidecar's registration is
    /// lying about its model — also something to fix rather than suppress.
    ///
    /// Nil when the worker row is missing or has no reading yet (a
    /// freshly-spawned session that hasn't taken a turn), which the caller
    /// treats as "no signal" rather than "zero".
    private func contextPercent(sessionKey: String, windowTokens: Int64) async -> Int? {
        guard windowTokens > 0 else { return nil }
        do {
            return try await dbPool.read { db -> Int? in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT currentContextTokens FROM workers WHERE workerId = ?",
                    arguments: [sessionKey]
                ) else { return nil }

                guard let used: Int64 = row["currentContextTokens"], used > 0 else { return nil }
                return Int((used * 100) / windowTokens)
            }
        } catch {
            logger.error("sidecar context read failed for \(sessionKey): \(error)")
            return nil
        }
    }

    /// Enqueue a `rotate_me` event addressed to the sidecar's own session, so
    /// it can finish current work and halt on its own terms.
    private func postRotateMe(sidecar: Sidecar, sessionKey: String, contextPct: Int) async {
        let payload: [String: Any] = [
            "sidecar": sidecar.name,
            "session_key": sessionKey,
            "context_pct": contextPct,
            "rotation_threshold": sidecar.rotationThreshold,
            "reason": "context_threshold_crossed",
        ]
        let payloadJSON: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return "{}" }
            return json
        }()

        let eventId = newUUID()
        let now = nowMs()
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO workerEvents
                            (id, type, payload, priority, assignedTo, status, createdAt, assignedAt)
                        VALUES (?, 'rotate_me', ?, ?, ?, 'assigned', ?, ?)
                        """,
                    arguments: [eventId, payloadJSON, Self.rotateEventPriority, sessionKey, now, now]
                )
            }
        } catch {
            // Re-arm so the next tick tries again rather than silently never
            // rotating this sidecar.
            rotateRequested.remove(sidecar.name)
            logger.error("failed to post rotate_me for sidecar '\(sidecar.name)': \(error)")
        }
    }

    // MARK: - Introspection

    /// Session key for a running sidecar, or nil when it isn't running.
    func sessionKey(for name: String) -> String? {
        handles[name]?.sessionKey
    }

    /// Names of every sidecar with a live session.
    func runningSidecarNames() -> [String] {
        Array(handles.keys)
    }
}
