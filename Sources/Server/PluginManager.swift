import Foundation
import GRDB

// MARK: - Plugin Manifest (parsed from <name>.plugin.json)

struct PluginManifest: Codable {
    let name: String
    let version: String
    let description: String?
    let author: String?
    let sonataVersion: String?
    let port: Int
    let arch: String?
    let startCommand: String
    let eventsChannel: String?     // WebSocket path, e.g. "/socket/websocket"
    let eventsTopic: String?       // Channel topic, e.g. "messages:events"
    let configSchema: [String: ConfigSchemaEntry]?
    let actions: [ManifestAction]?

    enum CodingKeys: String, CodingKey {
        case name, version, description, author, port, arch, actions
        case sonataVersion = "sonata_version"
        case startCommand = "start_command"
        case eventsChannel = "events_channel"
        case eventsTopic = "events_topic"
        case configSchema = "config_schema"
    }
}

struct ConfigSchemaEntry: Codable {
    let type: String
}

struct ManifestAction: Codable {
    let name: String
    let description: String
    let method: String
    let path: String?
    let params: [ManifestParam]?
}

struct ManifestParam: Codable {
    let name: String
    let type: String
    let required: Bool?
    let description: String?
}

// MARK: - Discovered Action (from GET /api/actions at runtime)

struct DiscoveredAction: Codable {
    let name: String
    let description: String
    let method: String
    let path: String
    let params: [DiscoveredParam]?
}

struct DiscoveredParam: Codable {
    let name: String
    let type: String
    let required: Bool?
    let description: String?
}

// MARK: - Plugin Runtime State

final class PluginRuntime: @unchecked Sendable {
    let name: String
    let manifest: PluginManifest
    let mode: String           // "managed" or "external"
    let baseURL: String        // e.g., "http://127.0.0.1:4000"
    var process: Process?      // nil for external mode
    var status: String         // installed/enabled/starting/running/failed/disabled
    var discoveredActions: [DiscoveredAction] = []
    var crashCount: Int = 0

    init(name: String, manifest: PluginManifest, mode: String, baseURL: String, status: String) {
        self.name = name
        self.manifest = manifest
        self.mode = mode
        self.baseURL = baseURL
        self.status = status
    }
}

// MARK: - PluginManager

final class PluginManager: @unchecked Sendable {
    let dbPool: DatabasePool
    let registry: ActionRegistry
    private var plugins: [String: PluginRuntime] = [:]
    private let lock = NSLock()

    /// Backoff intervals for crash recovery (seconds)
    private let backoffIntervals: [Double] = [2, 5, 15]

    /// Health check timeout per plugin (seconds)
    let healthTimeout: Double = 15.0

    /// Health check poll interval (seconds)
    let healthPollInterval: Double = 0.25

    init(dbPool: DatabasePool, registry: ActionRegistry) {
        self.dbPool = dbPool
        self.registry = registry
    }

    // MARK: - Startup (called during boot, before workers)

