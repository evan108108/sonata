import Foundation
import SwiftUI
import Hummingbird
import HummingbirdWebSocket
import GRDB
import Logging
import SwiftTerm

// MARK: - App Entry Point

/// Port for the Sonata HTTP server, configurable via SONATA_PORT env var.
let sonataPort: Int = Int(ProcessInfo.processInfo.environment["SONATA_PORT"] ?? "") ?? 3211

/// Deploy MCP bridge scripts from the app bundle to ~/.sonata/mcp/ and ensure
/// memory + sonata-bridge MCP servers are registered in ~/.claude/mcp.json.
/// Called on startup so every Claude Code session has access to Sona's memory.
func ensureGlobalMCPServers() {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser

    // 1. Deploy bundled MCP scripts to ~/.sonata/mcp/
    let mcpDir = home.appendingPathComponent(".sonata/mcp")
    try? fm.createDirectory(at: mcpDir, withIntermediateDirectories: true)

    // Copy mem-server.ts from bundle (always overwrite to keep in sync with app version)
    if let sourceURL = Bundle.module.url(forResource: "mem-server", withExtension: "ts", subdirectory: "mcp") {
        let dest = mcpDir.appendingPathComponent("mem-server.ts")
        try? fm.removeItem(at: dest)
        try? fm.copyItem(at: sourceURL, to: dest)
        sonataFileLog("MCP setup: deployed mem-server.ts to ~/.sonata/mcp/")
    }

    // Copy sonata-bridge.ts from bundle (always overwrite to keep in sync with app version)
    if let bridgeURL = Bundle.module.url(forResource: "sonata-bridge", withExtension: "ts", subdirectory: "mcp") {
        let dest = mcpDir.appendingPathComponent("sonata-bridge.ts")
        try? fm.removeItem(at: dest)
        try? fm.copyItem(at: bridgeURL, to: dest)
        sonataFileLog("MCP setup: deployed sonata-bridge.ts to ~/.sonata/mcp/")
    }

    // 2. Register in both ~/.claude/mcp.json (Claude Code) and ~/.claude.json (Claude Desktop)
    let memServerPath = mcpDir.appendingPathComponent("mem-server.ts").path
    let bridgePath = mcpDir.appendingPathComponent("sonata-bridge.ts").path

    let requiredServers: [String: [String: Any]] = [
        "memory": [
            "type": "stdio",
            "command": "bun",
            "args": ["run", memServerPath],
        ],
        "sonata-bridge": [
            "type": "stdio",
            "command": "bun",
            "args": [bridgePath],
            "env": ["SONA_WORKER": "1"],
        ],
    ]

    let configPaths = [
        home.appendingPathComponent(".claude/mcp.json"),   // Claude Code
        home.appendingPathComponent(".claude.json"),        // Claude Desktop
    ]

    for configPath in configPaths {
        do {
            var json: [String: Any] = [:]
            if let data = try? Data(contentsOf: configPath) {
                json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            var mcpServers = json["mcpServers"] as? [String: Any] ?? [:]

            var changed = false
            for (name, config) in requiredServers {
                if let existing = mcpServers[name] as? [String: Any],
                   let existingArgs = existing["args"] as? [String],
                   let newConfig = config as? [String: Any],
                   let newArgs = newConfig["args"] as? [String],
                   existingArgs == newArgs {
                    continue  // Already correct
                }
                mcpServers[name] = config
                changed = true
                sonataFileLog("MCP setup: set '\(name)' in \(configPath.lastPathComponent)")
            }

            if changed {
                json["mcpServers"] = mcpServers
                let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                try output.write(to: configPath)
                sonataFileLog("MCP setup: updated \(configPath.lastPathComponent)")
            }
        } catch {
            sonataFileLog("MCP setup: failed to update \(configPath.lastPathComponent) — \(error)")
        }
    }
}

/// Ensure ~/.sonata/worker/ and ~/.sonata/supervisor/ directories exist with CLAUDE.md files.
/// Copies defaults from the app bundle if not present. Does not overwrite existing files.
func ensureRoleDirectories() {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let sonataDir = home.appendingPathComponent(".sonata")

    for role in ["worker", "supervisor"] {
        let roleDir = sonataDir.appendingPathComponent(role)
        let claudeMdDest = roleDir.appendingPathComponent("CLAUDE.md")

        // Create directory
        try? fm.createDirectory(at: roleDir, withIntermediateDirectories: true)

        // Copy CLAUDE.md from bundle if not present
        if !fm.fileExists(atPath: claudeMdDest.path) {
            if let sourceURL = Bundle.module.url(forResource: "CLAUDE", withExtension: "md", subdirectory: role) {
                try? fm.copyItem(at: sourceURL, to: claudeMdDest)
                sonataFileLog("Role setup: copied \(role)/CLAUDE.md from bundle")
            } else {
                sonataFileLog("Role setup: \(role)/CLAUDE.md not found in bundle")
            }
        }
    }
}

/// Append a line to ~/Library/Logs/Sonata.log so errors are visible when the
/// app is launched from the Finder (where stderr is discarded).
func sonataFileLog(_ line: String) {
    let logsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let logURL = logsDir.appendingPathComponent("Sonata.log")
    let ts = ISO8601DateFormatter().string(from: Date())
    let entry = "[\(ts)] \(line)\n"
    if let data = entry.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}

/// Poll the local HTTP server until it responds or the timeout expires.
/// Blocks the current thread — intended to be called from init() so the
/// server is listening before the SwiftUI window loads any webview.
func waitForSonataHTTP(port: Int, timeoutSeconds: Double = 5.0) -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    let url = URL(string: "http://127.0.0.1:\(port)/api/system/status")!
    while Date() < deadline {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: url) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode < 500 {
                ok = true
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 0.5)
        if ok { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return false
}

@main
struct SonataApp: App {
    let dbPool: DatabasePool

    init() {
        // Singleton guard: if another Sonata is already running, activate it and exit
        let runningApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.sona.Sonata"
        )
        if runningApps.count > 1 {
            // Another instance is already running — bring it to front and terminate this one
            if let existing = runningApps.first(where: { $0 != NSRunningApplication.current }) {
                existing.activate()
            }
            sonataFileLog("Sonata init: another instance already running, exiting")
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
            // Still need to initialize dbPool to satisfy the compiler
            self.dbPool = try! DatabaseManager.openDatabase()
            return
        }

        // Make the app appear in dock and app switcher
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        sonataFileLog("Sonata init: starting (port \(sonataPort))")

        do {
            self.dbPool = try DatabaseManager.openDatabase()
        } catch {
            sonataFileLog("Sonata FATAL: database init failed — \(error)")
            fatalError("Sonata: Failed to initialize database — \(error)")
        }

        // Register for app termination to cleanly release the HTTP port
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { _ in
            sonataFileLog("App terminating — releasing port")
            _exit(0)
        }

        // Ensure memory + sonata-bridge MCP servers are in global ~/.claude.json
        ensureGlobalMCPServers()

        // Ensure worker + supervisor role directories exist with CLAUDE.md
        ensureRoleDirectories()

        let pool = self.dbPool
        let port = sonataPort

        // Start the HTTP server + all Phase 3 services in a detached task
        // so it doesn't block the main (SwiftUI) run loop.
        Task.detached {
            do {
                var logger = Logger(label: "sonata.http")
                logger.logLevel = .info
                logger.info("Starting Sonata HTTP server on 127.0.0.1:\(port)")
                sonataFileLog("HTTP task: entered detached task, about to build router")

                // Create scheduler early so routes can reference it
                // MeiliSearch full-text search subsystem
                let meili = MeiliSearchManager()
                await meili.start()
                await meili.ensureIndexes()

                let scheduler = SchedulerActor(dbPool: pool)

                let router = Router(context: BasicWebSocketRequestContext.self)

                // Unified action registry — every HTTP endpoint and MCP tool
                // comes from a single definition. See Sources/Actions/*.swift.
                let registry = ActionRegistry()
                registry.scheduler = scheduler
                registry.search = meili
                registry.register(memoryActions)
                registry.register(recallActions)
                registry.register(entityActions)
                registry.register(relationActions)
                registry.register(taskActions)
                registry.register(workerActions)
                registry.register(workerEventActions)
                registry.register(inspectorAction)
                registry.register(calendarActions)
                registry.register(emailActions)
                registry.register(emailInboxActions)
                registry.register(schedulerActions)
                registry.register(supervisorActions)
                registry.register(supervisorConfigActions)
                registry.register(wikiActions)
                registry.register(coreBlockActions)
                registry.register(checkpointActions)
                registry.register(secretActions)
                registry.register(documentActions)
                registry.register(embeddingActions)
                registry.register(contactActions)
                registry.register(backgroundActions)
                registry.register(fileActions)
                registry.register(systemActions)
                registry.register(pithActions)
                registry.register(statsActions)
                registry.register(compositeActions)

                // Create PluginManager (before mountHTTP so plugin management routes are included)
                let pluginManager = PluginManager(dbPool: pool, registry: registry)

                // Register plugin management actions BEFORE mountHTTP
                registry.register(makePluginActions(pluginManager: pluginManager))

                registry.mountHTTP(on: router, dbPool: pool)
                registry.mountMetaRoutes(on: router, dbPool: pool)

                // MCP WebSocket router (separate from HTTP router per HB docs)
                let wsRouter = Router(context: BasicWebSocketRequestContext.self)
                wsRouter.ws("/mcp", onUpgrade: { inbound, outbound, _ in
                    let handler = SonataMCPHandler(registry: registry, dbPool: pool)
                    for try await message in inbound.messages(maxSize: 1 << 20) {
                        if case .text(let text) = message {
                            if let response = await handler.handleMessage(text) {
                                try await outbound.write(.text(response))
                            }
                        }
                    }
                })
                logger.info("MCP WebSocket endpoint registered at ws://127.0.0.1:\(port)/mcp")

                // Serve web dashboard files (HTML/CSS/JS)
                let webPaths = [
                    "\(NSHomeDirectory())/memory/Sonata/Sources/Sonata/Resources/web",
                    Bundle.main.resourcePath.map { "\($0)/web" },
                    Bundle.main.resourcePath.map { "\($0)/Resources/web" },
                ].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }

                if let webDir = webPaths {
                    router.get("/web/{path}") { request, context -> Response in
                        let path = context.parameters.get("path") ?? ""
                        let filePath = "\(webDir)/\(path)"
                        guard FileManager.default.fileExists(atPath: filePath),
                              let data = FileManager.default.contents(atPath: filePath) else {
                            return Response(status: .notFound)
                        }
                        let ext = (path as NSString).pathExtension
                        let contentType: String
                        switch ext {
                        case "html": contentType = "text/html; charset=utf-8"
                        case "css": contentType = "text/css; charset=utf-8"
                        case "js": contentType = "application/javascript; charset=utf-8"
                        default: contentType = "application/octet-stream"
                        }
                        var headers = HTTPFields()
                        headers[.contentType] = contentType
                        return Response(status: .ok, headers: headers, body: .init(byteBuffer: .init(data: data)))
                    }
                    logger.info("Web dashboard: serving from \(webDir)")
                } else {
                    logger.warning("Web dashboard: no web resource directory found")
                }

                // Wait for port to be free (previous instance may still be releasing)
                for attempt in 1...10 {
                    let sock = socket(AF_INET, SOCK_STREAM, 0)
                    guard sock >= 0 else { break }
                    var addr = sockaddr_in()
                    addr.sin_family = sa_family_t(AF_INET)
                    addr.sin_port = UInt16(port).bigEndian
                    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                    var optval: Int32 = 1
                    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))
                    let bindResult = withUnsafePointer(to: &addr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    close(sock)
                    if bindResult == 0 {
                        if attempt > 1 { sonataFileLog("HTTP port \(port) free after \(attempt) attempts") }
                        break
                    }
                    sonataFileLog("HTTP port \(port) busy, waiting... (attempt \(attempt)/10)")
                    try? await Task.sleep(for: .seconds(1))
                }

                let app = Application(
                    router: router,
                    server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
                    configuration: .init(address: .hostname("127.0.0.1", port: port)),
                    logger: logger
                )

                // Start the HTTP server in a subtask
                async let serverTask: Void = app.runService()

                // Give the HTTP server a moment to bind before starting services
                try? await Task.sleep(for: .milliseconds(500))
                sonataFileLog("HTTP server: binding complete, starting services")

                // Start all enabled plugins — blocks until all are running or failed.
                // Must complete before workers spawn so plugin MCP tools are available.
                await pluginManager.startEnabledPlugins()
                sonataFileLog("Plugin system: initialization complete")

                // --- Phase 3: Initialize all scheduler services ---

                // 1. Scheduler Actor (created earlier, before routes)
                // Register internal functions before start so any due calendar
                // events of taskType=internal can fire immediately.
                await scheduler.registerInternal("wiki-compilation") { [pool] in
                    try await WikiCompilationJob.run(dbPool: pool)
                }
                await scheduler.start()
                _ = await scheduler.status()

                // Count calendar events and cron jobs from DB for the startup log
                let calendarCount: Int = (try? await pool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calendarEvents WHERE enabled = 1") ?? 0
                }) ?? 0
                let cronCount: Int = (try? await pool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduledJobs WHERE enabled = 1") ?? 0
                }) ?? 0

                // 2. Email Handler
                let emailHandler = EmailHandler(dbPool: pool)
                await emailHandler.start()

                // 3. Friend Relay
                let friendRelay = FriendRelay(dbPool: pool)
                await friendRelay.start()

                // 4. Background Job Runner
                let jobRunner = BackgroundJobRunner(dbPool: pool)
                await jobRunner.start()

                // 5. Task Orchestrator (dispatches pending tasks to Claude sessions)
                let orchestrator = TaskOrchestrator(dbPool: pool)
                await orchestrator.start()

                // 5. Health Monitor (with scheduler status closure)
                let healthMonitor = HealthMonitor(
                    dbPool: pool,
                    port: port,
                    schedulerStatus: { await scheduler.status().count >= 0 }  // returns true if scheduler is reachable
                )
                await healthMonitor.start()

                // 7. Backup Manager (nightly SQLite backup + S3)
                let backupManager = BackupManager(dbPool: pool)
                await backupManager.start()

                // 8. Wiki File Watcher (FSEvents on ~/.sonata/wiki/ and ~/.sonata/private/)
                let wikiWatcher = WikiFileWatcher(dbPool: pool, search: meili)
                await wikiWatcher.start()

                // 8a. MeiliSearch initial backfill (first run or after data clear)
                Task {
                    await meili.backfillWiki(dbPool: pool)
                    await meili.backfillArchive(dbPool: pool)
                    await meili.backfillDocs()
                    await meili.backfillPrivate()
                }

                logger.info("Sonata scheduler started: \(calendarCount) calendar events, \(cronCount) cron jobs, email polling every 2m, nightly backups enabled, wiki file watcher active")

                // 6. Spawn default workers (runs on MainActor since it creates terminal views)
                let workerCount = WorkerManager.defaultWorkerCount
                await MainActor.run {
                    WorkerManager.shared.spawnDefaultWorkers()
                }
                logger.info("Spawned \(workerCount) default workers")

                // 6b. Spawn the supervisor window (hidden by default — accessible from Window menu).
                // Creating the NSWindow spins up the SupervisorTerminalView, which starts Claude
                // with the supervisor prompt and role. Window close hides instead of destroying.
                await MainActor.run {
                    SupervisorWindowController.shared.ensureStarted()
                }
                logger.info("Supervisor window created (hidden)")

                // Register shutdown handler
                let shutdownHandler = {
                    logger.info("Sonata shutting down — stopping all services")
                    await scheduler.shutdown()
                    await emailHandler.shutdown()
                    await friendRelay.shutdown()
                    await jobRunner.shutdown()
                    await healthMonitor.shutdown()
                    await backupManager.shutdown()
                    await wikiWatcher.shutdown()
                    await pluginManager.shutdown()
                    await meili.shutdown()
                    logger.info("Sonata shutdown complete")
                }

                // Listen for termination signals to shut down gracefully
                let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM)
                signal(SIGTERM, SIG_IGN)
                sigTermSource.setEventHandler {
                    Task { await shutdownHandler() }
                }
                sigTermSource.resume()

                let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT)
                signal(SIGINT, SIG_IGN)
                sigIntSource.setEventHandler {
                    Task { await shutdownHandler() }
                }
                sigIntSource.resume()

                // Await the server — this blocks until the server stops
                try await serverTask
            } catch {
                // Log to both Logger and file so we can see what went wrong
                let logger = Logger(label: "sonata.http")
                logger.error("HTTP server failed: \(error)")
                sonataFileLog("HTTP FATAL: server failed — \(error)")
            }
        }
    }

    @FocusedValue(\.selectedTab) var selectedTab

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            // Tab navigation: Cmd+1 through Cmd+9, Cmd+0
            CommandGroup(after: .toolbar) {
                Section {
                    Button("Workers") { selectedTab?.wrappedValue = .workers }
                        .keyboardShortcut("1", modifiers: .command)
                    Button("Memory") { selectedTab?.wrappedValue = .memory }
                        .keyboardShortcut("2", modifiers: .command)
                    Button("Tasks") { selectedTab?.wrappedValue = .tasks }
                        .keyboardShortcut("3", modifiers: .command)
                    Button("Schedule") { selectedTab?.wrappedValue = .schedule }
                        .keyboardShortcut("4", modifiers: .command)
                    Button("Email") { selectedTab?.wrappedValue = .email }
                        .keyboardShortcut("5", modifiers: .command)
                    Button("People") { selectedTab?.wrappedValue = .people }
                        .keyboardShortcut("6", modifiers: .command)
                    Button("Wiki") { selectedTab?.wrappedValue = .wiki }
                        .keyboardShortcut("7", modifiers: .command)
                    Button("Files") { selectedTab?.wrappedValue = .files }
                        .keyboardShortcut("8", modifiers: .command)
                    Button("Health") { selectedTab?.wrappedValue = .health }
                        .keyboardShortcut("9", modifiers: .command)
                    Button("Settings") { selectedTab?.wrappedValue = .settings }
                        .keyboardShortcut("0", modifiers: .command)
                    Button("Plugins") { selectedTab?.wrappedValue = .plugins }
                        .keyboardShortcut("p", modifiers: [.command, .shift])
                }
            }

            CommandGroup(after: .importExport) {
                Button("Export Sonata Data...") {
                    exportSonataData()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Import Sonata Data...") {
                    importSonataData()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }

            CommandGroup(after: .windowArrangement) {
                Button("Supervisor") {
                    SupervisorWindowController.shared.show()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            }
        }
    }

    // MARK: - Export

    private func exportSonataData() {
        let panel = NSSavePanel()
        panel.title = "Export Sonata Data"
        panel.nameFieldStringValue = "sonata-backup-\(dateStamp()).sonata-backup"
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task.detached {
            let sonataDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".sonata")
            let tempZip = FileManager.default.temporaryDirectory
                .appendingPathComponent("sonata-export-\(UUID().uuidString).zip")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-r", tempZip.path, "."]
            process.currentDirectoryURL = sonataDir

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    try FileManager.default.moveItem(at: tempZip, to: url)
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "Export Complete"
                        alert.informativeText = "Sonata data exported to:\n\(url.lastPathComponent)"
                        alert.alertStyle = .informational
                        alert.runModal()
                    }
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Import

    private func importSonataData() {
        let panel = NSOpenPanel()
        panel.title = "Import Sonata Data"
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a .sonata-backup file to restore"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Confirm before overwriting
        let confirm = NSAlert()
        confirm.messageText = "Restore Sonata Data?"
        confirm.informativeText = "This will replace all data in ~/.sonata/ with the contents of the backup. This cannot be undone."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Restore")
        confirm.addButton(withTitle: "Cancel")

        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        Task.detached {
            let sonataDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".sonata")

            do {
                // Clear existing data
                if FileManager.default.fileExists(atPath: sonataDir.path) {
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: sonataDir, includingPropertiesForKeys: nil)
                    for item in contents {
                        try FileManager.default.removeItem(at: item)
                    }
                }

                // Unzip backup
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-o", url.path, "-d", sonataDir.path]

                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "Import Complete"
                        alert.informativeText = "Sonata data restored. Restart the app to load the new data."
                        alert.alertStyle = .informational
                        alert.runModal()
                    }
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Import Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            }
        }
    }

    private func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

// MARK: - Supervisor Window

/// Manages the persistent supervisor NSWindow. Created hidden at startup so the
/// underlying Claude process keeps running even when the user has never opened
/// the window. Close events hide the window instead of destroying it.
@MainActor
final class SupervisorWindowController: NSObject, NSWindowDelegate {
    static let shared = SupervisorWindowController()

    private var window: NSWindow?

    /// Create the window (and start the underlying process) if it doesn't exist yet.
    /// The window is created hidden — the user must explicitly open it.
    private var coordinator: SupervisorCoordinator?

    func ensureStarted() {
        guard window == nil else { return }

        // Create terminal view directly (same pattern as Worker)
        let termView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let coord = SupervisorCoordinator(terminalView: termView)
        self.coordinator = coord
        termView.processDelegate = coord

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Supervisor"
        win.contentView = termView
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        self.window = win

        // Start the process after a brief delay for the view to lay out
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            coord.startProcess()
        }
    }

    func show() {
        ensureStarted()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        DispatchQueue.main.async {
            sender.orderOut(nil)
        }
        return false
    }
}
