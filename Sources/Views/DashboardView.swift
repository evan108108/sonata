import SwiftUI

struct DashboardView: View {
    @Binding var selectedTab: SonataTab
    @State private var status: SystemStatus?
    @State private var lastRefresh: Date?
    @State private var hasLoadedOnce = false
    @State private var showingEntityBreakdown = false
    @State private var showingMemoryBreakdown = false
    @State private var showingTaskBreakdown = false
    @State private var showingEmailBreakdown = false
    @ObservedObject private var workerManager = WorkerManager.shared
    @ObservedObject private var sessionsVM = InteractiveSessionsViewModel.shared
    @StateObject private var activityVM = ActivityFeedViewModel()
    @StateObject private var tokenVM = TokenUsageViewModel()
    @StateObject private var pluginVM = PluginStatusViewModel()
    @StateObject private var thoughtsVM = RecentThoughtsViewModel()
    @StateObject private var deadlinesVM = DeadlinesViewModel()
    @StateObject private var afkVM = AFKQuestionsViewModel()

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let bootRetryInterval: TimeInterval = 1.5

    var body: some View {
        mainContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("System Health")
                    .font(.title.bold())
                Spacer()
                if let lastRefresh {
                    Text("Updated \(lastRefresh.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await fetchStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            if let status {
                ScrollView {
                    VStack(spacing: 16) {
                        // Overall health indicator
                        HStack(spacing: 12) {
                            Circle()
                                .fill(status.healthColor)
                                .frame(width: 16, height: 16)
                            Text(status.healthLabel)
                                .font(.headline)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)

                        // Attention zone — only renders when something is stuck.
                        if status.failedTasks + status.blockedTasks > 0 {
                            AttentionTasksCard(
                                failedTasks: status.failedTasks,
                                blockedTasks: status.blockedTasks
                            ) {
                                selectedTab = .tasks
                            }
                            .padding(.horizontal)
                        }

                        // Attention zone — Deadlines card; hides entirely when empty.
                        if !deadlinesVM.items.isEmpty {
                            DeadlinesCard(items: deadlinesVM.items) { item in
                                selectedTab = item.source == "task" ? .tasks : .memory
                            }
                            .padding(.horizontal)
                        }

                        // Attention zone — AFK Questions; hides entirely when empty.
                        if !afkVM.entries.isEmpty {
                            AFKQuestionsCard(
                                entries: afkVM.entries,
                                workersBySessionId: Dictionary(
                                    uniqueKeysWithValues: workerManager.workers.map { ($0.sessionId, $0) }
                                )
                            ) { worker in
                                WorkerManager.shared.selectedWorkerId = worker.id
                                selectedTab = .workers
                            }
                            .padding(.horizontal)
                        }

                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                        ], spacing: 16) {
                            Button {
                                showingMemoryBreakdown = true
                            } label: {
                                StatCard(title: "Memories", value: "\(status.memoryCount)", icon: "brain.head.profile", color: .purple, detail: status.memoriesBreakdown)
                            }
                            .buttonStyle(.plain)
                            Button {
                                showingEntityBreakdown = true
                            } label: {
                                StatCard(title: "Entities", value: "\(status.entityCount)", icon: "point.3.connected.trianglepath.dotted", color: .blue, detail: status.entitiesBreakdown)
                            }
                            .buttonStyle(.plain)
                            // Workers card removed — LiveWorkersSection below is the single source
                            // of truth for worker count, status, and per-worker telemetry. The
                            // duplicate StatCard read from a SQL aggregate that drifted out of sync
                            // with Sonata's local Worker array during cycle (showing e.g. "3 / 2 busy"
                            // when an old draining row hadn't been cleaned up yet).
                            Button {
                                showingTaskBreakdown = true
                            } label: {
                                StatCard(title: "Tasks", value: "\(status.totalTasks)", icon: "checklist", color: status.pendingTasks > 10 ? .orange : .green, detail: status.tasksBreakdown)
                            }
                            .buttonStyle(.plain)
                            Button {
                                showingEmailBreakdown = true
                            } label: {
                                StatCard(title: "Emails", value: "\(status.totalEmails)", icon: "envelope.badge.fill", color: status.unreadEmails > 0 ? .orange : .green, detail: status.emailsBreakdown)
                            }
                            .buttonStyle(.plain)
                            StatCard(title: "Next Event", value: status.nextEvent, icon: "calendar", color: .indigo)
                            PluginStatCard(vm: pluginVM) {
                                selectedTab = .plugins
                            }
                        }
                        .padding(.horizontal)

                        SessionsSection(sessionsVM: sessionsVM)
                            .padding(.horizontal)

                        LiveWorkersSection(workers: workerManager.workers) { worker in
                            WorkerManager.shared.selectedWorkerId = worker.id
                            selectedTab = .workers
                        }
                        .padding(.horizontal)

                        if !status.upcomingEvents.isEmpty {
                            UpcomingEventsSection(events: status.upcomingEvents) {
                                selectedTab = .schedule
                            }
                            .padding(.horizontal)
                        }

                        TokenUsageCard(vm: tokenVM)
                            .padding(.horizontal)

                        ActivityFeedSection(vm: activityVM) { item in
                            switch item.type {
                            case "worker_completed":          selectedTab = .workers
                            case "email_replied":             selectedTab = .email
                            case "scheduled_job_run",
                                 "calendar_event_fired":      selectedTab = .schedule
                            case "background_thinking_output": selectedTab = .memory
                            default:                          break
                            }
                        }
                        .padding(.horizontal)

                        if !thoughtsVM.items.isEmpty {
                            BackgroundThoughtsSection(vm: thoughtsVM)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.bottom)
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // Local server may still be booting — retry silently until the first success.
            while !hasLoadedOnce && !Task.isCancelled {
                await fetchStatus()
                if hasLoadedOnce { break }
                try? await Task.sleep(for: .seconds(bootRetryInterval))
            }
        }
        .task {
            // Same quiet-boot pattern for the activity feed; afterwards it rides the 30s timer.
            while !activityVM.hasLoadedOnce && !Task.isCancelled {
                await activityVM.fetch()
                if activityVM.hasLoadedOnce { break }
                try? await Task.sleep(for: .seconds(bootRetryInterval))
            }
        }
        .task {
            while !tokenVM.hasLoadedOnce && !Task.isCancelled {
                await tokenVM.fetch()
                if tokenVM.hasLoadedOnce { break }
                try? await Task.sleep(for: .seconds(bootRetryInterval))
            }
        }
        .task {
            while !pluginVM.hasLoadedOnce && !Task.isCancelled {
                await pluginVM.fetch()
                if pluginVM.hasLoadedOnce { break }
                try? await Task.sleep(for: .seconds(bootRetryInterval))
            }
        }
        .task {
            while !thoughtsVM.hasLoadedOnce && !Task.isCancelled {
                await thoughtsVM.fetch()
                if thoughtsVM.hasLoadedOnce { break }
                try? await Task.sleep(for: .seconds(bootRetryInterval))
            }
        }
        .task {
            while !deadlinesVM.hasLoadedOnce && !Task.isCancelled {
                await deadlinesVM.fetch()
                if deadlinesVM.hasLoadedOnce { break }
                try? await Task.sleep(for: .seconds(bootRetryInterval))
            }
        }
        .task {
            while !afkVM.hasLoadedOnce && !Task.isCancelled {
                await afkVM.fetch()
                if afkVM.hasLoadedOnce { break }
                try? await Task.sleep(for: .seconds(bootRetryInterval))
            }
        }
        .onReceive(timer) { _ in
            Task { await fetchStatus() }
            Task { await activityVM.fetch() }
            Task { await tokenVM.fetch() }
            Task { await pluginVM.fetch() }
            Task { await thoughtsVM.fetch() }
            Task { await deadlinesVM.fetch() }
            Task { await afkVM.fetch() }
        }
        .sheet(isPresented: $showingEntityBreakdown) {
            BreakdownSheet(title: "Entities by type", counts: status?.entitiesByType ?? [:], footnote: nil)
        }
        .sheet(isPresented: $showingMemoryBreakdown) {
            BreakdownSheet(
                title: "Memories by type",
                counts: status?.memoriesByType ?? [:],
                footnote: "Wiki pages live in a separate table from memories. The card's number combines them so the breakdown reconciles."
            )
        }
        .sheet(isPresented: $showingTaskBreakdown) {
            BreakdownSheet(title: "Tasks by status", counts: status?.tasksByStatus ?? [:], footnote: "The card's big number shows pending tasks specifically — what's actionable now.")
        }
        .sheet(isPresented: $showingEmailBreakdown) {
            BreakdownSheet(title: "Emails by status", counts: status?.emailsByStatus ?? [:], footnote: "The card's big number shows unread emails — what's awaiting attention.")
        }
    }

    private func fetchStatus() async {
        do {
            let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/status")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return
            }
            let decoded = try JSONDecoder().decode(StatusResponse.self, from: data)
            self.status = SystemStatus(from: decoded)
            self.hasLoadedOnce = true
            self.lastRefresh = Date()
        } catch {
            // Keep last-known state; the boot loop or 30s timer will retry.
        }
    }
}

