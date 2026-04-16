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

/// Ensure memory + sonata-bridge MCP servers are registered in ~/.claude.json.
/// Called on startup so every Claude Code session has access to Sona's memory.
func ensureGlobalMCPServers() {
    let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude.json")

    let requiredServers: [String: [String: Any]] = [
        "memory": [
            "type": "stdio",
            "command": "bun",
            "args": ["run", "/Users/evan/memory/mcp/mem-server.ts"],
        ],
        "sonata-bridge": [
            "type": "stdio",
            "command": "bun",
            "args": ["/Users/evan/memory/Sonata/sonata-bridge.ts"],
        ],
    ]

    do {
        let data = try Data(contentsOf: configPath)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var mcpServers = json["mcpServers"] as? [String: Any] ?? [:]

        var changed = false
        for (name, config) in requiredServers {
            if mcpServers[name] == nil {
                mcpServers[name] = config
                changed = true
                sonataFileLog("MCP setup: added '\(name)' to ~/.claude.json")
            }
        }

        if changed {
            json["mcpServers"] = mcpServers
            let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: configPath)
            sonataFileLog("MCP setup: updated ~/.claude.json with \(requiredServers.count) servers")
        }
    } catch {
        sonataFileLog("MCP setup: failed to update ~/.claude.json — \(error)")
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
                let scheduler = SchedulerActor(dbPool: pool)

                let router = Router(context: BasicWebSocketRequestContext.self)
                registerMemoryRoutes(on: router, dbPool: pool)
                registerEntityRoutes(on: router, dbPool: pool)
                registerRelationRoutes(on: router, dbPool: pool)
                registerDocumentRoutes(on: router, dbPool: pool)
                registerContactRoutes(on: router, dbPool: pool)
                registerCoreBlockRoutes(on: router, dbPool: pool)
                registerRecallRoutes(on: router, dbPool: pool)
                registerEmbeddingRoutes(on: router, dbPool: pool)
                registerStatsRoutes(on: router, dbPool: pool)
                registerEmailRoutes(on: router, dbPool: pool)
                registerCalendarRoutes(on: router, dbPool: pool, scheduler: scheduler)
                registerTaskRoutes(on: router, dbPool: pool)
                registerWorkerRoutes(on: router, dbPool: pool)
                registerSupervisorRoutes(on: router, dbPool: pool)
                registerScheduledJobRoutes(on: router, dbPool: pool, scheduler: scheduler)
                registerWikiRoutes(on: router, dbPool: pool)
                registerSecretRoutes(on: router)
                registerBackgroundRoutes(on: router, dbPool: pool)
                registerSystemRoutes(on: router, dbPool: pool)
                registerPithRoutes(on: router, dbPool: pool)
                registerCheckpointRoutes(on: router, dbPool: pool)
                registerFileRoutes(on: router)

                // MCP WebSocket router (separate from HTTP router per HB docs)
                let wsRouter = Router(context: BasicWebSocketRequestContext.self)
                wsRouter.ws("/mcp", onUpgrade: { inbound, outbound, _ in
                    let handler = SonataMCPHandler()
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
                    "/Users/evan/memory/Sonata/Sources/Sonata/Resources/web",
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

                // --- Phase 3: Initialize all scheduler services ---

                // 1. Scheduler Actor (created earlier, before routes)
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

                logger.info("Sonata scheduler started: \(calendarCount) calendar events, \(cronCount) cron jobs, email polling every 2m, nightly backups enabled")

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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
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
