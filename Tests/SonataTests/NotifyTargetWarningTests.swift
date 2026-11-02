import XCTest
import GRDB
@testable import Sonata

/// notifyTarget replaces execution; it is not a failure alert (2026-11-02).
/// 19 scout-cloud shell rows carried a notifyTarget and were DMed instead of
/// run, with lastResult "notified …" reading like a success. These tests pin:
///   1. scheduler_create / calendar_create / calendar_update return a
///      `warnings` entry when the row will be DMed instead of run;
///   2. rows without notifyTarget return the old shape, with no `warnings` key;
///   3. the fire-time result says the command was NOT executed.
final class NotifyTargetWarningTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    private func run(_ actions: [SonataAction], _ name: String, _ pool: DatabasePool, _ params: [String: Any]) async throws -> [String: Any] {
        let action = actions.first { $0.name == name }!
        let response = try await action.handler(ActionContext(params: ActionParams(params), dbPool: pool))
        let data = try JSONEncoder().encode(NotifyTargetEncodableShim(value: response))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - scheduler_create

    func testSchedulerCreateWithNotifyTargetWarns() async throws {
        let pool = try makePool()
        let json = try await run(schedulerActions, "scheduler_create", pool, [
            "name": "nudge", "schedule": "0 * * * *", "command": "check the queue",
            "enabled": false, "notifyTarget": "supervisor",
        ])
        XCTAssertEqual(json["success"] as? Bool, true, "a notify row is still accepted")
        let warnings = try XCTUnwrap(json["warnings"] as? [String])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("DMed to supervisor"), warnings[0])
        XCTAssertTrue(warnings[0].contains("NOT executed"), warnings[0])
        XCTAssertTrue(warnings[0].contains("POST /api/dm/send"), warnings[0])

