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
        actionRegistry: ActionRegistry,
        dbPool: DatabasePool,
        logger: Logger
    ) {
        // Legacy /mcp/:sessionKey routes (URL-path-keyed, bearer-validated).
        router.post("/mcp/:sessionKey") { request, context -> Response in
            return await handlePost(
                request: request, context: context,
                actionRegistry: actionRegistry, dbPool: dbPool, logger: logger
            )
        }
        router.get("/mcp/:sessionKey") { request, context -> Response in
            return await handleGet(
                request: request, context: context,
                actionRegistry: actionRegistry, dbPool: dbPool, logger: logger
            )
        }
        router.delete("/mcp/:sessionKey") { request, context -> Response in
            return await handleDelete(request: request, context: context)
        }
        router.on("/mcp/:sessionKey", method: .options) { _, _ -> Response in
            return Response(
                status: .noContent,
                headers: corsHeaders(allowMethod: "POST, GET, DELETE, OPTIONS")
            )
        }

        // Unified /mcp endpoint — bearer header IS the sessionKey.
        router.post("/mcp") { request, _ -> Response in
            return await handlePostNoPath(
                request: request,
                actionRegistry: actionRegistry, dbPool: dbPool, logger: logger
            )
        }
        router.get("/mcp") { request, _ -> Response in
            return await handleGetNoPath(
                request: request,
                actionRegistry: actionRegistry, dbPool: dbPool, logger: logger
            )
        }
        router.delete("/mcp") { request, _ -> Response in
            return await handleDeleteNoPath(request: request)
        }
        router.on("/mcp", method: .options) { _, _ -> Response in
            return Response(
                status: .noContent,
                headers: corsHeaders(allowMethod: "POST, GET, DELETE, OPTIONS")
            )
        }

        // Ad-hoc credential mint for external launchers.
        router.post("/api/mcp/issue-credential") { request, _ -> Response in
            return await issueCredential(request: request, logger: logger)
        }
    }

    // MARK: - issueCredential

    private static func issueCredential(request: Request, logger: Logger) async -> Response {
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
            let cred = try await MCPClaudeConfigWriter.writeAndMint(
                sessionKey: sessionKey, role: role, auth: MCPAuth.shared)
            let payload: [String: Any] = [
                "sessionKey": cred.sessionKey,
                "bearerToken": cred.bearerToken,
                "configPath": cred.configPath.path,
                "role": roleStr,
            ]
            let outData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            var buf = ByteBufferAllocator().buffer(capacity: outData.count)
            buf.writeBytes(outData)
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: buf))
        } catch {
            logger.warning("issueCredential failed for \(sessionKey): \(error)")
            return Response(status: .internalServerError)
        }
    }

    // MARK: - Bearer-keyed /mcp endpoint

    private static func deriveSessionKey(from headers: HTTPFields) -> (String, Bool) {
        guard let bearer = bearerToken(from: headers), !bearer.isEmpty else {
            return ("anon-\(randomHex8())", true)
        }
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
        actionRegistry: ActionRegistry,
        dbPool: DatabasePool,
        logger: Logger
    ) async -> Response {
        let (sessionKey, _) = deriveSessionKey(from: request.headers)
        guard MCPSessionKey.isValid(sessionKey) else {
            return jsonRPCErrorResponse(status: .badRequest, code: -32600,
                message: "Invalid session id (Authorization: Bearer ...)")
        }
        let bodyBuffer: ByteBuffer
        do {
            bodyBuffer = try await request.body.collect(upTo: 8 * 1024 * 1024)
        } catch {
            return jsonRPCErrorResponse(status: .badRequest, code: -32700, message: "Failed to read body")
        }
        let bodyData = Data(buffer: bodyBuffer)
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return jsonRPCErrorResponse(status: .badRequest, code: -32700, message: "Parse error")
        }
        let method = json["method"] as? String ?? ""
        if method.isEmpty {
            return jsonRPCErrorResponse(status: .badRequest, code: -32600, message: "Missing method")
        }
        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]

        let role = await inferRole(sessionKey: sessionKey, dbPool: dbPool)
        guard let responseJSON = await MCPHandshake.handle(
            method: method, id: id, params: params,
            sessionKey: sessionKey, role: role,
            actionRegistry: actionRegistry, dbPool: dbPool
        ) else {
            return Response(status: .accepted)
        }
        var headers = corsHeaders(allowMethod: "POST")
        headers[.contentType] = "application/json"
        var buffer = ByteBufferAllocator().buffer(capacity: responseJSON.utf8.count)
        buffer.writeString(responseJSON)
        return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: buffer))
    }

    private static func handleGetNoPath(
        request: Request,
        actionRegistry: ActionRegistry,
        dbPool: DatabasePool,
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
        await MCPConnections.shared.attach(sessionKey, writer: writer)
        writer.sendKeepAlive()

        var headers = corsHeaders(allowMethod: "GET")
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache, no-transform"
        headers[HTTPField.Name("Connection")!] = "keep-alive"
        headers[HTTPField.Name("X-Accel-Buffering")!] = "no"

        writer.setOnClose { [weak writer] in
            guard let writer else { return }
            Task {
                await MCPConnections.shared.detach(sessionKey, writer: writer)
                await MCPAuth.shared.revoke(sessionKey: sessionKey)
            }
        }
        let body = ResponseBody(asyncSequence: writer.stream)
        return Response(status: .ok, headers: headers, body: body)
    }

    private static func handleDeleteNoPath(request: Request) async -> Response {
        let (sessionKey, _) = deriveSessionKey(from: request.headers)
        guard MCPSessionKey.isValid(sessionKey) else {
            return Response(status: .badRequest)
        }
        // Detach any live writer for this key by finding it via a synthetic
        // "close-if-live" — MCPConnections owns the writer, so we can't detach
        // without a reference. Instead, force-close by walking liveSessionKeys.
        let live = await MCPConnections.shared.liveSessionKeys()
        if live.contains(sessionKey) {
            // The writer's own onClose callback will detach + revoke.
            // Alternatively, expose an explicit `closeSession(sessionKey)`:
            await MCPConnections.shared.closeIfLive(sessionKey)
        }
        await MCPAuth.shared.revoke(sessionKey: sessionKey)
        return Response(status: .noContent, headers: corsHeaders(allowMethod: "DELETE"))
    }

    // MARK: - Legacy /mcp/:sessionKey (URL-path-keyed)

    private static func handlePost<Context: RequestContext>(
        request: Request,
        context: Context,
        actionRegistry: ActionRegistry,
        dbPool: DatabasePool,
        logger: Logger
    ) async -> Response {
        guard let sessionKey = context.parameters.get("sessionKey"),
              MCPSessionKey.isValid(sessionKey) else {
            return Response(status: .badRequest)
        }
        let supplied = bearerToken(from: request.headers)
        let valid = await MCPAuth.shared.validate(sessionKey: sessionKey, supplied: supplied)
        guard valid else { return Response(status: .unauthorized) }

        let bodyBuffer: ByteBuffer
        do {
            bodyBuffer = try await request.body.collect(upTo: 8 * 1024 * 1024)
        } catch {
            return jsonRPCErrorResponse(status: .badRequest, code: -32700, message: "Failed to read body")
        }
        let bodyData = Data(buffer: bodyBuffer)
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return jsonRPCErrorResponse(status: .badRequest, code: -32700, message: "Parse error")
        }
        let method = json["method"] as? String ?? ""
        if method.isEmpty {
            return jsonRPCErrorResponse(status: .badRequest, code: -32600, message: "Missing method")
        }
        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]

        let role = await inferRole(sessionKey: sessionKey, dbPool: dbPool)
        guard let responseJSON = await MCPHandshake.handle(
            method: method, id: id, params: params,
            sessionKey: sessionKey, role: role,
            actionRegistry: actionRegistry, dbPool: dbPool
        ) else {
            return Response(status: .accepted)
        }
        var headers = corsHeaders(allowMethod: "POST")
        headers[.contentType] = "application/json"
        var buffer = ByteBufferAllocator().buffer(capacity: responseJSON.utf8.count)
        buffer.writeString(responseJSON)
        return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: buffer))
    }

    private static func handleGet<Context: RequestContext>(
        request: Request,
        context: Context,
        actionRegistry: ActionRegistry,
        dbPool: DatabasePool,
        logger: Logger
    ) async -> Response {
        guard let sessionKey = context.parameters.get("sessionKey"),
              MCPSessionKey.isValid(sessionKey) else {
            return Response(status: .badRequest)
        }
        let supplied = bearerToken(from: request.headers)
        let valid = await MCPAuth.shared.validate(sessionKey: sessionKey, supplied: supplied)
        guard valid else { return Response(status: .unauthorized) }

        let accept = request.headers[.accept] ?? ""
        guard accept.contains("text/event-stream") || accept.contains("*/*") else {
            return Response(status: .notAcceptable)
        }
        let writer = MCPSSEWriter()
        await MCPConnections.shared.attach(sessionKey, writer: writer)
        writer.sendKeepAlive()

        var headers = corsHeaders(allowMethod: "GET")
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache, no-transform"
        headers[HTTPField.Name("Connection")!] = "keep-alive"
        headers[HTTPField.Name("X-Accel-Buffering")!] = "no"

        writer.setOnClose { [weak writer] in
            guard let writer else { return }
            Task {
                await MCPConnections.shared.detach(sessionKey, writer: writer)
                await MCPAuth.shared.revoke(sessionKey: sessionKey)
            }
        }
        return Response(
            status: .ok, headers: headers,
            body: ResponseBody(asyncSequence: writer.stream)
        )
    }

    private static func handleDelete<Context: RequestContext>(
        request: Request,
        context: Context
    ) async -> Response {
        guard let sessionKey = context.parameters.get("sessionKey"),
              MCPSessionKey.isValid(sessionKey) else {
            return Response(status: .badRequest)
        }
        let supplied = bearerToken(from: request.headers)
        let valid = await MCPAuth.shared.validate(sessionKey: sessionKey, supplied: supplied)
        guard valid else { return Response(status: .unauthorized) }
        await MCPConnections.shared.closeIfLive(sessionKey)
        await MCPAuth.shared.revoke(sessionKey: sessionKey)
        return Response(status: .noContent, headers: corsHeaders(allowMethod: "DELETE"))
    }

    // MARK: - Helpers

    private static func bearerToken(from headers: HTTPFields) -> String? {
        guard let auth = headers[.authorization] else { return nil }
        guard auth.lowercased().hasPrefix("bearer ") else { return nil }
        return String(auth.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
    }

    static func corsHeaders(allowMethod: String) -> HTTPFields {
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
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: buffer))
    }

    /// Derive role from DB. Called from MCPHandshake as well.
    static func inferRole(sessionKey: String, dbPool: DatabasePool) async -> SessionRole {
        if sessionKey == "supervisor" { return .supervisor }
        do {
            let count = try await dbPool.read { db in
                try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM workers WHERE workerId = ?",
                    arguments: [sessionKey]) ?? 0
            }
            return count > 0 ? .worker : .interactive
        } catch {
            return .interactive
        }
    }
}