// MARK: - Models

private struct StatusResponse: Decodable {
    let memoryCount: Int?
    let memoriesByType: [String: Int]?
    let wikiPageCount: Int?
    let entityCount: Int?
    let entitiesByType: [String: Int]?
    let workerCount: Int?
    let workersByStatus: [String: Int]?
    let pendingTasks: Int?
    let tasksByStatus: [String: Int]?
    let failedTasks: Int?
    let blockedTasks: Int?
    let unreadEmails: Int?
    let emailsByStatus: [String: Int]?
    let nextCalendarEvent: NextCalendarEvent?
    let upcomingCalendarEvents: [NextCalendarEvent]?
    let status: String?

    struct NextCalendarEvent: Decodable {
        let id: String?
        let title: String?
        let startTime: Int64?
    }
}

private struct SystemStatus {
    let memoryCount: Int
    let memoriesByType: [String: Int]
    let wikiPageCount: Int
    let entityCount: Int
    let entitiesByType: [String: Int]
    let workerCount: Int
    let workersByStatus: [String: Int]
    let pendingTasks: Int
    let tasksByStatus: [String: Int]
    let failedTasks: Int
    let blockedTasks: Int
    let unreadEmails: Int
    let emailsByStatus: [String: Int]
    let nextEvent: String
    let upcomingEvents: [UpcomingEventInfo]
    let serverStatus: String