    /// Load and start all enabled plugins. Returns when all plugins are either
    /// running or failed. Does not throw — failed plugins are logged and skipped.
    func startEnabledPlugins() async {
        let rows: [(name: String, port: Int, mode: String, url: String?, path: String, configJson: String)] =
            (try? await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT name, port, mode, url, path, config_json
                    FROM plugins WHERE status IN ('enabled', 'running')
                """).map { row in
                    (
                        name: row["name"] as String,
                        port: row["port"] as Int,
                        mode: row["mode"] as String,
                        url: row["url"] as String?,
                        path: row["path"] as String,
                        configJson: row["config_json"] as String
                    )
                }
            }) ?? []

        for row in rows {
            let manifest = loadManifest(pluginDir: row.path)
            guard let manifest else {
                sonataFileLog("Plugin \(row.name): manifest not found at \(row.path), skipping")
                await updateStatus(name: row.name, status: "failed")
                continue
            }

            let baseURL = row.mode == "external"
                ? (row.url ?? "http://127.0.0.1:\(row.port)")
                : "http://127.0.0.1:\(row.port)"

            let runtime = PluginRuntime(
                name: row.name,
                manifest: manifest,
                mode: row.mode,
                baseURL: baseURL,
                status: "starting"
            )

            lock.lock()
            plugins[row.name] = runtime
            lock.unlock()

            await updateStatus(name: row.name, status: "starting")

            if row.mode == "managed" {
                await spawnPlugin(runtime, configJson: row.configJson)
            }

            let healthy = await waitForHealthy(runtime)
            if healthy {
                await discoverAndRegisterActions(runtime)
                subscribeToEventsChannel(runtime)
                runtime.status = "running"
                await updateStatus(name: row.name, status: "running", pid: runtime.process.map { Int($0.processIdentifier) })
                sonataFileLog("Plugin \(row.name): running on \(baseURL), \(runtime.discoveredActions.count) actions registered")
            } else {
                runtime.status = "failed"
                await updateStatus(name: row.name, status: "failed")
                sonataFileLog("Plugin \(row.name): failed to start (health check timeout)")
            }
        }
    }

    // MARK: - Manifest Parsing

    func loadManifest(pluginDir: String) -> PluginManifest? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: pluginDir) else { return nil }
        let manifestFile = contents.first { $0.hasSuffix(".plugin.json") }
        guard let manifestFile else { return nil }

        let manifestPath = (pluginDir as NSString).appendingPathComponent(manifestFile)
        guard let data = fm.contents(atPath: manifestPath) else { return nil }

        return try? JSONDecoder().decode(PluginManifest.self, from: data)
    }

    // MARK: - Process Spawning (managed mode)

    func spawnPlugin(_ runtime: PluginRuntime, configJson: String) async {
        let manifest = runtime.manifest

        let parts = manifest.startCommand.split(separator: " ").map(String.init)
        guard let executable = parts.first else {
            sonataFileLog("Plugin \(runtime.name): empty start_command")
            return
        }

        let path: String? = try? await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT path FROM plugins WHERE name = ?", arguments: [runtime.name])
        }
        guard let pluginPath = path else { return }

        let execPath = (pluginPath as NSString).appendingPathComponent(executable)
        let args = Array(parts.dropFirst())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: pluginPath)

        var env = ProcessInfo.processInfo.environment
        env["PORT"] = String(manifest.port)
        env["SONATA_PLUGIN_DATA_DIR"] = pluginPath
        env["SONATA_HOST"] = "http://127.0.0.1:\(sonataPort)"

        let prefix = runtime.name.uppercased()
        if let configData = configJson.data(using: .utf8),
           let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] {
            for (key, value) in config {
                let envKey = "\(prefix)_\(key.uppercased())"
                env[envKey] = "\(value)"
            }
        }

        process.environment = env

        // Kill any stale daemon from a previous run before starting
        stopPluginDaemon(pluginPath: pluginPath, executable: executable)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            runtime.process = process
            sonataFileLog("Plugin \(runtime.name): spawned PID \(process.processIdentifier)")

            let name = runtime.name
            let mgr = self
            process.terminationHandler = { proc in
                Task {
                    await mgr.handleCrash(pluginName: name, exitCode: proc.terminationStatus)
                }
            }
        } catch {
            sonataFileLog("Plugin \(runtime.name): failed to spawn — \(error)")
        }
    }

    // MARK: - Health Checking

    /// Poll GET /api/actions until 200 or timeout. Returns true if healthy.
    func waitForHealthy(_ runtime: PluginRuntime) async -> Bool {
        let deadline = Date().addingTimeInterval(healthTimeout)
        let url = URL(string: "\(runtime.baseURL)/api/actions")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)

        while Date() < deadline {
            do {
                let (_, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return true
                }
            } catch {
                // Expected during startup — plugin not ready yet
            }
            try? await Task.sleep(for: .milliseconds(Int(healthPollInterval * 1000)))
        }
        return false
    }

    // MARK: - Action Discovery

    /// Call GET /api/actions on the plugin, parse the response, and register
    /// each action as a prefixed SonataAction in the ActionRegistry.
    func discoverAndRegisterActions(_ runtime: PluginRuntime) async {
        let url = URL(string: "\(runtime.baseURL)/api/actions")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                sonataFileLog("Plugin \(runtime.name): discovery failed — non-200 response")
                return
            }

            let actions = try JSONDecoder().decode([DiscoveredAction].self, from: data)
            runtime.discoveredActions = actions

            let proxyActions = makeProxyActionsForPlugin(
                pluginName: runtime.name, baseURL: runtime.baseURL, actions: actions
            )

            registry.register(proxyActions)
        } catch {
            sonataFileLog("Plugin \(runtime.name): discovery failed — \(error)")
        }
    }

    /// Create a SonataAction that proxies calls to the plugin's HTTP endpoint.
    func makeProxyAction(pluginName: String, baseURL: String, action: DiscoveredAction) -> SonataAction {
        let toolName = "\(pluginName)_\(action.name)"
        let group = "/api/plugins/\(pluginName)"
        let routePath: String
        if action.path.hasPrefix("/api/") {
            routePath = "/" + action.path.dropFirst(5)
        } else if action.path.hasPrefix("/api") {
            routePath = "/" + action.path.dropFirst(4)
        } else {
            routePath = action.path
        }

        let method: ActionMethod
        switch action.method.lowercased() {
        case "get":    method = .get
        case "post":   method = .post
        case "patch":  method = .patch
        case "delete": method = .delete
        default:       method = .post
        }

        let params: [ActionParam] = (action.params ?? []).map { p in
            let paramType: ParamType
            switch p.type.lowercased() {
            case "string":  paramType = .string
            case "integer": paramType = .integer
            case "number":  paramType = .number
            case "boolean": paramType = .boolean
            case "array":   paramType = .stringArray
            case "object":  paramType = .object
            default:        paramType = .string
            }
            return ActionParam(
                p.name,
                paramType,
                required: p.required ?? false,
                description: p.description ?? ""
            )
        }

        let targetURLTemplate = "\(baseURL)\(action.path)"

        return SonataAction(
            name: toolName,
            description: "[\(pluginName)] \(action.description)",
            group: group,
            path: routePath,
            method: method,
            params: params,
            handler: { ctx in
                // Substitute path parameters (e.g., :message_id → actual value)
                var targetURL = targetURLTemplate
                for (key, value) in ctx.params.all {
                    targetURL = targetURL.replacingOccurrences(of: ":\(key)", with: "\(value)")
                }

                var request = URLRequest(url: URL(string: targetURL)!)
                request.httpMethod = action.method.uppercased()
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                if method == .get {
                    var components = URLComponents(string: targetURL)!
                    var queryItems: [URLQueryItem] = []
                    for (key, value) in ctx.params.all {
                        queryItems.append(URLQueryItem(name: key, value: "\(value)"))
                    }
                    if !queryItems.isEmpty {
                        components.queryItems = queryItems
                        request.url = components.url
                    }
                } else {
                    let bodyDict = ctx.params.all
                    request.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict)
                }

                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 30
                let session = URLSession(configuration: config)

                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ActionError.custom("Plugin unreachable", .serviceUnavailable)
                }

                if http.statusCode >= 400 {
                    let body = String(data: data, encoding: .utf8) ?? "unknown error"
                    throw ActionError.custom("Plugin error (\(http.statusCode)): \(body)",
                                             http.statusCode >= 500 ? .internalServerError : .badRequest)
                }

                if let json = try? JSONSerialization.jsonObject(with: data) {
                    return AnyEncodable(JSONPassthrough(json))
                }
                return AnyEncodable(String(data: data, encoding: .utf8) ?? "")
            }
        )
    }

    /// For actions that need special handling (like sonar_send which awaits a reply),
    /// wrap the standard proxy handler with additional logic.
    func makeProxyActionsForPlugin(pluginName: String, baseURL: String, actions: [DiscoveredAction]) -> [SonataAction] {
        let mgr = self
        return actions.map { action in
            var proxyAction = makeProxyAction(pluginName: pluginName, baseURL: baseURL, action: action)

            if action.name == "send" {
                let originalHandler = proxyAction.handler
                proxyAction = SonataAction(
                    name: proxyAction.name,
                    description: proxyAction.description,
                    group: proxyAction.group,
                    path: proxyAction.path,
                    method: proxyAction.method,
                    params: proxyAction.params,
                    handler: { ctx in
                        let result = try await originalHandler(ctx)

                        if let resultAny = result as? AnyEncodable,
                           let encoded = try? JSONEncoder().encode(resultAny),
                           let json = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                           let messageId = json["message_id"] as? String {

                            let reply = await mgr.awaitReply(messageId: messageId, timeout: 60)

                            if let reply {
                                return SendWithReplyResponse(
                                    messageId: messageId, status: "replied", reply: reply
                                )
                            } else {
                                return SendWithReplyResponse(
                                    messageId: messageId, status: "pending", reply: nil
                                )
                            }
                        }

                        return result
                    }
                )
            }

            return proxyAction
        }
    }

    // MARK: - Crash Recovery

    func handleCrash(pluginName: String, exitCode: Int32) async {
        lock.lock()
        guard let runtime = plugins[pluginName] else { lock.unlock(); return }
        lock.unlock()

        // Skip recovery if plugin was intentionally stopped (disable/uninstall)
        guard runtime.mode == "managed" && runtime.status == "running" else { return }

        runtime.crashCount += 1
        sonataFileLog("Plugin \(pluginName): crashed (exit \(exitCode)), attempt \(runtime.crashCount)/3")

        let actionNames = runtime.discoveredActions.map { "\(pluginName)_\($0.name)" }
        registry.unregister(actionNames)

        if runtime.crashCount > backoffIntervals.count {
            runtime.status = "failed"
            await updateStatus(name: pluginName, status: "failed")
            sonataFileLog("Plugin \(pluginName): giving up after \(runtime.crashCount) crashes")
            return
        }

        let delay = backoffIntervals[runtime.crashCount - 1]
        sonataFileLog("Plugin \(pluginName): restarting in \(delay)s...")
        try? await Task.sleep(for: .seconds(delay))

        runtime.status = "starting"
        await updateStatus(name: pluginName, status: "starting")

        let configJson: String = (try? await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT config_json FROM plugins WHERE name = ?", arguments: [pluginName])
        }) ?? "{}"

        await spawnPlugin(runtime, configJson: configJson)

        let healthy = await waitForHealthy(runtime)
        if healthy {
            await discoverAndRegisterActions(runtime)
            runtime.status = "running"
            runtime.crashCount = 0
            await updateStatus(name: pluginName, status: "running", pid: runtime.process.map { Int($0.processIdentifier) })
            sonataFileLog("Plugin \(pluginName): recovered successfully")
        } else {
            await handleCrash(pluginName: pluginName, exitCode: -1)
        }
    }

    // MARK: - Plugin Management API

    /// Install a plugin from a tarball at the given file path.
    /// Extracts to ~/.sonata/plugins/<name>/, reads manifest, inserts DB row.
    func install(tarballPath: String) async throws -> PluginManifest {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tempDir = "\(home)/.sonata/plugins/_installing_\(UUID().uuidString)"

        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xzf", tarballPath, "-C", tempDir]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(atPath: tempDir)
            throw ActionError.custom("Failed to extract tarball", .badRequest)
        }

        // Look for manifest at root, then in subdirectories (tarballs often have a wrapper dir)
        var sourceDir = tempDir
        if let m = loadManifest(pluginDir: tempDir) {
            _ = m  // manifest at root, sourceDir is tempDir
        } else if let (subdir, _) = findManifestInSubdirs(tempDir) {
            sourceDir = subdir  // manifest in a subdirectory — use that as the source
        }

        let manifest = loadManifest(pluginDir: sourceDir)

        guard let manifest else {
            try? FileManager.default.removeItem(atPath: tempDir)
            throw ActionError.custom("No .plugin.json manifest found in tarball", .badRequest)
        }

        let nameRegex = #/^[a-z0-9][a-z0-9-]*$/#
        guard manifest.name.wholeMatch(of: nameRegex) != nil else {
            try? FileManager.default.removeItem(atPath: tempDir)
            throw ActionError.custom("Invalid plugin name '\(manifest.name)' — must be lowercase alphanumeric + hyphens", .badRequest)
        }

        let existingStatus: String? = try? await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM plugins WHERE name = ?", arguments: [manifest.name])
        }
        if let status = existingStatus, status == "running" || status == "starting" {
            try? FileManager.default.removeItem(atPath: tempDir)
            throw ActionError.custom("Plugin '\(manifest.name)' is currently \(status) — disable it first", .conflict)
        }

        let finalDir = "\(home)/.sonata/plugins/\(manifest.name)"
        if FileManager.default.fileExists(atPath: finalDir) {
            // Preserve plugin data (DB files, data dir) across reinstalls
            let dataBackup = "\(home)/.sonata/plugins/_data_backup_\(manifest.name)"
            try? FileManager.default.removeItem(atPath: dataBackup)
            try? FileManager.default.createDirectory(atPath: dataBackup, withIntermediateDirectories: true)
            // Save all .db files and WAL/SHM files
            if let files = try? FileManager.default.contentsOfDirectory(atPath: finalDir) {
                for file in files where file.hasSuffix(".db") || file.hasSuffix(".db-wal") || file.hasSuffix(".db-shm") {
                    try? FileManager.default.moveItem(
                        atPath: (finalDir as NSString).appendingPathComponent(file),
                        toPath: (dataBackup as NSString).appendingPathComponent(file)
                    )
                }
            }
            try FileManager.default.removeItem(atPath: finalDir)
        }
        try FileManager.default.moveItem(atPath: sourceDir, toPath: finalDir)
        // Restore preserved data files
        let dataBackup = "\(home)/.sonata/plugins/_data_backup_\(manifest.name)"
        if FileManager.default.fileExists(atPath: dataBackup) {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dataBackup) {
                for file in files {
                    try? FileManager.default.moveItem(
                        atPath: (dataBackup as NSString).appendingPathComponent(file),
                        toPath: (finalDir as NSString).appendingPathComponent(file)
                    )
                }
            }
            try? FileManager.default.removeItem(atPath: dataBackup)
        }
        // Clean up temp dir if sourceDir was a subdirectory
        if sourceDir != tempDir {
            try? FileManager.default.removeItem(atPath: tempDir)
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await dbPool.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO plugins (name, version, description, port, status, mode, path, config_json, installedAt, updatedAt)
                VALUES (?, ?, ?, ?, 'installed', 'managed', ?, '{}', ?, ?)
            """, arguments: [manifest.name, manifest.version, manifest.description, manifest.port, finalDir, now, now])
        }

