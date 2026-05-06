import SwiftUI
import SwiftTerm
import AppKit

// MARK: - Worker Model

class Worker: ObservableObject, Identifiable {
    let id: String
    let label: String
    let sessionId: String  // Claude --session-id UUID for cycling/resume

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

    init(label: String) {
        self.id = "worker-\(Date().timeIntervalSince1970.description.replacingOccurrences(of: ".", with: "").suffix(10))"
        self.label = label
        self.sessionId = UUID().uuidString.lowercased()
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    }

    func startProcess() {
        let coord = WorkerCoordinator(worker: self)
        self.coordinator = coord
        terminalView.processDelegate = coord
        coord.terminalView = terminalView
        coord.startProcess()
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

    private var healthTimer: Timer?
    private let cycleStrategy: CycleStrategy = TaskCountStrategy()
    private var cycleFailureCount: [String: Int] = [:]  // worker label → consecutive failures

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
        startHealthPolling()
    }

    /// Spawn the default number of workers on app launch.
    /// Called from SonataApp after the HTTP server is ready.
    @MainActor
    func spawnDefaultWorkers() {
        guard workers.isEmpty else { return } // don't double-spawn
        let count = WorkerManager.defaultWorkerCount
        for i in 1...count {
            addWorker(label: "sona-worker-\(i)")
        }
    }

    func addWorker(label: String? = nil) {
        let usedIndices = workers.compactMap { w -> Int? in
            let prefix = "sona-worker-"
            guard w.label.hasPrefix(prefix) else { return nil }
            return Int(w.label.dropFirst(prefix.count))
        }
        let index = (usedIndices.max() ?? 0) + 1
        let workerLabel = label ?? "sona-worker-\(index)"
        let worker = Worker(label: workerLabel)
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

        // Mark old worker draining in DB
        oldWorker.status = .draining
        let port = Int(ProcessInfo.processInfo.environment["SONATA_PORT"] ?? "") ?? 3211
        Task {
            var req = URLRequest(url: URL(string: "http://localhost:\(port)/api/worker/drain?workerId=\(oldWorker.id)")!)
            req.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: req)
        }

        print("[cycle] spawn-started: \(slotLabel)")

        // Spawn replacement with same label
        let newWorker = Worker(label: slotLabel)
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

        // Un-drain the old worker
        oldWorker.status = .idle
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

    private func alertSupervisor(message: String) {
        let port = Int(ProcessInfo.processInfo.environment["SONATA_PORT"] ?? "") ?? 3211
        Task {
            var req = URLRequest(url: URL(string: "http://localhost:\(port)/api/supervisor/alert")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "type": "cycle-failure",
                "message": message
            ])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    private func startHealthPolling() {
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
                        // - starting/restarting: in-flight registration; keep waiting.
                        // - anything else: surprise disappearance — surface as offline
                        //   so the supervisor can repair.
                        if worker.status == .draining {
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

    init(worker: Worker) {
        self.worker = worker
    }

    func startProcess() {
        guard let view = terminalView else { return }

        let env = WorkerCoordinator.buildEnvironment(workerId: worker.id, sessionId: worker.sessionId, sessionLabel: worker.label)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.worker.status = .starting

            let terminal = view.getTerminal()
            terminal.resetToInitialState()

            var args: [String] = []
            args.append(contentsOf: ["--session-id", self.worker.sessionId])
            if WorkerManager.skipPermissions {
                args.append("--dangerously-skip-permissions")
            }
            if let channel = WorkerManager.channelServer {
                args.append(contentsOf: ["--dangerously-load-development-channels", "server:\(channel)"])
            }

            view.startProcess(
                executable: WorkerManager.claudeBinary,
                args: args,
                environment: env,
                currentDirectory: WorkerManager.workingDirectory
            )

            self.scheduleAutoConfirm()
            self.startContextWatch()

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
                URLSession.shared.dataTask(with: req) { _, _, _ in
                    DispatchQueue.main.async { [weak self] in
                        self?.worker.status = .idle
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

    static func buildEnvironment(workerId: String, sessionId: String? = nil, sessionLabel: String? = nil) -> [String] {
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
        env.append("WORKER_ID=\(workerId)")
        env.append("SONA_WORKER=1")
        if let sessionLabel {
            env.append("SESSION_LABEL=\(sessionLabel)")
        }
        if let sessionId {
            env.append("SONA_SESSION_ID=\(sessionId)")
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

        return env
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

            if self.autoRestartEnabled {
                print("[\(self.worker.label)] Auto-restarting in 3s...")
                self.worker.status = .restarting
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.startProcess()
                }
            }
        }
    }
}

// MARK: - Workers View (Tab Content)

struct WorkersView: View {
    @ObservedObject private var manager = WorkerManager.shared

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
            } detail: {
                if manager.workers.isEmpty {
                    emptyState
                } else {
                    TerminalContainerView()
                        .environmentObject(manager)
                }
            }
        }
    }

    // MARK: - Sidebar

    private var workerSidebar: some View {
        VStack(spacing: 0) {
            List(selection: $manager.selectedWorkerId) {
                ForEach(manager.workers) { worker in
                    WorkerSidebarRow(worker: worker)
                        .tag(worker.id)
                        .contextMenu {
                            Button("Restart") { manager.restartWorker(worker) }
                            Button("Remove", role: .destructive) { manager.removeWorker(worker) }
                        }
                }
            }
            .listStyle(.sidebar)

            PromptCacheStatsPanel()

            HStack {
                Button(action: { manager.addWorker() }) {
                    Label("Add Worker", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("\(manager.workers.count) worker\(manager.workers.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 220, idealWidth: 260)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
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
            Circle()
                .fill(worker.status.color)
                .frame(width: 8, height: 8)
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

    private func refresh() {
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
                    hitRate: hr
                )
            }
            DispatchQueue.main.async { self?.rows = parsed }
        }.resume()
    }
}

struct PromptCacheStatsPanel: View {
    @StateObject private var model = PromptCacheStatsModel()
    @State private var expanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
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
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }

            if expanded {
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
                                    Text("\(row.eventType) · \(row.promptHash)")
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
                    .frame(maxHeight: 160)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
    }
}
