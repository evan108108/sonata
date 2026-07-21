import Foundation
import GRDB
import Hummingbird
import HummingbirdCore
import HTTPTypes

// MARK: - Action Registry

final class ActionRegistry: @unchecked Sendable {
    private var actions: [SonataAction] = []
    private var byName: [String: SonataAction] = [:]
    private let lock = NSLock()
    var scheduler: SchedulerActor?
    var search: (any SearchService)?
    /// Live email handler (set after boot, once EmailHandler is constructed) so
    /// approval actions can re-dispatch a sender's pending_approval mail.
    var emailHandler: EmailHandler?

    /// Register a batch of actions. Re-registering an action with the same
    /// name replaces the existing entry (used when plugins re-discover on
    /// enable after connect).
    func register(_ newActions: [SonataAction]) {
        lock.lock()
        defer { lock.unlock() }
        let incomingNames = Set(newActions.map { $0.name })
        if !incomingNames.isEmpty {
            actions.removeAll { incomingNames.contains($0.name) }
        }
        for action in newActions {
            actions.append(action)
            byName[action.name] = action
        }
    }

    /// Unregister actions by name (used when plugins are disabled/uninstalled)
    func unregister(_ names: [String]) {
        lock.lock()
        defer { lock.unlock() }
        let nameSet = Set(names)
        actions.removeAll { nameSet.contains($0.name) }
        for name in names { byName.removeValue(forKey: name) }
    }

    /// Get action by name
    func action(named name: String) -> SonataAction? {
        lock.lock()
        defer { lock.unlock() }
        return byName[name]
    }

    /// All registered actions
    var allActions: [SonataAction] {
        lock.lock()
        defer { lock.unlock() }
        return actions
    }

    // MARK: - Mount HTTP Routes

    func mountHTTP<Context: RequestContext>(
        on router: Router<Context>,
        dbPool: DatabasePool
    ) {
        // Group actions by their group prefix for efficient registration
        let grouped = Dictionary(grouping: actions.filter { !$0.mcpOnly }) { $0.group }

        for (groupPath, groupActions) in grouped {
            let api = router.group(RouterPath(groupPath))
            for action in groupActions {
                let handler: @Sendable (Request, Context) async throws -> Response =
                    makeHTTPHandler(action: action, dbPool: dbPool)
                let path = RouterPath(action.path)
                switch action.method {
                case .get:    api.get(path, use: handler)
                case .post:   api.post(path, use: handler)
                case .patch:  api.patch(path, use: handler)
                case .delete: api.delete(path, use: handler)
                }
            }
        }

        // Wildcard fallback for plugin proxy routes. Plugins enabled AFTER boot
        // add actions to `actions` but cannot retroactively register routes on
        // the Hummingbird trie. The wildcard catches `/api/plugins/<name>/**`
        // and dispatches at request-time against the current `actions` list.
        //
        // The capture is named `name` (not `plugin`) on purpose: Hummingbird
        // rejects two captures with different names at the same trie position,
        // and PluginActions already uses `{name}` for /api/plugins/{name}/...
        // management routes. Sharing the capture name lets `**` slot in as a
        // sibling of `enable`/`disable`/`config`. Literals (priority 0) still
        // win over the recursive wildcard (priority -5), so management routes
        // and boot-time plugin per-action routes are unaffected.
        let pluginWildcard: RouterPath = "/api/plugins/:name/**"
        router.get(pluginWildcard, use: makePluginWildcardHandler(method: .get, dbPool: dbPool))
        router.post(pluginWildcard, use: makePluginWildcardHandler(method: .post, dbPool: dbPool))
        router.patch(pluginWildcard, use: makePluginWildcardHandler(method: .patch, dbPool: dbPool))
        router.delete(pluginWildcard, use: makePluginWildcardHandler(method: .delete, dbPool: dbPool))
    }

