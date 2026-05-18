import Foundation
import GRDB
import Hummingbird
import HummingbirdCore
import HTTPTypes
import Logging
import NIOCore

enum MCPHTTPRouter {
    static func register<Context: RequestContext>(
        on router: Router<Context>,
        registry: MCPSessionRegistry,
        actionRegistry: ActionRegistry,
        dbPool: DatabasePool,
        logger: Logger
    ) {
        router.post("/mcp/:sessionKey") { request, context -> Response in
            return await handlePost(
                request: request,
                context: context,
                registry: registry,
                logger: logger
            )
        }
        router.get("/mcp/:sessionKey") { request, context -> Response in
            return await handleGet(
                request: request,
                context: context,
                registry: registry,
                logger: logger
            )
        }
        router.delete("/mcp/:sessionKey") { request, context -> Response in
            return await handleDelete(
                request: request,
                context: context,
                registry: registry
            )
        }
        router.on("/mcp/:sessionKey", method: .options) { _, _ -> Response in
            return Response(
                status: .noContent,
                headers: corsHeaders(allowMethod: "POST, GET, DELETE, OPTIONS")
            )
        }

        // New unified MCP endpoint — bearer header IS the sessionKey.
        // See ~/.sonata/wiki/sonata/mcp-identity.md for the design.
        //
        // - sona-launched sessions: SONA_SESSION_ID env var is substituted by
        //   claude's HTTP MCP client into "Authorization: Bearer <uuid>".
        //   That uuid is the sessionKey, no pre-registration needed.
        // - non-sona sessions (env var not set): bearer arrives empty OR as
        //   the literal "${SONA_SESSION_ID}". We mint a temp anon-XXX
        //   sessionKey and (on SSE attach) push a channel notification
        //   asking the session to call sonata_identify.
        router.post("/mcp") { request, _ -> Response in
            return await handlePostNoPath(
                request: request, registry: registry, logger: logger)
        }
        router.get("/mcp") { request, _ -> Response in
            return await handleGetNoPath(
                request: request, registry: registry, logger: logger)
        }
        router.delete("/mcp") { request, _ -> Response in
            return await handleDeleteNoPath(
                request: request, registry: registry)
        }
        router.on("/mcp", method: .options) { _, _ -> Response in
            return Response(
                status: .noContent,
                headers: corsHeaders(allowMethod: "POST, GET, DELETE, OPTIONS")
            )
        }

        // Phase C.5 — ad-hoc credential mint for external launchers
        // (sona-launch wrapper, per-project .mcp.json, etc.). Body:
        // {"sessionKey":"...", "role":"interactive|worker|supervisor"}.
        // Returns the per-session MCP config path + bearer.
        router.post("/api/mcp/issue-credential") { request, _ -> Response in
            return await issueCredential(
                request: request,
                registry: registry,
                logger: logger
            )
        }

    }