        let stored = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT notifyTarget FROM scheduledJobs WHERE name = 'nudge'")
        }
        XCTAssertEqual(stored, "supervisor", "the warning does not change what is stored")
    }

    func testSchedulerCreateWithoutNotifyTargetHasNoWarningsKey() async throws {
        let pool = try makePool()
        let json = try await run(schedulerActions, "scheduler_create", pool, [
            "name": "plain", "schedule": "0 * * * *", "command": "echo hi", "enabled": false,
        ])
        XCTAssertEqual(json["success"] as? Bool, true)
        XCTAssertNil(json["warnings"], "backward-compatible shape: no warnings key at all")
        XCTAssertEqual(Set(json.keys), ["success"])
    }

    func testSchedulerCreateWithEmptyNotifyTargetHasNoWarningsKey() async throws {
        // The fire path treats "" as unset, so the warning must too.
        let pool = try makePool()
        let json = try await run(schedulerActions, "scheduler_create", pool, [
            "name": "cleared", "schedule": "0 * * * *", "command": "echo hi",
            "enabled": false, "notifyTarget": "",
        ])
        XCTAssertNil(json["warnings"])
    }

    // MARK: - calendar_create / calendar_update

    private func createEvent(_ pool: DatabasePool, _ extra: [String: Any]) async throws -> [String: Any] {
        var params: [String: Any] = [
            "title": "t", "scheduledAt": 1_900_000_000_000, "taskType": "spawn-claude",
            "prompt": "do the thing", "enabled": false,
        ]
        params.merge(extra) { _, new in new }
        return try await run(calendarActions, "calendar_create", pool, params)
    }

    func testCalendarCreateWithNotifyTargetWarns() async throws {
        let pool = try makePool()
        let json = try await createEvent(pool, ["notifyTarget": "supervisor"])
        XCTAssertNotNil(json["id"] as? String)
        let warnings = try XCTUnwrap(json["warnings"] as? [String])
        XCTAssertTrue(warnings[0].contains("prompt is DMed to supervisor"), warnings[0])
        XCTAssertTrue(warnings[0].contains("NO worker is spawned"), warnings[0])
    }

    func testCalendarCreateShellWithNotifyTargetSaysCommandNotExecuted() async throws {
        let pool = try makePool()
        let json = try await createEvent(pool, ["notifyTarget": "supervisor", "taskType": "shell", "prompt": "ls"])
        let warnings = try XCTUnwrap(json["warnings"] as? [String])
        XCTAssertTrue(warnings[0].contains("command is DMed to supervisor"), warnings[0])
        XCTAssertTrue(warnings[0].contains("NOT executed"), warnings[0])
    }

    func testCalendarCreateInternalWithNotifyTargetDoesNotWarn() async throws {
        // Internal-function payloads have no DM body and always execute.
        let pool = try makePool()
        let json = try await createEvent(pool, ["notifyTarget": "supervisor", "taskType": "internal", "prompt": "compileWiki"])
        XCTAssertNil(json["warnings"])
    }

    func testCalendarCreateWithoutNotifyTargetHasNoWarningsKey() async throws {
        let pool = try makePool()
        let json = try await createEvent(pool, [:])
        XCTAssertNotNil(json["id"] as? String)
        XCTAssertNil(json["warnings"])
        XCTAssertEqual(Set(json.keys), ["id", "success"])
    }

    func testCalendarUpdateSettingNotifyTargetWarns() async throws {
        let pool = try makePool()
        let created = try await createEvent(pool, [:])
        let id = try XCTUnwrap(created["id"] as? String)
        let json = try await run(calendarActions, "calendar_update", pool, ["id": id, "notifyTarget": "supervisor"])
        let warnings = try XCTUnwrap(json["warnings"] as? [String])
        XCTAssertTrue(warnings[0].contains("DMed to supervisor"), warnings[0])
    }

    func testCalendarUpdatePromptOnExistingNotifyRowWarns() async throws {
        let pool = try makePool()
        let created = try await createEvent(pool, ["notifyTarget": "supervisor"])
        let id = try XCTUnwrap(created["id"] as? String)
        let json = try await run(calendarActions, "calendar_update", pool, ["id": id, "prompt": "new text"])
        XCTAssertNotNil(json["warnings"], "a new prompt on a notify row is still only DMed")
    }

    func testCalendarUpdateUnrelatedFieldOnNotifyRowStaysQuiet() async throws {
        let pool = try makePool()
        let created = try await createEvent(pool, ["notifyTarget": "supervisor"])
        let id = try XCTUnwrap(created["id"] as? String)
        let json = try await run(calendarActions, "calendar_update", pool, ["id": id, "enabled": true])
        XCTAssertNil(json["warnings"])
        XCTAssertEqual(Set(json.keys), ["id", "success"])
    }

    func testCalendarUpdateClearingNotifyTargetHasNoWarningsKey() async throws {
        let pool = try makePool()
        let created = try await createEvent(pool, ["notifyTarget": "supervisor"])
        let id = try XCTUnwrap(created["id"] as? String)
        let json = try await run(calendarActions, "calendar_update", pool, ["id": id, "notifyTarget": ""])
        XCTAssertNil(json["warnings"])
    }

    // MARK: - fire-time result

    func testNotifiedResultForShellSaysCommandNotExecuted() {
        let result = NotifyTargetSemantics.notifiedResult(
            target: "supervisor", messageId: "m1", payload: .shellCommand(command: "ls"))
        XCTAssertEqual(result, "notified supervisor (dm m1); command NOT executed")
    }

    func testNotifiedResultForWorkerPromptSaysNoWorkerSpawned() {
        let result = NotifyTargetSemantics.notifiedResult(
            target: "supervisor", messageId: "m2",
            payload: .claude(prompt: "p", workingDir: nil, model: nil, maxTurns: nil))
        XCTAssertEqual(result, "notified supervisor (dm m2); no worker spawned")
    }
}

private struct NotifyTargetEncodableShim: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
