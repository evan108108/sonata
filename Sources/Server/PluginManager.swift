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
    let capabilities: PluginCapabilities?
    /// Claude Code slash-command skill slugs this plugin ships. For each slug
    /// listed here, the plugin must ship `SKILL.md` at
    /// `<plugin-dir>/skills/<slug>/SKILL.md` and Sonata installs it into
    /// `~/.claude/skills/<slug>/` on plugin install (with a `.plugin-owner`
    /// sidecar tagging the owning plugin), then removes it on uninstall.
    /// Optional — omit or leave empty to opt out. Overwriting a personal skill
    /// (no owner sidecar) or a different plugin's skill is logged and skipped
    /// unless the caller explicitly asked for takeover; today the safe path is
    /// always "skip and log."
    let skills: [String]?
    /// Seconds `waitForHealthy` will poll `/api/actions` before declaring the
    /// plugin failed. Optional — nil falls back to `PluginManager.healthTimeout`
    /// (15s, aggressive default for fast Node/Elixir plugins). A plugin whose
    /// boot path is dominated by external work (SSE handshakes to a remote
    /// gateway, WASM warmup, model preload) should declare its own budget
    /// here so steady-state startup doesn't get flagged failed and drop its
    /// actions off the registry every deploy. After the deadline the DB row
    /// stays `failed` and no re-registration runs — sonata-studio hit this
    /// 2026-08-27: 15s budget vs ~52s actual boot meant its 34 actions were
    /// silently missing from every session's tool surface until the operator
    /// toggled it in the UI.
    let healthTimeoutSeconds: Double?
    /// `"dynamic"` lets the plugin bind any free port in `portRange` instead
    /// of exactly `port`. PluginManager picks the port (sticky across
    /// restarts), passes it as PORT plus `<NAME>_PORT_RANGE`, learns the bound
    /// port from `<plugin-dir>/<name>.port`, and requires `GET /api/health`
    /// to answer `app == <name>` before adopting it. Callers resolve the URL
    /// through PluginEndpointRegistry. Omit for a fixed port. A plugin whose
    /// clients hardcode its URL (prstar on 4100) must stay fixed.
    let portPolicy: String?
    /// `[lo, hi]`, inclusive. Required when `portPolicy == "dynamic"`.
    let portRange: [Int]?

    /// The port range when this plugin opted into dynamic ports, else nil.
    var dynamicPortRange: ClosedRange<Int>? {
        guard portPolicy == "dynamic", let r = portRange, r.count == 2,
              r[0] > 0, r[0] <= r[1], r[1] <= 65_535 else { return nil }
        return r[0]...r[1]
    }

    enum CodingKeys: String, CodingKey {
        case name, version, description, author, port, arch, actions
        case sonataVersion = "sonata_version"
        case startCommand = "start_command"
        case eventsChannel = "events_channel"
        case eventsTopic = "events_topic"
        case configSchema = "config_schema"
        case capabilities, skills
        case healthTimeoutSeconds = "health_timeout_seconds"
        case portPolicy = "port_policy"
        case portRange = "port_range"
    }
}

/// Optional capability block plugins declare in their manifest. See
/// ~/.sonata/wiki/sonata/patterns/whathappened.md for the whathappened
/// convention. New capabilities added here MUST be optional so older
/// manifests still parse.
struct PluginCapabilities: Codable {
    let whathappened: PluginWhatHappenedCapability?
    /// Plugin receives third-party webhooks (via the 4a relay) and forwards
    /// them to POST /api/webhook/deliver. Declaring it makes spawnPlugin
    /// inject the shared bearer as SONATA_WEBHOOK_BEARER.
    let webhookReceiver: Bool?
}

struct PluginWhatHappenedCapability: Codable {
    let url: String
    let method: String?           // Defaults to "get"
    let args: [ManifestParam]?
    /// Optional domain slug. When present, overrides the plugin's `name`
    /// as the whathappened routing key. Lets a plugin serve a domain whose
    /// slug differs from its own name (e.g. plugin `lead-tracker` serves
    /// domain `lead`; a hypothetical `firm-tracker` could serve `firm` or
    /// even multiple domains in future versions of the manifest).
    let domain: String?
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
    /// e.g. "http://127.0.0.1:4001". For a dynamic-port plugin this starts as
    /// the assigned port and is corrected from its port file in waitForHealthy.
    var baseURL: String
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

    /// A recovered plugin must stay healthy this long before its crash counter is reset.
    /// A boots-then-dies plugin passes the health probe (an old instance is still listening)
    /// then exits seconds later; if the transient healthy snapshot reset crashCount to 0
    /// immediately, the give-up threshold could never be reached and it would loop forever.
    private let crashCountStableWindow: Double = 60

    /// Health check timeout per plugin (seconds)
    let healthTimeout: Double = 15.0

