import SwiftUI
import GRDB
import AppKit

/// Live status page for one sidecar.
///
/// Reads the sidecar's row from `workers`, aggregates its recent events from
/// `workerEvents`, and folds in the shared spend snapshot. All values are
/// snapshots — this view is deliberately not observing anything continuously
/// because a sidecar in normal use makes at most a few events per minute and
/// a manual refresh keeps the read cheap.
///
/// Shown out of the Window ▸ Sidecars submenu (see `SidecarsMenuContent`) via
/// `SidecarDetailWindowController`, in its own hidden-until-shown window that
/// mirrors the pattern `SupervisorWindowController` uses.
@MainActor
struct SidecarDetailView: View {
    let sidecarName: String

    @State private var snapshot: Snapshot? = nil
    @State private var spend: SidecarSpendSnapshot? = nil
    @State private var loading = true
    @State private var lastError: String? = nil

    /// One aggregated read of the sidecar's live state. All fields are optional
    /// because a sidecar that never spawned (no OAuth, `.off`, mid-rotation)
    /// still has a config row and we still want to show the tier/cap even
    /// though nothing else is populated.
    struct Snapshot: Equatable {
        var config: SidecarConfigView
        var worker: WorkerSummary?
        var events: EventSummary
        var loadedAt: Date

        struct SidecarConfigView: Equatable {
            let name: String
            let tier: String
            let capPct: Int
            let rotationThreshold: Int
            let eventTypes: [String]
            let contextWindowTokens: Int64
            let kind: SidecarKind
        }

        struct WorkerSummary: Equatable {
            let workerId: String
            let sessionId: String?
            let status: String
            let currentEventId: String?
            let currentContextTokens: Int64?
            let lastHeartbeat: Int64
            let registeredAt: Int64
        }

        struct EventSummary: Equatable {
            let totalHandled: Int
            let inFlight: Int
            let pendingAssigned: Int
            let failed: Int
            let averageLatencyMs: Int?
            let mostRecentCompletedAt: Int64?
        }

        /// Only populated for `.inProcess` sidecars — everything shown here is
        /// derived from what the handler configures itself with plus what it's
        /// actually produced. `.claudeCode` sidecars leave this nil; their
        /// story lives in the Session card instead.
        struct HandlerSummary: Equatable {
            let recencyMode: String
            let minRankScore: Double
            let topKCap: Int
            /// Rows currently sitting in `sidecarHints` — written by this
            /// sidecar's handler and not yet popped by a UserPromptSubmit
            /// hook. Usually 0 in a healthy loop (hooks pop on the next
            /// prompt), but a non-zero count is normal too if you look
            /// between an event and the source session's next prompt.
            let hintsInFlight: Int
            let mostRecentHintAt: Int64?
        }
    }