        sonataFileLog("Plugin \(manifest.name) v\(manifest.version): installed to \(finalDir)")
        return manifest
    }

    /// Find manifest in first-level subdirectories (tarball may have a wrapper dir)
    /// Returns (subdirectory path, manifest) if found.
    private func findManifestInSubdirs(_ dir: String) -> (String, PluginManifest)? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        for entry in entries {
            let subdir = (dir as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: subdir, isDirectory: &isDir), isDir.boolValue {
                if let m = loadManifest(pluginDir: subdir) { return (subdir, m) }
            }
        }
        return nil
    }

    /// Register an external (already-running) plugin by URL and manifest path.
    func connect(name: String, url: String, manifestPath: String?) async throws {
        let manifest: PluginManifest?
        if let path = manifestPath {
            manifest = loadManifest(pluginDir: (path as NSString).deletingLastPathComponent)
        } else {
            manifest = nil
        }

        let port = manifest?.port ?? 0
        let version = manifest?.version ?? "0.0.0"
        let description = manifest?.description

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await dbPool.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO plugins (name, version, description, port, status, mode, url, path, config_json, installedAt, updatedAt)
                VALUES (?, ?, ?, ?, 'installed', 'external', ?, '', '{}', ?, ?)
            """, arguments: [name, version, description, port, url, now, now])
        }

        let runtime = PluginRuntime(
            name: name,
            manifest: manifest ?? PluginManifest(
                name: name, version: version, description: description, author: nil,
                sonataVersion: nil, port: port, arch: nil, startCommand: "",
                eventsChannel: nil, eventsTopic: nil,
                configSchema: nil, actions: nil
            ),
            mode: "external",
            baseURL: url,
            status: "starting"
        )

        lock.lock()
        plugins[name] = runtime
        lock.unlock()

        let healthy = await waitForHealthy(runtime)
        if healthy {
            await discoverAndRegisterActions(runtime)
            runtime.status = "running"
            await updateStatus(name: name, status: "running")
            sonataFileLog("Plugin \(name): connected to \(url), \(runtime.discoveredActions.count) actions registered")
        } else {
            runtime.status = "failed"
            await updateStatus(name: name, status: "failed")
            throw ActionError.custom("Plugin at \(url) is not responding", .serviceUnavailable)
        }
    }

    /// Enable and start a plugin.
    func enable(name: String) async throws {
        let row = try await dbPool.read { db -> (port: Int, mode: String, url: String?, path: String, configJson: String)? in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM plugins WHERE name = ?", arguments: [name]) else { return nil }
            return (
                port: row["port"],
                mode: row["mode"],
                url: row["url"],
                path: row["path"],
                configJson: row["config_json"]
            )
        }

        guard let row else { throw ActionError.notFound("plugin '\(name)'") }

        let manifest = loadManifest(pluginDir: row.path)
        let baseURL = row.mode == "external"
            ? (row.url ?? "http://127.0.0.1:\(row.port)")
            : "http://127.0.0.1:\(row.port)"

        let runtime = PluginRuntime(
            name: name,
            manifest: manifest ?? PluginManifest(
                name: name, version: "0.0.0", description: nil, author: nil,
                sonataVersion: nil, port: row.port, arch: nil, startCommand: "",
                eventsChannel: nil, eventsTopic: nil,
                configSchema: nil, actions: nil
            ),
            mode: row.mode,
            baseURL: baseURL,
            status: "starting"
        )

        lock.lock()
        plugins[name] = runtime
        lock.unlock()

        await updateStatus(name: name, status: "starting")

        if row.mode == "managed" {
            await spawnPlugin(runtime, configJson: row.configJson)
        }

        let healthy = await waitForHealthy(runtime)
        if healthy {
            await discoverAndRegisterActions(runtime)
            runtime.status = "running"
            runtime.crashCount = 0
            await updateStatus(name: name, status: "running", pid: runtime.process.map { Int($0.processIdentifier) })
        } else {
            runtime.status = "failed"
            await updateStatus(name: name, status: "failed")
            throw ActionError.custom("Plugin \(name) failed to start", .serviceUnavailable)
        }
    }

    /// Disable and stop a plugin.
    func disable(name: String) async throws {
        lock.lock()
        let runtime = plugins[name]
        lock.unlock()

        if let runtime {
            // Set status BEFORE terminating so terminationHandler skips crash recovery
            runtime.status = "disabled"

            let actionNames = runtime.discoveredActions.map { "\(name)_\($0.name)" }
            registry.unregister(actionNames)
            runtime.discoveredActions = []

            if runtime.mode == "managed" {
                // Use the release's stop command to cleanly shut down the BEAM daemon
                let pluginPath: String? = try? await dbPool.read { db in
                    try String.fetchOne(db, sql: "SELECT path FROM plugins WHERE name = ?", arguments: [name])
                }
                if let pluginPath {
                    let parts = runtime.manifest.startCommand.split(separator: " ").map(String.init)
                    if let executable = parts.first {
                        stopPluginDaemon(pluginPath: pluginPath, executable: executable)
                    }
                }

                // Also terminate the wrapper process if still running
                if let proc = runtime.process, proc.isRunning {
                    proc.terminate()
                }
            }
            runtime.process = nil
            runtime.status = "disabled"
        }

        await updateStatus(name: name, status: "disabled")
    }

    /// Run the plugin's stop command to cleanly shut down any daemon process.
    /// For Elixir releases: `bin/sonar stop` kills the BEAM daemon.
    private func stopPluginDaemon(pluginPath: String, executable: String) {
        let stopPath = (pluginPath as NSString).appendingPathComponent(executable)
        guard FileManager.default.fileExists(atPath: stopPath) else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: stopPath)
        proc.arguments = ["stop"]
        proc.currentDirectoryURL = URL(fileURLWithPath: pluginPath)
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                sonataFileLog("Plugin stop: daemon stopped cleanly")
            }
            // Give the port a moment to release
            Thread.sleep(forTimeInterval: 1)
        } catch {
            // Stop command may fail if no daemon is running — that's fine
        }
    }

    /// Uninstall a plugin — stop it, remove from DB, delete files.
    func uninstall(name: String) async throws {
        try await disable(name: name)

        let path = try await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT path FROM plugins WHERE name = ?", arguments: [name])
        }

        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM plugins WHERE name = ?", arguments: [name])
        }

        if let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }

        lock.lock()
        plugins.removeValue(forKey: name)
        lock.unlock()

        sonataFileLog("Plugin \(name): uninstalled")
    }

    /// Update config for a plugin. If running, restart to pick up new config.
    func updateConfig(name: String, configJson: String) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await dbPool.write { db in
            try db.execute(sql: """
                UPDATE plugins SET config_json = ?, updatedAt = ? WHERE name = ?
            """, arguments: [configJson, now, name])
        }
    }

    /// List all plugins with their current status.
    func listPlugins() async throws -> [[String: Any]] {
        try await dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM plugins ORDER BY name").map { row in
                [
                    "name": row["name"] as String,
                    "version": row["version"] as String,
                    "description": (row["description"] as String?) ?? "",
                    "port": row["port"] as Int,
                    "status": row["status"] as String,
                    "mode": row["mode"] as String,
                    "url": (row["url"] as String?) ?? "",
                    "path": row["path"] as String,
                    "pid": (row["pid"] as Int?) ?? 0,
                    "installedAt": row["installedAt"] as Int64,
                    "updatedAt": row["updatedAt"] as Int64,
                ] as [String: Any]
            }
        }
    }

    // MARK: - Helpers

    func updateStatus(name: String, status: String, pid: Int? = nil) async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try? await dbPool.write { db in
            if let pid {
                try db.execute(sql: "UPDATE plugins SET status = ?, pid = ?, updatedAt = ? WHERE name = ?",
                               arguments: [status, pid, now, name])
            } else {
                try db.execute(sql: "UPDATE plugins SET status = ?, updatedAt = ? WHERE name = ?",
                               arguments: [status, now, name])
            }
        }
    }

    // MARK: - Events Channel (WebSocket Subscription)

    /// After a plugin becomes healthy, check manifest for events_channel.
    /// If present, connect via WebSocket and route incoming events.
    func subscribeToEventsChannel(_ runtime: PluginRuntime) {
        guard let channelPath = runtime.manifest.eventsChannel,
              let topic = runtime.manifest.eventsTopic else { return }

        let wsURL = runtime.baseURL
            .replacingOccurrences(of: "http://", with: "ws://")
            .replacingOccurrences(of: "https://", with: "wss://")
            + channelPath

        guard let url = URL(string: wsURL) else {
            sonataFileLog("Plugin \(runtime.name): invalid WebSocket URL \(wsURL)")
            return
        }

        // Phoenix Channel WebSocket uses vsn=2.0.0 with array framing:
        // [join_ref, ref, topic, event, payload]
        let wsURLWithParams = wsURL + "?vsn=2.0.0"
        guard let finalURL = URL(string: wsURLWithParams) else {
            sonataFileLog("Plugin \(runtime.name): invalid WebSocket URL \(wsURLWithParams)")
            return
        }

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: finalURL)
        wsTask.resume()

        // Join the channel: [join_ref, ref, topic, "phx_join", {}]
        let joinMsg: [Any] = ["1", "1", topic, "phx_join", [String: Any]()]
        if let joinData = try? JSONSerialization.data(withJSONObject: joinMsg),
           let joinStr = String(data: joinData, encoding: .utf8) {
            wsTask.send(.string(joinStr)) { error in
                if let error {
                    sonataFileLog("Plugin \(runtime.name): channel join failed — \(error)")
                }
            }
        }

        // Start heartbeat (Phoenix requires heartbeat every 30s or it disconnects)
        let heartbeatTask = Task.detached {
            var ref = 100
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                let hb: [Any] = [NSNull(), "\(ref)", "phoenix", "heartbeat", [String: Any]()]
                if let data = try? JSONSerialization.data(withJSONObject: hb),
                   let str = String(data: data, encoding: .utf8) {
                    wsTask.send(.string(str)) { _ in }
                }
                ref += 1
            }
        }

        let pluginName = runtime.name
        let mgr = self
        Task.detached {
            await mgr.listenForEvents(wsTask: wsTask, pluginName: pluginName, topic: topic)
            heartbeatTask.cancel()
        }

        sonataFileLog("Plugin \(runtime.name): subscribed to events channel \(topic)")
    }

    /// Continuously read WebSocket messages and route them.
    /// Phoenix v2 format: [join_ref, ref, topic, event, payload]
    private func listenForEvents(wsTask: URLSessionWebSocketTask, pluginName: String, topic: String) async {
        while wsTask.state == .running {
            do {
                let message = try await wsTask.receive()
                switch message {
                case .string(let text):
                    guard let data = text.data(using: .utf8),
                          let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          arr.count >= 5 else { continue }

                    // [join_ref, ref, topic, event, payload]
                    let event = arr[3] as? String ?? ""
                    let payload = arr[4] as? [String: Any] ?? [:]

                    // Skip Phoenix internal events
                    guard !event.hasPrefix("phx_") else { continue }

                    sonataFileLog("Plugin \(pluginName): channel event '\(event)'")
                    await handlePluginEvent(pluginName: pluginName, event: event, payload: payload)

                case .data:
                    continue
                @unknown default:
                    continue
                }
            } catch {
                sonataFileLog("Plugin \(pluginName): WebSocket read error — \(error)")
                break
            }
        }
    }

    /// Route a plugin event to the appropriate handler.
    func handlePluginEvent(pluginName: String, event: String, payload: [String: Any]) async {
        switch event {
        case "new_message":
            let messageId = payload["message_id"] as? String ?? ""
            let fromPeer = payload["from_peer"] as? String ?? "unknown"
            let question = payload["question"] as? String ?? ""

            let eventPayload: [String: Any] = [
                "plugin": pluginName,
                "type": "SONAR_MESSAGE",
                "message_id": messageId,
                "from_peer": fromPeer,
                "question": question
            ]
            let payloadJSON = (try? JSONSerialization.data(withJSONObject: eventPayload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

            try? await dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO workerEvents (id, type, payload, priority, status, createdAt)
                    VALUES (?, 'SONAR_MESSAGE', ?, 5, 'pending', ?)
                """, arguments: [newUUID(), payloadJSON, nowMs()])
            }
            sonataFileLog("Plugin \(pluginName): dispatched SONAR_MESSAGE from \(fromPeer) to worker queue")

        case "reply_received":
            let messageId = payload["message_id"] as? String ?? ""
            let answer = payload["answer"] as? String ?? ""
            resumeSendContinuation(messageId: messageId, answer: answer)

        case "reply_sent":
            break

        default:
            sonataFileLog("Plugin \(pluginName): unknown event '\(event)'")
        }
    }

    // MARK: - Send Continuation (async wait for reply)

    /// Pending sonar_send calls waiting for replies. Keyed by message_id.
    private var pendingReplies: [String: CheckedContinuation<String?, Never>] = [:]
    private let replyLock = NSLock()

    /// Register a continuation for a sonar_send call. Returns the reply or nil on timeout.
    func awaitReply(messageId: String, timeout: TimeInterval = 60) async -> String? {
        await withCheckedContinuation { continuation in
            replyLock.lock()
            pendingReplies[messageId] = continuation
            replyLock.unlock()

            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.replyLock.lock()
                let pending = self.pendingReplies.removeValue(forKey: messageId)
                self.replyLock.unlock()
                pending?.resume(returning: nil)
            }
        }
    }

    /// Resume a pending sonar_send continuation with the reply.
    private func resumeSendContinuation(messageId: String, answer: String) {
        replyLock.lock()
        let continuation = pendingReplies.removeValue(forKey: messageId)
        replyLock.unlock()
        continuation?.resume(returning: answer)
    }

    /// Shutdown all managed plugins (called during app termination).
    func shutdown() async {
        lock.lock()
        let allPlugins = Array(plugins.values)
        lock.unlock()

        for runtime in allPlugins where runtime.mode == "managed" {
            // Use stop command to cleanly shut down the BEAM daemon
            let pluginPath: String? = try? await dbPool.read { db in
                try String.fetchOne(db, sql: "SELECT path FROM plugins WHERE name = ?", arguments: [runtime.name])
            }
            if let pluginPath {
                let parts = runtime.manifest.startCommand.split(separator: " ").map(String.init)
                if let executable = parts.first {
                    stopPluginDaemon(pluginPath: pluginPath, executable: executable)
                }
            }
            // Also terminate the wrapper
            if let proc = runtime.process, proc.isRunning {
                proc.terminate()
            }
            sonataFileLog("Plugin \(runtime.name): stopped for shutdown")
        }
    }
}

