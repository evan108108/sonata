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

            let taskRow: Row? = try dbPool.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT id, title, status, source, assignedTo, dueAt,
                           startedAt, completedAt, retryCount, lastError,
                           createdAt, updatedAt
                    FROM tasks WHERE id = ?
                """, arguments: [taskId])
            }
            guard let taskRow else {
                return WhatHappenedResponse.errorResponse(
                    domain: "task",
                    artifact_id: taskId,
                    message: "task not found: \(taskId)"
                )
            }

            let status: String = taskRow["status"]
            let createdAt: Int64 = taskRow["createdAt"]
            let startedAt: Int64? = taskRow["startedAt"]
            let completedAt: Int64? = taskRow["completedAt"]
            let updatedAt: Int64 = taskRow["updatedAt"]
            let assignedTo: String? = taskRow["assignedTo"]
            let source: String? = taskRow["source"]
            let lastError: String? = taskRow["lastError"]
            let title: String = taskRow["title"]

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
            let weRows: [Row] = try dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, type, payload, status, assignedTo,
                           createdAt, assignedAt, completedAt
                    FROM workerEvents
                    WHERE payload LIKE ?
                    ORDER BY createdAt ASC
                """, arguments: ["%\"task_id\":\"\(taskId)\"%"])
            }
            for row in weRows {
                let evStatus: String = row["status"]
                let evType: String = row["type"]
                let evAssignedTo: String? = row["assignedTo"]
                let evCreatedAt: Int64 = row["createdAt"]
                let evAssignedAt: Int64? = row["assignedAt"]
                let evCompletedAt: Int64? = row["completedAt"]
                actions.append(WhatHappenedAction(
                    when: evCompletedAt ?? evAssignedAt ?? evCreatedAt,
                    action_kind: "workerEvent_\(evType)_\(evStatus)",
                    actor: evAssignedTo,
                    verdict: evStatus,
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

            let row: Row? = try dbPool.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT messageId, targetSessionId, fromSessionId, body,
                           sentAtMs, receivedAtMs, deliveredAtMs, ackedAtMs,
                           deliveryStatus, resolvedSessionKey, resolvedKind
                    FROM dm_messages
                    WHERE messageId = ?
                """, arguments: [messageId])
            }
            guard let row else {
                return WhatHappenedResponse.errorResponse(
                    domain: "dm",
                    artifact_id: messageId,
                    message: "dm message not found: \(messageId)"
                )
            }

            let target: String = row["targetSessionId"]
            let fromSessionId: String? = row["fromSessionId"]
            let sentAtMs: Int64 = row["sentAtMs"]
            let deliveredAtMs: Int64? = row["deliveredAtMs"]
            let ackedAtMs: Int64? = row["ackedAtMs"]
            let deliveryStatus: String = row["deliveryStatus"]
            let resolvedKind: String? = row["resolvedKind"]

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

            let row: Row? = try dbPool.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT id, type, source, importance, status, supersededBy,
                           revisionOf, revisionNote, createdAt, updatedAt,
                           lastAccessedAt, accessCount
                    FROM memories WHERE id = ?
                """, arguments: [id])
            }
            guard let row else {
                return WhatHappenedResponse.errorResponse(
                    domain: "memory",
                    artifact_id: id,
                    message: "memory not found: \(id)"
                )
            }

            let type: String = row["type"]
            let source: String? = row["source"]
            let status: String? = row["status"]
            let supersededBy: String? = row["supersededBy"]
            let revisionOf: String? = row["revisionOf"]
            let revisionNote: String? = row["revisionNote"]
            let createdAt: Int64 = row["createdAt"]
            let updatedAt: Int64 = row["updatedAt"]
            let lastAccessedAt: Int64? = row["lastAccessedAt"]
            let accessCount: Int? = row["accessCount"]

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
                    "importance": .double((row["importance"] as? Double) ?? 0),
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

            let embedRow: Row? = try dbPool.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT model, dimensions, createdAt
                    FROM memoryEmbeddings
                    WHERE memoryId = ?
                    ORDER BY createdAt DESC LIMIT 1
                """, arguments: [id])
            }

            var staleness: [String] = []
            if embedRow == nil {
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
