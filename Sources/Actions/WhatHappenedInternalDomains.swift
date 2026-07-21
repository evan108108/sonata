import Foundation
import GRDB

// Boot-time registrations of the three internal whathappened domains:
// `task`, `dm`, `memory`. Called once from SonataApp.swift after the
// ActionRegistry is built. Every domain returns the shared
// WhatHappenedResponse shape; see the wiki pattern page for the
// convention.

private let staleHeartbeatMs: Int64 = 15 * 60 * 1000
private let taskInFlightStatuses: [String] = ["active", "in_progress", "assigned"]

func registerInternalWhatHappenedDomains(dbPool: DatabasePool) {
    registerTaskDomain(dbPool: dbPool)
    registerDMDomain(dbPool: dbPool)
    registerMemoryDomain(dbPool: dbPool)
}

// MARK: - task

private func registerTaskDomain(dbPool: DatabasePool) {
    WhatHappenedRegistry.shared.register(
        domain: "task",
        argsSchema: [
            WhatHappenedArgSpec("taskId", type: .string, required: true,
                                description: "Sonata task id")
        ],
        description: "Sonata task — status timeline from tasks + workerEvents + task_watchers.",
        handler: { params, dbPool in
            let taskId = try params.require("taskId")
            let queriedAt = nowMs()

            struct TaskFields: Sendable {
                let status: String
                let createdAt: Int64
                let startedAt: Int64?
                let completedAt: Int64?
                let updatedAt: Int64
                let assignedTo: String?
                let source: String?
                let lastError: String?
                let title: String
            }
            let task: TaskFields? = try await dbPool.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT id, title, status, source, assignedTo, dueAt,
                           startedAt, completedAt, retryCount, lastError,
                           createdAt, updatedAt
                    FROM tasks WHERE id = ?
                """, arguments: [taskId]) else { return nil }
                return TaskFields(
                    status: row["status"],
                    createdAt: row["createdAt"],
                    startedAt: row["startedAt"],
                    completedAt: row["completedAt"],
                    updatedAt: row["updatedAt"],
                    assignedTo: row["assignedTo"],
                    source: row["source"],
                    lastError: row["lastError"],
                    title: row["title"]
                )
            }
            guard let task else {
                return WhatHappenedResponse.errorResponse(
                    domain: "task",
                    artifact_id: taskId,
                    message: "task not found: \(taskId)"
                )
            }

            let status = task.status
            let createdAt = task.createdAt
            let startedAt = task.startedAt
            let completedAt = task.completedAt
            let updatedAt = task.updatedAt
            let assignedTo = task.assignedTo
            let source = task.source
            let lastError = task.lastError
            let title = task.title

            var actions: [WhatHappenedAction] = []

            actions.append(WhatHappenedAction(
                when: createdAt,
                action_kind: "task_created",
                actor: source,
                verdict: nil,
                sha: nil,
                url: nil,
                meta: [
                    "title": .string(title),
                    "status_at_creation": .string("pending"),
                ]
            ))

            if let startedAt {
                actions.append(WhatHappenedAction(
                    when: startedAt,
                    action_kind: "task_started",
                    actor: assignedTo,
                    verdict: nil,
                    sha: nil,
                    url: nil,
                    meta: nil
                ))
            }
            if let completedAt {
                actions.append(WhatHappenedAction(
                    when: completedAt,
                    action_kind: "task_\(status)",
                    actor: assignedTo,
                    verdict: status,
                    sha: nil,
                    url: nil,
                    meta: lastError.map { ["last_error": .string($0)] }
                ))
            }

            // workerEvents rows related to this task. Payload is JSON;
            // task rows carry a task_id field.
            struct WorkerEventFields: Sendable {
                let status: String
                let type: String
                let assignedTo: String?
                let createdAt: Int64
                let assignedAt: Int64?
                let completedAt: Int64?
            }
            let weRows: [WorkerEventFields] = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, type, payload, status, assignedTo,
                           createdAt, assignedAt, completedAt
                    FROM workerEvents
                    WHERE payload LIKE ?
                    ORDER BY createdAt ASC
                """, arguments: ["%\"task_id\":\"\(taskId)\"%"]).map { row in
                    WorkerEventFields(
                        status: row["status"],
                        type: row["type"],
                        assignedTo: row["assignedTo"],
                        createdAt: row["createdAt"],
                        assignedAt: row["assignedAt"],
                        completedAt: row["completedAt"]
                    )
                }
            }
            for ev in weRows {
                actions.append(WhatHappenedAction(
                    when: ev.completedAt ?? ev.assignedAt ?? ev.createdAt,
                    action_kind: "workerEvent_\(ev.type)_\(ev.status)",
                    actor: ev.assignedTo,
                    verdict: ev.status,
                    sha: nil,
                    url: nil,
                    meta: nil
                ))
            }

            actions.sort { $0.when < $1.when }

            var inFlight: WhatHappenedInFlight? = nil
            var staleness: [String] = []

            if taskInFlightStatuses.contains(status), completedAt == nil {
                let heartbeat = updatedAt
                inFlight = WhatHappenedInFlight(
                    actor: assignedTo,
                    started_at: startedAt ?? createdAt,
                    action_kind: "task_\(status)",
                    last_heartbeat: heartbeat
                )
                let stale = queriedAt - heartbeat
                if stale > staleHeartbeatMs {
                    let mins = stale / 60_000
                    staleness.append("in_flight heartbeat is \(mins) minutes old")
                }
            }

            let watcherCount: Int? = try await dbPool.read { db in
                try Int.fetchOne(db,
                    sql: "SELECT COUNT(*) FROM task_watchers WHERE taskId = ?",
                    arguments: [taskId])
            }
            if let watcherCount, watcherCount > 0 {
                staleness.append("\(watcherCount) watcher(s) subscribed")
            }

            return WhatHappenedResponse(
                domain: "task",
                artifact_id: taskId,
                queried_at: queriedAt,
                actions: actions,
                in_flight: inFlight,
                external_verification: nil,
                staleness_notes: staleness,
                error: nil
            )
        }
    )
}

