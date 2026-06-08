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
        case "sonata_identify":
            return await sonataIdentify(args: args, state: state)
        case "sonata_whoami":
            return await sonataWhoami(state: state)
        case "sonar_dm_broadcast":
            return await sonarDMBroadcast(
                args: args, sessionKey: sessionKey, registry: registry, dbPool: dbPool)
        case "session_create":
            return await webviewCreate(args: args, sessionKey: sessionKey)
        case "session_close":
            return await webviewClose(args: args)
        case "session_list":
            return await webviewList()
        case "session_focus":
            return await webviewSimple(args: args) { try WebviewSessionService.shared.focus(sessionId: $0); return "focused \($0)" }
        case "navigate":
            return await webviewDrive(args: args) { sid in
                guard let url = args["url"] as? String else { return (false, "navigate: url required") }
                try await WebviewSessionService.shared.navigate(sessionId: sid, url: url); return (true, "navigated \(sid) → \(url)")
            }
        case "click":
            return await webviewDrive(args: args) { sid in
                let r = try await WebviewSessionService.shared.click(
                    sessionId: sid, selector: args["selector"] as? String,
                    x: args["x"] as? Double, y: args["y"] as? Double); return (true, r)
            }
        case "type":
            return await webviewDrive(args: args) { sid in
                guard let text = args["text"] as? String else { return (false, "type: text required") }
                let r = try await WebviewSessionService.shared.type(
                    sessionId: sid, text: text, selector: args["selector"] as? String); return (true, r)
            }
        case "scroll":
            return await webviewDrive(args: args) { sid in
                let r = try await WebviewSessionService.shared.scroll(
                    sessionId: sid, x: args["x"] as? Double, y: args["y"] as? Double,
                    selector: args["selector"] as? String); return (true, r)
            }
        case "screenshot":
            return await webviewDrive(args: args) { sid in
                let maxWidth = (args["maxWidth"] as? Double) ?? (args["maxWidth"] as? Int).map(Double.init)
                let format = (args["format"] as? String) ?? "png"
                let quality = (args["quality"] as? Double) ?? (args["quality"] as? Int).map(Double.init) ?? 0.7
                let shot = try await WebviewSessionService.shared.screenshot(
                    sessionId: sid, maxWidth: maxWidth, format: format, quality: quality)
                // With `path`, write to disk and return { path } — keeps large
                // images out of the agent's token budget. Otherwise base64.
                if let path = (args["path"] as? String), !path.isEmpty {
                    let dest = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    try shot.data.write(to: dest)
                    let payload: [String: Any] = ["path": dest.path, "bytes": shot.data.count,
                                                  "format": shot.format, "width": shot.width, "height": shot.height]
                    let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return (true, json)
                }
                let payload: [String: Any] = ["screenshot": shot.data.base64EncodedString(),
                                              "bytes": shot.data.count, "format": shot.format,
                                              "width": shot.width, "height": shot.height]
                let json = (try? JSONSerialization.data(withJSONObject: payload, options: []))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return (true, json)
            }
        case "evaluate":
            return await webviewDrive(args: args) { sid in
                guard let js = args["script"] as? String ?? args["js"] as? String else { return (false, "evaluate: script required") }
                let r = try await WebviewSessionService.shared.evaluate(sessionId: sid, js: js); return (true, r)
            }
        case "look":
            return await webviewDrive(args: args) { sid in
                let r = try await WebviewSessionService.shared.look(sessionId: sid); return (true, r)
            }
        case "get_page_info":
            return await webviewDrive(args: args) { sid in
                let r = try await WebviewSessionService.shared.getPageInfo(sessionId: sid); return (true, r)
            }
        default:
            return (false, "Unknown tool: \(toolName)")
        }
    }

    // MARK: - Webview session tools (Phase 1)

    private static func webviewCreate(
        args: [String: Any], sessionKey: String
    ) async -> (success: Bool, result: String) {
        // ownerAgentId defaults to the calling bridge session (decision F2).
        let owner = (args["ownerAgentId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sessionKey
        let url = args["url"] as? String
        let partition = (args["partition"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let background = (args["background"] as? Bool) ?? false
        let sid = await WebviewSessionService.shared.create(
            ownerAgentId: owner, url: url, partition: partition, background: background)
        let payload: [String: Any] = ["sessionId": sid, "ownerAgentId": owner, "background": background]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"sessionId\":\"\(sid)\"}"
        return (true, json)
    }

    private static func webviewClose(args: [String: Any]) async -> (success: Bool, result: String) {
        guard let sid = args["sessionId"] as? String, !sid.isEmpty else { return (false, "sessionId required") }
        do { try await WebviewSessionService.shared.close(sessionId: sid); return (true, "closed \(sid)") }
        catch { return (false, "\(error)") }
    }

    private static func webviewList() async -> (success: Bool, result: String) {
        let infos = await WebviewSessionService.shared.list()
        let data = (try? JSONEncoder().encode(infos)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return (true, data)
    }

    /// For verbs that take only a sessionId and return a string.
    private static func webviewSimple(
        args: [String: Any], _ op: @MainActor (String) async throws -> String
    ) async -> (success: Bool, result: String) {
        guard let sid = args["sessionId"] as? String, !sid.isEmpty else { return (false, "sessionId required") }
        do { return (true, try await op(sid)) } catch { return (false, "\(error)") }
    }

    /// For drive verbs: extracts sessionId, runs the op, maps thrown DriveError
    /// to a failed tool result. The op returns its own (success, result) so a
    /// verb can report a semantic failure (e.g. missing required arg) too.
    private static func webviewDrive(
        args: [String: Any], _ op: @MainActor (String) async throws -> (Bool, String)
    ) async -> (success: Bool, result: String) {
        guard let sid = args["sessionId"] as? String, !sid.isEmpty else { return (false, "sessionId required") }
        do { return try await op(sid) } catch { return (false, "\(error)") }
    }

    /// Fan a DM to every SSE-attached session matching the optional
    /// kind filter. Used for blasts that don't have a specific
    /// recipient — e.g. "any human, please ack" or "all workers,
    /// pause." Persists each delivery into dm_messages so backfill
    /// via dm_inbox works the same as for unicast DMs.
    private static func sonarDMBroadcast(
        args: [String: Any],
        sessionKey: String,
        registry: MCPSessionRegistry,
        dbPool: DatabasePool
    ) async -> (success: Bool, result: String) {
        guard let body = args["body"] as? String, !body.isEmpty else {
            return (false, "sonar_dm_broadcast: body required")
        }
        if body.utf8.count > 256 * 1024 {
            return (false, "sonar_dm_broadcast: body exceeds 256 KiB")
        }
        let filterRaw = (args["filter"] as? String)?.lowercased() ?? "all"
        let context = args["context"] as? String
        let metaJson: String?
        if let metaDict = args["meta"] as? [String: Any] {
            metaJson = (try? JSONSerialization.data(
                withJSONObject: metaDict, options: [.sortedKeys])).flatMap {
                    String(data: $0, encoding: .utf8)
                }
        } else {
            metaJson = nil
        }

        let allow: (SessionRole) -> Bool
        switch filterRaw {
        case "worker", "workers": allow = { $0 == .worker }
        case "interactive", "humans": allow = { $0 == .interactive }
        case "supervisor": allow = { $0 == .supervisor }
        case "all", "": allow = { _ in true }
        default:
            return (false, "sonar_dm_broadcast: unknown filter '\(filterRaw)' — use all|workers|interactive|supervisor")
        }

        let snapshots = await registry.snapshot()
        var delivered: [String] = []
        var skipped = 0
        let now = nowMs()
        for snap in snapshots {
            guard allow(snap.role), snap.hasSSE else { skipped += 1; continue }
            if snap.sessionKey == sessionKey { skipped += 1; continue }  // don't echo to sender
            let messageId = MCPTokenGenerator.newToken().prefix(32)
            let pushed = await registry.deliverDM(
                target: snap.sessionKey,
                messageId: String(messageId),
                body: body,
                fromSessionId: sessionKey,
                context: context,
                metaJson: metaJson,
                sentAtMs: now
            )
            if pushed {
                delivered.append(snap.sessionKey)
                let env = DMEnvelope(
                    messageId: String(messageId),
                    fromSessionId: sessionKey,
                    fromPubkey: nil,
                    fromPeerId: nil,
                    targetSessionId: snap.sessionKey,
                    body: body,
                    context: context,
                    sentAtMs: now,
                    receivedAtMs: now,
                    metaJson: metaJson
                )
                try? await dbPool.write { db in
                    _ = try dmMessagesPersist(env, deliveryStatus: "queued", db: db)
                }
            } else {
                skipped += 1
            }
        }

        let payload: [String: Any] = [
            "filter": filterRaw,
            "delivered_count": delivered.count,
            "skipped_count": skipped,
            "delivered_to": delivered,
        ]
        let json = (try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return (true, json)
    }

    /// Self-registration call. Non-sona-launched sessions land with a
    /// temporary "anon-XXX" sessionKey; after the channel-pushed
    /// "identify yourself" notification, they read
    /// ~/.claude/sessions/$PPID.json and call this with the fields.
    /// Sona-launched sessions already match bearer == sessionId so this
    /// call is mostly redundant for them — but harmless and idempotent.
    private static func sonataIdentify(
        args: [String: Any],
        state: MCPSessionState
    ) async -> (success: Bool, result: String) {
        let claudeSessionId = (args["sessionId"] as? String) ?? ""
        let cwd = args["cwd"] as? String
        let kindStr = args["kind"] as? String
        let pidNumber = args["pid"]
        let pid: Int? = (pidNumber as? Int) ?? (pidNumber as? Int64).map(Int.init) ?? (pidNumber as? Double).map(Int.init)
        guard !claudeSessionId.isEmpty else {
            return (false, "sonata_identify: sessionId required")
        }
        await state.identify(
            claudeSessionId: claudeSessionId,
            cwd: cwd,
            kind: kindStr,
            pid: pid
        )
        return (true, "Identified as \(claudeSessionId)")
    }

    /// Return the calling session's identity. Used by the /afk skill to learn
    /// the routing id it should embed in `[AFK-#<id>]` subjects so EmailHandler
    /// can push replies back via channel notification.
    ///
    /// `routingId` is the preferred handle: claudeSessionId if known (stable
    /// across `--resume`), otherwise the bearer-derived sessionKey. Both forms
    /// resolve via MCPSessionRegistry.resolveSession.
    private static func sonataWhoami(
        state: MCPSessionState
    ) async -> (success: Bool, result: String) {
        let sessionKey = state.sessionKey
        let claudeSessionId = await state.claudeSessionId
        let cwd = await state.cwd
        let role = await state.role
        let routingId = claudeSessionId ?? sessionKey
        var dict: [String: Any] = [
            "sessionKey": sessionKey,
            "routingId": routingId,
            "role": String(describing: role),
        ]
        if let cid = claudeSessionId { dict["claudeSessionId"] = cid }
        if let c = cwd { dict["cwd"] = c }
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
        return (true, String(data: data, encoding: .utf8) ?? "{}")
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
        // Accept BOTH snake_case (event_id, the published MCP schema) and
        // camelCase (eventId, the REST shim's worker_event_complete naming).
        // Diagnosed 2026-06-04: workers were burning retry loops because they
        // routinely conflate the two surfaces. Aliasing here removes the
        // entire class of "Missing required parameter" failures for this
        // tool. The schema still publishes event_id as canonical.
        let eventId = (args["event_id"] as? String) ?? (args["eventId"] as? String) ?? ""
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
        // Snake/camel alias on event_id — see completeEvent for the rationale.
        let eventId = (args["event_id"] as? String) ?? (args["eventId"] as? String) ?? ""
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

    /// Local target: persist to dm_messages, then push inline via
    /// MCPSessionRegistry.deliverDM (live SSE if attached, otherwise the
    /// recipient pulls via dm_inbox). Federation (peer_id set): delegate to
    /// the dm_send action which handles peer routing via Sonar.
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
            "description": "Send a DM to a session. Always queued durably in dm_messages; pushed live immediately if the target has an SSE connection, otherwise delivered the next time the target calls sonar_dm_inbox. No registration step — every session is reachable by id. Local target: omit peer_id. Remote target: include peer_id (Sonar peers.id, NOT instance_id).",
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
            "name": "sonar_dm_broadcast",
            "description": "Fan a DM to every SSE-attached session matching the optional kind filter ('all'|'workers'|'interactive'|'supervisor'; default 'all'). Excludes the sender. Persists each delivery into dm_messages.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "body": ["type": "string", "description": "Message body, ≤ 256 KiB"],
                    "filter": ["type": "string", "description": "Recipient kind filter (default 'all')"],
                    "context": ["type": "string", "description": "Optional context string"],
                    "meta": ["type": "object", "description": "Optional ≤4KB JSON metadata blob"],
                ],
                "required": ["body"],
            ],
        ],
        [
            "name": "sonata_identify",
            "description": "Self-register this session's claude metadata. Required for non-sona-launched sessions after the channel-pushed identify request. Idempotent.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "sessionId": ["type": "string", "description": "claude's session id (UUID from ~/.claude/sessions/$PPID.json)"],
                    "cwd": ["type": "string", "description": "working directory"],
                    "kind": ["type": "string", "description": "interactive | worker | supervisor | inspector"],
                    "pid": ["type": "number", "description": "claude's process id"],
                ],
                "required": ["sessionId"],
            ],
        ],
        [
            "name": "sonata_whoami",
            "description": "Return this session's identity: { sessionKey, routingId, role, claudeSessionId?, cwd? }. Used by /afk to learn which id to put in `[AFK-#<id>]` subjects so replies route back via channel notification. routingId is the preferred handle (claudeSessionId when known, else sessionKey).",
            "inputSchema": [
                "type": "object",
                "properties": [:],
            ],
        ],
        [
            "name": "sonar_dm_inbox",
            "description": "Backfill: fetch persisted DMs addressed to this session since a timestamp. Use after restart, or to pull DMs that arrived while not SSE-attached.",
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
        [
            "name": "session_create",
            "description": "Create an in-app webview session (WKWebView). Returns { sessionId }. ownerAgentId defaults to the calling session. Omit `partition` for the shared cookie jar (logins inherited); pass a name for an isolated store. `background:true` creates it headless (driveable, not shown until focused).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ownerAgentId": ["type": "string", "description": "Owning agent (defaults to caller's session)"],
                    "url": ["type": "string", "description": "Initial URL to load (optional)"],
                    "partition": ["type": "string", "description": "Cookie/data-store partition name (omit = shared default)"],
                    "background": ["type": "boolean", "description": "Headless: driveable but not mounted (default false)"],
                ],
            ],
        ],
        [
            "name": "session_close",
            "description": "Close a webview session and remove its registry row. Isolated-partition stores are reclaimed when their last session closes.",
            "inputSchema": ["type": "object", "properties": ["sessionId": ["type": "string", "description": "Session id from session_create"]], "required": ["sessionId"]],
        ],
        [
            "name": "session_list",
            "description": "List all webview sessions: [{ sessionId, ownerAgentId, status (live|suspended), background, url, title, partition, lastActivityAt }].",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "session_focus",
            "description": "Bring a webview session into the visible panel (spy/peek). Resumes it if suspended. Un-focusing happens in the UI and leaves it running.",
            "inputSchema": ["type": "object", "properties": ["sessionId": ["type": "string", "description": "Session id"]], "required": ["sessionId"]],
        ],
        [
            "name": "navigate",
            "description": "Load a URL in the webview session (WKWebView.load). Resumes a suspended session.",
            "inputSchema": ["type": "object", "properties": ["sessionId": ["type": "string"], "url": ["type": "string"]], "required": ["sessionId", "url"]],
        ],
        [
            "name": "click",
            "description": "Click an element in the webview session — by CSS `selector`, or by viewport `x`+`y`.",
            "inputSchema": ["type": "object", "properties": ["sessionId": ["type": "string"], "selector": ["type": "string"], "x": ["type": "number"], "y": ["type": "number"]], "required": ["sessionId"]],
        ],
        [
            "name": "type",
            "description": "Type `text` into the focused element, or into `selector` if given.",
            "inputSchema": ["type": "object", "properties": ["sessionId": ["type": "string"], "text": ["type": "string"], "selector": ["type": "string"]], "required": ["sessionId", "text"]],
        ],
        [
            "name": "scroll",
            "description": "Scroll the page by `x`/`y` pixels, or scroll `selector` into view.",
            "inputSchema": ["type": "object", "properties": ["sessionId": ["type": "string"], "x": ["type": "number"], "y": ["type": "number"], "selector": ["type": "string"]], "required": ["sessionId"]],
        ],
        [
            "name": "screenshot",
            "description": "Snapshot of the webview session. Returns { screenshot (base64), bytes, format, width, height }. Use `maxWidth` to shrink the image (a full retina PNG can blow the token budget), `format:\"jpeg\"` + `quality` for smaller payloads, or `path` to write the image to a file and get { path } back instead of base64.",
            "inputSchema": ["type": "object", "properties": [
                "sessionId": ["type": "string"],
                "maxWidth": ["type": "number", "description": "Scale the capture to this width in points (preserves aspect; smaller = fewer tokens)"],
                "format": ["type": "string", "description": "png (default) or jpeg"],
                "quality": ["type": "number", "description": "JPEG quality 0–1 (default 0.7); ignored for png"],
                "path": ["type": "string", "description": "If set, write the image here and return { path } instead of base64"]
            ], "required": ["sessionId"]],
        ],
        [
            "name": "evaluate",
            "description": "Run JavaScript in the page world (unsandboxed) and return the result. `script` is the JS source. Tool name matches Eyebrowse's `evaluate` exactly (zero relearning).",
            "inputSchema": ["type": "object", "properties": ["sessionId": ["type": "string"], "script": ["type": "string"]], "required": ["sessionId", "script"]],
        ],
        [
            "name": "look",
            "description": "Structured page snapshot: { url, title, text, links[], inputs[] } — what an agent needs to decide the next action.",
            "inputSchema": ["type": "object", "properties": ["sessionId": ["type": "string"]], "required": ["sessionId"]],
        ],
        [
            "name": "get_page_info",
            "description": "Lightweight page state: { url, title, readyState, scroll, viewport }.",
            "inputSchema": ["type": "object", "properties": ["sessionId": ["type": "string"]], "required": ["sessionId"]],
        ],
    ]
}
