import XCTest
import GRDB
import Logging
@testable import Sonata

/// A worker event pushed a second time must say so.
///
/// THE INCIDENT (event 2892bbd5, 2026-10-09): a deploy-local relaunch killed
/// worker-5876913629 mid-event. Sonata respawned it with `--resume` under the
/// same workerId, the event was still `assigned` to it, and the fresh
/// MCPEventPusher (whose "already pushed" set lives only in memory) pushed it
/// again with an identical body. The resumed session read its own earlier
/// line "the restart may end this session" and closed the event as "restarted
/// as expected"; the deploy was half done and the suite had never run.
///
/// Relaunch is simulated here the way it happens in production: a second
/// MCPEventPusher over the same database. The redelivery assertions are
/// written to fail on the pre-fix pusher, which pushed the second copy with
/// no marker at all.
final class WorkerEventRedeliveryTests: XCTestCase {

    private let workerA = "worker-1111111111"
    private let workerB = "worker-2222222222"
    private let eventId = "evt-redelivery-test"

    private static let redeliveredLine =
        "[REDELIVERED: this event was already delivered 1 time(s); a prior session may have done part of it. Verify each step against artifacts before asserting state.]"

    private struct Frame: Sendable {
        let sessionKey: String
        let content: String
        let meta: [String: String]
    }

    private actor Sink {
        var frames: [Frame] = []
        var accept = true
        func record(_ f: Frame) -> Bool {
            guard accept else { return false }
            frames.append(f)
            return true
        }
        func setAccept(_ v: Bool) { accept = v }
    }

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    private func makePusher(_ pool: DatabasePool, _ sink: Sink) -> MCPEventPusher {
        MCPEventPusher(dbPool: pool, logger: Logger(label: "test.redelivery")) { key, content, meta in
            await sink.record(Frame(sessionKey: key, content: content, meta: meta))
        }
    }

