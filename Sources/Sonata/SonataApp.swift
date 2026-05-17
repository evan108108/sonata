import Foundation
import SwiftUI
import Hummingbird
import HummingbirdWebSocket
import GRDB
import Logging
import SwiftTerm

// MARK: - Studio dbPool environment key (impl-spec §10 Diff E)

private struct DBPoolKey: EnvironmentKey {
    static let defaultValue: DatabasePool? = nil
}

extension EnvironmentValues {
    var dbPool: DatabasePool? {
        get { self[DBPoolKey.self] }
        set { self[DBPoolKey.self] = newValue }
    }
}

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
                   let newArgs = config["args"] as? [String],
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

/// Deploy Sona's bundled Claude Code skills to ~/.claude/skills/. Currently
/// just the `/afk` skill because that's the one tied directly to Sonata
/// runtime (channel-push from EmailHandler). Always overwrites so the skill
/// stays in sync with the Sonata version that owns the wire format.
///
/// Add new skills here by:
///   1. Drop SKILL.md (plus any sibling files) into
///      Sources/Sonata/Resources/skills/<name>/
///   2. Append the slug to the `skills` array below.
func ensureBundledSkills() {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let skillsRoot = home.appendingPathComponent(".claude/skills")
    try? fm.createDirectory(at: skillsRoot, withIntermediateDirectories: true)

    let skills = ["afk"]
    for slug in skills {
        let destDir = skillsRoot.appendingPathComponent(slug)
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destFile = destDir.appendingPathComponent("SKILL.md")
        guard let sourceURL = Bundle.module.url(
            forResource: "SKILL", withExtension: "md", subdirectory: "skills/\(slug)"
        ) else {
            sonataFileLog("Skill setup: SKILL.md not found in bundle for skills/\(slug)")
            continue
        }
        try? fm.removeItem(at: destFile)
        do {
            try fm.copyItem(at: sourceURL, to: destFile)
            sonataFileLog("Skill setup: deployed skills/\(slug)/SKILL.md to ~/.claude/skills/")
        } catch {
            sonataFileLog("Skill setup: failed to copy skills/\(slug)/SKILL.md — \(error)")
        }
    }
}