    /// Health check poll interval (seconds)
    let healthPollInterval: Double = 0.25

    init(dbPool: DatabasePool, registry: ActionRegistry) {
        self.dbPool = dbPool
        self.registry = registry
    }

    // MARK: - Locking helpers
    //
    // NSLock's lock()/unlock() are unavailable from async contexts under the
    // Swift 6 language mode. These helpers wrap the lock in a synchronous
    // closure so callers in async contexts can still mutate shared state.

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    @discardableResult
    private func withReplyLock<T>(_ body: () -> T) -> T {
        replyLock.lock()
        defer { replyLock.unlock() }
        return body()
    }

    // MARK: - Plugin Stdio Logging

    /// Tail a spawned plugin's stdout/stderr pipe into `plugin.log` in the plugin
    /// directory, prefixing each line with an ISO8601 timestamp and `[name/stream]`.
    /// Exits when the pipe hits EOF (process exited).
    ///
    /// Runs on a GCD utility-QoS thread — NOT the Swift cooperative pool. The pipe's
    /// `availableData` is a blocking `read(2)` that would pin whatever thread it ran on
    /// for the life of the plugin process. With N plugins × 2 pipes each on Swift's
    /// cooperative pool (~ncores threads), enough plugins would starve the pool: HTTP
    /// handler continuations couldn't schedule, `dbPool.read` awaits blocked on
    /// `Pool.get`'s semaphore forever, and NIO's `channelActive` would deinit its
    /// `NIOAsyncWriter` without `finish()` → SIGTRAP crash. GCD's global queues are
    /// designed for blocking I/O and don't share the cooperative pool.
    private func tailPluginPipe(_ pipe: Pipe, pluginName: String, stream: String, logPath: String) {
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                guard let text = String(data: data, encoding: .utf8) else { continue }

                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                var out = ""
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    if line.isEmpty { continue }
                    out += "[\(iso.string(from: Date()))] [\(pluginName)/\(stream)] \(line)\n"
                }
                guard !out.isEmpty, let outData = out.data(using: .utf8) else { continue }