    private static func issueCredential(
        request: Request,
        registry: MCPSessionRegistry,
        logger: Logger
    ) async -> Response {
        // Localhost-only guard. We're bound to 127.0.0.1 only at the
        // Hummingbird layer, so this is belt-and-suspenders for callers
        // that go through proxies.
        let hostRaw = request.headers[HTTPField.Name("host")!] ?? ""
        let host = hostRaw.split(separator: ":").first.map(String.init) ?? hostRaw
        if !host.isEmpty && host != "localhost" && host != "127.0.0.1" && host != "::1" {
            return Response(status: .forbidden)
        }
        let bodyBuffer: ByteBuffer
        do {
            bodyBuffer = try await request.body.collect(upTo: 4 * 1024)
        } catch {
            return Response(status: .badRequest)
        }
        let data = Data(buffer: bodyBuffer)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionKey = json["sessionKey"] as? String,
              MCPSessionKey.isValid(sessionKey) else {
            return Response(status: .badRequest)
        }
        let roleStr = (json["role"] as? String)?.lowercased() ?? "interactive"
        let role: SessionRole = {
            switch roleStr {
            case "worker": return .worker
            case "supervisor": return .supervisor
            default: return .interactive
            }
        }()
        do {
            let cred = try await MCPClaudeConfigWriter.writeAndRegister(
                sessionKey: sessionKey, role: role, registry: registry)
            let payload: [String: Any] = [
                "sessionKey": cred.sessionKey,
                "bearerToken": cred.bearerToken,
                "configPath": cred.configPath.path,
                "role": roleStr,
            ]
            let outData = try JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys])
            var buf = ByteBufferAllocator().buffer(capacity: outData.count)
            buf.writeBytes(outData)
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            return Response(status: .ok, headers: headers,
                body: ResponseBody(byteBuffer: buf))
        } catch {
            logger.warning("issueCredential failed for \(sessionKey): \(error)")
            return Response(status: .internalServerError)
        }
    }

    // MARK: - New /mcp endpoint (bearer-as-sessionKey)
    //
    // Derives the sessionKey from the bearer header. Empty / literal-
    // env-var bearers get a fresh "anon-<hex>" sessionKey; the SSE
    // attach handler queues a handshake notification telling the
    // session to call sonata_identify.

    /// Returns either:
    ///   - the bearer value verbatim (treated as the sessionKey for
    ///     sona-launched sessions)
    ///   - a fresh "anon-<8hex>" id when the bearer is missing, empty,
    ///     or the literal "${SONA_SESSION_ID}" (env var not set →
    ///     claude didn't substitute)
    /// `needsHandshake` is true in the anon path.
    private static func deriveSessionKey(
        from headers: HTTPFields
    ) -> (sessionKey: String, needsHandshake: Bool) {
        guard let bearer = bearerToken(from: headers), !bearer.isEmpty else {
            return ("anon-\(randomHex8())", true)
        }
        // Claude leaves unsubstituted env vars as the literal "${VAR}".
        if bearer.hasPrefix("${") && bearer.hasSuffix("}") {
            return ("anon-\(randomHex8())", true)
        }
        return (bearer, false)
    }

    private static func randomHex8() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        for i in 0..<4 { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func handlePostNoPath(
        request: Request,
        registry: MCPSessionRegistry,
        logger: Logger
    ) async -> Response {
        let (sessionKey, needsHandshake) = deriveSessionKey(from: request.headers)
        guard MCPSessionKey.isValid(sessionKey) else {
            return jsonRPCErrorResponse(
                status: .badRequest, code: -32600,
                message: "Invalid session id (Authorization: Bearer ...)")
        }
        let bodyBuffer: ByteBuffer
        do {
            bodyBuffer = try await request.body.collect(upTo: 64 * 1024)
        } catch {
            return jsonRPCErrorResponse(status: .badRequest, code: -32700,
                message: "Failed to read body")
        }
        let bodyData = Data(buffer: bodyBuffer)
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return jsonRPCErrorResponse(status: .badRequest, code: -32700,
                message: "Parse error")
        }
        let method = json["method"] as? String ?? ""
        if method.isEmpty {
            return jsonRPCErrorResponse(status: .badRequest, code: -32600,
                message: "Missing method")
        }
        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]

        let state = await registry.getOrCreate(sessionKey) {
            needsHandshake ? .interactive
                : await inferRole(sessionKey: sessionKey, dbPool: registry.dbPool)
        }
        guard let responseJSON = await state.handle(
                method: method, id: id, params: params) else {
            return Response(status: .accepted)
        }
        var headers = corsHeaders(allowMethod: "POST")
        headers[.contentType] = "application/json"
        var buffer = ByteBufferAllocator().buffer(capacity: responseJSON.utf8.count)
        buffer.writeString(responseJSON)
        return Response(status: .ok, headers: headers,
            body: ResponseBody(byteBuffer: buffer))
    }

    private static func handleGetNoPath(
        request: Request,
        registry: MCPSessionRegistry,
        logger: Logger
    ) async -> Response {
        let (sessionKey, _) = deriveSessionKey(from: request.headers)
        guard MCPSessionKey.isValid(sessionKey) else {
            return Response(status: .badRequest)
        }
        let accept = request.headers[.accept] ?? ""
        guard accept.contains("text/event-stream") || accept.contains("*/*") else {
            return Response(status: .notAcceptable)
        }
        let writer = MCPSSEWriter()
        let state = await registry.getOrCreate(sessionKey) {
            await inferRole(sessionKey: sessionKey, dbPool: registry.dbPool)
        }
        await state.attachSSE(writer)
        writer.sendKeepAlive()

        var headers = corsHeaders(allowMethod: "GET")
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache, no-transform"
        headers[HTTPField.Name("Connection")!] = "keep-alive"
        headers[HTTPField.Name("X-Accel-Buffering")!] = "no"

        // Single eviction rule for the whole system: when this SSE
        // stream's HTTP connection closes (peer disconnect, network
        // drop, claude exits, anything), fully evict the registry
        // entry. No timers, no age, no PID checks. "Connection up +
        // sessionKey from bearer" == registered. Connection gone ==
        // not registered.
        writer.setOnClose { [weak writer] in
            guard let writer else { return }
            Task {
                await state.detachSSE(writer)
                await registry.evict(sessionKey)
            }
        }

        let body = ResponseBody(asyncSequence: writer.stream)
        return Response(status: .ok, headers: headers, body: body)
    }

    private static func handleDeleteNoPath(
        request: Request,
        registry: MCPSessionRegistry
    ) async -> Response {
        let (sessionKey, _) = deriveSessionKey(from: request.headers)
        guard MCPSessionKey.isValid(sessionKey) else {
            return Response(status: .badRequest)
        }
        await registry.evict(sessionKey)
        return Response(status: .noContent,
            headers: corsHeaders(allowMethod: "DELETE"))
    }

    // MARK: - Legacy /mcp/:sessionKey endpoint (URL-path-keyed, bearer-validated)

    private static func handlePost<Context: RequestContext>(
        request: Request,
        context: Context,
        registry: MCPSessionRegistry,
        logger: Logger
    ) async -> Response {
        guard let sessionKey = context.parameters.get("sessionKey"),
              MCPSessionKey.isValid(sessionKey) else {
            return Response(status: .badRequest)
        }
        let supplied = bearerToken(from: request.headers)
        let valid = await registry.validateBearer(
            sessionKey: sessionKey, suppliedToken: supplied)
        guard valid else {
            return Response(status: .unauthorized)
        }
        let bodyBuffer: ByteBuffer
        do {
            bodyBuffer = try await request.body.collect(upTo: 64 * 1024)
        } catch {
            return jsonRPCErrorResponse(status: .badRequest, code: -32700,
                message: "Failed to read body")
        }
        let bodyData = Data(buffer: bodyBuffer)
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return jsonRPCErrorResponse(status: .badRequest, code: -32700,
                message: "Parse error")
        }
        let method = json["method"] as? String ?? ""
        if method.isEmpty {
            return jsonRPCErrorResponse(status: .badRequest, code: -32600,
                message: "Missing method")
        }
        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]

        let state = await registry.getOrCreate(sessionKey) {
            await inferRole(sessionKey: sessionKey, dbPool: registry.dbPool)
        }
        guard let responseJSON = await state.handle(
                method: method, id: id, params: params) else {
            return Response(status: .accepted)
        }
        var headers = corsHeaders(allowMethod: "POST")
        headers[.contentType] = "application/json"
        var buffer = ByteBufferAllocator().buffer(capacity: responseJSON.utf8.count)
        buffer.writeString(responseJSON)
        return Response(status: .ok, headers: headers,
            body: ResponseBody(byteBuffer: buffer))
    }

    private static func handleGet<Context: RequestContext>(
        request: Request,
        context: Context,
        registry: MCPSessionRegistry,
        logger: Logger
    ) async -> Response {
        guard let sessionKey = context.parameters.get("sessionKey"),
              MCPSessionKey.isValid(sessionKey) else {
            return Response(status: .badRequest)
        }
        let supplied = bearerToken(from: request.headers)
        let valid = await registry.validateBearer(
            sessionKey: sessionKey, suppliedToken: supplied)
        guard valid else {
            return Response(status: .unauthorized)
        }
        let accept = request.headers[.accept] ?? ""
        guard accept.contains("text/event-stream") || accept.contains("*/*") else {
            return Response(status: .notAcceptable)
        }

        let writer = MCPSSEWriter()
        let state = await registry.getOrCreate(sessionKey) {
            await inferRole(sessionKey: sessionKey, dbPool: registry.dbPool)
        }
        await state.attachSSE(writer)
        writer.sendKeepAlive()

        var headers = corsHeaders(allowMethod: "GET")
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache, no-transform"
        headers[HTTPField.Name("Connection")!] = "keep-alive"
        headers[HTTPField.Name("X-Accel-Buffering")!] = "no"

        writer.setOnClose { [weak writer] in
            guard let writer else { return }
            Task {
                await state.detachSSE(writer)
                await registry.evict(sessionKey)
            }
        }
        let body = ResponseBody(asyncSequence: writer.stream)
        return Response(status: .ok, headers: headers, body: body)
    }

    private static func handleDelete<Context: RequestContext>(
        request: Request,
        context: Context,
        registry: MCPSessionRegistry
    ) async -> Response {
        guard let sessionKey = context.parameters.get("sessionKey"),
              MCPSessionKey.isValid(sessionKey) else {
            return Response(status: .badRequest)
        }
        let supplied = bearerToken(from: request.headers)
        let valid = await registry.validateBearer(
            sessionKey: sessionKey, suppliedToken: supplied)
        guard valid else {
            return Response(status: .unauthorized)
        }
        await registry.evict(sessionKey)
        return Response(status: .noContent,
            headers: corsHeaders(allowMethod: "DELETE"))
    }

    private static func bearerToken(from headers: HTTPFields) -> String? {
        guard let auth = headers[.authorization] else { return nil }
        guard auth.lowercased().hasPrefix("bearer ") else { return nil }
        return String(auth.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
    }

    private static func corsHeaders(allowMethod: String) -> HTTPFields {
        var h = HTTPFields()
        h[.accessControlAllowOrigin] = "http://localhost:3211"
        h[HTTPField.Name("Access-Control-Allow-Methods")!] = "POST, GET, DELETE, OPTIONS"
        h[HTTPField.Name("Access-Control-Allow-Headers")!] = "Authorization, Content-Type, Accept"
        h[HTTPField.Name("Access-Control-Max-Age")!] = "600"
        return h
    }

    private static func jsonRPCErrorResponse(
        status: HTTPResponse.Status, code: Int, message: String
    ) -> Response {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNull(),
            "error": ["code": code, "message": message],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        var headers = corsHeaders(allowMethod: "POST")
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers,
            body: ResponseBody(byteBuffer: buffer))
    }

    private static func inferRole(
        sessionKey: String, dbPool: DatabasePool
    ) async -> SessionRole {
        if sessionKey == "supervisor" { return .supervisor }
        do {
            let count = try await dbPool.read { db in
                try Int.fetchOne(db,
                    sql: "SELECT COUNT(*) FROM workers WHERE workerId = ?",
                    arguments: [sessionKey]) ?? 0
            }
            return count > 0 ? .worker : .interactive
        } catch {
            return .interactive
        }
    }
}
