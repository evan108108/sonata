import Foundation
import GRDB
import Hummingbird
import HummingbirdCore
import HTTPTypes

// MARK: - Action Registry

final class ActionRegistry: @unchecked Sendable {
    private var actions: [SonataAction] = []
    private var byName: [String: SonataAction] = [:]

    /// Register a batch of actions
    func register(_ newActions: [SonataAction]) {
        for action in newActions {
            actions.append(action)
            byName[action.name] = action
        }
    }

    /// Get action by name
    func action(named name: String) -> SonataAction? {
        byName[name]
    }

    /// All registered actions
    var allActions: [SonataAction] { actions }

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
    }

    /// Create a generic HTTP handler for any action
    private func makeHTTPHandler<Context: RequestContext>(
        action: SonataAction,
        dbPool: DatabasePool
    ) -> @Sendable (Request, Context) async throws -> Response {
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
                    dbPool: dbPool
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

    /// Extract parameters from an HTTP request
    private static func extractHTTPParams<Context: RequestContext>(
        from request: Request,
        context: Context,
        action: SonataAction
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
                }
            case .body:
                if let v = bodyDict[p.name] {
                    params[p.name] = coerceAny(v, to: p.type)
                }
            case .path:
                // Path params extracted from URL segments
                if let v = context.parameters.get(p.name, as: String.self) {
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
            if let arr = value as? [String] { return arr }
            if let s = value as? String { return s }
            return ""
        case .object:
            return value as? [String: Any] ?? [:]
        }
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
                dbPool: dbPool
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

struct MCPCallResponse: Encodable {
    let result: String
    var error: Bool = false
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

/// Build a JSON response from an arbitrary JSON-serializable Any value
/// (e.g. `[[String: Any]]` for MCP tool schemas). Mirrors `jsonResponse` but
/// uses `JSONSerialization` since the payload isn't `Encodable`.
private func anyJSONResponse(
    _ value: Any,
    status: HTTPResponse.Status = .ok
) -> Response {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
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
