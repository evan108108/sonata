import Foundation

// Actions for sonata-bridge.ts processes that aren't pool workers — the
// "external claude sessions" surfaced on the dashboard. See
// ExternalBridgeRegistry for storage semantics.

let bridgeActions: [SonataAction] = [

    // POST /api/bridge/announce — external bridge declares itself on startup.
    SonataAction(
        name: "bridge_announce",
        description: "Announce an external (non-worker, non-supervisor) sonata-bridge process so the dashboard can count it as a live external Claude session.",
        group: "/api/bridge",
        path: "/announce",
        method: .post,
        params: [
            ActionParam("sessionId", .string, required: true, description: "Stable per-bridge session identifier (BRIDGE_SESSION_ID)"),
            ActionParam("sessionLabel", .string, description: "Optional human label for the session"),
            ActionParam("pid", .integer, description: "Bridge process pid"),
        ],
        handler: { ctx in
            let sessionId = try ctx.params.require("sessionId")
            let sessionLabel = ctx.params.string("sessionLabel")
            let pid = ctx.params.int("pid")
            ExternalBridgeRegistry.shared.announce(
                sessionId: sessionId,
                sessionLabel: sessionLabel,
                pid: pid
            )
            return SuccessResponse()
        }
    ),

    // POST /api/bridge/heartbeat — keepalive for an external bridge.
    SonataAction(
        name: "bridge_heartbeat",
        description: "Refresh the lastHeartbeat for an external sonata-bridge session. Entries without a heartbeat in 60s drop out of the count.",
        group: "/api/bridge",
        path: "/heartbeat",
        method: .post,
        params: [
            ActionParam("sessionId", .string, required: true, description: "Stable per-bridge session identifier"),
        ],
        handler: { ctx in
            let sessionId = try ctx.params.require("sessionId")
            ExternalBridgeRegistry.shared.heartbeat(sessionId: sessionId)
            return SuccessResponse()
        }
    ),

    // POST /api/bridge/unregister — bridge is shutting down cleanly.
    SonataAction(
        name: "bridge_unregister",
        description: "Drop an external sonata-bridge entry immediately (called on graceful shutdown).",
        group: "/api/bridge",
        path: "/unregister",
        method: .post,
        params: [
            ActionParam("sessionId", .string, required: true, description: "Stable per-bridge session identifier"),
        ],
        handler: { ctx in
            let sessionId = try ctx.params.require("sessionId")
            ExternalBridgeRegistry.shared.unregister(sessionId: sessionId)
            return SuccessResponse()
        }
    ),
]
