import Foundation
import GRDB

/// Delivery bookkeeping for worker events.
///
/// An event can reach a session more than once: a relaunch empties
/// MCPEventPusher's in-memory "already pushed" set and the still-`assigned`
/// event goes back to the `--resume`d worker, and reclaim/unregister re-enqueue
/// an event that a dead session may have half done. Before v45 every copy was
/// byte-identical, so the receiving session could not tell a fresh event from
/// one it had already started. On 2026-10-09 (event 2892bbd5) a resumed
/// session closed a half-finished deploy by reading its own earlier narration.
///
/// The count lives on the row (deliveryCount / firstDeliveredAt /
/// lastDeliveredToSession) and is bumped only after a push lands, so a push
/// with no live writer never turns the real first delivery into a "redelivery".
struct WorkerEventDeliveryStamp: Equatable, Sendable {
    /// 1-based number of the delivery about to be made.
    let delivery: Int
    /// When the event first reached a session; nil on a first delivery.
    let firstDeliveredAt: Int64?

    var isRedelivery: Bool { delivery > 1 }
}

enum WorkerEventDelivery {

    /// Stamp for the next delivery of `eventId`, read before pushing.
    static func nextStamp(_ db: Database, eventId: String) throws -> WorkerEventDeliveryStamp {
        let row = try Row.fetchOne(db, sql: """
            SELECT deliveryCount, firstDeliveredAt FROM workerEvents WHERE id = ?
            """, arguments: [eventId])
        let count = (row?["deliveryCount"] as Int?) ?? 0
        let first = row?["firstDeliveredAt"] as Int64?
        return WorkerEventDeliveryStamp(delivery: count + 1, firstDeliveredAt: first)
    }

    /// Record a delivery that reached `sessionKey`. Call only after the push
    /// succeeded.
    static func recordDelivered(
        _ db: Database, eventId: String, sessionKey: String, at now: Int64
    ) throws {
        try db.execute(sql: """
            UPDATE workerEvents
            SET deliveryCount = deliveryCount + 1,
                firstDeliveredAt = COALESCE(firstDeliveredAt, ?),
                lastDeliveredToSession = ?
            WHERE id = ?
            """, arguments: [now, sessionKey, eventId])
    }

    /// Channel meta added on a redelivery; empty on a first delivery.
    static func meta(for stamp: WorkerEventDeliveryStamp) -> [String: String] {
        guard stamp.isRedelivery else { return [:] }
        var meta = ["redelivered": "true", "delivery": String(stamp.delivery)]
        if let first = stamp.firstDeliveredAt {
            meta["first_delivered_at"] = ISO8601DateFormatter().string(
                from: Date(timeIntervalSince1970: TimeInterval(first) / 1000.0))
        }
        return meta
    }

    /// One-line lead for the pushed text on a redelivery; nil on a first one.
    static func leadLine(for stamp: WorkerEventDeliveryStamp) -> String? {
        guard stamp.isRedelivery else { return nil }
        return "[REDELIVERED: this event was already delivered \(stamp.delivery - 1) time(s); "
            + "a prior session may have done part of it. "
            + "Verify each step against artifacts before asserting state.]"
    }

    /// Apply a stamp to a built channel message.
    static func decorate(
        content: String, meta: [String: String], stamp: WorkerEventDeliveryStamp
    ) -> (content: String, meta: [String: String]) {
        let merged = meta.merging(Self.meta(for: stamp)) { existing, _ in existing }
        guard let lead = leadLine(for: stamp) else { return (content, merged) }
        return (lead + "\n" + content, merged)
    }
}