    private func insertAssignedEvent(_ pool: DatabasePool, to worker: String) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await pool.write { [eventId] db in
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, payload, priority, assignedTo, status, createdAt, assignedAt)
                VALUES (?, 'task', ?, 5, ?, 'assigned', ?, ?)
                """, arguments: [eventId, #"{"prompt":"deploy and run the suite"}"#, worker, now, now])
        }
    }

    // MARK: - First delivery

    func testFirstDeliveryCarriesNoMarker() async throws {
        let pool = try makePool()
        let sink = Sink()
        try await insertAssignedEvent(pool, to: workerA)

        await makePusher(pool, sink).pushPendingWorkerEvents()

        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertNil(frames[0].meta["redelivered"])
        XCTAssertNil(frames[0].meta["delivery"])
        XCTAssertNil(frames[0].meta["first_delivered_at"])
        XCTAssertTrue(frames[0].content.hasPrefix("[TASK] "), frames[0].content)
        XCTAssertFalse(frames[0].content.contains("REDELIVERED"))
    }

    func testSamePusherDoesNotRepushWithinOneProcess() async throws {
        // The in-memory set still owns de-duplication inside one process; the
        // delivery counter must not turn every tick into a "redelivery".
        let pool = try makePool()
        let sink = Sink()
        try await insertAssignedEvent(pool, to: workerA)
        let pusher = makePusher(pool, sink)

        await pusher.pushPendingWorkerEvents()
        await pusher.pushPendingWorkerEvents()

        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
    }

    // MARK: - Redelivery (the incident)

    func testRelaunchRedeliveryToResumedSessionCarriesMarker() async throws {
        let pool = try makePool()
        let sink = Sink()
        try await insertAssignedEvent(pool, to: workerA)

        let before = Date()
        await makePusher(pool, sink).pushPendingWorkerEvents()
        let after = Date()
        // Relaunch: new process, new pusher, same row still `assigned` to the
        // same (resumed) worker.
        await makePusher(pool, sink).pushPendingWorkerEvents()

        let frames = await sink.frames
        XCTAssertEqual(frames.count, 2, "relaunch must redeliver the in-flight event")
        guard frames.count == 2 else { return }
        let second = frames[1]
        XCTAssertEqual(second.sessionKey, workerA)
        XCTAssertEqual(second.meta["redelivered"], "true")
        XCTAssertEqual(second.meta["delivery"], "2")
        XCTAssertEqual(second.meta["event_id"], eventId, "existing meta must survive")

        let firstLine = second.content.split(separator: "\n", maxSplits: 1).first.map(String.init)
        XCTAssertEqual(firstLine, Self.redeliveredLine)
        XCTAssertTrue(second.content.contains("[TASK] deploy and run the suite"),
                      "the original body must still be delivered: \(second.content)")

        let iso = ISO8601DateFormatter()
        let stamped = second.meta["first_delivered_at"].flatMap { iso.date(from: $0) }
        XCTAssertNotNil(stamped, "first_delivered_at must be ISO-8601: \(String(describing: second.meta["first_delivered_at"]))")
        if let stamped {
            // ISO8601DateFormatter drops sub-second precision.
            XCTAssertGreaterThanOrEqual(stamped.timeIntervalSince1970, floor(before.timeIntervalSince1970))
            XCTAssertLessThanOrEqual(stamped.timeIntervalSince1970, after.timeIntervalSince1970)
        }
    }

    func testThirdDeliveryCountsBothPriorDeliveries() async throws {
        let pool = try makePool()
        let sink = Sink()
        try await insertAssignedEvent(pool, to: workerA)

        for _ in 0..<3 { await makePusher(pool, sink).pushPendingWorkerEvents() }

        let frames = await sink.frames
        XCTAssertEqual(frames.count, 3)
        guard frames.count == 3 else { return }
        XCTAssertEqual(frames[2].meta["delivery"], "3")
        XCTAssertTrue(frames[2].content.hasPrefix("[REDELIVERED: this event was already delivered 2 time(s);"),
                      frames[2].content)
        XCTAssertEqual(frames[1].meta["first_delivered_at"], frames[2].meta["first_delivered_at"],
                       "first_delivered_at is the FIRST delivery, never moved")
    }

    func testReclaimedEventDeliveredToAnotherWorkerCarriesMarker() async throws {
        // reclaimStrandedEvents / unregister re-enqueue to `pending`; the next
        // worker to get it must learn a prior session may have started it.
        let pool = try makePool()
        let sink = Sink()
        try await insertAssignedEvent(pool, to: workerA)
        await makePusher(pool, sink).pushPendingWorkerEvents()

        try await pool.write { [eventId, workerB] db in
            try db.execute(sql: "UPDATE workerEvents SET status = 'pending', assignedTo = NULL WHERE id = ?",
                           arguments: [eventId])
            try db.execute(sql: "UPDATE workerEvents SET status = 'assigned', assignedTo = ? WHERE id = ?",
                           arguments: [workerB, eventId])
        }
        await makePusher(pool, sink).pushPendingWorkerEvents()

        let frames = await sink.frames
        XCTAssertEqual(frames.count, 2)
        guard frames.count == 2 else { return }
        XCTAssertEqual(frames[1].sessionKey, workerB)
        XCTAssertEqual(frames[1].meta["redelivered"], "true")
        XCTAssertEqual(frames[1].meta["delivery"], "2")
    }

    // MARK: - Only a delivery that landed counts

    func testFailedPushIsNotCountedAsADelivery() async throws {
        // No live SSE writer → nothing reached a session. Counting it would
        // stamp the eventual FIRST real delivery as a redelivery.
        let pool = try makePool()
        let sink = Sink()
        try await insertAssignedEvent(pool, to: workerA)

        await sink.setAccept(false)
        await makePusher(pool, sink).pushPendingWorkerEvents()
        await sink.setAccept(true)
        await makePusher(pool, sink).pushPendingWorkerEvents()

        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertNil(frames.first?.meta["redelivered"])
    }
}
