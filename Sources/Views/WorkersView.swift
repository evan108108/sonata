import SwiftUI
import SwiftTerm
import AppKit
import Combine
import GRDB

// MARK: - Worker Model

class Worker: ObservableObject, Identifiable {
    let id: String
    let label: String
    let sessionId: String  // Claude --session-id UUID for cycling/resume
    let engine: WorkerEngine  // Claude (default) or Goose — see WorkerEngine.swift

    @Published var status: WorkerStatus = .starting
    @Published var currentTask: String = ""
    @Published var currentEventId: String = ""
    @Published var taskStartedAt: Int64 = 0
    @Published var eventsHandled: Int = 0
    @Published var tasksSinceSpawn: Int = 0
    @Published var currentEventTokens: Int = 0
    @Published var currentSlug: String = ""
    @Published var currentCacheReadTokens: Int = 0
    @Published var currentInputTokens: Int = 0

    var currentCacheHitRate: Double? {
        currentInputTokens > 0
            ? Double(currentCacheReadTokens) / Double(currentInputTokens)
            : nil
    }

    let terminalView: LocalProcessTerminalView
    var coordinator: WorkerCoordinator?

    init(label: String, engine: WorkerEngine = WorkerEngine.defaultEngine) {
        self.id = "worker-\(Date().timeIntervalSince1970.description.replacingOccurrences(of: ".", with: "").suffix(10))"
        self.label = label
        self.sessionId = UUID().uuidString.lowercased()
        self.engine = engine
        self.terminalView = DropEnabledTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        terminalView.applyWarmChrome()
    }

    /// Recovery init: reuse a candidate's prior workerId + sessionId so the
    /// engine resumes the existing session on relaunch (sonata-restart-recovery-v0-plan §4).
    /// Engine defaults to `.claude` — recovered workers stay on Claude until the
    /// `engine` column is persisted in the workers table (T4 follow-up).
    init(label: String, workerId: String, sessionId: String, engine: WorkerEngine = .claude) {
        self.id = workerId
        self.label = label
        self.sessionId = sessionId
        self.engine = engine
        self.terminalView = DropEnabledTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        terminalView.applyWarmChrome()
    }

    func startProcess(restartNudge: Bool = false, taskId: String? = nil, lastEventId: String? = nil) {
        let coord = WorkerCoordinator(worker: self)
        self.coordinator = coord
        terminalView.processDelegate = coord
        coord.terminalView = terminalView
        coord.startProcess(restartNudge: restartNudge, taskId: taskId, lastEventId: lastEventId)
    }

    enum WorkerStatus: String {
        case starting = "Starting"
        case idle = "Idle"
        case busy = "Busy"
        case offline = "Offline"
        case restarting = "Restarting"
        case draining = "Draining"

        var color: SwiftUI.Color {
            switch self {
            case .starting, .restarting: return .yellow
            case .idle: return .green
            case .busy: return .orange
            case .offline: return .red
            case .draining: return .purple
            }
        }

        var icon: String {
            switch self {
            case .starting: return "arrow.clockwise.circle"
            case .idle: return "checkmark.circle"
            case .busy: return "bolt.circle.fill"
            case .offline: return "xmark.circle"
            case .restarting: return "arrow.clockwise"
            case .draining: return "arrow.triangle.2.circlepath"
            }
        }
    }
}

// MARK: - Worker Manager

class WorkerManager: ObservableObject {
    static let shared = WorkerManager()

    @Published var workers: [Worker] = []
    @Published var selectedWorkerId: String?
    @Published var isCyclingPaused: Bool = CycleSettings.shared.pauseCycling

    /// Live count of workers in `.busy` status. Kept in sync via Combine
    /// subscriptions to each `Worker.$status` because `Worker` is a class —
    /// mutating `workers[i].status` does NOT trigger `@Published var workers`
    /// to re-emit. Without this, the nav-rail badge only refreshes when the
    /// containing view re-renders for some unrelated reason (clicking any
    /// nav-rail item triggered a re-render via the `selectedTab` change).
    @Published var busyWorkerCount: Int = 0

    private var healthTimer: Timer?
    private let cycleStrategy: CycleStrategy = TaskCountStrategy()
    private var cycleFailureCount: [String: Int] = [:]  // worker label → consecutive failures
    private var statusObservers: [String: AnyCancellable] = [:]  // worker.id → status sub
    private var workersArraySub: AnyCancellable?