    init(from r: StatusResponse) {
        let memOnly = r.memoryCount ?? 0
        let wikiCount = r.wikiPageCount ?? 0
        // Treat wiki pages as part of the knowledge surface — combined with memories
        // so the card's big number, subtitle breakdown, and sheet all reconcile.
        self.memoryCount = memOnly + wikiCount
        var byType = r.memoriesByType ?? [:]
        if wikiCount > 0 { byType["wiki"] = wikiCount }
        self.memoriesByType = byType
        self.wikiPageCount = wikiCount
        self.entityCount = r.entityCount ?? 0
        self.entitiesByType = r.entitiesByType ?? [:]
        self.workerCount = r.workerCount ?? 0
        self.workersByStatus = r.workersByStatus ?? [:]
        self.pendingTasks = r.pendingTasks ?? 0
        self.tasksByStatus = r.tasksByStatus ?? [:]
        // Older servers won't have these fields; default to 0 so the Attention
        // card simply doesn't render against a stale binary.
        self.failedTasks = r.failedTasks ?? (r.tasksByStatus?["failed"] ?? 0)
        self.blockedTasks = r.blockedTasks ?? 0
        self.unreadEmails = r.unreadEmails ?? 0
        self.emailsByStatus = r.emailsByStatus ?? [:]
        self.nextEvent = r.nextCalendarEvent?.title ?? "None"
        self.upcomingEvents = (r.upcomingCalendarEvents ?? []).compactMap { e in
            guard let id = e.id, let title = e.title, let st = e.startTime else { return nil }
            return UpcomingEventInfo(id: id, title: title, startTime: st)
        }
        self.serverStatus = r.status ?? "unknown"
    }

    /// Top 3 entity types as a compact subtitle, with "+N more" if more types exist.
    var entitiesBreakdown: String? {
        Self.topBreakdown(entitiesByType)
    }

