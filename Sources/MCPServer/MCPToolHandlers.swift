import Foundation
import GRDB

enum MCPToolHandlers {
    static func handle(
        toolName: String,
        args: [String: Any],
        role: SessionRole,
        sessionKey: String,
        state: MCPSessionState,
        registry: MCPSessionRegistry,
        actionRegistry: ActionRegistry,
        dbPool: DatabasePool
    ) async -> (success: Bool, result: String) {
        switch toolName {
        case "complete_event":
            return await completeEvent(args: args, role: role, sessionKey: sessionKey,
                state: state, actionRegistry: actionRegistry, dbPool: dbPool)
        case "fail_event":
            return await failEvent(args: args, role: role, sessionKey: sessionKey,
                state: state, actionRegistry: actionRegistry, dbPool: dbPool)
        case "sonar_dm_send":
            return await sonarDMSend(args: args, sessionKey: sessionKey,
                registry: registry, actionRegistry: actionRegistry, dbPool: dbPool)
        case "sonar_dm_inbox":
            return await sonarDMInbox(args: args, sessionKey: sessionKey,
                actionRegistry: actionRegistry, dbPool: dbPool)
        case "mem_task_list":
            return await actionRegistry.executeMCPTool(
                name: "mem_task_list", args: args, dbPool: dbPool)
        case "mem_task_get":
            return await actionRegistry.executeMCPTool(
                name: "mem_task_get", args: args, dbPool: dbPool)
        case "mem_task_create":
            return await memTaskCreate(
                args: args, actionRegistry: actionRegistry, dbPool: dbPool)
        case "mem_task_watch":
            return await memTaskWatch(
                args: args, sessionKey: sessionKey,
                actionRegistry: actionRegistry, dbPool: dbPool)
        case "mem_task_unwatch":
            return await memTaskUnwatch(
                args: args, sessionKey: sessionKey,
                actionRegistry: actionRegistry, dbPool: dbPool)
        default:
            return (false, "Unknown tool: \(toolName)")
        }
    }

    /// Defaults target_session_id to the caller's sessionKey when omitted —
    /// the "subscribe me to this task" pattern is the common case and forcing
    /// every caller to repeat its own id is friction.
    private static func memTaskWatch(
        args: [String: Any],
        sessionKey: String,
        actionRegistry: ActionRegistry,
        dbPool: DatabasePool
    ) async -> (success: Bool, result: String) {
        var coerced = args
        if (coerced["target_session_id"] as? String).map({ $0.isEmpty }) ?? true {
            coerced["target_session_id"] = sessionKey
        }
        return await actionRegistry.executeMCPTool(
            name: "mem_task_watch", args: coerced, dbPool: dbPool)
    }

    private static func memTaskUnwatch(
        args: [String: Any],
        sessionKey: String,
        actionRegistry: ActionRegistry,
        dbPool: DatabasePool
    ) async -> (success: Bool, result: String) {
        var coerced = args
        if (coerced["target_session_id"] as? String).map({ $0.isEmpty }) ?? true {
            coerced["target_session_id"] = sessionKey
        }
        return await actionRegistry.executeMCPTool(
            name: "mem_task_unwatch", args: coerced, dbPool: dbPool)
    }

    /// Worker-facing mem_task_create. The dispatcher only picks up rows
    /// with status='pending'; an active-on-create task is orphaned (per
    /// feedback_mem_task_create_pending). Workers therefore have no
    /// legitimate reason to set any other status here — we silently
    /// coerce to 'pending' and emit a stderr warning when the caller
    /// supplied something else, so the misuse is visible in logs
    /// without breaking the create call.
    private static func memTaskCreate(
        args: [String: Any],
        actionRegistry: ActionRegistry,
        dbPool: DatabasePool
    ) async -> (success: Bool, result: String) {
        var coerced = args
        if let supplied = args["status"] as? String, supplied != "pending" {
            FileHandle.standardError.write(Data(
                "[mcp-tool] mem_task_create: worker caller supplied status='\(supplied)' — coerced to 'pending' (dispatcher only picks up pending rows; see feedback_mem_task_create_pending)\n".utf8))
        }
        coerced["status"] = "pending"
        return await actionRegistry.executeMCPTool(
            name: "mem_task_create", args: coerced, dbPool: dbPool)
    }

    private static func completeEvent(
        args: [String: Any],
        role: SessionRole,
        sessionKey: String,
        state: MCPSessionState,
        actionRegistry: ActionRegistry,
        dbPool: DatabasePool
    ) async -> (success: Bool, result: String) {
        let eventId = args["event_id"] as? String ?? ""
        let result = args["result"] as? String

        switch role {
        case .supervisor:
            let (success, output) = await actionRegistry.executeMCPTool(
                name: "supervisor_heartbeat",
                args: ["sessionId": sessionKey],
                dbPool: dbPool
            )
            await state.clearInFlight()
            if success {
                return (true, "Supervisor event \(eventId) acknowledged")
            } else {
                return (false, output)
            }

        case .worker, .interactive:
            var callArgs: [String: Any] = ["eventId": eventId]
            if let result { callArgs["result"] = result }
            callArgs["workerId"] = sessionKey
            let (success, output) = await actionRegistry.executeMCPTool(
                name: "worker_event_complete",
                args: callArgs,
                dbPool: dbPool
            )
            await state.clearInFlight()
            return (success, success ? "Event \(eventId) completed" : output)
        }
    }

