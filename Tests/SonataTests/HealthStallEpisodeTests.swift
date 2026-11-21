import XCTest
import GRDB
import Darwin
@testable import Sonata

/// One healthMonitorStall email per episode, diagnosed, with the supervisor
/// told (2026-11-21). A keychain dialog held Sonata's main thread from 14:00Z;
/// check:workerPool waited on MainActor, and the old watchdog emailed Evan
/// "stuck in check:workerPool" every 10 minutes without saying a dialog was on
/// his screen.
///
/// Like HealthLoopWatchdogTests, these never run the real monitorLoop (its
/// GhostWorkerReaper would SIGTERM the host's live workers) and never write the
/// live app's alert-state file (alertStatePath is a temp file).
final class HealthStallEpisodeTests: XCTestCase {

    // MARK: - Harness

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    private func tempAlertStatePath() -> String {
        let path = NSTemporaryDirectory() + "health-alert-state-\(UUID().uuidString).json"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private static let keychain = StallDiagnosis(
        cause: .keychainDialog,
        securityAgentSince: Date(timeIntervalSince1970: 1_795_269_656),  // 2026-11-21 14:00:56Z
        sampleEvidence: "SecItemCopyMatching"
    )

    private func makeMonitor(
        pool: DatabasePool,
        diagnosis: StallDiagnosis = .notMainThread,
        workerPoolStatus: (@Sendable () async -> (target: Int, effective: Int))? = nil,
        hopTimeout: TimeInterval = HealthMonitor.defaultMainActorHopTimeout
    ) -> HealthMonitor {
        HealthMonitor(
            dbPool: pool,
            workerPoolStatus: workerPoolStatus,
            mainActorHopTimeout: hopTimeout,
            stallDiagnoser: { _ in diagnosis },
            alertStatePath: tempAlertStatePath()
        )
    }

    /// Which step each generation hangs in (nil = cycle normally, forever).
    private actor Script {
        private let hangs: [String?]
        private(set) var started: [Int] = []
        private var unresponsive = true
        init(hangs: [String?]) { self.hangs = hangs }
        func next(_ gen: Int) -> String? {
            started.append(gen)
            let i = started.count - 1
            return i < hangs.count ? hangs[i] : nil
        }
        func setUnresponsive(_ v: Bool) { unresponsive = v }
        var isUnresponsive: Bool { unresponsive }
    }

    /// A loop whose generations hang per `script`, then cycle normally.
    private func scriptedLoop(_ script: Script) -> @Sendable (HealthMonitor, Int) async -> Void {
        { m, gen in
            let hang = await script.next(gen)
            if let step = hang {
                m.progress.begin(gen)
                m.progress.mark(gen, step)
                await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            }
            while !Task.isCancelled {
                m.progress.begin(gen)
                m.progress.mark(gen, "check:database")
                m.progress.end(gen)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func stallAlerts(_ m: HealthMonitor) async -> [String] {
        await m.deliveredAlerts.filter { $0.check == HealthMonitor.stallAlertCheck }.map(\.message)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func supervisorStallRows(_ pool: DatabasePool) async throws -> [String] {
        try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT payload FROM supervisorEvents WHERE type = ?",
                                arguments: [HealthMonitor.stallSupervisorEventType])
        }
    }

    // MARK: - One alert per episode

    func testRepeatStallInSameStepAlertsOnceNotN() async throws {
        let pool = try makePool()
        let m = makeMonitor(pool: pool)
        let script = Script(hangs: ["check:workerPool", "check:workerPool", "check:workerPool"])
        await m.superviseForTesting(loop: scriptedLoop(script), watchdogInterval: 0.05, stallThreshold: 0.2)

        try await waitUntil { await m.stallRecoveries.count >= 3 }
        try await Task.sleep(for: .milliseconds(200))   // let any alert for the 3rd stall land
        let recoveries = await m.stallRecoveries.count
        let alerts = await stallAlerts(m)
        let rows = try await supervisorStallRows(pool)
        await m.shutdown()

        XCTAssertGreaterThanOrEqual(recoveries, 3, "control: the same step stalled three times")
        XCTAssertEqual(alerts.filter { !$0.hasPrefix("RECOVERED") }.count, 1,
                       "three stalls in one step are one episode: one email, not three")
        XCTAssertEqual(rows.count, 1, "the supervisor is told once per episode")
    }

    func testDifferentStepReAlertsAtOnce() async throws {
        let pool = try makePool()
        let m = makeMonitor(pool: pool)
        let script = Script(hangs: ["check:workerPool", "reapOverdueTasks"])
        await m.superviseForTesting(loop: scriptedLoop(script), watchdogInterval: 0.05, stallThreshold: 0.2)

        // stallRecoveries is appended before the alert is sent: wait on the alerts.
        try await waitUntil { await self.stallAlerts(m).filter { !$0.hasPrefix("RECOVERED") }.count >= 2 }
        let alerts = await stallAlerts(m).filter { !$0.hasPrefix("RECOVERED") }
        await m.shutdown()

        XCTAssertEqual(alerts.count, 2, "a stall in a different step is a new episode")
        XCTAssertTrue(alerts.first?.contains("'check:workerPool'") ?? false)
        XCTAssertTrue(alerts.last?.contains("'reapOverdueTasks'") ?? false)
    }

    func testRecoveryAfterRepeatsSendsExactlyOneRecovered() async throws {
        let pool = try makePool()
        let m = makeMonitor(pool: pool)
        let script = Script(hangs: ["check:workerPool", "check:workerPool"])
        await m.superviseForTesting(loop: scriptedLoop(script), watchdogInterval: 0.05, stallThreshold: 0.2)

        try await waitUntil { await self.stallAlerts(m).contains { $0.hasPrefix("RECOVERED") } }
        // Keep cycling well past recovery: no second notice.
        try await Task.sleep(for: .milliseconds(500))
        let alerts = await stallAlerts(m)
        let cycles = m.progress.completedCycles
        await m.shutdown()

        let recovered = alerts.filter { $0.hasPrefix("RECOVERED") }
        XCTAssertEqual(alerts.count - recovered.count, 1, "one alert for the episode")
        XCTAssertEqual(recovered.count, 1, "one RECOVERED notice for the episode")
        XCTAssertTrue(recovered.first?.contains("repeated 1 more time(s)") ?? false,
                      "the notice carries the repeat count: \(recovered.first ?? "nil")")
        XCTAssertGreaterThan(cycles, 5, "control: the replacement loop kept cycling after recovery")
    }

    // MARK: - Main thread unresponsive: diagnosed, no restart, supervisor told

    func testMainThreadStretchAlertsOnceWithKeychainActionAndTellsSupervisor() async throws {
        let pool = try makePool()
        let m = makeMonitor(pool: pool, diagnosis: Self.keychain)
        let script = Script(hangs: [])
        await m.superviseForTesting(loop: { m, gen in
            _ = await script.next(gen)
            while !Task.isCancelled {
                m.progress.begin(gen)
                m.progress.mark(gen, "check:workerPool")
                if await script.isUnresponsive {
                    m.progress.noteMainThreadUnresponsive(gen, step: "check:workerPool")
                } else {
                    m.progress.noteMainThreadResponsive(gen)
                }
                m.progress.end(gen)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }, watchdogInterval: 0.05, stallThreshold: 0.2)

        try await waitUntil { await !self.stallAlerts(m).isEmpty }
        try await Task.sleep(for: .milliseconds(500))   // several more unresponsive ticks
        let during = await stallAlerts(m)
        await script.setUnresponsive(false)
        try await waitUntil { await self.stallAlerts(m).contains { $0.hasPrefix("RECOVERED") } }
        let after = await stallAlerts(m)
        let started = await script.started
        let kinds = await m.stallRecoveries.map(\.kind)
        let rows = try await supervisorStallRows(pool)
        await m.shutdown()

        XCTAssertEqual(during.count, 1, "one unresponsive stretch, one email")
        let mail = during.first ?? ""
        XCTAssertTrue(mail.contains("A macOS keychain dialog from Sonata is waiting on your screen since"), mail)
        XCTAssertTrue(mail.contains("click Always Allow"), mail)
        XCTAssertTrue(mail.contains("fc30d09 on fix/webcrypto-master-key-delegate"), mail)
        XCTAssertEqual(started.count, 1, "cycles were still completing: the loop is not restarted")
        XCTAssertEqual(kinds, [.mainThreadUnresponsive])
        XCTAssertEqual(after.filter { $0.hasPrefix("RECOVERED") }.count, 1)

        XCTAssertEqual(rows.count, 1)
        let payload = try XCTUnwrap(rows.first.flatMap { $0.data(using: .utf8) })
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(obj["diagnosis"] as? String, "keychainDialog")
        XCTAssertEqual(obj["humanOnly"] as? Bool, true)
        XCTAssertEqual(obj["step"] as? String, "check:workerPool")
        XCTAssertEqual(obj["securityAgentSince"] as? String, "2026-11-21T14:00:56Z")
        let rendered = MCPEventPusher.renderStallEvent(payload: rows[0])
        XCTAssertTrue(rendered.contains("HUMAN-ONLY"), rendered)
    }

    // MARK: - Bounded MainActor hop

    func testWorkerPoolTimeoutLetsLaterChecksRun() async throws {
        let pool = try makePool()
        // Stands in for `await MainActor.run { … }` behind a blocked main thread.
        let m = makeMonitor(pool: pool, workerPoolStatus: {
            await withUnsafeContinuation { (_: UnsafeContinuation<(target: Int, effective: Int), Never>) in }
        }, hopTimeout: 0.2)
        let gen = m.progress.newGeneration()
        m.progress.begin(gen)

        let started = Date()
        let results = await m.runAllChecksForTesting(generation: gen)
        let elapsed = Date().timeIntervalSince(started)
        let names = results.map(\.name)

        let pool0 = results.first { $0.name == "worker_pool" }
        XCTAssertEqual(pool0?.message.hasPrefix("unknown: main thread unresponsive"), true, pool0?.message ?? "nil")
        XCTAssertEqual(pool0?.healthy, true, "the watchdog owns this alert; a failing result would page twice")
        XCTAssertTrue(names.contains("dispatchStall"), "a check after workerPool still ran: \(names)")
        XCTAssertTrue(names.contains("orphanedAssignee"), "the last check still ran: \(names)")
        XCTAssertLessThan(elapsed, 10, "the cycle was not held by the hop")
        XCTAssertNotNil(m.progress.mainThreadUnresponsiveSince, "the stretch is handed to the watchdog")
    }

    func testWorkerPoolAnswerEndsTheStretch() async throws {
        let pool = try makePool()
        let m = makeMonitor(pool: pool, workerPoolStatus: { (target: 2, effective: 2) }, hopTimeout: 0.2)
        let gen = m.progress.newGeneration()
        m.progress.noteMainThreadUnresponsive(gen, step: "check:workerPool")
        let result = await m.runWorkerPoolCheckForTesting(generation: gen)
        XCTAssertEqual(result?.message, "OK (2/2)")
        XCTAssertNil(m.progress.mainThreadUnresponsiveSince)
    }

    // MARK: - Diagnosis

    func testClassify() {
        let since = Date()
        XCTAssertEqual(StallDiagnoser.classify(mainThreadResponds: true, securityAgentSince: since, sampleEvidence: "x").cause,
                       .notMainThread, "a main thread that answers is not the cause")
        XCTAssertEqual(StallDiagnoser.classify(mainThreadResponds: false, securityAgentSince: since, sampleEvidence: nil).cause,
                       .keychainDialog)
        XCTAssertEqual(StallDiagnoser.classify(mainThreadResponds: false, securityAgentSince: nil, sampleEvidence: "SecItemCopyMatching").cause,
                       .keychainDialog)
        XCTAssertEqual(StallDiagnoser.classify(mainThreadResponds: false, securityAgentSince: nil, sampleEvidence: nil).cause,
                       .mainThreadBlocked)
    }

    func testKeychainFrameAndAgentStartFilters() {
        let sample = "  2142 WebCore::defaultWebCryptoMasterKey()\n  2142 SecItemCopyMatching\n"
        XCTAssertEqual(StallDiagnoser.keychainFrame(inSample: sample), "SecItemCopyMatching")
        XCTAssertNil(StallDiagnoser.keychainFrame(inSample: "2142 mach_msg2_trap\n2142 CFRunLoopRun"))

        let launch = Date(timeIntervalSince1970: 1_000)
        let before = Date(timeIntervalSince1970: 900), after1 = Date(timeIntervalSince1970: 1_100), after2 = Date(timeIntervalSince1970: 1_200)
        XCTAssertEqual(StallDiagnoser.newestStart(of: [before, after1, after2], after: launch), after2)
        XCTAssertNil(StallDiagnoser.newestStart(of: [before], after: launch), "a dialog older than Sonata is not Sonata's")
    }

    func testProcessTableReadsRealProcesses() {
        let own = StallDiagnoser.processStartTime(pid: getpid())
        XCTAssertNotNil(own)
        XCTAssertLessThan(own ?? .distantFuture, Date(), "this process started in the past")
        XCTAssertFalse(StallDiagnoser.processStartTimes(named: "launchd").isEmpty,
                       "control: the lookup finds a process that is always running")
        XCTAssertTrue(StallDiagnoser.processStartTimes(named: "no-such-process-\(UUID().uuidString.prefix(6))").isEmpty)
    }

    func testHumanActionNamesTheDialogAndTheFix() {
        let action = Self.keychain.humanAction
        XCTAssertTrue(action.hasPrefix("A macOS keychain dialog from Sonata is waiting on your screen since "), action)
        XCTAssertTrue(action.contains("14:00:56Z"), action)
        XCTAssertTrue(action.contains("enter your login password and click Always Allow"), action)
        XCTAssertEqual(StallDiagnosis.notMainThread.humanAction, "")
    }

    /// SecurityAgent can outlive one dialog and draw the next, so its start
    /// time may predate Sonata; the email then names when the wait began.
    func testDialogTimeFallsBackToWhenTheWaitBegan() {
        let now = Date(timeIntervalSince1970: 1_795_300_000)
        let stretch = HealthCycleProgress.Stall(generation: 1, step: "check:workerPool", cycleSeconds: 660,
                                                stepSeconds: 0, kind: .mainThreadUnresponsive)
        XCTAssertEqual(StallDiagnoser.blockedSince(of: stretch, now: now), now.addingTimeInterval(-660))
        let stuck = HealthCycleProgress.Stall(generation: 1, step: "reapOverdueTasks", cycleSeconds: 700, stepSeconds: 610)
        XCTAssertEqual(StallDiagnoser.blockedSince(of: stuck, now: now), now.addingTimeInterval(-610))

        var d = StallDiagnoser.classify(mainThreadResponds: false, securityAgentSince: nil, sampleEvidence: "SecItemCopyMatching")
        XCTAssertTrue(d.humanAction.contains("since an unknown time"), "control: no time without a fallback")
        d.blockedSince = now
        XCTAssertFalse(d.humanAction.contains("unknown time"), d.humanAction)
        XCTAssertTrue(d.humanAction.contains(StallDiagnosis.describe(now)), d.humanAction)
    }
}