    /// Build the wildcard handler for `/api/plugins/:plugin/**`. The handler
    /// resolves the matching SonataAction at request-time so runtime-enabled
    /// plugins become HTTP-reachable without a restart.
    private func makePluginWildcardHandler<Context: RequestContext>(
        method: ActionMethod,
        dbPool: DatabasePool
    ) -> @Sendable (Request, Context) async throws -> Response {
        let scheduler = self.scheduler
        let search = self.search
        let emailHandler = self.emailHandler
        let registry = self
        return { request, context in
            guard let pluginName = context.parameters.get("name", as: String.self) else {
                return errorResponse("Missing plugin name in path", status: .badRequest)
            }
            let segments = context.parameters.getCatchAll().map(String.init)
            let subPath = "/" + segments.joined(separator: "/")

            guard let resolved = registry.resolvePluginAction(
                plugin: pluginName, subPath: subPath, method: method
            ) else {
                return pluginActionNotFoundResponse(plugin: pluginName, subPath: subPath)
            }
            let action = resolved.action
            let captures = resolved.pathCaptures

            do {
                let params = try await Self.extractHTTPParams(
                    from: request,
                    context: context,
                    action: action,
                    pathOverrides: captures
                )

                for p in action.params where p.required {
                    if params[p.name] == nil, p.defaultValue == nil {
                        return errorResponse(
                            "Missing required parameter: \(p.name)",
                            status: .badRequest
                        )
                    }
                }

                var finalParams = params
                for p in action.params {
                    if finalParams[p.name] == nil, let d = p.defaultValue {
                        finalParams[p.name] = d
                    }
                }
                // Path captures that aren't declared as action params still need
                // to flow into ActionContext so proxy handlers can substitute
                // `:key` placeholders into the upstream target URL.
                for (key, value) in captures where finalParams[key] == nil {
                    finalParams[key] = value
                }

                let ctx = ActionContext(
                    params: ActionParams(finalParams),
                    dbPool: dbPool,
                    scheduler: scheduler,
                    search: search,
                    emailHandler: emailHandler
                )
                let result = try await action.handler(ctx)
                return jsonResponse(AnyEncodable(result))
            } catch let error as ActionError {
                return errorResponse(error.localizedDescription, status: error.httpStatus)
            } catch {
                return errorResponse(
                    "Internal error: \(error.localizedDescription)",
                    status: .internalServerError
                )
            }
        }
    }

    /// Find the plugin action registered under `/api/plugins/<plugin>` whose
    /// path template matches `subPath`. Exact matches win; if none, fall back
    /// to segment-wise matching that captures `:name` placeholders.
    private func resolvePluginAction(
        plugin: String,
        subPath: String,
        method: ActionMethod
    ) -> (action: SonataAction, pathCaptures: [String: String])? {
        let groupPrefix = "/api/plugins/\(plugin)"
        lock.lock()
        let snapshot = actions
        lock.unlock()

        // Pass 1: exact path match (covers paths without `:name` placeholders,
        // which is what every Studio action uses).
        for action in snapshot
        where action.group == groupPrefix && action.method == method && action.path == subPath {
            return (action, [:])
        }

        // Pass 2: segment-wise match with `:name` captures. Supports plugin
        // actions whose path templates contain path parameters (e.g.
        // `/message/:id/forward`).
        let requestSegments = subPath.split(separator: "/").map(String.init)
        for action in snapshot
        where action.group == groupPrefix && action.method == method {
            let actionSegments = action.path.split(separator: "/").map(String.init)
            guard actionSegments.count == requestSegments.count else { continue }
            var captures: [String: String] = [:]
            var matched = true
            for (a, r) in zip(actionSegments, requestSegments) {
                if a.hasPrefix(":") {
                    captures[String(a.dropFirst())] = r
                } else if a != r {
                    matched = false
                    break
                }
            }
            if matched {
                return (action, captures)
            }
        }
        return nil
    }

