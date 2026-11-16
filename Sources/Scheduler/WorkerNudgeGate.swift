import Foundation
import GRDB

/// Decides whether the health monitor's "busy but idle" nudge may be sent,
/// from a FRESH read of the worker row and the event row it names.
///
/// ## Why this exists (2026-11-16)
///
/// The nudge used to trust `workers.currentEventId` alone. That column can
/// outlive the claim it describes: an event gets reassigned, or the registry
/// re-registers and a slot label ("sona-worker-8") moves to a new workerId,
/// while an old worker row still points at the event. Three incidents in ~24h:
///
///   - 11/15 (memory 10912ad4): sona-worker-5 was told to complete 195bfba5
///     while sona-worker-9 held it.
///   - 11/16 (memory d6f969f0): slot-addressed nudges during a 6-event
///     reassignment batch after a ~12h dispatch gap.
///   - 11/16 (memory 80943708): 5 nudges reached session ea5b1c11 for
///     58227180, an event whose channel push that session never received.
///     Minutes later the registry re-registered and sona-worker-2 held it.
///
/// Obeying such a nudge closes another worker's task undone. So the nudge
/// now requires the event row to agree: the event is `assigned`, to THIS
/// workerId, from THIS worker's current session. It is routed to the
/// event's `sessionId` (the session that claimed it), never to a label.
///
/// A worker whose `lastProgressAt` predates the event's `assignedAt` has
/// completed no model turn since the hand-off, so it never read the event
/// (claim committed, push not delivered). Asking it to complete_event is
/// wrong; that case is reported as `.possiblyStranded` and left to
/// `reclaimStrandedEvents`, which re-enqueues it.
enum WorkerNudgeGate {

    struct WorkerSnapshot: Equatable, Sendable {
        let workerId: String
        let sessionId: String?
        let sessionLabel: String
        let status: String
        let currentEventId: String?
        let lastHeartbeat: Int64
        let lastProgressAt: Int64?
    }

    struct EventSnapshot: Equatable, Sendable {
        let id: String
        let status: String
        let assignedTo: String?
        let assignedAt: Int64?
        let sessionId: String?
    }

    enum SkipReason: Equatable, Sendable {
        case workerGone
        case workerNotBusy(status: String)
        case workerMovedOn(currentEventId: String?)
        case heartbeatStale
        case progressFresh
        case eventGone
        case eventNotAssigned(status: String)
        /// The event is held by another workerId (reassignment, or a registry
        /// reset that left this worker row pointing at it).
        case reassigned(holder: String?)
        /// The event row names no claiming session, so there is nowhere
        /// safe to route a DM.
        case noHolderSession
        /// The worker row's current session is not the session that claimed
        /// the event; a DM to either one could reach a session without it.
        case sessionMismatch(workerSession: String?, eventSession: String)
    }

    enum Decision: Equatable, Sendable {
        /// Send exactly one nudge, addressed to the session holding the event.
        case nudge(targetSessionId: String)
        /// Ownership checks pass but the holder has done no model turn since
        /// `assignedAt`: it never received the event. Don't ask it to complete.
        case possiblyStranded(sessionId: String, assignedAt: Int64, lastProgressAt: Int64?)
        case skip(SkipReason)
    }

    /// Pure decision. `aliveSinceMs` / `stuckBeforeMs` are the same cutoffs
    /// the sweep query uses (heartbeat freshness, progress staleness), so the
    /// re-read re-asserts every predicate rather than only the new ones.
    static func decide(
        eventId: String,
        worker: WorkerSnapshot?,
        event: EventSnapshot?,
        aliveSinceMs: Int64,
        stuckBeforeMs: Int64
    ) -> Decision {
        guard let w = worker else { return .skip(.workerGone) }
        guard w.status == "busy" else { return .skip(.workerNotBusy(status: w.status)) }
        guard w.currentEventId == eventId else { return .skip(.workerMovedOn(currentEventId: w.currentEventId)) }
        guard w.lastHeartbeat >= aliveSinceMs else { return .skip(.heartbeatStale) }
        if let p = w.lastProgressAt, p >= stuckBeforeMs { return .skip(.progressFresh) }

        guard let e = event else { return .skip(.eventGone) }
        guard e.status == "assigned" else { return .skip(.eventNotAssigned(status: e.status)) }
        guard e.assignedTo == w.workerId else { return .skip(.reassigned(holder: e.assignedTo)) }
        guard let holder = e.sessionId, !holder.isEmpty else { return .skip(.noHolderSession) }
        guard w.sessionId == holder else {
            return .skip(.sessionMismatch(workerSession: w.sessionId, eventSession: holder))
        }

        // No model turn since the hand-off → the event was never read.
        if let assignedAt = e.assignedAt, (w.lastProgressAt ?? Int64.min) < assignedAt {
            return .possiblyStranded(sessionId: holder, assignedAt: assignedAt, lastProgressAt: w.lastProgressAt)
        }
        return .nudge(targetSessionId: holder)
    }

    /// Fresh read of both rows, keyed by the ids the sweep found. Call inside
    /// the same transaction as the nudge's durable insert so the check and
    /// the send can't be split by a reassignment.
    static func snapshot(
        _ db: Database, workerId: String, eventId: String
    ) throws -> (WorkerSnapshot?, EventSnapshot?) {
        let w = try Row.fetchOne(db, sql: """
            SELECT workerId, sessionId, sessionLabel, status, currentEventId,
                   lastHeartbeat, lastProgressAt
            FROM workers WHERE workerId = ?
            """, arguments: [workerId]).map { row in
            WorkerSnapshot(
                workerId: row["workerId"],
                sessionId: row["sessionId"],
                sessionLabel: row["sessionLabel"],
                status: row["status"],
                currentEventId: row["currentEventId"],
                lastHeartbeat: row["lastHeartbeat"],
                lastProgressAt: row["lastProgressAt"])
        }
        let e = try Row.fetchOne(db, sql: """
            SELECT id, status, assignedTo, assignedAt, sessionId
            FROM workerEvents WHERE id = ?
            """, arguments: [eventId]).map { row in
            EventSnapshot(
                id: row["id"],
                status: row["status"],
                assignedTo: row["assignedTo"],
                assignedAt: row["assignedAt"],
                sessionId: row["sessionId"])
        }
        return (w, e)
    }
}