// MARK: - JSON Passthrough

/// Wraps raw JSON data so it can be returned from a SonataAction handler
/// as a pass-through. The plugin's response bytes are forwarded as-is —
/// the wrapped value is walked and re-emitted via Codable containers so the
/// outer JSONEncoder produces real JSON structure (not a JSON-escaped string).
struct JSONPassthrough: Encodable {
    let value: Any

    /// Init from already-serialized JSON data (preferred — zero re-encoding)
    init(data: Data) {
        if let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            self.value = parsed
        } else {
            self.value = [String: Any]()
        }
    }

    /// Init from a JSONSerialization-compatible value (e.g., [[String: Any]])
    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try Self.encodeAny(value, to: encoder)
    }

    private static func encodeAny(_ value: Any, to encoder: Encoder) throws {
        if let dict = value as? [String: Any] {
            var c = encoder.container(keyedBy: DynamicKey.self)
            for (k, v) in dict {
                let key = DynamicKey(stringValue: k)!
                try encodeAny(v, in: &c, key: key)
            }
        } else if let arr = value as? [Any] {
            var c = encoder.unkeyedContainer()
            for v in arr {
                try encodeAny(v, in: &c)
            }
        } else {
            var c = encoder.singleValueContainer()
            try encodeScalar(value, in: &c)
        }
    }

    private static func encodeAny(_ value: Any, in c: inout KeyedEncodingContainer<DynamicKey>, key: DynamicKey) throws {
        if let dict = value as? [String: Any] {
            var nested = c.nestedContainer(keyedBy: DynamicKey.self, forKey: key)
            for (k, v) in dict {
                let nk = DynamicKey(stringValue: k)!
                try encodeAny(v, in: &nested, key: nk)
            }
        } else if let arr = value as? [Any] {
            var nested = c.nestedUnkeyedContainer(forKey: key)
            for v in arr {
                try encodeAny(v, in: &nested)
            }
        } else if value is NSNull {
            try c.encodeNil(forKey: key)
        } else if let b = value as? Bool {
            try c.encode(b, forKey: key)
        } else if let i = value as? Int64 {
            try c.encode(i, forKey: key)
        } else if let i = value as? Int {
            try c.encode(i, forKey: key)
        } else if let d = value as? Double {
            try c.encode(d, forKey: key)
        } else if let s = value as? String {
            try c.encode(s, forKey: key)
        } else if let n = value as? NSNumber {
            // Disambiguate NSNumber for bool vs numeric
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                try c.encode(n.boolValue, forKey: key)
            } else {
                try c.encode(n.doubleValue, forKey: key)
            }
        } else {
            try c.encodeNil(forKey: key)
        }
    }

    private static func encodeAny(_ value: Any, in c: inout UnkeyedEncodingContainer) throws {
        if let dict = value as? [String: Any] {
            var nested = c.nestedContainer(keyedBy: DynamicKey.self)
            for (k, v) in dict {
                let nk = DynamicKey(stringValue: k)!
                try encodeAny(v, in: &nested, key: nk)
            }
        } else if let arr = value as? [Any] {
            var nested = c.nestedUnkeyedContainer()
            for v in arr {
                try encodeAny(v, in: &nested)
            }
        } else if value is NSNull {
            try c.encodeNil()
        } else if let b = value as? Bool {
            try c.encode(b)
        } else if let i = value as? Int64 {
            try c.encode(i)
        } else if let i = value as? Int {
            try c.encode(i)
        } else if let d = value as? Double {
            try c.encode(d)
        } else if let s = value as? String {
            try c.encode(s)
        } else if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                try c.encode(n.boolValue)
            } else {
                try c.encode(n.doubleValue)
            }
        } else {
            try c.encodeNil()
        }
    }

    private static func encodeScalar(_ value: Any, in c: inout SingleValueEncodingContainer) throws {
        if value is NSNull {
            try c.encodeNil()
        } else if let b = value as? Bool {
            try c.encode(b)
        } else if let i = value as? Int64 {
            try c.encode(i)
        } else if let i = value as? Int {
            try c.encode(i)
        } else if let d = value as? Double {
            try c.encode(d)
        } else if let s = value as? String {
            try c.encode(s)
        } else if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                try c.encode(n.boolValue)
            } else {
                try c.encode(n.doubleValue)
            }
        } else {
            try c.encodeNil()
        }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

