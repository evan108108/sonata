import SwiftUI
import SwiftTerm
import AppKit

// MARK: - Worker Model

class Worker: ObservableObject, Identifiable {
    let id: String
    let label: String

    @Published var status: WorkerStatus = .starting
    @Published var currentTask: String = ""
    @Published var currentEventId: String = ""
    @Published var taskStartedAt: Int64 = 0
    @Published var eventsHandled: Int = 0

    let terminalView: LocalProcessTerminalView
    var coordinator: WorkerCoordinator?

    init(label: String) {
        self.id = "worker-\(Date().timeIntervalSince1970.description.replacingOccurrences(of: ".", with: "").suffix(10))"
        self.label = label
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

        var color: SwiftUI.Color {
            switch self {
            case .starting, .restarting: return .yellow
            case .idle: return .green
            case .busy: return .orange
            case .offline: return .red
            }
        }

        var icon: String {
            switch self {
            case .starting: return "arrow.clockwise.circle"
            case .idle: return "checkmark.circle"
            case .busy: return "bolt.circle.fill"
            case .offline: return "xmark.circle"
            case .restarting: return "arrow.clockwise"
            }
        }
    }
}

// MARK: - Worker Manager

class WorkerManager: ObservableObject {
    static let shared = WorkerManager()

    @Published var workers: [Worker] = []
    @Published var selectedWorkerId: String?

    private var healthTimer: Timer?

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
        let index = workers.count + 1
        let workerLabel = label ?? "sona-worker-\(index)"
        let worker = Worker(label: workerLabel)
        workers.append(worker)
        selectedWorkerId = worker.id
        DispatchQueue.main.async {
            worker.startProcess()
        }
    }

    func removeWorker(_ worker: Worker) {
        worker.coordinator?.stop()
        workers.removeAll { $0.id == worker.id }
        if selectedWorkerId == worker.id {
            selectedWorkerId = workers.first?.id
        }
    }

    func restartWorker(_ worker: Worker) {
        worker.status = .restarting
        worker.coordinator?.restart()
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
                for worker in self.workers {
                    if let info = serverState[worker.id] {
                        let status = info["status"] as? String ?? "offline"
                        switch status {
                        case "idle": worker.status = .idle
                        case "busy": worker.status = .busy
                        case "offline": worker.status = .offline
                        default: break
                        }
                        if let eventId = info["currentEventId"] as? String, !eventId.isEmpty {
                            worker.currentEventId = eventId
                            worker.currentTask = info["currentTask"] as? String ?? "Working..."
                            if let assignedAt = info["assignedAt"] as? Int64 {
                                worker.taskStartedAt = assignedAt
                            }
                        } else {
                            worker.currentEventId = ""
                            worker.currentTask = ""
                            worker.taskStartedAt = 0
                        }
                    } else {
                        if worker.status != .starting && worker.status != .restarting {
                            worker.status = .offline
                        }
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
    private var autoRestartEnabled = true
    private var contextWatchTimer: Timer?

    init(worker: Worker) {
        self.worker = worker
    }

    func startProcess() {
        guard let view = terminalView else { return }

        let env = WorkerCoordinator.buildEnvironment(workerId: worker.id)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.worker.status = .starting

            let terminal = view.getTerminal()
            terminal.resetToInitialState()

            var args: [String] = []
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
            let port = Int(ProcessInfo.processInfo.environment["SONATA_PORT"] ?? "") ?? 3211
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                // Register
                var req = URLRequest(url: URL(string: "http://localhost:\(port)/api/worker/register")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: [
                    "workerId": workerId,
                    "sessionLabel": label,
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

    static func buildEnvironment(workerId: String) -> [String] {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")

        let commonPaths = [
            "\(home)/.local/bin",
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

        if let extra = ProcessInfo.processInfo.environment["SONA_EXTRA_ENV"] {
            for item in extra.components(separatedBy: ",") where !item.isEmpty {
                env.append(item)
            }
        }

        return env
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

    // MARK: - Sidebar

    private var workerSidebar: some View {
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
        .safeAreaInset(edge: .bottom) {
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
        .frame(minWidth: 180, idealWidth: 220)
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
                        if worker.taskStartedAt > 0 {
                            let elapsed = (Date().timeIntervalSince1970 * 1000 - Double(worker.taskStartedAt)) / 60_000
                            Text("\(Int(elapsed))m")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
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
