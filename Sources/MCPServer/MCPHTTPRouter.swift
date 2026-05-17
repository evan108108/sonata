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
    }

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
            Task { await state.detachSSE(writer) }
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