    /// Create a generic HTTP handler for any action
    private func makeHTTPHandler<Context: RequestContext>(
        action: SonataAction,
        dbPool: DatabasePool
    ) -> @Sendable (Request, Context) async throws -> Response {
        let scheduler = self.scheduler
        let search = self.search
        let emailHandler = self.emailHandler
        return { request, context in
            do {
                // Extract parameters based on HTTP method and param source
                let params = try await Self.extractHTTPParams(
                    from: request,
                    context: context,
                    action: action
                )

                // Validate required params (defaults are filled next)
                for p in action.params where p.required {
                    if params[p.name] == nil, p.defaultValue == nil {
                        return errorResponse(
                            "Missing required parameter: \(p.name)",
                            status: .badRequest
                        )
                    }
                }

                // Apply defaults
                var finalParams = params
                for p in action.params {
                    if finalParams[p.name] == nil, let d = p.defaultValue {
                        finalParams[p.name] = d
                    }
                }

                let ctx = ActionContext(
                    params: ActionParams(finalParams),
                    dbPool: dbPool,
                    scheduler: scheduler,
                    search: search,
                    emailHandler: emailHandler
                )
                let result = try await action.handler(ctx)
                return jsonResponse(AnyEncodable(result))
            } catch let error as ActionError {
                return errorResponse(error.localizedDescription, status: error.httpStatus)
            } catch {
                return errorResponse(
                    "Internal error: \(error.localizedDescription)",
                    status: .internalServerError
                )
            }
        }
    }

    /// Extract parameters from an HTTP request.
    ///
    /// `pathOverrides` supplies pre-captured path parameters (used by the
    /// runtime plugin-wildcard dispatcher, which extracts `:name` segments
    /// itself rather than relying on Hummingbird's per-action route).
    private static func extractHTTPParams<Context: RequestContext>(
        from request: Request,
        context: Context,
        action: SonataAction,
        pathOverrides: [String: String] = [:]
    ) async throws -> [String: Any] {
        var params: [String: Any] = [:]
        let queryParams = request.uri.queryParameters

        // For POST/PATCH/DELETE with body, decode JSON body
        var bodyDict: [String: Any] = [:]
        if action.method == .post || action.method == .patch || action.method == .delete {
            if let buffer = try? await request.body.collect(upTo: .max),
               let json = try? JSONSerialization.jsonObject(with: Data(buffer: buffer)) as? [String: Any] {
                bodyDict = json
            }
        }

        for p in action.params {
            let source: ParamSource = p.source == .auto
                ? (action.method == .get || action.method == .delete ? .query : .body)
                : p.source

            switch source {
            case .query, .auto:
                if let v = queryParams[Substring(p.name)] {
                    params[p.name] = coerce(String(v), to: p.type)
                } else if let v = bodyDict[p.name] {
                    // Declared query-side, but the caller sent a JSON body. Accept
                    // it: a POST whose param happens to be declared .query would
                    // otherwise reject a perfectly well-formed body (this is what
                    // broke `mem archive` — the CLI POSTs {"id":…} to an endpoint
                    // that only read ?id=).
                    params[p.name] = coerceAny(v, to: p.type)
                }
            case .body:
                if let v = bodyDict[p.name] {
                    params[p.name] = coerceAny(v, to: p.type)
                } else if let v = queryParams[Substring(p.name)] {
                    // Same leniency in the other direction.
                    params[p.name] = coerce(String(v), to: p.type)
                }
            case .path:
                // Path params extracted from URL segments. Overrides win so
                // the wildcard dispatcher can inject captures it parsed itself.
                if let v = pathOverrides[p.name] {
                    params[p.name] = v
                } else if let v = context.parameters.get(p.name, as: String.self) {
                    params[p.name] = v
                }
            }
        }

        return params
    }

    /// Coerce a string value to the expected type
    private static func coerce(_ value: String, to type: ParamType) -> Any {
        switch type {
        case .string:      return value
        case .number:      return Double(value) ?? value
        case .integer:     return Int(value) ?? value
        case .boolean:     return ["true", "1", "yes"].contains(value.lowercased())
        case .stringArray: return value  // ActionParams.stringArray() handles splitting
        case .object:      return value  // Caller must parse
        }
    }