    /// Top 3 memory types as a compact subtitle, with "+N more" if more types exist.
    var memoriesBreakdown: String? {
        Self.topBreakdown(memoriesByType)
    }

    /// Total tasks across all statuses (sum of subtitle entries).
    var totalTasks: Int {
        tasksByStatus.values.reduce(0, +)
    }

    /// Total emails across all statuses (sum of subtitle entries).
    var totalEmails: Int {
        emailsByStatus.values.reduce(0, +)
    }

    /// Total worker rows (alive + any offline/stale that haven't been cleaned up).
    var totalWorkers: Int {
        workersByStatus.values.reduce(0, +)
    }

    /// Task status breakdown with pending pinned first so the headline state always shows.
    var tasksBreakdown: String? {
        Self.breakdownWithHeadline(tasksByStatus, headline: "pending")
    }

    /// Email status breakdown with unread pinned first so the headline state always shows.
    var emailsBreakdown: String? {
        Self.breakdownWithHeadline(emailsByStatus, headline: "unread")
    }

    /// Build a breakdown string with `headline` pinned to position 1, then top 3 of the rest.
    private static func breakdownWithHeadline(_ dict: [String: Int], headline: String) -> String? {
        let headlineCount = dict[headline] ?? 0
        let others = dict.filter { $0.key != headline }
        var parts = ["\(headlineCount) \(headline)"]
        let sortedOthers = others.sorted { $0.value > $1.value }
        let topOthers = sortedOthers.prefix(3).map { "\($0.value) \($0.key)" }
        parts.append(contentsOf: topOthers)
        let remainder = sortedOthers.count - topOthers.count
        if remainder > 0 { parts.append("+\(remainder) more") }
        return parts.joined(separator: " · ")
    }

    private static func topBreakdown(_ dict: [String: Int]) -> String? {
        guard !dict.isEmpty else { return nil }
        let sorted = dict.sorted { $0.value > $1.value }
        let top = sorted.prefix(3).map { "\($0.value) \($0.key)" }
        let remainder = sorted.count - top.count
        var parts = top
        if remainder > 0 { parts.append("+\(remainder) more") }
        return parts.joined(separator: " · ")
    }

    /// Order alive states first, problem states last.
    private static let statusOrder = ["starting", "idle", "busy", "draining", "stale", "offline"]

    var workersBreakdown: String? {
        guard !workersByStatus.isEmpty else { return nil }
        let known = Self.statusOrder.compactMap { s -> String? in
            guard let n = workersByStatus[s], n > 0 else { return nil }
            return "\(n) \(s)"
        }
        let unknown = workersByStatus
            .filter { !Self.statusOrder.contains($0.key) && $0.value > 0 }
            .map { "\($0.value) \($0.key)" }
            .sorted()
        let parts = known + unknown
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var hasZombieWorkers: Bool {
        (workersByStatus["stale"] ?? 0) > 0
    }

    var healthColor: Color {
        if workerCount == 0 || pendingTasks > 20 || serverStatus == "error" { return .red }
        if hasZombieWorkers || pendingTasks > 10 || unreadEmails > 20 { return .yellow }
        return .green
    }

    var healthLabel: String {
        if workerCount == 0 { return "Degraded — no live workers" }
        if serverStatus == "error" { return "Degraded" }
        if pendingTasks > 20 { return "Degraded — task backlog" }
        if hasZombieWorkers { return "Warning — stale workers" }
        if pendingTasks > 10 || unreadEmails > 20 { return "Warning" }
        return "All Systems Healthy"
    }
}

// MARK: - Stat Card

// MARK: - Breakdown Sheet

private struct BreakdownSheet: View {
    let title: String
    let counts: [String: Int]
    let footnote: String?
    @Environment(\.dismiss) private var dismiss

    private var sorted: [(String, Int)] {
        counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
    }

    private var total: Int {
        counts.values.reduce(0, +)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.title3.bold())
                Spacer()
                Text("\(total) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderless)
                    .padding(.leading, 8)
            }
            .padding()

            Divider()

            if sorted.isEmpty {
                VStack {
                    Spacer()
                    Text("Nothing to show yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sorted, id: \.0) { type, count in
                            HStack {
                                Text(type)
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                Text("\(count)")
                                    .font(.system(.body, design: .rounded).bold())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                            Divider()
                        }
                    }
                }
            }