// MARK: - dm

private func registerDMDomain(dbPool: DatabasePool) {
    WhatHappenedRegistry.shared.register(
        domain: "dm",
        argsSchema: [
            WhatHappenedArgSpec("messageId", type: .string, required: true,
                                description: "DM message id (from dm_send response)")
        ],
        description: "DM message — send + delivery + ack timeline from dm_messages.",
        handler: { params, dbPool in
            let messageId = try params.require("messageId")
            let queriedAt = nowMs()

            struct DMFields: Sendable {
                let target: String
                let fromSessionId: String?
                let sentAtMs: Int64
                let deliveredAtMs: Int64?
                let ackedAtMs: Int64?
                let deliveryStatus: String
                let resolvedKind: String?
            }
            let dm: DMFields? = try await dbPool.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT messageId, targetSessionId, fromSessionId, body,
                           sentAtMs, receivedAtMs, deliveredAtMs, ackedAtMs,
                           deliveryStatus, resolvedSessionKey, resolvedKind
                    FROM dm_messages
                    WHERE messageId = ?
                """, arguments: [messageId]) else { return nil }
                return DMFields(
                    target: row["targetSessionId"],
                    fromSessionId: row["fromSessionId"],
                    sentAtMs: row["sentAtMs"],
                    deliveredAtMs: row["deliveredAtMs"],
                    ackedAtMs: row["ackedAtMs"],
                    deliveryStatus: row["deliveryStatus"],
                    resolvedKind: row["resolvedKind"]
                )
            }
            guard let dm else {
                return WhatHappenedResponse.errorResponse(
                    domain: "dm",
                    artifact_id: messageId,
                    message: "dm message not found: \(messageId)"
                )
            }

            let target = dm.target
            let fromSessionId = dm.fromSessionId
            let sentAtMs = dm.sentAtMs
            let deliveredAtMs = dm.deliveredAtMs
            let ackedAtMs = dm.ackedAtMs
            let deliveryStatus = dm.deliveryStatus
            let resolvedKind = dm.resolvedKind

            var actions: [WhatHappenedAction] = []
            actions.append(WhatHappenedAction(
                when: sentAtMs,
                action_kind: "dm_sent",
                actor: fromSessionId,
                verdict: nil,
                sha: nil,
                url: nil,
                meta: [
                    "target": .string(target),
                    "resolved_kind": .string(resolvedKind ?? ""),
                ]
            ))
            if let deliveredAtMs {
                actions.append(WhatHappenedAction(
                    when: deliveredAtMs,
                    action_kind: "dm_delivered",
                    actor: target,
                    verdict: deliveryStatus,
                    sha: nil,
                    url: nil,
                    meta: nil
                ))
            }
            if let ackedAtMs {
                actions.append(WhatHappenedAction(
                    when: ackedAtMs,
                    action_kind: "dm_acked",
                    actor: target,
                    verdict: nil,
                    sha: nil,
                    url: nil,
                    meta: nil
                ))
            }

            var inFlight: WhatHappenedInFlight? = nil
            if deliveryStatus == "sent" && deliveredAtMs == nil {
                inFlight = WhatHappenedInFlight(
                    actor: target,
                    started_at: sentAtMs,
                    action_kind: "dm_awaiting_delivery",
                    last_heartbeat: nil
                )
            } else if deliveredAtMs != nil && ackedAtMs == nil {
                inFlight = WhatHappenedInFlight(
                    actor: target,
                    started_at: deliveredAtMs,
                    action_kind: "dm_awaiting_ack",
                    last_heartbeat: nil
                )
            }

            var staleness: [String] = []
            if deliveryStatus == "not_live" {
                staleness.append("target session was not live at send time")
            }
            if deliveryStatus == "not_found" {
                staleness.append("target could not be resolved to any session or peer")
            }

            return WhatHappenedResponse(
                domain: "dm",
                artifact_id: messageId,
                queried_at: queriedAt,
                actions: actions,
                in_flight: inFlight,
                external_verification: nil,
                staleness_notes: staleness,
                error: nil
            )
        }
    )
}

// MARK: - memory

private func registerMemoryDomain(dbPool: DatabasePool) {
    WhatHappenedRegistry.shared.register(
        domain: "memory",
        argsSchema: [
            WhatHappenedArgSpec("id", type: .string, required: true,
                                description: "Memory id")
        ],
        description: "Memory — creation + revision + supersede chain + embedding + FTS status.",
        handler: { params, dbPool in
            let id = try params.require("id")
            let queriedAt = nowMs()

            struct MemoryFields: Sendable {
                let type: String
                let source: String?
                let status: String?
                let supersededBy: String?
                let revisionOf: String?
                let revisionNote: String?
                let createdAt: Int64
                let updatedAt: Int64
                let lastAccessedAt: Int64?
                let accessCount: Int?
                let importance: Double
            }
            let memory: MemoryFields? = try await dbPool.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT id, type, source, importance, status, supersededBy,
                           revisionOf, revisionNote, createdAt, updatedAt,
                           lastAccessedAt, accessCount
                    FROM memories WHERE id = ?
                """, arguments: [id]) else { return nil }
                return MemoryFields(
                    type: row["type"],
                    source: row["source"],
                    status: row["status"],
                    supersededBy: row["supersededBy"],
                    revisionOf: row["revisionOf"],
                    revisionNote: row["revisionNote"],
                    createdAt: row["createdAt"],
                    updatedAt: row["updatedAt"],
                    lastAccessedAt: row["lastAccessedAt"],
                    accessCount: row["accessCount"],
                    importance: (row["importance"] as? Double) ?? 0
                )
            }
            guard let memory else {
                return WhatHappenedResponse.errorResponse(
                    domain: "memory",
                    artifact_id: id,
                    message: "memory not found: \(id)"
                )
            }

            let type = memory.type
            let source = memory.source
            let status = memory.status
            let supersededBy = memory.supersededBy
            let revisionOf = memory.revisionOf
            let revisionNote = memory.revisionNote
            let createdAt = memory.createdAt
            let updatedAt = memory.updatedAt
            let lastAccessedAt = memory.lastAccessedAt
            let accessCount = memory.accessCount

            var actions: [WhatHappenedAction] = []
            actions.append(WhatHappenedAction(
                when: createdAt,
                action_kind: "memory_created",
                actor: source,
                verdict: nil,
                sha: nil,
                url: nil,
                meta: [
                    "type": .string(type),
                    "importance": .double(memory.importance),
                ]
            ))
            if let revisionOf {
                actions.append(WhatHappenedAction(
                    when: createdAt,
                    action_kind: "memory_revised_from",
                    actor: source,
                    verdict: nil,
                    sha: nil,
                    url: nil,
                    meta: [
                        "revised_from": .string(revisionOf),
                        "note": .string(revisionNote ?? ""),
                    ]
                ))
            }
            if updatedAt > createdAt {
                actions.append(WhatHappenedAction(
                    when: updatedAt,
                    action_kind: "memory_updated",
                    actor: nil,
                    verdict: status,
                    sha: nil,
                    url: nil,
                    meta: nil
                ))
            }
            if let supersededBy {
                actions.append(WhatHappenedAction(
                    when: updatedAt,
                    action_kind: "memory_superseded",
                    actor: nil,
                    verdict: "superseded",
                    sha: nil,
                    url: nil,
                    meta: ["superseded_by": .string(supersededBy)]
                ))
            }
            if let lastAccessedAt, let accessCount, accessCount > 0 {
                actions.append(WhatHappenedAction(
                    when: lastAccessedAt,
                    action_kind: "memory_last_accessed",
                    actor: nil,
                    verdict: nil,
                    sha: nil,
                    url: nil,
                    meta: ["access_count": .int(Int64(accessCount))]
                ))
            }

            actions.sort { $0.when < $1.when }

            let hasEmbedding: Bool = (try? await dbPool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT 1 FROM memoryEmbeddings
                    WHERE memoryId = ? LIMIT 1
                """, arguments: [id]) != nil
            }) ?? false

            var staleness: [String] = []
            if !hasEmbedding {
                staleness.append("no embedding stored for this memory")
            }
            if status == "archived" {
                staleness.append("memory is archived")
            }
            if supersededBy != nil {
                staleness.append("memory has been superseded by \(supersededBy!)")
            }

            return WhatHappenedResponse(
                domain: "memory",
                artifact_id: id,
                queried_at: queriedAt,
                actions: actions,
                in_flight: nil,
                external_verification: nil,
                staleness_notes: staleness,
                error: nil
            )
        }
    )
}
