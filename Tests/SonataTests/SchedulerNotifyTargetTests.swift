import XCTest
import GRDB
import Logging
@testable import Sonata

/// v43 `notifyTarget` column on calendarEvents + scheduledJobs, plus the
/// SchedulerActor fire path that DMs the target instead of spawning a
/// worker when set. Covers:
///
///   1. Schema round-trip: INSERT with notifyTarget survives SELECT for
///      both tables.
///   2. Body-wrap contract: the exact preamble format the recipient sees.
///      Locked here because sessions depend on being able to detect a
///      scheduled fire vs a peer DM by pattern.
///   3. Fallback path: `attemptScheduledNotify` against a DB with no
///      workers / sessions / sonar peer returns a `fellBackNotFound`
///      outcome — the caller's fallback (spawn worker / shell exec) then
///      runs so the schedule doesn't silently disappear.
///
/// Uses `TestDatabase.makePool()` (full production migrator) so the
/// v43 migration column is really there — see 2026-08-11 partial-index
/// trap for why hand-rolled schemas in tests are banned.
final class SchedulerNotifyTargetTests: XCTestCase {

    // MARK: - Schema round-trip

    func testCalendarEventPersistsNotifyTarget() async throws {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let id = UUID().uuidString.lowercased()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO calendarEvents
                    (id, title, prompt, scheduledAt, taskType, notifyTarget,
                     runCount, enabled, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, 0, 1, ?, ?)
                """,
                arguments: [id, "test", "run this", now + 60_000,
                           "spawn-claude", "sona-worker-3", now, now]
            )
        }

        let row = try await pool.read { db in
            try CalendarEventRow.fetchOne(db, sql: "SELECT * FROM calendarEvents WHERE id = ?", arguments: [id])
        }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.notifyTarget, "sona-worker-3")
    }

    func testCalendarEventDefaultsNotifyTargetToNil() async throws {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let id = UUID().uuidString.lowercased()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO calendarEvents
                    (id, title, scheduledAt, taskType, runCount, enabled, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, 0, 1, ?, ?)
                """,
                arguments: [id, "no-notify", now + 60_000, "spawn-claude", now, now]
            )
        }

        let row = try await pool.read { db in
            try CalendarEventRow.fetchOne(db, sql: "SELECT * FROM calendarEvents WHERE id = ?", arguments: [id])
        }
        XCTAssertNotNil(row)
        XCTAssertNil(row?.notifyTarget, "old rows / rows without notifyTarget must read as nil")
    }

    func testScheduledJobPersistsNotifyTarget() async throws {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let id = UUID().uuidString.lowercased()
        let now = Double(Date().timeIntervalSince1970 * 1000)
        try await pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO scheduledJobs
                    (id, name, schedule, command, enabled, nextRunAt, notifyTarget, createdAt)
                VALUES (?, ?, ?, ?, 1, ?, ?, ?)
                """,
                arguments: [id, "ping-supervisor", "*/5 * * * *", "check batch",
                           now + 300_000, "supervisor", now]
            )
        }

        let row = try await pool.read { db in
            try ScheduledJobRow.fetchOne(db, sql: "SELECT * FROM scheduledJobs WHERE name = ?", arguments: ["ping-supervisor"])
        }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.notifyTarget, "supervisor")
    }

    // MARK: - Body-wrap contract

    func testWrappedNotifyBodyForCalendarEvent() {
        let firedAt = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15T08:00:00Z
        let out = SchedulerActor.wrappedNotifyBody(
            bodyText: "verify scout #537 stamped correctly",
            entryId: "abc123",
            source: .calendarEvent,
            firedAt: firedAt
        )
        XCTAssertTrue(out.hasPrefix("[scheduled reminder from calendar_event/abc123, fired at 2027-01-15T08:00:00Z]\n\n"),
                      "body wrap must open with the calendar_event/<id> preamble; got: \(out)")
        XCTAssertTrue(out.hasSuffix("verify scout #537 stamped correctly"),
                      "body wrap must end with the original prompt verbatim")
    }

    func testWrappedNotifyBodyForScheduledJob() {
        let firedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let out = SchedulerActor.wrappedNotifyBody(
            bodyText: "check overnight batch",
            entryId: "job-42",
            source: .scheduledJob,
            firedAt: firedAt
        )
        XCTAssertTrue(out.hasPrefix("[scheduled reminder from scheduler_job/job-42, fired at 2027-01-15T08:00:00Z]\n\n"),
                      "body wrap must open with the scheduler_job/<id> preamble; got: \(out)")
        XCTAssertTrue(out.contains("check overnight batch"))
    }

    // MARK: - Fallback path — target not found

    func testAttemptScheduledNotifyFallsBackWhenNoTargetsExist() async throws {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        // No workers, no interactive sessions, no sonar plugin — resolver
        // will return nil. attemptScheduledNotify must surface a
        // fellBackNotFound so fireJob knows to spawn a worker instead.
        let outcome = await SchedulerActor.attemptScheduledNotify(
            target: "nobody-listens-here",
            bodyText: "wake up and verify the deploy",
            entryId: "cal-xyz",
            source: .calendarEvent,
            dbPool: pool,
            logger: Logger(label: "test.scheduler")
        )

        switch outcome {
        case .fellBackNotFound:
            break  // expected
        case .sent(let msgId):
            XCTFail("expected fellBackNotFound, got .sent(\(msgId))")
        case .fellBackNotLive(let reason):
            XCTFail("expected fellBackNotFound, got fellBackNotLive(\(reason))")
        }
    }

    // MARK: - notifyBodyText — payload discriminator

    func testNotifyBodyTextForClaudePayload() {
        let entry = ScheduledEntry(
            id: "e1",
            name: "cal-test",
            jobType: .spawnClaude,
            nextFireTime: Date(),
            payload: .claude(prompt: "hello", workingDir: nil, model: nil, maxTurns: nil),
            notifyTarget: "supervisor"
        )
        XCTAssertEqual(entry.notifyBodyText(), "hello")
    }

    func testNotifyBodyTextForShellPayload() {
        let entry = ScheduledEntry(
            id: "e2",
            name: "sched-test",
            jobType: .shell,
            nextFireTime: Date(),
            payload: .shellCommand(command: "echo hi"),
            notifyTarget: "sona-worker-1"
        )
        XCTAssertEqual(entry.notifyBodyText(), "echo hi")
    }

    func testNotifyBodyTextForInternalIsNil() {
        // Internal-function payloads have no natural text body to DM.
        // fireJob checks this and skips the notify branch entirely — the
        // schedule still fires via the exec path even if notifyTarget is set.
        let entry = ScheduledEntry(
            id: "e3",
            name: "internal-test",
            jobType: .internal,
            nextFireTime: Date(),
            payload: .internalFunc(name: "compileWiki"),
            notifyTarget: "supervisor"
        )
        XCTAssertNil(entry.notifyBodyText())
    }
}