                if !FileManager.default.fileExists(atPath: logPath) {
                    FileManager.default.createFile(atPath: logPath, contents: nil)
                }
                if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                    defer { try? fh.close() }
                    _ = try? fh.seekToEnd()
                    try? fh.write(contentsOf: outData)
                }
            }
        }
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

            withLock { plugins[row.name] = runtime }

            await updateStatus(name: row.name, status: "starting")

            if row.mode == "managed" {
                await spawnPlugin(runtime, configJson: row.configJson)
            }

            let healthy = await waitForHealthy(runtime)
            if healthy {
                await publishEndpoint(runtime)
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

        let row: (path: String, port: Int?, pid: Int?)? = try? await dbPool.read { db in
            guard let r = try Row.fetchOne(db, sql: "SELECT path, port, pid FROM plugins WHERE name = ?",
                                           arguments: [runtime.name]) else { return nil }
            return (path: r["path"], port: r["port"], pid: r["pid"])
        }
        guard let row else { return }
        let pluginPath = row.path

        // Stop any stale daemon from a previous run before picking a port, so
        // a dynamic plugin's own old listener frees its sticky port first.
        stopPluginDaemon(pluginPath: pluginPath, executable: executable)
        reclaimStalePluginProcesses(
            name: runtime.name,
            pluginPath: pluginPath,
            recordedPID: row.pid,
            ports: Array(Set([manifest.port] + (row.port.map { [$0] } ?? [])))
        )

        // A dynamic-port plugin gets the first free port in its range,
        // preferring the one it had last time. A fixed-port plugin gets its
        // manifest port, held or not, exactly as before.
        var port = manifest.port
        if let range = manifest.dynamicPortRange {
            guard let picked = pickPluginPort(preferred: row.port, range: range) else {
                sonataFileLog("Plugin \(runtime.name): every port in \(range.lowerBound)-\(range.upperBound) is held — not spawning")
                return
            }
            port = picked
            runtime.baseURL = "http://127.0.0.1:\(picked)"
            try? FileManager.default.removeItem(atPath: portFilePath(name: runtime.name, pluginPath: pluginPath))
            sonataFileLog("Plugin \(runtime.name): assigned port \(picked) (range \(range.lowerBound)-\(range.upperBound))")
        }

        let execPath = (pluginPath as NSString).appendingPathComponent(executable)
        let args = Array(parts.dropFirst())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: pluginPath)

        var env = ProcessInfo.processInfo.environment
        env["PORT"] = String(port)
        env["SONATA_PLUGIN_DATA_DIR"] = pluginPath
        env["SONATA_HOST"] = "http://127.0.0.1:\(sonataPort)"

        // Webhook-receiver plugins authenticate to POST /api/webhook/deliver
        // with a shared bearer. Generated-or-loaded here, before launch, so
        // the very first spawn already carries it — no post-hoc respawn.
        if manifest.capabilities?.webhookReceiver == true {
            env["SONATA_WEBHOOK_BEARER"] =
                SecretStore.getOrSet("4a_webhook_shared_secret") { UUID().uuidString }
        }

        let prefix = runtime.name.uppercased()
        if let range = manifest.dynamicPortRange {
            env["\(prefix)_PORT_RANGE"] = "\(range.lowerBound)-\(range.upperBound)"
        }
        if let configData = configJson.data(using: .utf8),
           let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] {
            for (key, value) in config {
                let envKey = "\(prefix)_\(key.uppercased())"
                env[envKey] = "\(value)"
            }
        }

        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            runtime.process = process
            sonataFileLog("Plugin \(runtime.name): spawned PID \(process.processIdentifier)")

            let logPath = (pluginPath as NSString).appendingPathComponent("plugin.log")
            tailPluginPipe(outPipe, pluginName: runtime.name, stream: "stdout", logPath: logPath)
            tailPluginPipe(errPipe, pluginName: runtime.name, stream: "stderr", logPath: logPath)

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

    /// Poll until the plugin answers or the budget runs out. Returns true if healthy.
    ///
    /// A fixed-port plugin is healthy on a 200 from GET /api/actions. A
    /// dynamic-port plugin must also prove it is the plugin: its port file
    /// names the port, and GET /api/health must answer `app == <name>`. A
    /// squatter on the port (NoMachine on :4000) is never adopted.
    func waitForHealthy(_ runtime: PluginRuntime) async -> Bool {
        // Per-plugin override lets slow-boot plugins (studio boots ~52s
        // via 4a SSE handshakes) declare a larger budget in their manifest
        // so their actions don't get dropped from the registry every deploy.
        let budget = runtime.manifest.healthTimeoutSeconds ?? healthTimeout
        let deadline = Date().addingTimeInterval(budget)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)

        if runtime.manifest.dynamicPortRange != nil {
            return await waitForDynamicPortHealthy(runtime, session: session, deadline: deadline)
        }

        let url = URL(string: "\(runtime.baseURL)/api/actions")!
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

    private func waitForDynamicPortHealthy(_ runtime: PluginRuntime, session: URLSession, deadline: Date) async -> Bool {
        let pluginPath: String? = runtime.mode == "managed"
            ? (try? await dbPool.read { db in
                try String.fetchOne(db, sql: "SELECT path FROM plugins WHERE name = ?", arguments: [runtime.name])
            }) ?? nil
            : nil

        while Date() < deadline {
            if let pluginPath, let bound = readPortFile(name: runtime.name, pluginPath: pluginPath) {
                runtime.baseURL = "http://127.0.0.1:\(bound)"
            }
            if let url = URL(string: "\(runtime.baseURL)/api/health"),
               let (data, response) = try? await session.data(from: url),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               pluginIdentityMatches(healthBody: data, name: runtime.name) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(Int(healthPollInterval * 1000)))
        }
        sonataFileLog("Plugin \(runtime.name): no healthy `app == \(runtime.name)` answer at \(runtime.baseURL)")
        return false
    }

    private func readPortFile(name: String, pluginPath: String) -> Int? {
        guard let text = try? String(contentsOfFile: portFilePath(name: name, pluginPath: pluginPath), encoding: .utf8),
              let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(port) else { return nil }
        return port
    }

    /// Once a plugin is healthy, record where it actually is: the plugins row's
    /// port (so the next spawn prefers it) and PluginEndpointRegistry (so
    /// callers like SonarPluginEndpoint reach it).
    func publishEndpoint(_ runtime: PluginRuntime) async {
        PluginEndpointRegistry.publish(runtime.name, baseURL: runtime.baseURL)
        guard runtime.manifest.dynamicPortRange != nil,
              let port = URLComponents(string: runtime.baseURL)?.port else { return }
        try? await dbPool.write { db in
            try db.execute(sql: "UPDATE plugins SET port = ? WHERE name = ?", arguments: [port, runtime.name])
        }
        sonataFileLog("Plugin \(runtime.name): bound port \(port) published")
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
            // The tool surface just grew — tell every live MCP session to
            // re-pull tools/list. This is the moment that fixes the
            // reconnect-while-plugin-still-booting race: a session that
            // re-pulled before this plugin registered would otherwise hold a
            // plugin-less surface forever (see MCPNotificationDispatcher
            // .broadcastToolsListChanged).
            Task { await MCPNotificationDispatcher.shared.broadcastToolsListChanged() }
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
        guard let runtime = withLock({ plugins[pluginName] }) else { return }

        // Skip recovery if plugin was intentionally stopped (disable/uninstall)
        guard runtime.mode == "managed" && runtime.status == "running" else { return }

        runtime.crashCount += 1
        sonataFileLog("Plugin \(pluginName): crashed (exit \(exitCode)), attempt \(runtime.crashCount)/3")

        let actionNames = runtime.discoveredActions.map { "\(pluginName)_\($0.name)" }
        registry.unregister(actionNames)
        Task { await MCPNotificationDispatcher.shared.broadcastToolsListChanged() }

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
            await publishEndpoint(runtime)
            await discoverAndRegisterActions(runtime)
            subscribeToEventsChannel(runtime)
            runtime.status = "running"
            // Do NOT reset crashCount immediately — a boots-then-dies plugin passes this
            // health probe and then exits. Defer the reset until it proves stable, so a
            // crash loop actually accumulates toward the give-up threshold (#27 fix).
            scheduleCrashCountReset(runtime)
            await updateStatus(name: pluginName, status: "running", pid: runtime.process.map { Int($0.processIdentifier) })
            sonataFileLog("Plugin \(pluginName): recovered (pending \(Int(crashCountStableWindow))s stability check)")
        } else {
            await handleCrash(pluginName: pluginName, exitCode: -1)
        }
    }

    /// Reset a plugin's crashCount only after it stays healthy for `crashCountStableWindow`
    /// seconds with no further crash. Captures the current count; if another crash bumps it
    /// (or the plugin leaves "running") meanwhile, the reset is skipped so the accumulated
    /// count can still reach the give-up threshold. Without this, a plugin that passes the
    /// health probe and dies seconds later resets its own counter every cycle and loops
    /// forever instead of being skipped (#26/#27 root cause).
    private func scheduleCrashCountReset(_ runtime: PluginRuntime) {
        let observed = runtime.crashCount
        let name = runtime.name
        Task {
            try? await Task.sleep(for: .seconds(crashCountStableWindow))
            guard let rt = withLock({ plugins[name] }), rt === runtime else { return }
            if rt.status == "running" && rt.crashCount == observed {
                rt.crashCount = 0
                sonataFileLog("Plugin \(name): stable for \(Int(crashCountStableWindow))s — crash counter reset")
            }
        }
    }

    // MARK: - Plugin Management API

    /// Install a plugin from a tarball at the given file path.
    /// Extracts to ~/.sonata/plugins/<name>/, reads manifest, inserts DB row.
    func install(tarballPath: String) async throws -> PluginManifest {
        let tempDir = "\(SonataInstance.dataDirectory)/plugins/_installing_\(UUID().uuidString)"

        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        // Off the cooperative pool — extraction blocks for the size of the
        // tarball, and a blocked cooperative thread starves the HTTP server
        // this install request is itself being served from (SCT-4).
        let extraction = await OffPoolProcess.run("/usr/bin/tar", ["xzf", tarballPath, "-C", tempDir])

        guard let extraction, extraction.status == 0 else {
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

        let finalDir = "\(SonataInstance.dataDirectory)/plugins/\(manifest.name)"
        if FileManager.default.fileExists(atPath: finalDir) {
            // Preserve plugin data (DB files, data dir) across reinstalls
            let dataBackup = "\(SonataInstance.dataDirectory)/plugins/_data_backup_\(manifest.name)"
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
        let dataBackup = "\(SonataInstance.dataDirectory)/plugins/_data_backup_\(manifest.name)"
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
            // Preserve existing config_json across reinstall — the row already
            // exists on upgrade/reinstall paths and holds plugin identity keys
            // (studio's schnorr keypair, sonar's discovery config, etc). The
            // prior hardcoded '{}' wiped those on every reinstall, silently
            // reissuing the plugin's identity and orphaning every prior
            // artifact it signed (studio cards, room memberships).
            let existingConfig: String = (try? String.fetchOne(db,
                sql: "SELECT config_json FROM plugins WHERE name = ?",
                arguments: [manifest.name])).flatMap { $0 } ?? "{}"
            try db.execute(sql: """
                INSERT OR REPLACE INTO plugins (name, version, description, port, status, mode, path, config_json, installedAt, updatedAt)
                VALUES (?, ?, ?, ?, 'installed', 'managed', ?, ?, ?, ?)
            """, arguments: [manifest.name, manifest.version, manifest.description, manifest.port, finalDir, existingConfig, now, now])
        }

        installPluginSkills(manifest: manifest, pluginDir: finalDir)

        sonataFileLog("Plugin \(manifest.name) v\(manifest.version): installed to \(finalDir)")
        return manifest
    }

    /// Deploy plugin-declared Claude Code skills into ~/.claude/skills/.
    ///
    /// For each `skills[]` slug in the manifest, copy
    /// `<pluginDir>/skills/<slug>/` to `~/.claude/skills/<slug>/`, then write a
    /// `.plugin-owner` sidecar naming the plugin so uninstall can distinguish
    /// its own from a user's personal skill or another plugin's.
    ///
    /// Conflict rules:
    ///   - Destination exists with NO `.plugin-owner` file (user-personal
    ///     skill): skip and log WARN. Users own their `~/.claude/skills/`.
    ///   - Destination exists with a `.plugin-owner` naming a DIFFERENT plugin:
    ///     skip and log WARN. Two plugins claiming the same slug is an
    ///     integration problem, not something Sonata quietly resolves. The
    ///     first-installed plugin keeps the slot.
    ///   - Destination exists with a `.plugin-owner` naming THIS plugin: full
    ///     overwrite. Same-plugin reinstall or upgrade always refreshes.
    ///   - Destination missing: create fresh, tag it.
    ///
    /// Missing on-disk skill files (declared in manifest but not shipped)
    /// are logged and skipped so a partial rollout doesn't fail install.
    private func installPluginSkills(manifest: PluginManifest, pluginDir: String) {
        guard let slugs = manifest.skills, !slugs.isEmpty else { return }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let skillsRoot = home.appendingPathComponent(".claude/skills")
        try? fm.createDirectory(at: skillsRoot, withIntermediateDirectories: true)

        for slug in slugs {
            let sourceDir = (pluginDir as NSString).appendingPathComponent("skills/\(slug)")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sourceDir, isDirectory: &isDir), isDir.boolValue else {
                sonataFileLog("Plugin \(manifest.name): declared skill '\(slug)' — no directory at \(sourceDir), skipping")
                continue
            }
            let destDir = skillsRoot.appendingPathComponent(slug)
            let ownerFile = destDir.appendingPathComponent(".plugin-owner")

            if fm.fileExists(atPath: destDir.path) {
                if let existingOwner = try? String(contentsOf: ownerFile, encoding: .utf8) {
                    let owner = existingOwner.trimmingCharacters(in: .whitespacesAndNewlines)
                    if owner != manifest.name {
                        sonataFileLog("Plugin \(manifest.name): skill '\(slug)' already owned by plugin '\(owner)' — skipping (uninstall the other plugin first)")
                        continue
                    }
                    // Same-plugin reinstall: nuke and refresh.
                    try? fm.removeItem(at: destDir)
                } else {
                    // No owner tag = user-personal skill. Never overwrite.
                    sonataFileLog("Plugin \(manifest.name): skill '\(slug)' already exists in ~/.claude/skills without a plugin owner — skipping (would clobber user-personal skill)")
                    continue
                }
            }

            do {
                try fm.copyItem(atPath: sourceDir, toPath: destDir.path)
                try manifest.name.write(to: ownerFile, atomically: true, encoding: .utf8)
                sonataFileLog("Plugin \(manifest.name): installed skill '\(slug)' from \(sourceDir)")
            } catch {
                sonataFileLog("Plugin \(manifest.name): failed to install skill '\(slug)' — \(error)")
            }
        }
    }

    /// Remove plugin-owned Claude Code skills from ~/.claude/skills/.
    /// Only removes directories whose `.plugin-owner` sidecar names `pluginName`
    /// — user-personal skills and other plugins' skills stay intact.
    ///
    /// The manifest is optional: on uninstall the on-disk plugin dir has
    /// already been read to find `finalDir`, so a manifest re-parse is cheap,
    /// but a stale/partial install may not have one. When absent, this scans
    /// the skills root and matches on owner tag alone.
    private func uninstallPluginSkills(pluginName: String, manifest: PluginManifest?) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let skillsRoot = home.appendingPathComponent(".claude/skills")
        guard fm.fileExists(atPath: skillsRoot.path) else { return }

        // Prefer the manifest's declared list so we don't scan the whole
        // skills root when we know exactly what was installed. Fall back to a
        // full scan for stale-install cleanup.
        let candidateSlugs: [String]
        if let declared = manifest?.skills, !declared.isEmpty {
            candidateSlugs = declared
        } else {
            candidateSlugs = (try? fm.contentsOfDirectory(atPath: skillsRoot.path)) ?? []
        }

        for slug in candidateSlugs {
            let destDir = skillsRoot.appendingPathComponent(slug)
            let ownerFile = destDir.appendingPathComponent(".plugin-owner")
            guard let existingOwner = try? String(contentsOf: ownerFile, encoding: .utf8) else {
                continue  // Not a plugin-owned skill; leave alone.
            }
            let owner = existingOwner.trimmingCharacters(in: .whitespacesAndNewlines)
            guard owner == pluginName else { continue }
            do {
                try fm.removeItem(at: destDir)
                sonataFileLog("Plugin \(pluginName): removed skill '\(slug)'")
            } catch {
                sonataFileLog("Plugin \(pluginName): failed to remove skill '\(slug)' — \(error)")
            }
        }
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
            // Preserve existing config_json across re-connect (see the
            // matching preservation logic in install() above).
            let existingConfig: String = (try? String.fetchOne(db,
                sql: "SELECT config_json FROM plugins WHERE name = ?",
                arguments: [name])).flatMap { $0 } ?? "{}"
            try db.execute(sql: """
                INSERT OR REPLACE INTO plugins (name, version, description, port, status, mode, url, path, config_json, installedAt, updatedAt)
                VALUES (?, ?, ?, ?, 'installed', 'external', ?, '', ?, ?, ?)
            """, arguments: [name, version, description, port, url, existingConfig, now, now])
        }

        let runtime = PluginRuntime(
            name: name,
            manifest: manifest ?? PluginManifest(
                name: name, version: version, description: description, author: nil,
                sonataVersion: nil, port: port, arch: nil, startCommand: "",
                eventsChannel: nil, eventsTopic: nil,
                configSchema: nil, actions: nil, capabilities: nil,
                skills: nil,
                healthTimeoutSeconds: nil,
                portPolicy: nil,
                portRange: nil
            ),
            mode: "external",
            baseURL: url,
            status: "starting"
        )

        withLock { plugins[name] = runtime }

        let healthy = await waitForHealthy(runtime)
        if healthy {
            await publishEndpoint(runtime)
            await discoverAndRegisterActions(runtime)
            await registerWhatHappenedCapability(runtime)
            runtime.status = "running"
            await updateStatus(name: name, status: "running")
            sonataFileLog("Plugin \(name): connected to \(url), \(runtime.discoveredActions.count) actions registered")
        } else {
            runtime.status = "failed"
            await updateStatus(name: name, status: "failed")
            throw ActionError.custom("Plugin at \(url) is not responding", .serviceUnavailable)
        }
    }

    // MARK: - whathappened capability plumbing
    //
    // Plugins may declare a top-level `capabilities.whathappened` block in
    // their manifest. On plugin_enable / plugin_connect, upsert the row into
    // `plugin_whathappened`. On plugin_disable / plugin_uninstall, delete it.
    // The whathappened MCP action reads this table when routing a domain
    // that isn't in the internal WhatHappenedRegistry.
    //
    // See ~/.sonata/wiki/sonata/patterns/whathappened.md for the schema.

    private func registerWhatHappenedCapability(_ runtime: PluginRuntime) async {
        guard let cap = runtime.manifest.capabilities?.whathappened else { return }
        let args = cap.args ?? []
        let argsData = (try? JSONEncoder().encode(args)) ?? Data("[]".utf8)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "[]"
        let method = (cap.method?.isEmpty == false ? cap.method! : "get").lowercased()
        // The bound port, not the manifest one: a dynamic-port plugin may sit
        // anywhere in its range.
        let port = URLComponents(string: runtime.baseURL)?.port ?? runtime.manifest.port
        let name = runtime.name
        // Domain slug — manifest override wins, plugin name is the fallback.
        // Trim + non-empty guard so a whitespace-only override doesn't create
        // an unroutable "" domain.
        let declared = cap.domain?.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = (declared?.isEmpty == false ? declared! : name)
        do {
            try await dbPool.write { db in
                // Row is keyed by plugin_name (unique per plugin) so a
                // re-enable replaces its own row. If ANOTHER plugin already
                // claims this domain, defer to it and log — the convention
                // is one domain per owner. (Downstream: consider making this
                // a hard error once we see whether it happens in practice.)
                if let existingOwner = try String.fetchOne(db,
                    sql: "SELECT plugin_name FROM plugin_whathappened WHERE domain = ? AND plugin_name != ?",
                    arguments: [domain, name]) {
                    sonataFileLog("Plugin \(name): domain '\(domain)' already claimed by plugin '\(existingOwner)' — capability NOT registered")
                    return
                }
                try db.execute(sql: """
                    INSERT OR REPLACE INTO plugin_whathappened
                    (plugin_name, domain, url, method, args_json, port, registered_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [name, domain, cap.url, method, argsJSON, port, nowMs()])
            }
            sonataFileLog("Plugin \(name): registered whathappened domain '\(domain)' at \(cap.url)")
        } catch {
            sonataFileLog("Plugin \(name): failed to register whathappened capability: \(error.localizedDescription)")
        }
    }

    private func unregisterWhatHappenedCapability(name: String) async {
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "DELETE FROM plugin_whathappened WHERE plugin_name = ?",
                    arguments: [name]
                )
            }
        } catch {
            sonataFileLog("Plugin \(name): failed to remove whathappened capability: \(error.localizedDescription)")
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
                configSchema: nil, actions: nil, capabilities: nil,
                skills: nil,
                healthTimeoutSeconds: nil,
                portPolicy: nil,
                portRange: nil
            ),
            mode: row.mode,
            baseURL: baseURL,
            status: "starting"
        )

        withLock { plugins[name] = runtime }

        await updateStatus(name: name, status: "starting")

        if row.mode == "managed" {
            await spawnPlugin(runtime, configJson: row.configJson)
        }

        let healthy = await waitForHealthy(runtime)
        if healthy {
            await publishEndpoint(runtime)
            await discoverAndRegisterActions(runtime)
            subscribeToEventsChannel(runtime)
            await registerWhatHappenedCapability(runtime)
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
        let runtime = withLock { plugins[name] }

        if let runtime {
            // Set status BEFORE terminating so terminationHandler skips crash recovery
            runtime.status = "disabled"

            let actionNames = runtime.discoveredActions.map { "\(name)_\($0.name)" }
            registry.unregister(actionNames)
            runtime.discoveredActions = []
            await unregisterWhatHappenedCapability(name: name)
            Task { await MCPNotificationDispatcher.shared.broadcastToolsListChanged() }

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
        PluginEndpointRegistry.remove(name)

        await updateStatus(name: name, status: "disabled")
    }

    /// Stale processes of THIS plugin that must die before a fresh spawn:
    /// the pid recorded on the plugins row plus every listener on `ports`,
    /// kept only when processBelongsToPlugin says it's this plugin's.
    ///
    /// Needed for compiled Bun binaries where `bin/<name> stop` is a no-op —
    /// without it the old process keeps holding the port and the new spawn
    /// crashes immediately. The path filter is new (10/29): this used to
    /// signal every listener on the manifest port, which would have killed
    /// NoMachine's nxd on :4000 had it been visible to us, and could kill any
    /// unrelated same-user daemon that happens to sit on a plugin's port. A
    /// foreign holder is now logged and left alone; a dynamic-port plugin
    /// simply binds elsewhere.
    ///
    /// The executable-path test alone missed every node plugin: on the 10/29
    /// relaunch it called prstar's and lead-tracker's own boot-time node
    /// processes foreign, left them on :4100 and :4110, and both fresh spawns
    /// died with EADDRINUSE.
    private func stalePluginPIDs(pluginPath: String, recordedPID: Int?, ports: [Int], logForeign: Bool = false) -> [pid_t] {
        var candidates = Set(ports.flatMap { tcpListenerPIDs(port: $0) })
        if let recordedPID, recordedPID > 0, recordedPID != Int(getpid()) {
            candidates.insert(pid_t(recordedPID))
        }
        return candidates.filter { pid in
            guard let exe = executablePath(of: pid) else { return false }
            if processBelongsToPlugin(pid, pluginPath: pluginPath) { return true }
            if logForeign, pid != pid_t(recordedPID ?? 0) {
                sonataFileLog("Plugin port: pid \(pid) (\(exe)) holds a plugin port but isn't the plugin — leaving it")
            }
            return false
        }.sorted()
    }

    /// Reclaim ports held by this plugin's own stale processes before spawning
    /// a fresh one. SIGTERM first; if a holder ignores it (e.g. a hung
    /// graceful-shutdown waiting on keep-alive connections), escalate to
    /// SIGKILL, and don't return until they're gone (or a hard deadline). A
    /// boots-then-dies crash loop is almost always EADDRINUSE: the new process
    /// can't bind because the old one never released the port, so spawning
    /// before the port frees just reproduces the loop (#27 fix).
    private func reclaimStalePluginProcesses(name: String, pluginPath: String, recordedPID: Int?, ports: [Int]) {
        let stale = { self.stalePluginPIDs(pluginPath: pluginPath, recordedPID: recordedPID, ports: ports) }
        let initial = stalePluginPIDs(pluginPath: pluginPath, recordedPID: recordedPID, ports: ports, logForeign: true)
        guard !initial.isEmpty else { return }
        for pid in initial { kill(pid, SIGTERM) }

        // Poll for graceful exit; escalate to SIGKILL if still alive after the grace period.
        let graceDeadline = Date().addingTimeInterval(2.5)
        while Date() < graceDeadline {
            if stale().isEmpty { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let stubborn = stale()
        if !stubborn.isEmpty {
            sonataFileLog("Plugin \(name): \(stubborn.count) stale process(es) ignored SIGTERM after 2.5s — sending SIGKILL")
            for pid in stubborn { kill(pid, SIGKILL) }
        }

        // Wait for them to actually go so the fresh spawn can bind.
        let killDeadline = Date().addingTimeInterval(2.5)
        while Date() < killDeadline {
            if stale().isEmpty { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !stale().isEmpty {
            sonataFileLog("Plugin \(name): stale process still alive after SIGKILL + ~5s — spawn may fail with EADDRINUSE")
        }
    }

    /// `<plugin-dir>/<name>.port`, where a dynamic-port plugin publishes the
    /// port it actually bound.
    private func portFilePath(name: String, pluginPath: String) -> String {
        (pluginPath as NSString).appendingPathComponent("\(name).port")
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
            // Timeout: don't hang forever if the stop command doesn't exit
            let deadline = Date().addingTimeInterval(5)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if proc.isRunning {
                proc.terminate()
                sonataFileLog("Plugin stop: timed out after 5s, force terminated")
            } else if proc.terminationStatus == 0 {
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

        // Read the manifest before nuking the dir so uninstallPluginSkills
        // knows exactly which slugs to look for. Falls back to a full scan of
        // ~/.claude/skills for stale installs whose plugin dir is already gone.
        let manifest: PluginManifest? = path.flatMap { loadManifest(pluginDir: $0) }
        uninstallPluginSkills(pluginName: name, manifest: manifest)

        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM plugins WHERE name = ?", arguments: [name])
        }

        if let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }

        withLock { plugins.removeValue(forKey: name) }

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

    /// Read a plugin's stored config as a parsed object. Used by plugins that
    /// fetch their own config on boot via the plugin_config_get MCP action —
    /// see wiki `sonata/patterns/plugin-config.md`.
    ///
    /// Returns an empty dict if the plugin has no config set yet. Throws if
    /// the plugin row doesn't exist or the stored JSON is malformed (a
    /// malformed row would silently mask a corrupt install; loud failure
    /// makes it visible).
    func getConfig(name: String) async throws -> [String: Any] {
        let jsonStr: String? = try await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT config_json FROM plugins WHERE name = ?", arguments: [name])
        }
        guard let jsonStr else {
            throw ActionError.notFound("plugin \(name) not installed")
        }
        if jsonStr.isEmpty || jsonStr == "{}" {
            return [:]
        }
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ActionError.invalidParam("config_json", "plugin \(name) has malformed stored config_json")
        }
        return obj
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

        guard URL(string: wsURL) != nil else {
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
            // Every inbound peer DM lands here now. DMActionsInbound decides whether
            // to route directly (in_reply_to present → chain continuation) or create
            // a sonar_dm workerEvent (thread initiation). Legacy SONAR_MESSAGE path
            // deleted — no more mixed-version fallback.
            await DMActionsInbound.routePeerInbound(payload: payload, dbPool: dbPool)
            sonataFileLog("Plugin \(pluginName): routed peer DM messageId=\(payload["message_id"] as? String ?? "?")")
            return

        case "ack_forward":
            // Peer forwarded an ACK for a DM we originally sent. Update audit +
            // push dm_ack notification to the original local sender's SSE.
            await DMActionsInbound.routePeerAckForward(payload: payload, dbPool: dbPool)
            return

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
            withReplyLock { pendingReplies[messageId] = continuation }

            Task {
                try? await Task.sleep(for: .seconds(timeout))
                let pending = self.withReplyLock { self.pendingReplies.removeValue(forKey: messageId) }
                pending?.resume(returning: nil)
            }
        }
    }

    /// Resume a pending sonar_send continuation with the reply.
    private func resumeSendContinuation(messageId: String, answer: String) {
        let continuation = withReplyLock { pendingReplies.removeValue(forKey: messageId) }
        continuation?.resume(returning: answer)
    }

    /// Shutdown all managed plugins (called during app termination).
    func shutdown() async {
        let allPlugins = withLock { Array(plugins.values) }

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
        } else if let n = value as? NSNumber {
            // `JSONSerialization` returns `NSNumber` for ALL numerics + bools, and
            // `NSNumber(1) as? Bool` evaluates to `true` — so this branch MUST
            // come before `as? Bool` / `as? Int` / `as? Double`, otherwise JSON
            // `1` would silently re-emit as `true`. Disambiguate via CFTypeID.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                try c.encode(n.boolValue, forKey: key)
            } else if let i = n as? Int64, NSNumber(value: i) == n {
                try c.encode(i, forKey: key)
            } else {
                try c.encode(n.doubleValue, forKey: key)
            }
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
        } else if let n = value as? NSNumber {
            // See keyed-variant comment: NSNumber check MUST come first.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                try c.encode(n.boolValue)
            } else if let i = n as? Int64, NSNumber(value: i) == n {
                try c.encode(i)
            } else {
                try c.encode(n.doubleValue)
            }
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
        } else {
            try c.encodeNil()
        }
    }

    private static func encodeScalar(_ value: Any, in c: inout SingleValueEncodingContainer) throws {
        if value is NSNull {
            try c.encodeNil()
        } else if let n = value as? NSNumber {
            // See keyed-variant comment: NSNumber check MUST come first.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                try c.encode(n.boolValue)
            } else if let i = n as? Int64, NSNumber(value: i) == n {
                try c.encode(i)
            } else {
                try c.encode(n.doubleValue)
            }
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