    private static func failEvent(
        args: [String: Any],
        role: SessionRole,
        sessionKey: String,
        state: MCPSessionState,
        actionRegistry: ActionRegistry,
        dbPool: DatabasePool
    ) async -> (success: Bool, result: String) {
        let eventId = args["event_id"] as? String ?? ""
        let errMsg = args["error"] as? String ?? "Unknown error"

        switch role {
        case .supervisor:
            let (success, output) = await actionRegistry.executeMCPTool(
                name: "supervisor_heartbeat",
                args: ["sessionId": sessionKey],
                dbPool: dbPool
            )
            await state.clearInFlight()
            if success {
                return (true, "Supervisor event \(eventId) failed: \(errMsg)")
            } else {
                return (false, output)
            }

        case .worker, .interactive:
            let callArgs: [String: Any] = [
                "eventId": eventId,
                "workerId": sessionKey,
                "error": errMsg,
            ]
            let (success, output) = await actionRegistry.executeMCPTool(
                name: "worker_event_fail",
                args: callArgs,
                dbPool: dbPool
            )
            await state.clearInFlight()
            return (success, success ? "Event \(eventId) failed" : output)
        }
    }

    /// Local target: bypass DMRegistry, persist to dm_messages, push
    /// inline via the registry's atomic deliverDM. Federation (peer_id
    /// set): preserve the existing dm_send action which handles peer
    /// routing.
    private static func sonarDMSend(
        args: [String: Any],
        sessionKey: String,
        registry: MCPSessionRegistry,
        actionRegistry: ActionRegistry,
        dbPool: DatabasePool
    ) async -> (success: Bool, result: String) {
        guard let target = args["target_session_id"] as? String,
              MCPSessionKey.isValid(target) else {
            return (false, "bad_session_id")
        }
        guard let body = args["body"] as? String, !body.isEmpty else {
            return (false, "body_empty")
        }
        if body.utf8.count > 262_144 { return (false, "body_too_large") }

        if let peerId = args["peer_id"] as? String, !peerId.isEmpty {
            var callArgs: [String: Any] = [
                "targetSessionId": target,
                "fromSessionId": sessionKey,
                "body": body,
                "peerId": peerId,
            ]
            if let context = args["context"] as? String { callArgs["context"] = context }
            if let meta = args["meta"] as? [String: Any] { callArgs["meta"] = meta }
            return await actionRegistry.executeMCPTool(
                name: "dm_send", args: callArgs, dbPool: dbPool)
        }

        let messageId = newUUID()
        let sentAt = nowMs()
        let context = args["context"] as? String
        let metaJson: String? = (args["meta"] as? [String: Any]).flatMap { m in
            guard let d = try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys]),
                  let s = String(data: d, encoding: .utf8) else { return nil }
            return s
        }

        do {
            try await dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO dm_messages
                        (messageId, fromSessionId, targetSessionId, body,
                         context, metaJson, sentAtMs, receivedAtMs, deliveryStatus)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    messageId, sessionKey, target, body, context, metaJson,
                    sentAt, sentAt, "queued",
                ])
            }
        } catch {
            return (false, "db_error: \(error)")
        }

        let delivered = await registry.deliverDM(
            target: target,
            messageId: messageId,
            body: body,
            fromSessionId: sessionKey,
            context: context,
            metaJson: metaJson,
            sentAtMs: sentAt
        )

        let status = delivered ? "delivered" : "queued"
        let deliveredAt: Int64? = delivered ? nowMs() : nil
        try? await dbPool.write { db in
            try db.execute(sql:
                "UPDATE dm_messages SET deliveryStatus = ?, deliveredAtMs = ? WHERE messageId = ?",
                arguments: [status, deliveredAt, messageId])
        }

        let result: [String: Any] = [
            "message_id": messageId,
            "queued_at_ms": sentAt,
            "delivery_status": status,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data()
        return (true, String(data: data, encoding: .utf8) ?? "{}")
    }

    private static func sonarDMInbox(
        args: [String: Any],
        sessionKey: String,
        actionRegistry: ActionRegistry,
        dbPool: DatabasePool
    ) async -> (success: Bool, result: String) {
        let since = args["since_ts"] as? Int64 ?? 0
        let limit = args["limit"] as? Int ?? 50
        return await actionRegistry.executeMCPTool(
            name: "dm_inbox",
            args: [
                "sessionId": sessionKey,
                "since": since,
                "limit": limit,
            ],
            dbPool: dbPool
        )
    }
}