    /// Default number of workers to spawn on launch — stored in UserDefaults.
    static var defaultWorkerCount: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: "defaultWorkerCount")
            return val > 0 ? val : 2
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "defaultWorkerCount")
        }
    }

    /// Whether to respawn recovery workers on app launch (sonata-restart-recovery v0).
    /// Defaults to ON (the feature is the point of v0). Stored in UserDefaults so
    /// settings UI can toggle without env-var fiddling. Reads SONATA_RESTART_RECOVERY
    /// env as an override for testing if set to "0" or "1".
    static var restartRecoveryEnabled: Bool {
        get {
            if let env = ProcessInfo.processInfo.environment["SONATA_RESTART_RECOVERY"] {
                return env == "1"
            }
            if UserDefaults.standard.object(forKey: "restartRecoveryEnabled") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "restartRecoveryEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "restartRecoveryEnabled")
        }
    }

    /// Config — mirrors SonaWorkers Config but reads from env
    static var claudeBinary: String {
        if let env = ProcessInfo.processInfo.environment["SONA_CLAUDE_BINARY"] {
            return env
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "claude"
    }

    /// Goose binary path (no-fork engine, T3) — `SONA_GOOSE_BINARY` override or
    /// the usual install locations. Delegates to the pure resolver in
    /// `GooseEngineBinding` so it stays testable.
    static var gooseBinary: String {
        GooseEngineBinding.binary()
    }

    /// Resolve the executable for a worker's engine. Claude is the default;
    /// Goose is opt-in. New engines slot in here.
    static func binary(for engine: WorkerEngine) -> String {
        switch engine {
        case .claude: return claudeBinary
        case .goose: return gooseBinary
        }
    }

    static var workingDirectory: String {
        ProcessInfo.processInfo.environment["SONA_WORKING_DIR"]
            ?? "\(ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())/.sonata/worker"
    }

    static var skipPermissions: Bool {
        ProcessInfo.processInfo.environment["SONA_SKIP_PERMISSIONS"] != "0"
    }

    static var channelServer: String? {
        ProcessInfo.processInfo.environment["SONA_CHANNEL_SERVER"] ?? "sonata-bridge"
    }

    static var healthEndpoint: String? {
        ProcessInfo.processInfo.environment["SONA_HEALTH_ENDPOINT"] ?? "http://localhost:3211/api/worker/status"
    }

    init() {
        // Health polling is started by SonataApp boot AFTER respawnRecoveryWorkers
        // and spawnDefaultWorkers populate the workers collection. Starting it here
        // would race the recovery: pollHealth → maintainPoolSize → addWorker(label:)
        // would spawn fresh-ID Workers in slots before the recovery workers appear.

        // Re-subscribe to each Worker's @Published status whenever the workers
        // array changes (spawn / remove / restart). Keeps busyWorkerCount in
        // sync so the nav-rail badge updates without waiting for any other
        // view to force a re-render of ContentView.
        workersArraySub = $workers.sink { [weak self] newWorkers in
            self?.reconcileWorkerStatusObservers(for: newWorkers)
        }
    }

    private func reconcileWorkerStatusObservers(for currentWorkers: [Worker]) {
        let liveIds = Set(currentWorkers.map(\.id))
        // Drop subscriptions for workers that left the pool.
        for id in statusObservers.keys where !liveIds.contains(id) {
            statusObservers.removeValue(forKey: id)
        }
        // Add subscriptions for workers we haven't seen yet. Worker.$status
        // emits on initial subscribe AND every mutation, so the first sink
        // also seeds busyWorkerCount correctly.
        for worker in currentWorkers where statusObservers[worker.id] == nil {
            statusObservers[worker.id] = worker.$status
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.recomputeBusyWorkerCount()
                }
        }
        recomputeBusyWorkerCount()
    }

    private func recomputeBusyWorkerCount() {
        let next = workers.filter { $0.status == .busy }.count
        if busyWorkerCount != next {
            busyWorkerCount = next
        }
    }

    /// Spawn the default number of workers on app launch.
    /// Called from SonataApp after the HTTP server is ready.
    ///
    /// `reservingFor` is the count of recovery workers already pre-populated by
    /// `respawnRecoveryWorkers()`. Slot indices `1...reservingFor` are skipped so
    /// recovery workers and fresh-default workers don't double-allocate the pool
    /// (sonata-restart-recovery-v0-plan §4).
    @MainActor
    func spawnDefaultWorkers(reservingFor: Int = 0) {
        guard workers.count <= reservingFor else { return } // don't double-spawn
        let count = WorkerManager.defaultWorkerCount
        let total = max(reservingFor, count)
        guard total > reservingFor else { return }
        for i in (reservingFor + 1)...total {
            addWorker(label: "sona-worker-\(i)")
        }
    }

    /// Restart-recovery v0 (T4): on app boot, find workers whose `lastHeartbeat`
    /// is stale AND whose `currentEventId` points to a still-active task, then
    /// spawn replacement processes reusing the prior `workerId`/`sessionId`/
    /// `sessionLabel`. claude resumes the existing JSONL session and the bridge
    /// fires a one-shot `sonata_restart` channel event so the worker knows it's
    /// resumed. Returns the count of recoveries actually started so
    /// `spawnDefaultWorkers(reservingFor:)` doesn't double-allocate slots.
    @MainActor
    func respawnRecoveryWorkers(dbPool: DatabasePool) async -> Int {
        let now = nowMs()
        // Boot-time recovery: every existing worker is dead (Sonata just started;
        // none have heartbeated yet). The runtime 30s stale threshold doesn't
        // apply — pass Int64.max so the lastHeartbeat filter accepts any row.
        let candidates = findStaleWorkersWithActiveWork(
            in: dbPool,
            cutoffMs: Int64.max,
            taskMaxAgeMs: now - 86_400_000
        )
        if candidates.isEmpty {
            return 0
        }

        var spawned = 0
        for candidate in candidates {
            let priorAgeSec: Int64
            do {
                priorAgeSec = try await dbPool.write { db -> Int64 in
                    let row = try Row.fetchOne(db, sql: """
                        SELECT lastHeartbeat FROM workers WHERE workerId = ?
                    """, arguments: [candidate.workerId])
                    let age = (row?["lastHeartbeat"] as? Int64).map { (now - $0) / 1000 } ?? 0
                    // Set status='busy' directly — the worker has currentEventId
                    // pointing at an active task, so the derived-state rule is
                    // already busy. Setting 'recovering' first and letting heartbeat
                    // resolve it adds 15-30s of UI lag where the worker shows idle.
                    try db.execute(sql: """
                        UPDATE workers SET status = 'busy', lastHeartbeat = ?
                        WHERE workerId = ?
                    """, arguments: [now, candidate.workerId])
                    return age
                }
            } catch {
                print("[restart-recovery] skipped workerId=\(candidate.workerId) taskId=\(candidate.taskId) reason=db-write-failed:\(error.localizedDescription)")
                continue
            }

            print("[restart-recovery] respawning workerId=\(candidate.workerId) taskId=\(candidate.taskId) priorSessionAge=\(priorAgeSec)")

            let label = candidate.sessionLabel.isEmpty ? "sona-worker-recovery" : candidate.sessionLabel
            let worker = Worker(label: label, workerId: candidate.workerId, sessionId: candidate.sessionId)
            workers.append(worker)
            selectedWorkerId = worker.id
            let taskId = candidate.taskId
            let lastEventId = candidate.currentEventId
            DispatchQueue.main.async {
                worker.startProcess(restartNudge: true, taskId: taskId, lastEventId: lastEventId)
            }
            spawned += 1
        }

        print("[restart-recovery] recovered \(spawned) workers")
        return spawned
    }

    /// Pure value type carrying the planned mutations for `maintainPoolSize`.
    /// Exposed so unit tests can exercise the planning logic without
    /// instantiating real `Worker` objects (which spin up AppKit views).
    struct PoolMaintainPlan: Equatable {
        /// Labels of new workers to spawn (e.g. "sona-worker-2").
        let toSpawn: [String]
        /// IDs of stale `.offline` workers to displace before spawning their
        /// slot's replacement.
        let toDisplace: [String]
    }

    /// Minimal projection of `Worker` fields used by `computePoolMaintainPlan`.
    struct WorkerSlotInfo: Equatable {
        let id: String
        let label: String
        let status: Worker.WorkerStatus
    }

    /// Pure planning function for pool maintenance. Status-aware: an
    /// `.offline` worker is treated as not occupying its slot, so the
    /// pool refills around it; the stale `.offline` Worker is reported
    /// in `toDisplace` so the caller can remove it before spawning.
    /// In-flight states (`.starting`, `.restarting`) still occupy the
    /// slot so we don't double-spawn during a normal startup.
    /// 2026-05-18 incident: prior version treated `.offline` as occupied
    /// and the pool stalled at 1/2 while a dead Worker held the slot.
    static func computePoolMaintainPlan(target: Int, workers: [WorkerSlotInfo]) -> PoolMaintainPlan {
        guard target > 0 else { return PoolMaintainPlan(toSpawn: [], toDisplace: []) }
        let prefix = "sona-worker-"
        var bySlot: [Int: [WorkerSlotInfo]] = [:]
        for w in workers {
            guard w.label.hasPrefix(prefix),
                  let idx = Int(w.label.dropFirst(prefix.count)) else { continue }
            bySlot[idx, default: []].append(w)
        }
        var toSpawn: [String] = []
        var toDisplace: [String] = []
        for idx in 1...target {
            let occupants = bySlot[idx] ?? []
            let liveOccupants = occupants.filter { $0.status != .offline }
            if liveOccupants.isEmpty {
                for stale in occupants where stale.status == .offline {
                    toDisplace.append(stale.id)
                }
                toSpawn.append("\(prefix)\(idx)")
            }
        }
        return PoolMaintainPlan(toSpawn: toSpawn, toDisplace: toDisplace)
    }

    /// Ensure the pool has a Worker for every slot index in 1...defaultWorkerCount.
    /// Called from pollHealth and from any removal path so that pollHealth-driven
    /// removals (displaced predecessors, drained-and-vanished) and coordinator-driven
    /// removals don't leave the pool below its configured size. Fills gaps by index
    /// (e.g. sona-worker-1 missing while sona-worker-2 exists → spawn sona-worker-1)
    /// rather than appending sona-worker-N+1, which would create duplicate-label
    /// drift over time. Status-aware via `computePoolMaintainPlan`.
    @MainActor
    @discardableResult
    func maintainPoolSize() -> [String] {
        let target = WorkerManager.defaultWorkerCount
        let snapshot = workers.map {
            WorkerSlotInfo(id: $0.id, label: $0.label, status: $0.status)
        }
        let plan = WorkerManager.computePoolMaintainPlan(target: target, workers: snapshot)

        // Displace stale .offline workers first so addWorker's max-index search
        // and pollHealth's later reconcile pass don't observe two entries for
        // the same slot.
        for displacedId in plan.toDisplace {
            if let stale = workers.first(where: { $0.id == displacedId }) {
                print("[pool] displaced offline worker \(stale.label)")
                alertSupervisor(message: "Replacing offline worker \(stale.label) — auto-spawn refilling slot")
            }
        }
        if !plan.toDisplace.isEmpty {
            let displacedSet = Set(plan.toDisplace)
            workers.removeAll { displacedSet.contains($0.id) }
            if let selected = selectedWorkerId, displacedSet.contains(selected) {
                selectedWorkerId = workers.first?.id
            }
        }

        for label in plan.toSpawn {
            print("[pool] missing slot — spawning \(label)")
            addWorker(label: label)
        }
        return plan.toSpawn
    }

    func addWorker(label: String? = nil, engine: WorkerEngine = WorkerEngine.defaultEngine) {
        let usedIndices = workers.compactMap { w -> Int? in
            let prefix = "sona-worker-"
            guard w.label.hasPrefix(prefix) else { return nil }
            return Int(w.label.dropFirst(prefix.count))
        }
        let index = (usedIndices.max() ?? 0) + 1
        let workerLabel = label ?? "sona-worker-\(index)"
        let worker = Worker(label: workerLabel, engine: engine)
        workers.append(worker)
        selectedWorkerId = worker.id
        DispatchQueue.main.async {
            worker.startProcess()
        }
    }

    /// Remove a worker permanently — drain in DB, SIGTERM/SIGKILL the process, do
    /// NOT spawn a replacement. Shrinks the pool by one. Use cycleWorker if you
    /// want a replacement.
    func removeWorker(_ worker: Worker) {
        let slotLabel = worker.label
        let sigtermGrace = CycleSettings.shared.sigtermGrace

        // Mark draining in DB so the server stale-sweep treats it correctly.
        worker.status = .draining
        let port = Int(ProcessInfo.processInfo.environment["SONATA_PORT"] ?? "") ?? 3211
        Task {
            var req = URLRequest(url: URL(string: "http://localhost:\(port)/api/worker/drain?workerId=\(worker.id)")!)
            req.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: req)
        }

        teardownWorker(worker, sigtermGrace: sigtermGrace, slotLabel: slotLabel)
    }

    func restartWorker(_ worker: Worker) {
        worker.status = .restarting
        worker.coordinator?.restart()
    }

    // MARK: - Worker Cycling

    /// Called by the HTTP complete/fail handlers via NotificationCenter.
    /// Evaluates whether the worker should be cycled.
    func onEventCompleted(workerId: String) {
        guard let worker = workers.first(where: { $0.id == workerId }) else { return }
        worker.tasksSinceSpawn += 1
        worker.eventsHandled += 1

        let settings = CycleSettings.shared

        // Refresh pause state for UI
        isCyclingPaused = settings.pauseCycling

        if settings.pauseCycling {
            print("[cycle] Cycling paused — skipping evaluation for \(worker.label)")
            return
        }

        if cycleStrategy.shouldCycle(tasksSinceSpawn: worker.tasksSinceSpawn, settings: settings) {
            print("[cycle] threshold-reached: \(worker.label) tasks=\(worker.tasksSinceSpawn)")
            cycleWorker(worker)
        }
    }

    /// Spawn replacement → drain old → SIGTERM → SIGKILL if needed.
    func cycleWorker(_ oldWorker: Worker) {
        let slotLabel = oldWorker.label
        let settings = CycleSettings.shared

        // Mark old worker draining in DB and freeze auto-restart on its coordinator.
        // If the old bridge exits early (e.g. server returns 410 Gone after the new
        // bridge's predecessor-cleanup deletes its row), we do NOT want the coordinator
        // to helpfully respawn it — that would resurrect a worker we just intentionally
        // retired and put it back into the rotation.
        oldWorker.status = .draining
        oldWorker.coordinator?.autoRestartEnabled = false
        let port = Int(ProcessInfo.processInfo.environment["SONATA_PORT"] ?? "") ?? 3211
        Task {
            var req = URLRequest(url: URL(string: "http://localhost:\(port)/api/worker/drain?workerId=\(oldWorker.id)")!)
            req.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: req)
        }

        print("[cycle] spawn-started: \(slotLabel)")

        // Spawn replacement with same label + engine
        let newWorker = Worker(label: slotLabel, engine: oldWorker.engine)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.workers.append(newWorker)
            newWorker.startProcess()
        }

        // Wait for registration, then teardown old
        let spawnTimeout = settings.spawnTimeout
        let sigtermGrace = settings.sigtermGrace
        DispatchQueue.global().asyncAfter(deadline: .now() + spawnTimeout) { [weak self] in
            guard let self else { return }

            // Check if new worker registered (status != .starting)
            DispatchQueue.main.async {
                if newWorker.status == .starting || newWorker.status == .offline {
                    // Spawn failed
                    print("[cycle] spawn-failed: \(slotLabel)")
                    self.handleSpawnFailure(oldWorker: oldWorker, newWorker: newWorker, slotLabel: slotLabel)
                    return
                }

                print("[cycle] spawn-succeeded: \(slotLabel) newSessionId=\(newWorker.sessionId)")

                // Teardown old worker
                self.teardownWorker(oldWorker, sigtermGrace: sigtermGrace, slotLabel: slotLabel)

                // Reset failure counter on success
                self.cycleFailureCount[slotLabel] = 0
            }
        }
    }

    private func handleSpawnFailure(oldWorker: Worker, newWorker: Worker, slotLabel: String) {
        // Kill the nascent replacement
        newWorker.coordinator?.stop()
        workers.removeAll { $0.id == newWorker.id }

        // Un-drain the old worker — restore both DB status and auto-restart so it
        // continues serving (cycleWorker disabled auto-restart preemptively).
        oldWorker.status = .idle
        oldWorker.coordinator?.autoRestartEnabled = true
        let port = Int(ProcessInfo.processInfo.environment["SONATA_PORT"] ?? "") ?? 3211
        Task {
            var req = URLRequest(url: URL(string: "http://localhost:\(port)/api/worker/undrain?workerId=\(oldWorker.id)")!)
            req.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: req)
        }

        // Track consecutive failures
        let count = (cycleFailureCount[slotLabel] ?? 0) + 1
        cycleFailureCount[slotLabel] = count
        print("[cycle] cycle-aborted: \(slotLabel) consecutiveFailures=\(count)")

        if count >= CycleSettings.shared.cycleFailAlert {
            alertSupervisor(message: "Worker cycling failed \(count) times for slot \(slotLabel). Old worker continues serving.")
        }
    }

    private func teardownWorker(_ worker: Worker, sigtermGrace: TimeInterval, slotLabel: String) {
        print("[cycle] term-sent: \(slotLabel) pid=\(worker.coordinator?.terminalView?.process?.shellPid ?? 0)")
        worker.coordinator?.autoRestartEnabled = false
        worker.coordinator?.terminalView?.terminate()  // SIGTERM

        DispatchQueue.global().asyncAfter(deadline: .now() + sigtermGrace) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                if worker.status != .offline {
                    // Still alive after grace — SIGKILL
                    print("[cycle] kill-required: \(slotLabel)")
                    if let view = worker.coordinator?.terminalView, view.process?.shellPid ?? 0 > 0 {
                        kill(view.process.shellPid, SIGKILL)
                    }
                    self.alertSupervisor(message: "Worker \(slotLabel) required SIGKILL — idle worker refused to exit after SIGTERM.")
                }
                print("[cycle] exit-observed: \(slotLabel)")
                self.workers.removeAll { $0.id == worker.id }
                // Select the replacement if nothing selected
                if self.selectedWorkerId == worker.id {
                    self.selectedWorkerId = self.workers.first?.id
                }
            }
        }
    }

    func alertSupervisor(type: String = "cycle-failure", message: String) {
        let port = Int(ProcessInfo.processInfo.environment["SONATA_PORT"] ?? "") ?? 3211
        Task {
            var req = URLRequest(url: URL(string: "http://localhost:\(port)/api/supervisor/alert")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "type": type,
                "message": message
            ])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    func startHealthPolling() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.pollHealth()
        }
    }

    private func pollHealth() {
        guard let endpoint = WorkerManager.healthEndpoint else { return }
        let listUrl = endpoint.replacingOccurrences(of: "/status", with: "/list")
        guard let url = URL(string: listUrl) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self, let data, error == nil else { return }
            guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

            var serverState: [String: [String: Any]] = [:]
            for row in rows {
                if let wid = row["workerId"] as? String {
                    serverState[wid] = row
                }
            }

            DispatchQueue.main.async {
                // First pass: reconcile present workers; collect IDs to remove.
                var toRemove: [String] = []
                for worker in self.workers {
                    if let info = serverState[worker.id] {
                        let status = info["status"] as? String ?? "offline"
                        switch status {
                        case "idle": worker.status = .idle
                        case "busy": worker.status = .busy
                        case "offline": worker.status = .offline
                        case "draining": worker.status = .draining
                        default: break
                        }
                        if let eventId = info["currentEventId"] as? String, !eventId.isEmpty {
                            worker.currentEventId = eventId
                            worker.currentTask = info["currentTask"] as? String ?? "Working..."
                            if let assignedAt = info["assignedAt"] as? Int64 {
                                worker.taskStartedAt = assignedAt
                            }
                            worker.currentSlug = info["currentSlug"] as? String ?? ""
                            worker.currentEventTokens = (info["currentEventTokens"] as? Int)
                                ?? Int((info["currentEventTokens"] as? Int64) ?? 0)
                            worker.currentInputTokens = (info["currentInputTokens"] as? Int)
                                ?? Int((info["currentInputTokens"] as? Int64) ?? 0)
                            worker.currentCacheReadTokens = (info["currentCacheReadTokens"] as? Int)
                                ?? Int((info["currentCacheReadTokens"] as? Int64) ?? 0)
                        } else {
                            worker.currentEventId = ""
                            worker.currentTask = ""
                            worker.taskStartedAt = 0
                            worker.currentSlug = ""
                            worker.currentEventTokens = 0
                            worker.currentInputTokens = 0
                            worker.currentCacheReadTokens = 0
                        }
                    } else {
                        // Worker is no longer in the server's worker_list. The right
                        // reaction depends on what we last knew about it:
                        // - draining: server's stale-sweep DELETEd it on purpose. Don't
                        //   resurrect it as 'offline' — that's the non-sensical
                        //   draining→offline transition. Just remove it locally.
                        // - displaced predecessor: another live Worker shares this slot
                        //   label, meaning a fresh bridge registered with the same
                        //   sessionLabel and the register handler's predecessor-cleanup
                        //   deleted this row. The local draining flag may have been
                        //   overwritten by an earlier pollHealth tick that observed the
                        //   row before the drain POST landed — same effective state.
                        // - starting/restarting: in-flight registration; keep waiting.
                        // - anything else: surprise disappearance — surface as offline
                        //   so the supervisor can repair.
                        let displacedBySameSlot = self.workers.contains { other in
                            other.id != worker.id
                                && other.label == worker.label
                                && other.status != .offline
                                && other.status != .draining
                        }
                        if worker.status == .draining || displacedBySameSlot {
                            toRemove.append(worker.id)
                        } else if worker.status != .starting && worker.status != .restarting {
                            worker.status = .offline
                        }
                    }
                }
                if !toRemove.isEmpty {
                    self.workers.removeAll { toRemove.contains($0.id) }
                    if let selected = self.selectedWorkerId, toRemove.contains(selected) {
                        self.selectedWorkerId = self.workers.first?.id
                    }
                }
                // Pool maintainer — every health tick. Cheap when the pool is full
                // (single dictionary build); spawns deterministically when a slot is
                // missing. Replaces the implicit assumption that cycleWorker is the
                // only path that removes Workers.
                self.maintainPoolSize()
            }
        }.resume()
    }

    deinit {
        healthTimer?.invalidate()
    }
}

