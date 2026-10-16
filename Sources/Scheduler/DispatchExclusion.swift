import Foundation
import GRDB

/// A task can name sessions that must never run it.
///
/// prStar's live_review is the case that needs it: the payload's `dmTarget` is
/// the fixer session the reviewer DMs findings to. When /prfix runs from a pool
/// worker, that fixer sits `idle` between turns, so plain idle-worker selection
/// can hand the fixer its own review (2026-10-15, run 1308 on PR #762). The
/// reviewer and the fixer would then be one session DMing itself.
///
/// The task carries the list in `tasks.metadata` as `excludeSessionIds`. The
/// dispatcher copies it onto the worker event as `exclude_session_ids`, so it
/// still holds after HealthMonitor re-enqueues a stranded event to `pending`
/// and the claim endpoint or the SSE pusher picks the next worker.
///
/// An id matches a worker on any of its three names: workerId (what
/// `sonata_whoami` returns as routingId for a pool worker), sessionId (the
/// Claude session uuid) or sessionLabel (`sona-worker-N`). Callers name the
/// fixer by whichever handle they hold, so matching only one would leave the
/// other two as holes.
enum DispatchExclusion {
    static let taskMetadataKey = "excludeSessionIds"
    static let eventPayloadKey = "exclude_session_ids"

    /// The excluded ids in a task's metadata JSON. Missing, malformed or
    /// non-array values yield `[]`, which excludes nothing. Empty strings are
    /// dropped: a worker with a NULL sessionId compares as '' in SQL, and an
    /// empty entry must not exclude every such worker.
    static func ids(fromTaskMetadata metadata: String?) -> [String] {
        guard let data = metadata?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json[taskMetadataKey] as? [Any] else { return [] }
        return raw.compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    /// Predicate over a `workers` row: true when none of its three names is in
    /// `ids`. Empty `ids` is the tautology, so unexcluded tasks query exactly
    /// as before.
    static func workerPredicate(excluding ids: [String]) -> (sql: String, arguments: StatementArguments) {
        guard !ids.isEmpty else { return ("1", []) }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
            (workerId NOT IN (\(placeholders))
             AND COALESCE(sessionId, '') NOT IN (\(placeholders))
             AND COALESCE(sessionLabel, '') NOT IN (\(placeholders)))
            """
        var args: [DatabaseValueConvertible] = []
        for _ in 0..<3 { args.append(contentsOf: ids.map { $0 as DatabaseValueConvertible }) }
        return (sql, StatementArguments(args))
    }

    /// Predicate over a `workerEvents` row: true when the event's
    /// `exclude_session_ids` names none of this worker's three names. The
    /// json_valid guard sits in a CASE so json_each never sees a non-JSON
    /// payload (dispatchToChannel falls back to the raw prompt when
    /// serialization fails); a malformed row would otherwise error the whole
    /// claim query for every worker.
    static func eventPredicate(workerId: String, sessionId: String?, sessionLabel: String?) -> (sql: String, arguments: StatementArguments) {
        let sql = """
            (CASE WHEN json_valid(payload) THEN NOT EXISTS (
                SELECT 1 FROM json_each(payload, '$.\(eventPayloadKey)') x
                WHERE x.value IN (?, ?, ?)
            ) ELSE 1 END)
            """
        // '' never matches: ids(fromTaskMetadata:) drops empty strings.
        return (sql, [workerId, sessionId ?? "", sessionLabel ?? ""])
    }
}
