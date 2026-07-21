import Foundation
import GRDB

enum MCPToolHandlers {
    static func handle(
        toolName: String,
        args: [String: Any],
        role: SessionRole,
        sessionKey: String,
        actionRegistry: ActionRegistry,
        dbPool: DatabasePool
    ) async -> (success: Bool, result: String) {
        switch toolName {
        case "complete_event":
            return await completeEvent(args: args, role: role, sessionKey: sessionKey,
                actionRegistry: actionRegistry, dbPool: dbPool)
        case "fail_event":
            return await failEvent(args: args, role: role, sessionKey: sessionKey,
                actionRegistry: actionRegistry, dbPool: dbPool)
        case "sonar_dm_send", "dm_send":
            // Both names route to the same action. sonar_dm_send is legacy; dm_send
            // is the new canonical name. Args mapped: targetSessionId → target,
            // fromSessionId, body, peerId (ignored — peers resolve by name now),
            // context → context.
            var normalizedArgs = args
            if let t = args["targetSessionId"] as? String, args["target"] == nil {
                normalizedArgs["target"] = t
            }
            // Legacy sonar_dm_send schema declares target_session_id — map it too.
            if let t = args["target_session_id"] as? String, normalizedArgs["target"] == nil {
                normalizedArgs["target"] = t
            }
            // Legacy sonar_dm_send callers never sent fromSessionId (old handler
            // used sessionKey implicitly). The dm_send action requires it.
            if normalizedArgs["fromSessionId"] == nil {
                normalizedArgs["fromSessionId"] = sessionKey
            }
            // Ignore peerId — target resolution is unified now.
            normalizedArgs["peerId"] = nil
            return await actionRegistry.executeMCPTool(
                name: "dm_send", args: normalizedArgs, dbPool: dbPool
            )
        case "dm_reply":
            return await actionRegistry.executeMCPTool(
                name: "dm_reply", args: args, dbPool: dbPool
            )
        case "dm_ack":
            return await actionRegistry.executeMCPTool(
                name: "dm_ack", args: args, dbPool: dbPool
            )
        case "dm_targets":
            return await actionRegistry.executeMCPTool(
                name: "dm_targets", args: args, dbPool: dbPool
            )
        // case "sonar_dm_inbox": DELETED — no queue to poll.
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
        case "email_send", "email_reply":
            // The outbound seam needs to know WHO is sending: the AFK subject
            // tag is stamped from the caller's sessionKey, and thread ownership
            // is recorded against it. Injecting here (rather than declaring the
            // args and trusting callers to fill them) means identity can't be
            // spoofed or forgotten — same pattern dm_broadcast uses above.
            var identifiedArgs = args
            identifiedArgs["sessionKey"] = sessionKey
            identifiedArgs["role"] = role.rawValue
            return await actionRegistry.executeMCPTool(
                name: toolName, args: identifiedArgs, dbPool: dbPool
            )
        case "sonata_identify":
            return await sonataIdentify(args: args, sessionKey: sessionKey, dbPool: dbPool)
        case "sonata_whoami":
            return await sonataWhoami(sessionKey: sessionKey, role: role, dbPool: dbPool)
        case "sonar_dm_broadcast", "dm_broadcast":
            // The dm_broadcast action requires fromSessionId to exclude the
            // sender; legacy sonar_dm_broadcast had no such arg.
            var broadcastArgs = args
            if broadcastArgs["fromSessionId"] == nil {
                broadcastArgs["fromSessionId"] = sessionKey
            }
            return await actionRegistry.executeMCPTool(
                name: "dm_broadcast", args: broadcastArgs, dbPool: dbPool
            )
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
        // `read` is the consumption half of the pair `look` starts. `look`
        // answers "what is on this page and what can I do next" — structured
        // JSON: url, title, a text prefix, links, form controls. `read` answers
        // "what does this page SAY" — the main content as markdown, with nav,
        // sidebars, cookie banners and footers dropped.
        //
        // It is not an innerText dump: it runs the pulpie pipeline over the
        // live DOM (simplify JS → CoreML classifier → markdown JS), so what
        // comes back is the article, not the chrome around it. Classification
        // failures surface as errors; there is no whole-page fallback, because
        // a boilerplate-laden dump that claims to be an extraction is worse
        // than a visible failure.
        case "read":
            return await webviewDrive(args: args) { sid in
                // The classifier's CoreML model is built for macOS 15; the rest
                // of the package still targets 14.
                guard #available(macOS 15, *) else {
                    return (false, "read: requires macOS 15 or later (the pulpie CoreML model targets macOS 15)")
                }
                let r = try await WebviewSessionService.shared.readPage(sessionId: sid)
                let payload: [String: Any] = [
                    "url": r.url, "title": r.title, "markdown": r.markdown,
                    "extractionMs": r.extractionMs, "blockCount": r.blockCount,
                    "mainBlockCount": r.mainBlockCount,
                ]
                let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return (true, json)
            }
        case "page_save_html":
            return await webviewDrive(args: args) { sid in
                guard let path = args["path"] as? String, !path.isEmpty else {
                    return (false, "page_save_html: path required")
                }
                // The serialized DOM goes disk-side only — the response carries
                // just the receipt, never the html.
                let saved = try await WebviewSessionService.shared.saveHTML(sessionId: sid, path: path)
                let payload: [String: Any] = ["path": saved.path, "bytes": saved.bytes,
                                              "url": saved.url, "title": saved.title]
                let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return (true, json)
            }
        default:
            // Fall through to the full ActionRegistry surface — MCPHandshake
            // advertises every registered action via mergedToolSchemas, so
            // tools like worker_list that aren't explicitly cased above must
            // dispatch here. executeMCPTool returns "Unknown tool: …" if
            // nothing matches, preserving the old error text.
            return await actionRegistry.executeMCPTool(name: toolName, args: args, dbPool: dbPool)
        }
    }

    // Worker tool-denial check — reads from this table on every worker tool
    // call. Returns true when the given tool is denied for the given worker.
    static func checkToolDenial(
        workerId: String, toolName: String, dbPool: DatabasePool
    ) async -> Bool {
        let count = (try? await dbPool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM workerToolDenials
                WHERE workerId = ? AND toolName = ?
            """, arguments: [workerId, toolName]) ?? 0
        }) ?? 0
        return count > 0
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

    // Replaces the old sonataIdentify helper. Writes claudeSessionId to
    // interactiveSessions row identified by the derived mcpSessionKey.
    //
    // Uses `SELECT changes()` for the affected-row count so MCPToolHandlers.swift
    // doesn't need to import SQLite3 (unlike DMActions.swift which does).
    private static func sonataIdentify(args: [String: Any], sessionKey: String, dbPool: DatabasePool) async -> (Bool, String) {
        guard let claudeSessionId = (args["claudeSessionId"] as? String) ?? (args["sessionId"] as? String) else {
            return (false, "sonata_identify: claudeSessionId (or legacy sessionId) required")
        }
        let cwd = args["cwd"] as? String
        _ = args["pid"] as? Int   // accepted for caller compat, ignored — there is
                                  // no durable pid store and none is needed.

        let updated = (try? await dbPool.write { db -> Int in
            try db.execute(sql: """
                UPDATE interactiveSessions
                SET claudeSessionId = ?,
                    cwd = COALESCE(?, cwd)
                WHERE ('session-' || SUBSTR(REPLACE(sessionId, '-', ''), 1, 16)) = ?
            """, arguments: [claudeSessionId, cwd, sessionKey])
            return (try? Int.fetchOne(db, sql: "SELECT changes()")) ?? 0
        }) ?? 0

        return (true, "identified sessionKey=\(sessionKey) claudeSessionId=\(claudeSessionId) updated=\(updated)")
    }

    private static func sonataWhoami(sessionKey: String, role: SessionRole, dbPool: DatabasePool) async -> (Bool, String) {
        var label: String?
        var claudeSessionId: String?
        var cwd: String?
        switch role {
        case .worker:
            label = (try? await dbPool.read { db in
                try String.fetchOne(db, sql: "SELECT sessionLabel FROM workers WHERE workerId = ?", arguments: [sessionKey])
            }).flatMap { $0 }
        case .interactive:
            let fields: (name: String?, claudeSessionId: String?, cwd: String?)? =
                try? await dbPool.read { db in
                    guard let row = try Row.fetchOne(db, sql: """
                        SELECT name, claudeSessionId, cwd FROM interactiveSessions
                        WHERE ('session-' || SUBSTR(REPLACE(sessionId, '-', ''), 1, 16)) = ?
                    """, arguments: [sessionKey]) else { return nil }
                    return (row["name"], row["claudeSessionId"], row["cwd"])
                }
            label = fields?.name
            claudeSessionId = fields?.claudeSessionId
            cwd = fields?.cwd
        case .supervisor:
            label = "supervisor"
        }
        // routingId is the preferred handle: claudeSessionId when known (stable
        // across --resume), otherwise the bearer-derived sessionKey. Used by
        // /afk to embed in `[AFK-#<id>]` subjects so replies route back.
        let routingId = claudeSessionId ?? sessionKey
        var out: [String: Any] = [
            "sessionKey": sessionKey,
            "routingId": routingId,
            "role": String(describing: role),
            "sessionLabel": label ?? sessionKey,
        ]
        if let claudeSessionId, !claudeSessionId.isEmpty { out["claudeSessionId"] = claudeSessionId }
        if let cwd, !cwd.isEmpty { out["cwd"] = cwd }
        let json = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return (true, json)
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
            return (success, success ? "Event \(eventId) completed" : output)
        }
    }

    private static func failEvent(
        args: [String: Any],
        role: SessionRole,
        sessionKey: String,
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
            return (success, success ? "Event \(eventId) failed" : output)
        }
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
            "description": "Legacy alias of dm_send. Fire-and-observe: pushed immediately if the target has a live connection, otherwise returns not_live — there is no queue and no inbox. Prefer dm_send.",
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
            "name": "dm_send",
            "description": "Send a DM to any target the system knows about — a worker (by workerId or sessionLabel), an interactive session (by sessionId or tab name), 'supervisor', or a sonar peer (by name). Returns immediately with sent | not_live | not_found. ACK arrives async as dm_ack notification.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "target": ["type": "string", "description": "Any identifier for the recipient."],
                    "body": ["type": "string", "description": "Message body, ≤ 256 KB."],
                    "fromSessionId": ["type": "string", "description": "Sender's sessionKey."],
                    "context": ["type": "string", "description": "Optional context string."],
                ],
                "required": ["target", "body", "fromSessionId"],
            ],
        ],
        [
            "name": "dm_reply",
            "description": "Reply to a prior DM by messageId. Routes directly to the original endpoint via the message chain — no workerEvent is created on receive.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "to_message_id": ["type": "string"],
                    "body": ["type": "string"],
                    "fromSessionId": ["type": "string"],
                ],
                "required": ["to_message_id", "body", "fromSessionId"],
            ],
        ],
        [
            "name": "dm_ack",
            "description": "Acknowledge receipt of a DM after processing it. Called by the receiver. Sonata forwards the ack to the sender's SSE stream.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "messageId": ["type": "string"],
                ],
                "required": ["messageId"],
            ],
        ],
        [
            "name": "dm_targets",
            "description": "List every currently DM-able target (session, worker, supervisor, peer). Presence in the list means live.",
            "inputSchema": [
                "type": "object",
                "properties": [:],
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
        [
            "name": "read",
            "description": "Compact markdown of the page's main content (via pulpie classifier). Complement to `look`: `look` returns structured JSON for deciding next action, `read` returns markdown for consumption. Returns { url, title, markdown, extractionMs, blockCount, mainBlockCount }.",
            "inputSchema": ["type": "object", "properties": ["sessionId": ["type": "string"]], "required": ["sessionId"]],
        ],
        [
            "name": "page_save_html",
            "description": "Serialize the rendered DOM natively and write it to `path`. Returns { path, bytes, url, title } — the html itself never crosses MCP, so a 5 MB page costs no tokens. Prefer this over evaluate(\"document.documentElement.outerHTML\") whenever you want the whole page.",
            "inputSchema": ["type": "object", "properties": [
                "sessionId": ["type": "string"],
                "path": ["type": "string", "description": "Absolute destination path. Parent dirs are created; an existing file is overwritten."]
            ], "required": ["sessionId", "path"]],
        ],
    ]
}