enum MCPToolSchemas {
    static let all: [[String: Any]] = [
        [
            "name": "complete_event",
            "description": "Mark a worker event as completed.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "event_id": ["type": "string", "description": "The event_id from the channel notification"],
                    "result": ["type": "string", "description": "Brief summary of what was done"],
                ],
                "required": ["event_id"],
            ],
        ],
        [
            "name": "fail_event",
            "description": "Mark a worker event as failed.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "event_id": ["type": "string", "description": "The event_id from the channel notification"],
                    "error": ["type": "string", "description": "What went wrong"],
                ],
                "required": ["event_id", "error"],
            ],
        ],
        [
            "name": "sonar_dm_send",
            "description": "Send a session-addressed DM. Local target: omit peer_id. Remote target: include peer_id (Sonar peers.id, NOT instance_id).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "target_session_id": ["type": "string", "description": "Target bridge session id (1-128 chars, [A-Za-z0-9_-])"],
                    "body": ["type": "string", "description": "Message body, ≤ 256 KB"],
                    "peer_id": ["type": "string", "description": "Sonar peer id (omit for local targets)"],
                    "context": ["type": "string", "description": "Optional context string"],
                    "meta": ["type": "object", "description": "Optional ≤4KB JSON metadata blob"],
                ],
                "required": ["target_session_id", "body"],
            ],
        ],
        [
            "name": "sonar_dm_inbox",
            "description": "Backfill: fetch persisted DMs addressed to this session since a timestamp. Use after restart/registration to catch up.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "since_ts": ["type": "number", "description": "Epoch ms; default 0 (returns up to limit)"],
                    "limit": ["type": "number", "description": "Max rows (default 50, max 500)"],
                ],
            ],
        ],
        [
            "name": "mem_task_list",
            "description": "List tasks in the worker queue with optional filters.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "number", "description": "Max results (default 50)"],
                    "offset": ["type": "number", "description": "Skip N results (default 0)"],
                    "status": ["type": "string", "description": "Filter by status (e.g. 'pending', 'active', 'completed')"],
                    "project": ["type": "string", "description": "Filter by project namespace"],
                    "assignedTo": ["type": "string", "description": "Filter by assignee"],
                ],
            ],
        ],
        [
            "name": "mem_task_get",
            "description": "Fetch a single task by ID.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Task ID"],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "mem_task_create",
            "description": "Create a new task. Worker callers can only create rows with status='pending' — any other status is silently coerced (the dispatcher only picks up pending rows, so active-on-create orphans the task).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Task title"],
                    "source": ["type": "string", "description": "Source system (required)"],
                    "description": ["type": "string", "description": "Task description"],
                    "priority": ["type": "string", "description": "Priority (default 'normal')"],
                    "prompt": ["type": "string", "description": "Prompt/instructions for the worker"],
                    "workingDir": ["type": "string", "description": "Working directory"],
                    "model": ["type": "string", "description": "Model override"],
                    "maxTurns": ["type": "number", "description": "Max turns"],
                    "project": ["type": "string", "description": "Project namespace"],
                    "blockedBy": ["type": "array", "items": ["type": "string"], "description": "Blocker task IDs"],
                    "parentTask": ["type": "string", "description": "Parent task ID"],
                    "sourceRef": ["type": "string", "description": "External source reference"],
                    "tags": ["type": "array", "items": ["type": "string"], "description": "Tags"],
                    "assignedTo": ["type": "string", "description": "Assignee"],
                    "dueAt": ["type": "number", "description": "Due timestamp (epoch ms)"],
                    "maxRetries": ["type": "number", "description": "Max retries"],
                    "tools": ["type": "array", "items": ["type": "string"], "description": "Allowed tools"],
                    "metadata": ["type": "string", "description": "JSON metadata string"],
                ],
                "required": ["title", "source"],
            ],
        ],
        [
            "name": "mem_task_watch",
            "description": "Subscribe to status transitions on a task — delivers a sonar DM on change instead of polling. Defaults target_session_id to the caller's session.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "taskId": ["type": "string", "description": "Task ID to watch"],
                    "target_session_id": ["type": "string", "description": "Session to receive DMs (defaults to caller)"],
                    "on": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Subset of [done, failed, status_change]. Defaults to [status_change].",
                    ],
                ],
                "required": ["taskId"],
            ],
        ],
        [
            "name": "mem_task_unwatch",
            "description": "Drop a task watcher. Idempotent. Defaults target_session_id to the caller's session.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "taskId": ["type": "string", "description": "Task ID"],
                    "target_session_id": ["type": "string", "description": "Watcher session id (defaults to caller)"],
                ],
                "required": ["taskId"],
            ],
        ],
    ]
}