// MARK: - Worker Coordinator (Process Lifecycle)

class WorkerCoordinator: NSObject, LocalProcessTerminalViewDelegate {
    weak var terminalView: LocalProcessTerminalView?
    let worker: Worker
    var autoRestartEnabled = true
    private var contextWatchTimer: Timer?

    /// Per-coordinator consecutive auto-restart counter. Reset on successful
    /// HTTP registration (worker reached `.idle`) or when an inbound event is
    /// handled. Bounded by `CycleSettings.maxAutoRestarts` so a broken launch
    /// (e.g. claude rejecting `--session-id` with "already in use") does not
    /// produce a silent infinite restart loop. 2026-05-18 incident root cause.
    var restartAttempts: Int = 0

    /// Exit code recorded by the most recent `processTerminated`. Included
    /// in the supervisor alert when `restartAttempts` exceeds its bound so
    /// the operator can correlate with claude's stderr / JSONL state.
    var lastExitCode: Int32?

    init(worker: Worker) {
        self.worker = worker
    }

    /// Resolve the claude session JSONL path for a given sessionId and cwd.
    /// Mirrors claude's CLI behavior: it stores transcripts under
    /// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`, where the
    /// encoding replaces `/` and `.` with `-`. Pure: no I/O, no globals.
    static func sessionJSONLPath(sessionId: String, cwd: String, home: String) -> String {
        let encoded = cwd.replacingOccurrences(
            of: #"[\/.]"#, with: "-", options: .regularExpression)
        return "\(home)/.claude/projects/\(encoded)/\(sessionId).jsonl"
    }

    /// Returns true when claude has already persisted a JSONL for this
    /// sessionId. If so, a fresh `--session-id` relaunch will be rejected
    /// with "already in use"; the restart must use `--resume` instead.
    static func sessionJSONLExists(
        sessionId: String,
        cwd: String = WorkerManager.workingDirectory,
        home: String? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        let resolvedHome = home
            ?? ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        let path = sessionJSONLPath(sessionId: sessionId, cwd: cwd, home: resolvedHome)
        return fileManager.fileExists(atPath: path)
    }

    /// Returns true when `restartAttempts` (post-increment) has exceeded the
    /// configured bound. Pure helper for testing.
    static func shouldDisableAfterAttempts(attempts: Int, max: Int) -> Bool {
        attempts > max
    }

    func startProcess(restartNudge: Bool = false, taskId: String? = nil, lastEventId: String? = nil) {
        guard let view = terminalView else { return }

        let launch = WorkerCoordinator.buildLaunchEnv(
            workerId: worker.id,
            sessionId: worker.sessionId,
            sessionLabel: worker.label,
            restartNudge: restartNudge,
            taskId: taskId,
            lastEventId: lastEventId,
            engine: worker.engine
        )

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.worker.status = .starting

            let terminal = view.getTerminal()
            terminal.resetToInitialState()

            var args: [String] = []
            switch self.worker.engine {
            case .claude:
                // Recovery workers use --resume to load the existing JSONL session;
                // claude rejects --session-id with "already in use" when the JSONL exists
                // (sessionIdExists in claude's CLI just statSyncs <sessionId>.jsonl).
                // Fresh workers use --session-id with a new UUID — no existing JSONL.
                if restartNudge {
                    args.append(contentsOf: ["--resume", self.worker.sessionId])
                } else {
                    args.append(contentsOf: ["--session-id", self.worker.sessionId])
                }
                if WorkerManager.skipPermissions {
                    args.append("--dangerously-skip-permissions")
                }
                if let channel = WorkerManager.channelServer {
                    args.append(contentsOf: ["--dangerously-load-development-channels", "server:\(channel)"])
                }
                // Spread any --mcp-config args from the in-proc opt-in path.
                args.append(contentsOf: launch.extraArgs)
            case .goose:
                // Goose has no JSONL/session-id-collision quirk: `session --name`
                // both creates and resumes the same named session, so fresh and
                // recovery spawns use identical argv. Report-back + skills come
                // from the MCP extensions in launch.extraArgs; permission bypass
                // is GOOSE_MODE=auto in the env (set by buildLaunchEnv), not a flag.
                args = GooseEngineBinding.spawnArgs(
                    sessionId: self.worker.sessionId,
                    extensionArgs: launch.extraArgs
                )
            }

            view.startProcess(
                executable: WorkerManager.binary(for: self.worker.engine),
                args: args,
                environment: launch.env,
                currentDirectory: WorkerManager.workingDirectory
            )

            // Auto-confirm + context-limit watch are Claude-Code-TUI specific
            // (carriage-return dismissals + "Context limit reached" → /compact).
            // Goose's interactive prompts differ and GOOSE_MODE=auto avoids tool
            // gating; its auto-confirm/context handling is a T4 follow-up.
            if self.worker.engine == .claude {
                self.scheduleAutoConfirm()
                self.startContextWatch()
            }

            // Register worker with Sonata HTTP API and set status to idle after startup
            let workerId = worker.id
            let label = worker.label
            let workerSessionId = worker.sessionId
            let port = Int(ProcessInfo.processInfo.environment["SONATA_PORT"] ?? "") ?? 3211
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                // Register
                var req = URLRequest(url: URL(string: "http://localhost:\(port)/api/worker/register")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: [
                    "workerId": workerId,
                    "sessionLabel": label,
                    "sessionId": workerSessionId,
                    "capabilities": ["task", "email"]
                ])
                URLSession.shared.dataTask(with: req) { _, response, _ in
                    let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                    DispatchQueue.main.async { [weak self] in
                        self?.worker.status = .idle
                        // Reset auto-restart counter once the process actually
                        // reaches a registered+idle state — the restart loop
                        // was productive, so subsequent crashes start counting
                        // from zero again. Fix 3 of the 2026-05-18 auto-spawn
                        // patch (claude/documents/plans/worker-auto-spawn-...).
                        if ok {
                            self?.restartAttempts = 0
                        }
                    }
                }.resume()
            }
        }
    }

    func stop() {
        autoRestartEnabled = false
        contextWatchTimer?.invalidate()
        contextWatchTimer = nil
        terminalView?.terminate()
    }

    func restart() {
        autoRestartEnabled = true
        worker.status = .restarting
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startProcess()
        }
    }

    private func scheduleAutoConfirm() {
        for delay in [2.0, 4.0, 7.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.terminalView?.send(txt: "\r")
            }
        }
    }

    private func startContextWatch() {
        contextWatchTimer?.invalidate()
        contextWatchTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkForContextLimit()
        }
    }

    private func checkForContextLimit() {
        guard let view = terminalView else { return }
        let terminal = view.getTerminal()
        let rows = terminal.rows
        var screenText = ""
        for row in max(0, rows - 5)..<rows {
            if let line = terminal.getLine(row: row) {
                screenText += line.translateToString() + "\n"
            }
        }
        if screenText.contains("Context limit reached") || screenText.contains("/compact or /clear") {
            print("[\(worker.label)] Context limit detected — auto-sending /compact")
            view.send(txt: "/compact\r")
        }
    }

    struct LaunchEnv {
        let env: [String]
        let extraArgs: [String]
    }

    /// Backwards-compat shim — pre-§6 call sites that only need the env
    /// (e.g. tests) keep working. New code should prefer
    /// `buildLaunchEnv(...)` and spread `.extraArgs` into the claude args.
    static func buildEnvironment(
        workerId: String,
        sessionId: String? = nil,
        sessionLabel: String? = nil,
        restartNudge: Bool = false,
        taskId: String? = nil,
        lastEventId: String? = nil
    ) -> [String] {
        return buildLaunchEnv(
            workerId: workerId,
            sessionId: sessionId,
            sessionLabel: sessionLabel,
            restartNudge: restartNudge,
            taskId: taskId,
            lastEventId: lastEventId
        ).env
    }

    /// Per plan §6: returns env-vars plus any extra args to spread into
    /// the claude command line. When SONATA_MCP_INPROC=1 and the
    /// MCPSessionRegistry is published, `extraArgs` carries
    /// `["--mcp-config", "<path>"]` and the legacy WORKER_ID /
    /// SONA_SESSION_ID / restart-nudge env-vars are omitted (the new
    /// MCP server learns identity from the URL path). Flag unset =
    /// byte-for-byte identical to pre-§6.
    static func buildLaunchEnv(
        workerId: String,
        sessionId: String? = nil,
        sessionLabel: String? = nil,
        restartNudge: Bool = false,
        taskId: String? = nil,
        lastEventId: String? = nil,
        engine: WorkerEngine = .claude
    ) -> LaunchEnv {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")

        let commonPaths = [
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.nvm/versions/node/v25.8.1/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? commonPaths.joined(separator: ":")
        let mergedPath = commonPaths.filter { !currentPath.contains($0) }.joined(separator: ":")
        env.append("PATH=\(mergedPath.isEmpty ? currentPath : "\(mergedPath):\(currentPath)")")

        env.append("HOME=\(home)")
        env.append("SONA_WORKER=1")

        // Engine-specific MCP wiring + identity. Claude (default) keeps its
        // exact in-proc/legacy behavior; Goose attaches its MCP servers as
        // CLI extensions and never touches the Claude in-proc credential path.
        var resolvedExtraArgs: [String] = []
        switch engine {
        case .claude:
            // Per plan §6: opt-in in-proc MCP via SONATA_MCP_INPROC=1.
            let inProcExtras = MCPSpawn.extraArgsForInProcMCP(
                sessionKey: workerId,
                role: .worker,
                slotLabel: sessionLabel
            )
            if inProcExtras != nil {
                // SONA_SESSION_ID still emitted (mem-server.ts sibling-injection
                // compatibility — Open Question 3 in plan §12). Other legacy
                // identity vars (WORKER_ID, SESSION_LABEL, restart-nudge trio)
                // are NOT emitted: identity is in the URL path now, and the
                // restart nudge fires inline via MCPNotificationDispatcher
                // after spawn (scheduled below).
                if let sessionId {
                    env.append("SONA_SESSION_ID=\(sessionId)")
                }
                if restartNudge, let taskId, let lastEventId {
                    // Fire the SONATA_RESTART channel notification ~2s after
                    // spawn, once the in-proc SSE writer has had time to
                    // attach. Cheap detached Task; failure is logged but
                    // non-fatal.
                    let nudgeWorkerId = workerId
                    let nudgeTaskId = taskId
                    let nudgeLastEventId = lastEventId
                    Task.detached {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await MCPNotificationDispatcher.shared.pushSonataRestart(
                            sessionKey: nudgeWorkerId,
                            taskId: nudgeTaskId,
                            lastEventId: nudgeLastEventId
                        )
                    }
                }
            } else {
                env.append("WORKER_ID=\(workerId)")
                if let sessionLabel {
                    env.append("SESSION_LABEL=\(sessionLabel)")
                }
                if let sessionId {
                    env.append("SONA_SESSION_ID=\(sessionId)")
                }
                if restartNudge {
                    env.append("SONATA_RESTART_NUDGE=1")
                }
                if let taskId {
                    env.append("SONATA_RESTART_TASK_ID=\(taskId)")
                }
                if let lastEventId {
                    env.append("SONATA_RESTART_LAST_EVENT_ID=\(lastEventId)")
                }
            }
            resolvedExtraArgs = inProcExtras ?? []
        case .goose:
            // Goose reports back + loads skills via MCP extensions (channels/T2,
            // skills-loader/T1) passed as `--with-extension` args; permission
            // bypass is GOOSE_MODE=auto. No Claude in-proc credential is issued.
            if let sessionId {
                env.append("SONA_SESSION_ID=\(sessionId)")
            }
            env.append(contentsOf: GooseEngineBinding.envAdditions(
                skipPermissions: WorkerManager.skipPermissions
            ))
            resolvedExtraArgs = GooseEngineBinding.extensionArgs()
        }

        // Pass through auth and API keys from parent environment or .env file
        let passthrough = [
            "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY",
            "AGENTMAIL_API_KEY", "OPENROUTER_API_KEY", "OPENAI_API_KEY",
            "CF_D1_EDIT_TOKEN", "CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_API_TOKEN",
            "EYEBROWSE_URL", "EYEBROWSE_TOKEN",
        ]
        // Try parent env first, then ~/.sonata/.env
        let dotEnv = loadDotEnv(path: "\(home)/.sonata/.env")
        for key in passthrough {
            if let val = ProcessInfo.processInfo.environment[key] {
                env.append("\(key)=\(val)")
            } else if let val = dotEnv[key] {
                env.append("\(key)=\(val)")
            }
        }

        if let extra = ProcessInfo.processInfo.environment["SONA_EXTRA_ENV"] {
            for item in extra.components(separatedBy: ",") where !item.isEmpty {
                env.append(item)
            }
        }

        return LaunchEnv(env: env, extraArgs: resolvedExtraArgs)
    }

    static func loadDotEnv(path: String) -> [String: String] {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in data.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if let eqRange = trimmed.range(of: "=") {
                let key = String(trimmed[trimmed.startIndex..<eqRange.lowerBound])
                let val = String(trimmed[eqRange.upperBound...])
                result[key] = val
            }
        }
        return result
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        print("[\(worker.label)] Process exited with code: \(exitCode ?? -1)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.worker.status = .offline
            self.lastExitCode = exitCode

            guard self.autoRestartEnabled else { return }

            let maxAttempts = CycleSettings.shared.maxAutoRestarts
            self.restartAttempts += 1
            if WorkerCoordinator.shouldDisableAfterAttempts(attempts: self.restartAttempts, max: maxAttempts) {
                self.autoRestartEnabled = false
                let exitDesc = exitCode.map(String.init(describing:)) ?? "?"
                print("[\(self.worker.label)] Auto-restart bound (\(maxAttempts)) exceeded — disabling autoRestart (lastExit=\(exitDesc))")
                WorkerManager.shared.alertSupervisor(
                    type: "auto-restart-bound",
                    message: "Worker \(self.worker.label) hit auto-restart bound (\(maxAttempts) consecutive attempts); lastExit=\(exitDesc). autoRestart disabled — pool maintainer or supervisor must intervene."
                )
                return
            }

            // Pick --resume vs --session-id based on JSONL state. Claude rejects
            // --session-id with "already in use" once a JSONL exists for that
            // UUID; before this guard, the auto-restart loop produced a silent
            // infinite restart on the 2026-05-18 incident. --resume rehydrates
            // the prior conversation (Evan, 2026-05-18: "RESUME").
            let useResume = WorkerCoordinator.sessionJSONLExists(sessionId: self.worker.sessionId)
            print("[\(self.worker.label)] Auto-restarting in 3s (attempt \(self.restartAttempts)/\(maxAttempts), useResume=\(useResume))...")
            self.worker.status = .restarting
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.startProcess(restartNudge: useResume)
            }
        }
    }
}