    /// Coerce an Any value (from JSON body) to the expected type
    private static func coerceAny(_ value: Any, to type: ParamType) -> Any {
        switch type {
        case .string:      return (value as? String) ?? "\(value)"
        case .number:      return (value as? Double) ?? (value as? Int).map(Double.init) ?? 0.0
        case .integer:     return (value as? Int) ?? (value as? Double).map(Int.init) ?? 0
        case .boolean:     return (value as? Bool) ?? false
        case .stringArray:
            if let arr = value as? [String] { return normalizeStringArray(arr) }
            if let arr = value as? [Any] {
                // Plain string array → normalize. Mixed/object array → pass
                // through raw so plugins that accept richer shapes (e.g.
                // `default_tracks: [{name, title}]`) aren't silently flattened
                // to an empty list.
                let asStrings = arr.compactMap { $0 as? String }
                if asStrings.count == arr.count {
                    return normalizeStringArray(asStrings)
                }
                return arr
            }
            if let s = value as? String { return s }  // stringArray() will parse it
            return ""
        case .object:
            return value as? [String: Any] ?? [:]
        }
    }

    /// Flatten string-array elements that are themselves JSON-encoded arrays.
    /// Why: callers occasionally pass `["[\"id1\"]"]` (an array containing a
    /// JSON-encoded array string) instead of `["id1"]`. Without flattening,
    /// equality comparisons against the inner ids never match (e.g. blockedBy
    /// auto-unblock).
    private static func normalizeStringArray(_ arr: [String]) -> [String] {
        var result: [String] = []
        for s in arr {
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["),
               let data = trimmed.data(using: .utf8),
               let inner = try? JSONDecoder().decode([String].self, from: data) {
                result.append(contentsOf: inner)
            } else if !trimmed.isEmpty {
                result.append(trimmed)
            }
        }
        return result
    }

    // MARK: - MCP Tool Schemas

    /// Generate all MCP tool definitions for GET /api/mcp/tools
    func mcpToolSchemas() -> [[String: Any]] {
        actions.filter { !$0.httpOnly }
            .map { $0.mcpToolSchema() }
    }

    // MARK: - MCP Tool Execution

    /// Execute an MCP tool call: POST /api/mcp/call
    func executeMCPTool(
        name: String,
        args: [String: Any],
        dbPool: DatabasePool
    ) async -> (success: Bool, result: String) {
        guard let action = byName[name] else {
            return (false, "Unknown tool: \(name)")
        }

        do {
            // Apply defaults
            var finalArgs: [String: Any] = args
            for p in action.params {
                if finalArgs[p.name] == nil, let d = p.defaultValue {
                    finalArgs[p.name] = d
                }
            }

            let ctx = ActionContext(
                params: ActionParams(finalArgs),
                dbPool: dbPool,
                scheduler: scheduler,
                search: search,
                emailHandler: emailHandler
            )

            let result = try await action.handler(ctx)

            // Use MCP formatter if available, otherwise JSON
            if let formatter = action.mcpFormatter {
                return (true, formatter(result))
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                let data = try encoder.encode(AnyEncodable(result))
                return (true, String(data: data, encoding: .utf8) ?? "{}")
            }
        } catch let error as ActionError {
            return (false, error.localizedDescription)
        } catch {
            return (false, "Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Meta Routes (mounted separately)

    /// Register the /api/mcp/tools and /api/mcp/call routes
    func mountMetaRoutes<Context: RequestContext>(
        on router: Router<Context>,
        dbPool: DatabasePool
    ) {
        let registry = self

        // GET /api/mcp/tools — returns all tool schemas
        router.get("/api/mcp/tools") { _, _ -> Response in
            let schemas = registry.mcpToolSchemas()
            return anyJSONResponse(schemas)
        }

        // POST /api/mcp/call — execute a tool by name
        router.post("/api/mcp/call") { request, context -> Response in
            guard let body = try? await request.decode(
                as: MCPCallRequest.self, context: context
            ) else {
                return errorResponse("Invalid request body — need {name, arguments}")
            }

            let (success, result) = await registry.executeMCPTool(
                name: body.name,
                args: body.arguments ?? [:],
                dbPool: dbPool
            )

            if success {
                return jsonResponse(MCPCallResponse(result: result))
            } else {
                return jsonResponse(
                    MCPCallResponse(result: result, error: true),
                    status: .badRequest
                )
            }
        }

        // GET /api/mcp/actions — debug endpoint, lists all actions with metadata
        router.get("/api/mcp/actions") { _, _ -> Response in
            let list: [[String: Any]] = registry.allActions.map { action in
                [
                    "name": action.name,
                    "method": action.method.rawValue,
                    "path": action.fullPath,
                    "params": action.params.map { p -> [String: Any] in
                        ["name": p.name, "type": p.type.rawValue, "required": p.required]
                    },
                    "httpOnly": action.httpOnly,
                    "mcpOnly": action.mcpOnly,
                ]
            }
            return anyJSONResponse(list)
        }
    }
}

// MARK: - Supporting Types

struct MCPCallRequest: Decodable, @unchecked Sendable {
    let name: String
    let arguments: [String: Any]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        // Decode arguments as raw JSON via the shared AnyCodable (defined in EntityRoutes.swift)
        if let argsData = try? container.decode(
            [String: AnyCodable].self, forKey: .arguments
        ) {
            arguments = argsData.mapValues { $0.value }
        } else {
            arguments = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, arguments
    }
}

/// Response envelope for `POST /api/mcp/call`.
///
/// `result` arrives here as a JSON-encoded string (executeMCPTool returned it
/// from JSONEncoder). Prior versions emitted this string verbatim, which meant
/// every raw HTTP consumer received `{"result": "{\"...\": ...}"}` — a nested
/// JSON payload wrapped inside a JSON-encoded string. Callers had to
/// `JSON.parse` twice.
///
/// This custom encode fixes that: when the string parses as JSON, `result`
/// is emitted as the nested value (object / array / number / etc.). When it
/// doesn't parse (bare error strings from executeMCPTool on failure), the
/// string is emitted as-is so error messages still read cleanly.
///
/// Consumers all had defensive `typeof result === "string"` parsing so this
/// change is backward-safe for them. The one consumer that needed an update
/// alongside this change was the `mem-server.ts` stdio proxy, which passed
/// `result.result` straight through as MCP text content. That proxy was
/// deleted on 2026-07-21 (Phase D — see `ensureGlobalMCPServers`), so the
/// only remaining consumers are raw HTTP callers, which want the nested
/// value this encode produces.
struct MCPCallResponse: Encodable {
    let result: String
    var error: Bool = false

    enum CodingKeys: String, CodingKey {
        case result, error
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(error, forKey: .error)
        // Try to unwrap the pre-serialized JSON. On success emit as nested;
        // on failure (bare error text) emit as the raw string.
        if let data = result.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            try c.encode(AnyJSONEncodable(parsed), forKey: .result)
        } else {
            try c.encode(result, forKey: .result)
        }
    }
}

/// Type-erased Encodable wrapper
struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        _encode = { encoder in try value.encode(to: encoder) }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

// MARK: - Helpers

/// 404 envelope returned by the `/api/plugins/:plugin/**` wildcard fallback
/// when no SonataAction matches the requested sub-path.
private func pluginActionNotFoundResponse(plugin: String, subPath: String) -> Response {
    struct PluginActionNotFound: Encodable {
        let error = "plugin_action_not_found"
        let plugin: String
        let path: String
    }
    return jsonResponse(
        PluginActionNotFound(plugin: plugin, path: subPath),
        status: .notFound
    )
}

/// Build a JSON response from an arbitrary JSON-serializable Any value
/// (e.g. `[[String: Any]]` for MCP tool schemas). Mirrors `jsonResponse` but
/// uses `JSONSerialization` since the payload isn't `Encodable`.
private func anyJSONResponse(
    _ value: Any,
    status: HTTPResponse.Status = .ok
) -> Response {
    // SafeJSON guards against a scalar top-level (uncatchable NSException →
    // process crash). Callers pass containers today; the `Any` signature must
    // not be a landmine for a future caller.
    let data = SafeJSON.data(withJSONObject: value, options: [.sortedKeys])
        ?? Data("{\"error\":\"encoding failed\"}".utf8)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("Access-Control-Allow-Origin")!] = "*"
    headers[HTTPField.Name("Access-Control-Allow-Headers")!] = "Content-Type"
    headers[HTTPField.Name("Access-Control-Allow-Methods")!] = "GET, POST, PUT, DELETE, OPTIONS"
    return Response(
        status: status,
        headers: headers,
        body: .init(byteBuffer: .init(data: data))
    )
}