            if let footnote {
                Divider()
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 360, minHeight: 420)
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.title, design: .rounded).bold())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Live Workers Section

private struct LiveWorkersSection: View {
    let workers: [Worker]
    let onTapRow: (Worker) -> Void

    private var busyCount: Int {
        workers.filter { $0.status == .busy }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Live Workers")
                    .font(.headline)
                Text("\(workers.count) total · \(busyCount) busy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    WorkerManager.shared.addWorker()
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Add worker")
            }

            if workers.isEmpty {
                VStack(spacing: 4) {
                    Text("No workers registered")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Use + above to spawn a Claude Code worker.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 2) {
                    ForEach(workers) { worker in
                        LiveWorkerRow(worker: worker, onTap: onTapRow)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LiveWorkerRow: View {
    @ObservedObject var worker: Worker
    let onTap: (Worker) -> Void

    @State private var isHovered = false
    @State private var showRestartAlert = false
    @State private var showRemoveAlert = false

    private static let cacheSampleFloor = 5_000

    private var statusDotColor: Color {
        switch worker.status {
        case .idle: return .green
        case .busy: return .blue
        case .draining: return .purple
        case .starting, .restarting: return .orange
        case .offline: return .red
        }
    }

    private var statusText: String {
        worker.status.rawValue.lowercased()
    }

    var body: some View {
        Button {
            onTap(worker)
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .alert("Restart \(worker.label)?", isPresented: $showRestartAlert) {
            Button("Restart") { WorkerManager.shared.cycleWorker(worker) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Remove \(worker.label)?", isPresented: $showRemoveAlert) {
            Button("Remove", role: .destructive) { WorkerManager.shared.removeWorker(worker) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This won't spawn a replacement.")
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)

            Text(worker.label)
                .font(.system(.caption, design: .monospaced))
                .frame(minWidth: 110, alignment: .leading)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if worker.status == .draining {
                Text("(cycling)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if worker.status == .busy {
                if !worker.currentSlug.isEmpty {
                    Text("· \(worker.currentSlug)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if worker.taskStartedAt > 0 {
                    let elapsedSec = Int((Date().timeIntervalSince1970 * 1000 - Double(worker.taskStartedAt)) / 1000)
                    Text("· \(elapsedSec)s elapsed")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if worker.currentEventTokens > 0 {
                    let kTokens = Double(worker.currentEventTokens) / 1000.0
                    Text(String(format: "· %.1fk tokens", kTokens))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let hr = worker.currentCacheHitRate,
                   worker.currentInputTokens >= Self.cacheSampleFloor {
                    Text(String(format: "· %.0f%% cache", hr * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if hr < 0.5 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Button {
                    showRestartAlert = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Restart (cycle) worker")

                Button {
                    showRemoveAlert = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove worker (drain + teardown without replacement)")
            }
            .opacity(isHovered ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .opacity(worker.status == .offline ? 0.6 : 1.0)
    }
}

// MARK: - Sessions Section

private struct SessionsSection: View {
    @ObservedObject var sessionsVM: InteractiveSessionsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sessions")
                .font(.headline)

            HStack(spacing: 12) {
                SessionLaunchCard(
                    title: "Supervisor",
                    icon: "shield.lefthalf.filled",
                    tint: .indigo,
                    badge: nil,
                    action: { SupervisorWindowController.shared.show() }
                )

                SessionLaunchCard(
                    title: "Interactive Sessions",
                    icon: "bubble.left.and.bubble.right.fill",
                    tint: .purple,
                    badge: badgeText,
                    action: { InteractiveSessionsWindowController.shared.show() }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Tab count when the window is open, otherwise nothing.
    private var badgeText: String? {
        guard InteractiveSessionsWindowController.shared.isVisible else { return nil }
        let n = sessionsVM.tabs.count
        return n > 0 ? "\(n)" : nil
    }
}

private struct SessionLaunchCard: View {
    let title: String
    let icon: String
    let tint: Color
    let badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                        if let badge {
                            Text(badge)
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(tint.opacity(0.18), in: Capsule())
                                .foregroundStyle(tint)
                        }
                    }
                    Text("Open window")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