// MARK: - Workers View (Tab Content)

struct WorkersView: View {
    @ObservedObject private var manager = WorkerManager.shared
    @State private var showPromptCachePopover: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Cycling pause banner
            if manager.isCyclingPaused {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.yellow)
                    Text("Worker cycling is paused")
                        .font(.caption.bold())
                    Spacer()
                    Button("Unpause") {
                        UserDefaults.standard.set(false, forKey: "sonata.pauseCycling")
                        manager.isCyclingPaused = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.yellow.opacity(0.1))
            }

            NavigationSplitView {
                workerSidebar
                    .sonataSidebar(flame: true)
            } detail: {
                if manager.workers.isEmpty {
                    emptyState
                } else {
                    TerminalContainerView()
                        .environmentObject(manager)
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    // MARK: - Sidebar

    private var workerSidebar: some View {
        VStack(spacing: 0) {
            workerSidebarHeader
            Divider()

            // Custom scrollable list instead of `List(.sidebar)`. macOS's
            // sidebar List paints selection backgrounds from
            // NSColor.selectedContentBackgroundColor, which SwiftUI's
            // `.tint(...)` cannot override — so .preferredColorScheme +
            // .tint at the app root still left selection as system blue.
            // Drawing the row background here lets us bind the highlight
            // to Theme.Color.selectionTint and stay consistent across
            // macOS point releases.
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(manager.workers) { worker in
                        WorkerSidebarRow(worker: worker)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(manager.selectedWorkerId == worker.id
                                          ? Theme.Color.selectionTint
                                          : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(manager.selectedWorkerId == worker.id
                                            ? Theme.Color.selectionAccent.opacity(0.55)
                                            : Color.clear,
                                            lineWidth: 0.5)
                            )
                            .onTapGesture {
                                manager.selectedWorkerId = worker.id
                            }
                            .contextMenu {
                                Button("Restart") { manager.restartWorker(worker) }
                                Button("Remove", role: .destructive) { manager.removeWorker(worker) }
                            }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }

            HStack(spacing: 8) {
                Button(action: { showPromptCachePopover.toggle() }) {
                    Image(systemName: "chart.bar")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Prompt cache hit rates")
                .popover(isPresented: $showPromptCachePopover, arrowEdge: .top) {
                    PromptCacheStatsPanel()
                        .frame(width: 320, height: 280)
                }

                Spacer()
                Text("\(manager.workers.count) worker\(manager.workers.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // Background, flame, and trailing stroke now come from
        // `.sonataSidebar(flame: true)` applied in the NavigationSplitView
        // sidebar closure — single source of truth shared with every sidebar.
    }

    private var workerSidebarHeader: some View {
        HStack(spacing: 8) {
            Text("Workers")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Button {
                manager.addWorker()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Add Worker")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Workers Running")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Click + Add Worker to spawn a Claude Code session")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Add Worker") {
                manager.addWorker()
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Worker Row

struct WorkerSidebarRow: View {
    @ObservedObject var worker: Worker

    var body: some View {
        HStack(spacing: 8) {
            // Worker icon tinted + glowing in the status color, baseline-aligned
            // with the label — mirrors the Sessions sidebar's kind icon. The
            // glow replaces the old status dot so the row conveys both "this is
            // a worker" and its liveness in one mark.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(worker.label)
                        .font(.system(.body, design: .monospaced))
                    HStack(spacing: 4) {
                        Text(worker.status.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if worker.status == .busy && !worker.currentTask.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(worker.currentTask)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if !worker.currentEventId.isEmpty {
                                Text(liveMonitoringLine(worker))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            Spacer()
            if worker.status == .busy && !worker.currentEventId.isEmpty {
                Button {
                    Task { await releaseWorker(worker) }
                } label: {
                    Text("Release")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .help("Fail current event and free this worker")
            }
            if worker.eventsHandled > 0 {
                Text("\(worker.eventsHandled)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    /// Worker icon tinted + glowing in the status color so each row conveys
    /// liveness without a separate dot — same treatment as the Sessions
    /// sidebar's kind icon (state colors come from `WorkerStatus.color`).
    private var statusIcon: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: 12))
            .foregroundStyle(worker.status.color)
            .shadow(color: worker.status.color.opacity(0.75), radius: 4)
            .frame(width: 16, alignment: .center)
    }

    private func liveMonitoringLine(_ worker: Worker) -> String {
        var parts: [String] = []
        let slug = worker.currentSlug.isEmpty ? "—" : worker.currentSlug
        parts.append(slug)
        if worker.taskStartedAt > 0 {
            let elapsedSec = Int((Date().timeIntervalSince1970 * 1000 - Double(worker.taskStartedAt)) / 1000)
            parts.append("\(elapsedSec)s")
        }
        if worker.currentEventTokens > 0 {
            let kTokens = Double(worker.currentEventTokens) / 1000.0
            parts.append(String(format: "%.1fk", kTokens))
        }
        if let hr = worker.currentCacheHitRate {
            parts.append(String(format: "%.0f%%", hr * 100))
        }
        return parts.joined(separator: " · ")
    }

    private func releaseWorker(_ worker: Worker) async {
        guard !worker.currentEventId.isEmpty,
              let endpoint = WorkerManager.healthEndpoint else { return }
        let baseUrl = endpoint.replacingOccurrences(of: "/status", with: "")
        guard let url = URL(string: "\(baseUrl)/events/fail?eventId=\(worker.currentEventId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"error\":\"Released by user\"}".utf8)
        _ = try? await URLSession.shared.data(for: request)
    }
}

// MARK: - Prompt Cache Stats Panel

struct PromptCacheStatsRow: Identifiable {
    let id: String         // promptKey
    let eventType: String
    let promptHash: String
    let sampleCount: Int64
    let hitRate: Double?
    let sessionLabel: String?
    let cwdBasename: String?

    /// Threshold flag from planning doc: enough samples to trust the rate AND
    /// hit rate is below 50%. Sub-floor samples are treated as noise.
    var isLeak: Bool {
        guard let hr = hitRate else { return false }
        return sampleCount >= 20 && hr < 0.5
    }
}

@MainActor
final class PromptCacheStatsModel: ObservableObject {
    @Published var rows: [PromptCacheStatsRow] = []
    private var timer: Timer?

    init() { startPolling() }
    deinit { timer?.invalidate() }

    private func startPolling() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let port = Int(ProcessInfo.processInfo.environment["SONATA_PORT"] ?? "") ?? 3211
        guard let url = URL(string: "http://localhost:\(port)/api/prompt_cache_stats") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            let parsed: [PromptCacheStatsRow] = arr.compactMap { row in
                guard let key = row["promptKey"] as? String else { return nil }
                let hr = row["hitRate"] as? Double
                let sample: Int64 = (row["sampleCount"] as? Int64)
                    ?? Int64((row["sampleCount"] as? Int) ?? 0)
                return PromptCacheStatsRow(
                    id: key,
                    eventType: row["eventType"] as? String ?? "",
                    promptHash: row["promptHash"] as? String ?? "",
                    sampleCount: sample,
                    hitRate: hr,
                    sessionLabel: row["sessionLabel"] as? String,
                    cwdBasename: row["cwdBasename"] as? String
                )
            }
            DispatchQueue.main.async { self?.rows = parsed }
        }.resume()
    }
}

struct PromptCacheStatsPanel: View {
    @StateObject private var model = PromptCacheStatsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Prompt cache")
                    .font(.caption.bold())
                Spacer()
                if !model.rows.isEmpty {
                    Text("\(model.rows.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if model.rows.isEmpty {
                Text("No data yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            HStack(spacing: 6) {
                                if row.isLeak {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                                Text(displayLabel(row))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(row.sampleCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 36, alignment: .trailing)
                                if let hr = row.hitRate {
                                    Text(String(format: "%.0f%%", hr * 100))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(row.isLeak ? .orange : .secondary)
                                        .frame(width: 36, alignment: .trailing)
                                } else {
                                    Text("—")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 36, alignment: .trailing)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
        .onAppear { model.refresh() }
    }

    private func displayLabel(_ row: PromptCacheStatsRow) -> String {
        let primary = (row.sessionLabel?.isEmpty == false) ? row.sessionLabel! : row.promptHash
        return "\(row.eventType) · \(primary)"
    }
}