/// Redirect stdout + stderr to ~/Library/Logs/Sonata.log so any `print(...)`,
/// FileHandle.standardError write, or runtime crash trace lands in the same
/// file the in-app Logs viewer tails. Without this, Finder-launched Sonata
/// silently drops every print() — making the LogsView miss most runtime errors
/// from the worker pool, inspector, and ad-hoc debug print sites.
///
/// Gated on `isatty(stderr)`: when stderr is already a terminal (`swift run`,
/// Xcode console, ssh shell) we leave it alone so console output keeps working.
/// When stderr is *not* a TTY (Finder launch, double-clicked .app) we redirect
/// to the log file so the LogsView is the source of truth.
private var stderrRedirectInstalled = false
func installSonataStdoutRedirect() {
    guard !stderrRedirectInstalled else { return }
    stderrRedirectInstalled = true

    // If stderr is already a TTY, the developer is running from a terminal and
    // wants console output. Skip the redirect.
    if isatty(fileno(stderr)) != 0 { return }

    let logsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let logURL = logsDir.appendingPathComponent("Sonata.log")

    // Boot-time rotation: if Sonata.log is over the cap, move it aside to
    // Sonata.log.1 (overwriting any older rotation) and start fresh. Sonata
    // restarts often enough that a once-per-boot check is sufficient — we
    // don't bother with a mid-session timer.
    let rotateCapBytes: UInt64 = 200 * 1024 * 1024
    let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))
        .flatMap { ($0[.size] as? NSNumber)?.uint64Value } ?? 0
    if size > rotateCapBytes {
        let prev = logsDir.appendingPathComponent("Sonata.log.1")
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.moveItem(at: logURL, to: prev)
    }

    let fd = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    // Line-buffer so prints land in the file promptly instead of waiting for a
    // 4 KB flush — the LogsView polls every 500 ms and we want it lively.
    setvbuf(stdout, nil, _IOLBF, 0)
    setvbuf(stderr, nil, _IOLBF, 0)
    dup2(fd, fileno(stdout))
    dup2(fd, fileno(stderr))
    close(fd)
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
        // Tee stdout/stderr into ~/Library/Logs/Sonata.log so every print() and
        // runtime stderr write is captured by the in-app LogsView. Must run
        // before any other code that might print, so it lives at the very top
        // of init().
        installSonataStdoutRedirect()

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

        // Deploy bundled Claude Code skills (currently just /afk) to ~/.claude/skills/
        ensureBundledSkills()

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
                registry.register(bridgeActions)
                registry.register(inspectorAction)
                registry.register(afkActions)
                registry.register(dmActions)
                // sonar-dm v0: production heartbeat checker + 60s prune timer.
                DMRegistry.shared.setHeartbeatChecker(makeProductionHeartbeatChecker(dbPool: pool))
                DMRegistry.shared.startPruneTimer()
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

                // 4. Task Orchestrator (dispatches pending tasks to bridge workers)
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

                // 6. Respawn recovery workers (sonata-restart-recovery-v0 §4) then top up
                // the default pool. Both run on MainActor since they create terminal views.
                let workerCount = WorkerManager.defaultWorkerCount
                // sonata-restart-recovery v0 (claude/documents/plans/sonata-restart-recovery-v0-plan.md):
                // when toggled on, respawn workers that died holding active work, reusing
                // their prior workerId/sessionId so claude --resume loads the prior JSONL.
                // Toggle stored in UserDefaults at "restartRecoveryEnabled" (UI exposes it);
                // SONATA_RESTART_RECOVERY env override available for testing.
                let enableRecovery = WorkerManager.restartRecoveryEnabled
                let recovered = enableRecovery
                    ? await WorkerManager.shared.respawnRecoveryWorkers(dbPool: pool)
                    : 0
                await MainActor.run {
                    WorkerManager.shared.spawnDefaultWorkers(reservingFor: recovered)
                    WorkerManager.shared.startHealthPolling()
                }
                logger.info("Spawned \(workerCount) default workers (\(recovered) recovered, recovery=\(enableRecovery ? "on" : "off"))")

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
    @FocusedValue(\.focusSearchBar) var focusSearchBar

    // MARK: - Studio: DBPool environment plumbing (per impl-spec §10 Diff E)
    //
    // Studio's tab-scoped StudioStore needs the DatabasePool via SwiftUI's
    // environment (plan §11 D2 — no singleton). The environment key + value
    // accessor live alongside the app entrypoint so the value is injected
    // once at the WindowGroup boundary below.

    var body: some Scene {
        WindowGroup("") {
            StartupGate(dbPool: dbPool, port: sonataPort) {
                ContentView()
                    .frame(minWidth: 1100, minHeight: 720)
                    .environment(\.dbPool, dbPool)
                    .warmWindowTitlebar()
                    // s4a:// URL scheme handler. The Info.plist registers the
                    // scheme with macOS LaunchServices; .onOpenURL is what
                    // SwiftUI hands the resulting URL through. Boot-time pending
                    // URLs (Sonata wasn't running when the user clicked the
                    // link) replay through here automatically after launch
                    // finishes — no manual queueing needed.
                    .onOpenURL { url in
                        if StudioDeepLinkRouter.isInviteURL(url) {
                            StudioDeepLinkRouter.shared.handle(url: url)
                        }
                    }
            }
            // Lock Sonata to dark appearance regardless of the user's macOS
            // setting (Spotify / Discord / Linear pattern). The loader, theme
            // tokens, and warm chrome are designed for dark; light mode would
            // wash them out.
            .preferredColorScheme(.dark)
        }
        // Default window size on first launch (and a fallback when SwiftUI's
        // window state restoration fails — currently a regression caused by
        // our AppKit titlebar interop, TODO investigate). Picked to be roomy
        // on a 13" MBP without overflowing.
        .defaultSize(width: 1300, height: 800)
        .commands {
            // Tab navigation: Cmd+1 through Cmd+9, Cmd+0
            CommandGroup(after: .toolbar) {
                Section {
                    Button("Search Sona…") { focusSearchBar?() }
                        .keyboardShortcut("k", modifiers: .command)
                }
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
                    Button("Dashboard") { selectedTab?.wrappedValue = .dashboard }
                        .keyboardShortcut("9", modifiers: .command)
                    Button("Settings") { selectedTab?.wrappedValue = .settings }
                        .keyboardShortcut("0", modifiers: .command)
                    Button("Plugins") { selectedTab?.wrappedValue = .plugins }
                        .keyboardShortcut("p", modifiers: [.command, .shift])
                    Button("Studio") { selectedTab?.wrappedValue = .studio }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
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

                Button("Interactive Sessions") {
                    InteractiveSessionsWindowController.shared.show()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Button("Logs") {
                    LogsWindowController.shared.show()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
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
        let termView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        termView.applyWarmChrome()
        let coord = SupervisorCoordinator(terminalView: termView)
        self.coordinator = coord
        termView.processDelegate = coord

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
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
