import Foundation
import GRDB

// MARK: - Task watchers (push-vs-poll primitive)

/// How long a watching session can be silent before we treat it as dead and
/// drop its watchers on the next fan-out (passive sweep — no separate timer).
/// 15 min matches the task spec default; the dashboard's "alive" lamp uses a
/// much tighter 90 s window for a different question ("is this session
/// actively talking right now").
let taskWatcherStaleAfterMs: Int64 = 15 * 60 * 1000

private let validWatcherEvents: Set<String> = ["done", "failed", "status_change"]
private let terminalSuccess: Set<String> = ["completed"]
private let terminalFailure: Set<String> = ["failed"]

private func parseOnMask(_ json: String) -> Set<String> {
    guard let data = json.data(using: .utf8),
          let arr = try? JSONDecoder().decode([String].self, from: data) else {
        return []
    }
    return Set(arr)
}

private func encodeOnMask(_ events: [String]) -> String {
    let normalized = events
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { validWatcherEvents.contains($0) }
    let deduped = Array(Set(normalized)).sorted()
    let payload = deduped.isEmpty ? ["status_change"] : deduped
    guard let data = try? JSONEncoder().encode(payload),
          let str = String(data: data, encoding: .utf8) else {
        return "[\"status_change\"]"
    }
    return str
}

private func maskMatches(_ mask: Set<String>, newStatus: String) -> Bool {
    if mask.contains("status_change") { return true }
    if mask.contains("done") && terminalSuccess.contains(newStatus) { return true }
    if mask.contains("failed") && terminalFailure.contains(newStatus) { return true }
    return false
}

// MARK: - Liveness probe (injectable for tests)

struct TaskWatcherLiveness: Sendable {
    /// Returns the lastContactedAt timestamp (ms) for `sessionId` if the
    /// session is currently in the MCP registry; nil if not registered.
    var lastContactedAtMs: @Sendable (_ sessionId: String) async -> Int64?
}

/// Production liveness check — consults `MCPSessionRegistry.shared`.
func makeProductionTaskWatcherLiveness() -> TaskWatcherLiveness {
    TaskWatcherLiveness(lastContactedAtMs: { sessionId in
        guard let reg = MCPSessionRegistry.shared else { return nil }
        let snaps = await reg.snapshot()
        return snaps.first(where: { $0.sessionKey == sessionId })?.lastContactedAt
    })
}

// MARK: - Local DM dispatch (used by fan-out)

/// Injectable DM dispatcher so tests can capture calls without a registry.
struct TaskWatcherDispatcher: Sendable {
    /// Send a DM to `targetSession`. Returns true on synchronous delivery,
    /// false if it was queued for later. Persistence to dm_messages and the
    /// in-memory push are the dispatcher's responsibility.
    var send: @Sendable (
        _ targetSession: String,
        _ body: String,
        _ context: String,
        _ meta: [String: Any]
    ) async -> Bool
}

/// Production dispatcher — same write+push semantics as the MCP
/// `sonar_dm_send` tool, but invoked from server-internal code (no caller
/// sessionKey, so we mark `fromSessionId="sonata"`).
func makeProductionTaskWatcherDispatcher(dbPool: DatabasePool) -> TaskWatcherDispatcher {
    TaskWatcherDispatcher(send: { target, body, context, meta in
        let messageId = newUUID()
        let sentAt = nowMs()
        let metaJson: String? = {
            guard let d = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]),
                  let s = String(data: d, encoding: .utf8) else { return nil }
            return s
        }()
        do {
            try await dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO dm_messages
                        (messageId, fromSessionId, targetSessionId, body,
                         context, metaJson, sentAtMs, receivedAtMs, deliveryStatus)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    messageId, "sonata", target, body, context, metaJson,
                    sentAt, sentAt, "queued",
                ])
            }
        } catch {
            return false
        }
        var delivered = false
        if let reg = MCPSessionRegistry.shared {
            delivered = await reg.deliverDM(
                target: target,
                messageId: messageId,
                body: body,
                fromSessionId: "sonata",
                context: context,
                metaJson: metaJson,
                sentAtMs: sentAt
            )
        }
        let status = delivered ? "delivered" : "queued"
        let deliveredAt: Int64? = delivered ? nowMs() : nil
        try? await dbPool.write { db in
            try db.execute(
                sql: "UPDATE dm_messages SET deliveryStatus = ?, deliveredAtMs = ? WHERE messageId = ?",
                arguments: [status, deliveredAt, messageId]
            )
        }
        return delivered
    })
}

// MARK: - Fan-out hook

