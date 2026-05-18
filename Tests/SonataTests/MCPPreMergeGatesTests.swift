import XCTest
@testable import Sonata

// Plan §12 — Pre-merge gates summary. The actual gate assertions live in
// the topical test files (G1 in MCPToolCallTests, G2-burst in MCPSSETests,
// G3 in MCPAFKDeliveryTests + MCPDMDeliveryTests). This file:
//
//  - documents what each gate means
//  - pins the gates that are runtime-checkable but don't belong in any
//    other suite (G2-schema-entrypoint, G4 declarative note, G5 backstop)
//  - fails loudly when a backstop assumption breaks
//
// If Phase C cutover is attempted with any of these red, the supervisor
// can lose `check` events or workers can double-process events on restart.

final class MCPPreMergeGatesTests: XCTestCase {

    /// G2 (plan-doc form). Plan §9 named the schema entrypoint
    /// `Schema.applyMigrations(pool)` and the action-registration entrypoint
    /// `ActionRegistry.registerAll(into:)`. The actual names are different
    /// (DatabaseMigrator extension + per-module register calls). The harness
    /// uses the real names; if either is renamed in source, the harness
    /// stops compiling and this test never runs. This assertion documents
    /// that the rename happened in the harness, not in production code.
    func testGate_G2_HarnessUsesRealEntrypoints() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        // Schema-migrator landed a complete schema; one of the tables
        // exists and is queryable.
        let count = try await h.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workers") ?? -1
        }
        XCTAssertGreaterThanOrEqual(count, 0,
            "DatabaseMigrator.registerSonataSchema must produce a workers table")

        // ActionRegistry has the modules the MCP tool handlers dispatch
        // into. If we don't register them, executeMCPTool returns
        // "Unknown tool: ..." and every tool-call test silently flaps.
        XCTAssertNotNil(h.actionRegistry.action(named: "worker_event_complete"))
        XCTAssertNotNil(h.actionRegistry.action(named: "worker_event_fail"))
        XCTAssertNotNil(h.actionRegistry.action(named: "supervisor_heartbeat"))
        XCTAssertNotNil(h.actionRegistry.action(named: "dm_send"))
        XCTAssertNotNil(h.actionRegistry.action(named: "dm_inbox"))
    }

    /// G5 (Phase A backstop). The Phase A smoke (Tools/MCPHTTPSmokeTest)
    /// is a manual gate; it ran green at commit 25f357b and is required
    /// before Phase C cutover. The test target here can't re-run that
    /// executable, but we can pin the executable's presence in the
    /// build graph so it never silently disappears.
    func testGate_G5_PhaseASmokeTargetExists() {
        // The MCPHTTPSmokeTest executable is defined in Package.swift;
        // its existence is a build-graph fact. We can't link against
        // executables from a test target, but we can verify the
        // canonical entry file is on disk so a future rename gets caught.
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // Tests/SonataTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Tools/MCPHTTPSmokeTest/main.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
            "Phase A smoke test source missing at \(url.path); G5 backstop violated")
    }

    /// Pin: worker_spawn is on the ActionRegistry surface so the supervisor
    /// can call it via the `memory` MCP server (which auto-exposes every
    /// non-httpOnly SonataAction). Mirrors testToolsListReturnsExactlyThe-
    /// BridgeToolSet in spirit — surface-only assertion, no handler call,
    /// so the test doesn't trigger a real worker spawn through
    /// WorkerManager.shared. 2026-05-18 incident: supervisor had no MCP
    /// path to refill a stuck-at-1/2 pool; this tool is that path.
    func testWorkerSpawnIsOnTheSupervisorMCPSurface() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        // Pinned peers: worker_purge already lets the supervisor drop
        // stale registrations; worker_spawn is the new admit-side peer.
        XCTAssertNotNil(h.actionRegistry.action(named: "worker_purge"),
            "worker_purge is the existing supervisor-callable peer")
        XCTAssertNotNil(h.actionRegistry.action(named: "worker_spawn"),
            "worker_spawn must be registered so the supervisor can self-heal under-capacity pool states (2026-05-18 incident)")

        let names = Set(h.actionRegistry.mcpToolSchemas().compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("worker_spawn"),
            "worker_spawn must appear in mcpToolSchemas() so the memory MCP server lists it on tools/list")
    }

    /// G4 is external: confirm Claude Code v2.1.50+ ships --mcp-config with
    /// exclusive-config semantics AND supports headers in type=http entries.
    /// Verified manually before Phase A; documented here so the gate is
    /// findable from `swift test --list-tests | grep G4`. This test is a
    /// declarative no-op; if the assumption breaks, Phase C cutover
    /// fails at the first launched session and rolls back via R10.
    func testGate_G4_DeclarativeNote() {
        // Intentional empty assertion: G4 cannot be checked from Swift.
        // The verification record lives in plan §12 OQ 4.
    }
}