    @State private var handler: Snapshot.HandlerSummary? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if loading && snapshot == nil {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 20)
                } else if let snapshot {
                    configSection(snapshot.config)
                    workerSection(snapshot.worker, contextWindowTokens: snapshot.config.contextWindowTokens, isInProcess: snapshot.config.kind == .inProcess)
                    if let handler {
                        handlerSection(handler)
                    }
                    eventsSection(snapshot.events)
                    spendSection
                    footer(loadedAt: snapshot.loadedAt)
                } else if let lastError {
                    Text(lastError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 460, minHeight: 500)
        .task { await refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sidecarName)
                    .font(.title2.bold())
                Text("Sidecar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func configSection(_ config: Snapshot.SidecarConfigView) -> some View {
        sectionCard(title: "Configuration") {
            gridRow("Tier", config.tier)
            gridRow("Subscription cap", "\(config.capPct)%")
            gridRow("Rotation threshold", "\(config.rotationThreshold)%")
            gridRow("Context window", "\(formatTokens(config.contextWindowTokens))")
            gridRow("Event types", config.eventTypes.isEmpty ? "—" : config.eventTypes.joined(separator: ", "))
        }
    }

    @ViewBuilder
    private func workerSection(_ worker: Snapshot.WorkerSummary?, contextWindowTokens: Int64, isInProcess: Bool) -> some View {
        sectionCard(title: "Session") {
            if isInProcess {
                Text("In-process handler")
                    .font(.callout)
                Text("This sidecar runs as a Swift closure inside Sonata — no Claude Code session, no context window, no rotation. Events are dispatched directly to the handler by MCPEventPusher.")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            } else if let worker {
                gridRow("Worker id", worker.workerId).monospaced()
                gridRow("Session id", worker.sessionId ?? "—").monospaced()
                gridRow("Status", worker.status)
                gridRow("Handling event", worker.currentEventId ?? "—").monospaced()
                gridRow("Context", contextRow(worker.currentContextTokens, windowTokens: contextWindowTokens))
                gridRow("Last heartbeat", relativeTime(worker.lastHeartbeat))
                gridRow("Registered", relativeTime(worker.registeredAt))
            } else {
                Text("No live worker row for this sidecar.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Text("The sidecar hasn't spawned this launch. That's normal when it's registered `.off`, when OAuth credentials are missing, or briefly between rotations.")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func handlerSection(_ handler: Snapshot.HandlerSummary) -> some View {
        sectionCard(title: "Handler") {
            gridRow("Recency mode", handler.recencyMode)
            gridRow("Min rank score", String(format: "%.2f", handler.minRankScore))
            gridRow("Top-K cap", "\(handler.topKCap)")
            gridRow("Hints in flight", "\(handler.hintsInFlight)")
            gridRow("Most recent hint", handler.mostRecentHintAt.map(relativeTime) ?? "—")
        }
    }

    @ViewBuilder
    private func eventsSection(_ events: Snapshot.EventSummary) -> some View {
        sectionCard(title: "Events") {
            gridRow("Total handled", "\(events.totalHandled)")
            gridRow("In flight", "\(events.inFlight)")
            gridRow("Pending assigned", "\(events.pendingAssigned)")
            gridRow("Failed", "\(events.failed)")
            gridRow("Average latency", events.averageLatencyMs.map { "\($0) ms" } ?? "—")
            gridRow("Most recent finish", events.mostRecentCompletedAt.map(relativeTime) ?? "—")
        }
    }

    @ViewBuilder
    private var spendSection: some View {
        sectionCard(title: "Spend") {
            if let spend {
                gridRow("Used", "\(formatTokens(Int64(spend.spentTokens)))")
                gridRow("Allowance", "\(formatTokens(Int64(spend.allowanceTokens)))")
                gridRow("Percent", "\(spend.percentUsed)%")
                ProgressView(value: Double(min(spend.percentUsed, 100)), total: 100)
                    .tint(spend.percentUsed >= 100 ? .red : (spend.percentUsed >= 80 ? .orange : .accentColor))
            } else {
                Text("No spend allowance configured.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    private func footer(loadedAt: Date) -> some View {
        HStack {
            Spacer()
            Text("Snapshot at \(loadedAt.formatted(date: .omitted, time: .standard))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Row / card helpers

    @ViewBuilder
    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .padding(10)
            .background(Color.black.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func gridRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func contextRow(_ tokens: Int64?, windowTokens: Int64) -> String {
        guard let tokens else { return "—" }
        guard windowTokens > 0 else { return "\(formatTokens(tokens))" }
        let pct = Int((Double(tokens) / Double(windowTokens)) * 100)
        return "\(formatTokens(tokens)) / \(formatTokens(windowTokens)) (\(pct)%)"
    }

    private func formatTokens(_ n: Int64) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
        if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }

    private func relativeTime(_ epochMs: Int64) -> String {
        let then = Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000)
        let delta = Date().timeIntervalSince(then)
        if delta < 60 { return "\(Int(delta))s ago" }
        if delta < 3600 { return "\(Int(delta / 60))m ago" }
        if delta < 86400 { return "\(Int(delta / 3600))h ago" }
        return then.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Load

    private func refresh() async {
        loading = true
        lastError = nil
        defer { loading = false }

        guard let sidecar = SidecarRegistry.shared.lookup(byName: sidecarName) else {
            lastError = "No such sidecar registered."
            return
        }
        let userConfig = SidecarConfigStore.shared.config(for: sidecar)
        let sessionKey = SidecarRegistry.shared.sessionKey(for: sidecarName)

        let configView = Snapshot.SidecarConfigView(
            name: sidecar.name,
            tier: userConfig.tier.rawValue,
            capPct: userConfig.subscriptionCapPct,
            rotationThreshold: userConfig.rotationThreshold,
            eventTypes: sidecar.eventTypes,
            contextWindowTokens: sidecar.contextWindowTokens,
            kind: sidecar.kind
        )

        var workerSummary: Snapshot.WorkerSummary? = nil
        var eventSummary = Snapshot.EventSummary(
            totalHandled: 0, inFlight: 0, pendingAssigned: 0, failed: 0,
            averageLatencyMs: nil, mostRecentCompletedAt: nil
        )

        if let dbPool = SonataApp.sharedDbPool, let sessionKey {
            do {
                let read = try await dbPool.read { db -> (Snapshot.WorkerSummary?, Snapshot.EventSummary) in
                    let workerRow = try Row.fetchOne(db, sql: """
                        SELECT workerId, sessionId, status, currentEventId, currentContextTokens, lastHeartbeat, registeredAt
                        FROM workers WHERE workerId = ?
                    """, arguments: [sessionKey])
                    let worker: Snapshot.WorkerSummary? = workerRow.map { row in
                        Snapshot.WorkerSummary(
                            workerId: row["workerId"] ?? sessionKey,
                            sessionId: row["sessionId"],
                            status: row["status"] ?? "unknown",
                            currentEventId: row["currentEventId"],
                            currentContextTokens: row["currentContextTokens"],
                            lastHeartbeat: row["lastHeartbeat"] ?? 0,
                            registeredAt: row["registeredAt"] ?? 0
                        )
                    }

                    let total = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM workerEvents WHERE assignedTo = ? AND status = 'completed'
                    """, arguments: [sessionKey]) ?? 0
                    let inFlight = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM workerEvents WHERE assignedTo = ? AND status IN ('running', 'in_progress')
                    """, arguments: [sessionKey]) ?? 0
                    let pending = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM workerEvents WHERE assignedTo = ? AND status = 'assigned'
                    """, arguments: [sessionKey]) ?? 0
                    let failed = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM workerEvents WHERE assignedTo = ? AND status = 'failed'
                    """, arguments: [sessionKey]) ?? 0
                    let mostRecent = try Int64.fetchOne(db, sql: """
                        SELECT MAX(completedAt) FROM workerEvents WHERE assignedTo = ? AND status = 'completed'
                    """, arguments: [sessionKey])
                    let avgLatency = try Double.fetchOne(db, sql: """
                        SELECT AVG(completedAt - assignedAt)
                        FROM workerEvents
                        WHERE assignedTo = ? AND status = 'completed'
                          AND assignedAt IS NOT NULL AND completedAt IS NOT NULL
                          AND completedAt > assignedAt
                    """, arguments: [sessionKey])

                    let events = Snapshot.EventSummary(
                        totalHandled: total,
                        inFlight: inFlight,
                        pendingAssigned: pending,
                        failed: failed,
                        averageLatencyMs: avgLatency.map { Int($0.rounded()) },
                        mostRecentCompletedAt: mostRecent
                    )
                    return (worker, events)
                }
                workerSummary = read.0
                eventSummary = read.1
            } catch {
                lastError = "DB read failed: \(error.localizedDescription)"
            }
        }

        let s = await SidecarSpendRegistry.shared.spendSnapshot(for: sidecarName)
        spend = s

        // Handler section is only meaningful for in-process sidecars. Top-K
        // cap is the handler's own hardcoded max — 3 for the memory sidecar
        // (a wider fan-out is noise without a judge), threaded through the
        // display so a reader who tunes topK understands why 10 doesn't
        // actually produce 10.
        if sidecar.kind == .inProcess {
            var hintsInFlight = 0
            var mostRecent: Int64? = nil
            if let dbPool = SonataApp.sharedDbPool {
                do {
                    let read = try await dbPool.read { db -> (Int, Int64?) in
                        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sidecarHints") ?? 0
                        let latest = try Int64.fetchOne(db, sql: "SELECT MAX(writtenAtMs) FROM sidecarHints")
                        return (count, latest)
                    }
                    hintsInFlight = read.0
                    mostRecent = read.1
                } catch {
                    // Non-fatal — leave stats at 0/nil.
                }
            }
            handler = Snapshot.HandlerSummary(
                recencyMode: userConfig.recencyMode.label,
                minRankScore: userConfig.minRankScore,
                topKCap: 3,
                hintsInFlight: hintsInFlight,
                mostRecentHintAt: mostRecent
            )
        } else {
            handler = nil
        }

        snapshot = Snapshot(
            config: configView,
            worker: workerSummary,
            events: eventSummary,
            loadedAt: Date()
        )
    }
}

/// Hosts one detail window per sidecar. Same shape as
/// `SupervisorWindowController` / `LogsWindowController` — a lazy dictionary of
/// NSWindows keyed by sidecar name, each surviving close as `orderOut` so
/// re-opening from the menu is instant.
@MainActor
final class SidecarDetailWindowController: NSObject, NSWindowDelegate {
    static let shared = SidecarDetailWindowController()

    private var windows: [String: NSWindow] = [:]

    private override init() { super.init() }

    func show(name: String) {
        if let existing = windows[name] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SidecarDetailView(sidecarName: name))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sidecar — \(name) (stats)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 520, height: 620))
        window.center()
        windows[name] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        DispatchQueue.main.async { sender.orderOut(nil) }
        return false
    }
}
