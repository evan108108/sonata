// Tools/MCPHTTPSmokeTest/main.swift
//
// Phase A smoke test for the in-app MCP HTTP+SSE server. Verifies that
// `notifications/claude/channel` works over Streamable HTTP (SSE) to a real
// Claude Code session before we commit to the §4 production implementation.
//
// Procedure (see plan §4 line 2365):
//   1. swift run MCPHTTPSmokeTest &   (binds 127.0.0.1:9999)
//   2. ~/.claude.json: mcpServers.sonata-test = { type: "http", url: "http://localhost:9999/mcp/test" }
//   3. Launch claude; observe whether a <channel source="sonata-test">...</channel>
//      block appears within ~3s (the GET handler emits one after 2s).
//   4. If yes → green light for Phase B. If no → §10 R1 fallback.

import Foundation
import Hummingbird
import HummingbirdCore
import NIOCore
import HTTPTypes

let initJSON = """
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{},"experimental":{"claude/channel":{}}},"serverInfo":{"name":"sonata-test","version":"0.0.1"},"instructions":"Phase A smoke-test server."}}
"""

func idJSON(_ id: Any?) -> String {
    if let i = id as? Int { return String(i) }
    if let s = id as? String { return "\"\(s)\"" }
    return "null"
}

let router = Router()

router.post("/mcp/test") { request, _ -> Response in
    let body = try await request.body.collect(upTo: 8 * 1024)
    let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any]
    let method = json?["method"] as? String ?? ""
    let id = json?["id"]

    FileHandle.standardError.write(Data("[smoke] POST method=\(method)\n".utf8))

    if method == "initialize" {
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: ResponseBody(byteBuffer: ByteBuffer(string: initJSON))
        )
    }
    if method == "tools/list" {
        let toolsList = """
        {"jsonrpc":"2.0","id":\(idJSON(id)),"result":{"tools":[{"name":"noop","description":"no-op","inputSchema":{"type":"object","properties":{}}}]}}
        """
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: ResponseBody(byteBuffer: ByteBuffer(string: toolsList))
        )
    }
    if method == "tools/call" {
        let callResult = """
        {"jsonrpc":"2.0","id":\(idJSON(id)),"result":{"content":[{"type":"text","text":"noop ok"}],"isError":false}}
        """
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: ResponseBody(byteBuffer: ByteBuffer(string: callResult))
        )
    }
    if method == "ping" {
        let pong = "{\"jsonrpc\":\"2.0\",\"id\":\(idJSON(id)),\"result\":{}}"
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: ResponseBody(byteBuffer: ByteBuffer(string: pong))
        )
    }
    return Response(status: .accepted)
}

router.get("/mcp/test") { _, _ -> Response in
    FileHandle.standardError.write(Data("[smoke] GET /mcp/test — opening SSE stream\n".utf8))
    let stream = AsyncStream<ByteBuffer> { cont in
        Task {
            // Push the channel notification after 2 seconds.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let notif = """
            {"jsonrpc":"2.0","method":"notifications/claude/channel","params":{"content":"test from in-app server","meta":{"event_type":"smoke_test","event_id":"smoke-0"}}}
            """
            var buf = ByteBufferAllocator().buffer(capacity: 0)
            buf.writeString("event: message\ndata: \(notif)\n\n")
            cont.yield(buf)
            FileHandle.standardError.write(Data("[smoke] pushed channel notification\n".utf8))
            // Keep stream alive 60s so we can observe in claude.
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            cont.finish()
        }
    }
    return Response(
        status: .ok,
        headers: [.contentType: "text/event-stream"],
        body: ResponseBody(asyncSequence: stream)
    )
}

let app = Application(
    router: router,
    configuration: .init(address: .hostname("127.0.0.1", port: 9999))
)

FileHandle.standardError.write(Data("[smoke] Phase A MCP HTTP+SSE smoke server on http://127.0.0.1:9999/mcp/test\n".utf8))
try await app.runService()