/// Called from every code path that transitions a task's status. Looks up
/// the watcher rows for `taskId`, drops watchers whose session has been
/// silent past `taskWatcherStaleAfterMs`, and DMs the rest whose `on_mask`
/// matches the transition.
///
/// Fire-and-forget per the spec — errors are swallowed (the status update
/// itself already succeeded, so failing to fan out shouldn't roll it back).
@discardableResult
func fireTaskWatcherDMs(
    taskId: String,
    oldStatus: String,
    newStatus: String,
    dbPool: DatabasePool,
    liveness: TaskWatcherLiveness = makeProductionTaskWatcherLiveness(),
    dispatcher: TaskWatcherDispatcher? = nil
) async -> Int {
    // No-op when nothing actually changed — saves a query on idempotent
    // updates (e.g. /complete on an already-completed task).
    guard oldStatus != newStatus else { return 0 }

    let watchers: [(target: String, mask: Set<String>)]
    do {
        watchers = try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT target_session_id, on_mask FROM task_watchers WHERE taskId = ?",
                arguments: [taskId]
            )
            return rows.map { row in
                (target: row["target_session_id"] as? String ?? "",
                 mask: parseOnMask(row["on_mask"] as? String ?? "[]"))
            }
        }
    } catch {
        return 0
    }
    guard !watchers.isEmpty else { return 0 }

    let now = nowMs()
    let cutoff = now - taskWatcherStaleAfterMs
    let actualDispatcher = dispatcher ?? makeProductionTaskWatcherDispatcher(dbPool: dbPool)

    var deadTargets: [String] = []
    var fired = 0
    for w in watchers {
        let lastContacted = await liveness.lastContactedAtMs(w.target)
        let isDead = (lastContacted == nil) || (lastContacted! < cutoff)
        if isDead {
            deadTargets.append(w.target)
            continue
        }
        guard maskMatches(w.mask, newStatus: newStatus) else { continue }
        let bodyDict: [String: Any] = [
            "taskId": taskId,
            "oldStatus": oldStatus,
            "newStatus": newStatus,
            "ts": now,
        ]
        let bodyData = (try? JSONSerialization.data(withJSONObject: bodyDict, options: [.sortedKeys])) ?? Data()
        let bodyStr = String(data: bodyData, encoding: .utf8) ?? "{}"
        let meta: [String: Any] = [
            "kind": "task_watch_event",
            "taskId": taskId,
            "oldStatus": oldStatus,
            "newStatus": newStatus,
        ]
        _ = await actualDispatcher.send(w.target, bodyStr, "task_watch", meta)
        fired += 1
    }

    if !deadTargets.isEmpty {
        let placeholders = Array(repeating: "?", count: deadTargets.count).joined(separator: ",")
        // Build args INSIDE the write closure so the [DatabaseValueConvertible]
        // var doesn't get captured into a @Sendable closure (Swift 6 rejects
        // that capture because the element protocol isn't Sendable).
        let sql = "DELETE FROM task_watchers WHERE taskId = ? AND target_session_id IN (\(placeholders))"
        let deadCopy = deadTargets
        let taskIdCopy = taskId
        try? await dbPool.write { db in
            var args: [any DatabaseValueConvertible] = [taskIdCopy]
            args.append(contentsOf: deadCopy)
            try db.execute(sql: sql, arguments: StatementArguments(args))
        }
    }

    return fired
}

// MARK: - Watch / unwatch actions

let taskWatcherActions: [SonataAction] = [

    // POST /api/task/watch — register interest in a task's status transitions.
    SonataAction(
        name: "mem_task_watch",
        description: "Subscribe a session to status transitions on a task. Delivers a sonar DM on change; eliminates polling.",
        group: "/api/task",
        path: "/watch",
        method: .post,
        params: [
            ActionParam("taskId", .string, required: true, description: "Task ID to watch"),
            ActionParam("target_session_id", .string, required: true, description: "Session that should receive DMs"),
            ActionParam("on", .stringArray, description: "Subset of [done, failed, status_change]. Defaults to [status_change]."),
        ],
        handler: { ctx in
            let taskId = try ctx.params.require("taskId")
            let target = try ctx.params.require("target_session_id")
            guard MCPSessionKey.isValid(target) else {
                throw ActionError.invalidParam("target_session_id", "must match [A-Za-z0-9_-]{1,128}")
            }
            let onJSON = encodeOnMask(ctx.params.stringArray("on") ?? [])
            let now = nowMs()

            // Reject unknown taskIds — surfaces typos at registration time
            // instead of silently never firing.
            let exists = try await ctx.dbPool.read { db -> Bool in
                try Int.fetchOne(
                    db,
                    sql: "SELECT 1 FROM tasks WHERE id = ?",
                    arguments: [taskId]
                ) != nil
            }
            guard exists else {
                throw ActionError.notFound("Task not found: \(taskId)")
            }

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO task_watchers
                            (taskId, target_session_id, on_mask, createdAt)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(taskId, target_session_id) DO UPDATE SET
                            on_mask = excluded.on_mask
                        """,
                        arguments: [taskId, target, onJSON, now]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return TaskWatchResponse(ok: true, taskId: taskId, target_session_id: target, on_mask: onJSON)
        }
    ),

    // POST /api/task/unwatch — drop a watcher. Idempotent.
    SonataAction(
        name: "mem_task_unwatch",
        description: "Drop a previously-registered task watcher. Idempotent.",
        group: "/api/task",
        path: "/unwatch",
        method: .post,
        params: [
            ActionParam("taskId", .string, required: true, description: "Task ID"),
            ActionParam("target_session_id", .string, required: true, description: "Watcher session id"),
        ],
        handler: { ctx in
            let taskId = try ctx.params.require("taskId")
            let target = try ctx.params.require("target_session_id")
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "DELETE FROM task_watchers WHERE taskId = ? AND target_session_id = ?",
                        arguments: [taskId, target]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),
]

struct TaskWatchResponse: Encodable {
    let ok: Bool
    let taskId: String
    let target_session_id: String
    let on_mask: String
}
