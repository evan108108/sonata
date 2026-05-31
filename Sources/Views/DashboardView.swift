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
    @StateObject private var attentionVM = AttentionTasksViewModel()
    @StateObject private var allSessionsVM = AllSessionsViewModel()

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    /// Sessions list refreshes faster than the rest of the dashboard so
    /// new Connected rows appear shortly after a session attaches its
    /// SSE — not after up to 30s.
    private let sessionsTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    private let bootRetryInterval: TimeInterval = 1.5

    var body: some View {
        mainContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Subtle refresh strip — the dashboard is now the entry surface for the
            // whole app, so we no longer brand it with a "System Health" title. The
            // green-dot health indicator below acts as the de-facto title.
            HStack {
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
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if let status {
                ScrollView {
                    VStack(spacing: 16) {
                        // Health line — sits at the top as the de-facto title now
                        // that "System Health" is gone. One-line status with a
                        // colored dot is enough to anchor the page.
                        HStack(spacing: 12) {
                            Circle()
                                .fill(status.healthColor)
                                .frame(width: 14, height: 14)
                            Text(status.healthLabel)
                                .font(.title3.weight(.semibold))
                            Spacer()
                        }
                        .padding(.horizontal)

                        // ── Summary grid ────────────────────────────────────────
                        // High-level state at a glance. Tap a card to peek the
                        // breakdown sheet for that resource.
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                        ], spacing: 16) {
                            Button { showingMemoryBreakdown = true } label: {
                                StatCard(title: "Memories", value: "\(status.memoryCount)", icon: "brain.head.profile", color: .purple, detail: status.memoriesBreakdown)
                            }.buttonStyle(.plain)
                            Button { showingEntityBreakdown = true } label: {
                                StatCard(title: "Entities", value: "\(status.entityCount)", icon: "point.3.connected.trianglepath.dotted", color: .blue, detail: status.entitiesBreakdown)
                            }.buttonStyle(.plain)
                            Button { showingTaskBreakdown = true } label: {
                                StatCard(title: "Tasks", value: "\(status.totalTasks)", icon: "checklist", color: status.pendingTasks > 10 ? .orange : .green, detail: status.tasksBreakdown)
                            }.buttonStyle(.plain)
                            Button { showingEmailBreakdown = true } label: {
                                StatCard(title: "Emails", value: "\(status.totalEmails)", icon: "envelope.badge.fill", color: status.unreadEmails > 0 ? .orange : .green, detail: status.emailsBreakdown)
                            }.buttonStyle(.plain)
                            StatCard(title: "Next Event", value: status.nextEvent, icon: "calendar", color: .indigo, detail: status.nextEventDetail)
                            PluginStatCard(vm: pluginVM) { selectedTab = .plugins }
                        }
                        .padding(.horizontal)

                        // ── Live Workers ───────────────────────────────────────
                        // Sits directly below the summary grid: "what does the
                        // pool look like right now" is the natural follow-on to
                        // the totals above.
                        LiveWorkersSection(
                            workers: workerManager.workers
                        ) { worker in
                            WorkerManager.shared.selectedWorkerId = worker.id
                            selectedTab = .workers
                        }
                        .padding(.horizontal)

                        ConnectedSessionsSection(vm: allSessionsVM)
                            .padding(.horizontal)

                        UnconnectedSessionsSection(vm: allSessionsVM)
                            .padding(.horizontal)

                        AgentWebviewsSection(vm: allSessionsVM)
                            .padding(.horizontal)

                        // ── Token Usage ────────────────────────────────────────
                        // What is this costing right now — sparkline + today's spend.
                        TokenUsageCard(vm: tokenVM)
                            .padding(.horizontal)

                        // ── Attention zone ─────────────────────────────────────
                        // Things needing the user's eyes; each hides when empty.
                        if !attentionVM.items.isEmpty {
                            AttentionTasksCard(vm: attentionVM) { selectedTab = .tasks }
                                .padding(.horizontal)
                        }

                        if !deadlinesVM.items.isEmpty {
                            DeadlinesCard(items: deadlinesVM.items) { item in
                                selectedTab = item.source == "task" ? .tasks : .memory
                            }
                            .padding(.horizontal)
                        }

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

                        // (SessionsSection lives in a pinned footer below the ScrollView
                        //  so the Supervisor / Interactive Sessions launchers are always
                        //  reachable without scrolling.)

                        if !status.upcomingEvents.isEmpty {
                            UpcomingEventsSection(events: status.upcomingEvents) {
                                selectedTab = .schedule
                            }
                            .padding(.horizontal)
                        }

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
                    .padding(.top, 4)
                    .padding(.bottom)
                }

                // Pinned footer — Supervisor / Interactive Sessions launchers are
                // always one click away regardless of scroll position. The Sessions
                // section is small (two buttons) and accessing live agent surfaces
                // shouldn't require remembering where it scrolled to.
                Divider()
                SessionsSection(sessionsVM: sessionsVM) {
                    selectedTab = .sessions
                }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
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
        .task {
            while !attentionVM.hasLoadedOnce && !Task.isCancelled {
                await attentionVM.fetch()
                if attentionVM.hasLoadedOnce { break }
                try? await Task.sleep(for: .seconds(bootRetryInterval))
            }
        }
        .task {
            while !allSessionsVM.hasLoadedOnce && !Task.isCancelled {
                await allSessionsVM.fetch()
                if allSessionsVM.hasLoadedOnce { break }
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
            Task { await attentionVM.fetch() }
            Task { await allSessionsVM.fetch() }
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
    let nextScheduledJob: NextCalendarEvent?
    let upcomingScheduledJobs: [NextCalendarEvent]?
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
    /// Subtitle for the Next Event card: "in 14m · scheduler" / "in 2d · calendar".
    /// Nil when there's no next item from either system.
    let nextEventDetail: String?
    /// Combined upcoming stream: calendar events + scheduledJobs, sorted by
    /// startTime ASC, capped at 6. Each item carries a `source` label so the
    /// dashboard can teach the calendar-vs-scheduler distinction inline.
    let upcomingEvents: [UpcomingEventInfo]
    let upcomingCalendarOnly: [UpcomingEventInfo]
    let upcomingSchedulerOnly: [UpcomingEventInfo]
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
        // Next Event card: pick the soonest of (next calendar event, next
        // scheduler firing) so the widget reflects both systems instead of
        // only one. Calendar = one-off reminders ("Restart Profile 3"),
        // scheduler = recurring shell/cron jobs ("scout-rss"). Without this
        // merge, the card reads "None" whenever calendar is empty even when
        // dozens of scheduler jobs are healthily queued — which is the
        // common case.
        let calNext: (title: String, st: Int64)? = {
            guard let title = r.nextCalendarEvent?.title, let st = r.nextCalendarEvent?.startTime else { return nil }
            return (title, st)
        }()
        let jobNext: (title: String, st: Int64)? = {
            guard let title = r.nextScheduledJob?.title, let st = r.nextScheduledJob?.startTime else { return nil }
            return (title, st)
        }()
        let pickedSource: String?
        let pickedTitle: String?
        let pickedStart: Int64?
        switch (calNext, jobNext) {
        case let (.some(c), .some(j)):
            if c.st <= j.st {
                pickedSource = "calendar"; pickedTitle = c.title; pickedStart = c.st
            } else {
                pickedSource = "scheduler"; pickedTitle = j.title; pickedStart = j.st
            }
        case let (.some(c), .none):
            pickedSource = "calendar"; pickedTitle = c.title; pickedStart = c.st
        case let (.none, .some(j)):
            pickedSource = "scheduler"; pickedTitle = j.title; pickedStart = j.st
        case (.none, .none):
            pickedSource = nil; pickedTitle = nil; pickedStart = nil
        }
        self.nextEvent = pickedTitle ?? "None"
        if let src = pickedSource, let st = pickedStart {
            self.nextEventDetail = "\(SystemStatus.relativeCountdown(to: st)) · \(src)"
        } else {
            self.nextEventDetail = nil
        }

        let calItems: [UpcomingEventInfo] = (r.upcomingCalendarEvents ?? []).compactMap { e in
            guard let id = e.id, let title = e.title, let st = e.startTime else { return nil }
            return UpcomingEventInfo(id: id, title: title, startTime: st, source: "calendar")
        }
        let jobItems: [UpcomingEventInfo] = (r.upcomingScheduledJobs ?? []).compactMap { e in
            guard let id = e.id, let title = e.title, let st = e.startTime else { return nil }
            return UpcomingEventInfo(id: id, title: title, startTime: st, source: "scheduler")
        }
        self.upcomingCalendarOnly = calItems
        self.upcomingSchedulerOnly = jobItems
        self.upcomingEvents = (calItems + jobItems)
            .sorted { $0.startTime < $1.startTime }
            .prefix(6)
            .map { $0 }
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

    /// "in 23m" / "in 3h 12m" / "in 2d 4h". Mirror of UpcomingEventsSection's
    /// helper, exposed here so the Next Event card subtitle can format itself
    /// without reaching across files.
    static func relativeCountdown(to startMs: Int64) -> String {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let delta = max(0, startMs - nowMs) / 1000
        if delta < 60 { return "now" }
        let mins = delta / 60
        if mins < 60 { return "in \(mins)m" }
        let hours = mins / 60
        let remMin = mins % 60
        if hours < 24 {
            return remMin == 0 ? "in \(hours)h" : "in \(hours)h \(remMin)m"
        }
        let days = hours / 24
        let remHr = hours % 24
        return remHr == 0 ? "in \(days)d" : "in \(days)d \(remHr)h"
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
        // maxHeight: .infinity makes the card stretch to its grid row height so
        // a card with a wrapping value/detail (e.g. a long "Next Event" title)
        // doesn't leave its row-mates shorter than itself.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Live Workers Section

private struct LiveWorkersSection: View {
    let workers: [Worker]
    let onTapRow: (Worker) -> Void
    @State private var dmTarget: Worker?
    @State private var dmResult: String?

    private var busyCount: Int {
        workers.filter { $0.status == .busy }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header — matches AttentionTasksCard's pattern so stacked
            // sections read as a consistent set: icon + title + count + meta on
            // the left, actions on the right.
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .foregroundStyle(.cyan)
                Text("Workers")
                    .font(.headline)
                Text("\(workers.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("· \(busyCount) busy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    WorkerManager.shared.addWorker()
                } label: {
                    Label("Add", systemImage: "plus.circle")
                        .font(.caption)
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
                    workerColumnHeader
                    ForEach(workers) { worker in
                        LiveWorkerRow(worker: worker, onTap: onTapRow) {
                            dmTarget = worker
                        }
                    }
                }
            }
            if let result = dmResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .sheet(item: $dmTarget) { worker in
            WorkerDMSheet(worker: worker) { text in
                Task {
                    dmResult = await Self.sendDM(target: worker.id, body: text)
                }
            }
        }
    }

    private static func sendDM(target: String, body: String) async -> String {
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/dm/send")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "targetSessionId": target,
            "fromSessionId": "dashboard",
            "body": body,
            "context": "dashboard-worker-dm",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let delivery = obj["deliveryStatus"] as? String {
                return "Sent to \(target) — \(delivery)"
            }
            let snippet = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
            return "Failed (HTTP \(code)) — \(snippet)"
        } catch {
            return "Failed — \(error.localizedDescription)"
        }
    }
}

private struct WorkerDMSheet: View {
    let worker: Worker
    let onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var messageText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill").foregroundStyle(.cyan)
                Text("DM \(worker.label)").font(.headline)
                Text(worker.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.borderless)
            }
            TextEditor(text: $messageText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .padding(6)
                .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Text("\(messageText.utf8.count) bytes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Send") {
                    onSend(messageText)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 260)
    }
}

/// Column header for the Workers section — column widths match
/// LiveWorkerRow.rowContent so headers line up.
fileprivate var workerColumnHeader: some View {
    HStack(spacing: 10) {
        Color.clear.frame(width: 8, height: 8)
        Text("WORKER")
            .frame(width: 110, alignment: .leading)
        Text("STATUS")
            .frame(width: 70, alignment: .leading)
        Text("CURRENT TASK")
            .frame(maxWidth: .infinity, alignment: .leading)
        Text("ELAPSED")
            .frame(width: 60, alignment: .trailing)
        Text("TASKS")
            .frame(width: 50, alignment: .trailing)
        Text("TOKENS")
            .frame(width: 60, alignment: .trailing)
        Text("CACHE")
            .frame(width: 60, alignment: .trailing)
        // action column placeholder (3 buttons ≈ 60pt)
        Color.clear.frame(width: 60)
    }
    .font(.system(size: 9, weight: .semibold))
    .foregroundStyle(.tertiary)
    .padding(.top, 4)
    .padding(.bottom, 2)
}

private struct LiveWorkerRow: View {
    @ObservedObject var worker: Worker
    let onTap: (Worker) -> Void
    let onDM: () -> Void

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

    private var labelCell: some View {
        Text(worker.label)
            .font(.system(.caption, design: .monospaced))
            .frame(width: 110, alignment: .leading)
    }

    private var statusCell: some View {
        Text(worker.status == .draining ? "draining" : statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 70, alignment: .leading)
    }

    private var taskCell: some View {
        // Pick the first non-empty hint: slug (most readable) → task
        // (often the prompt summary) → eventId (last-resort identifier).
        let candidates = [worker.currentSlug, worker.currentTask, worker.currentEventId]
        let display = candidates.first(where: { !$0.isEmpty }) ?? ""
        let hasTask = !display.isEmpty
        return Text(hasTask ? display : "—")
            .font(.caption)
            .foregroundStyle(hasTask ? .secondary : .tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(hasTask ? display : "(no task assigned)")
    }

    private var elapsedCell: some View {
        let text: String = {
            guard worker.status == .busy, worker.taskStartedAt > 0 else { return "—" }
            let elapsedSec = Int((Date().timeIntervalSince1970 * 1000 - Double(worker.taskStartedAt)) / 1000)
            return "\(elapsedSec)s"
        }()
        return Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 60, alignment: .trailing)
    }

    private var tasksCountCell: some View {
        Text("\(worker.tasksSinceSpawn)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 50, alignment: .trailing)
            .help("Tasks completed since this worker spawned")
    }

    private var tokensCell: some View {
        let text: String = {
            guard worker.currentEventTokens > 0 else { return "—" }
            return String(format: "%.1fk", Double(worker.currentEventTokens) / 1000.0)
        }()
        return Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 60, alignment: .trailing)
    }

    @ViewBuilder
    private var cacheCell: some View {
        HStack(spacing: 2) {
            if let hr = worker.currentCacheHitRate,
               worker.currentInputTokens >= Self.cacheSampleFloor {
                if hr < 0.5 {
                    Text(String(format: "%.0f%%", hr * 100))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.orange)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.orange)
                } else {
                    Text(String(format: "%.0f%%", hr * 100))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 60, alignment: .trailing)
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
            labelCell
            statusCell
            taskCell
            elapsedCell
            tasksCountCell
            tokensCell
            cacheCell
            HStack(spacing: 6) {
                Button {
                    onDM()
                } label: {
                    Image(systemName: "paperplane")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("DM this worker")

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
    let onOpenInteractiveSessions: () -> Void

    var body: some View {
        // No headline — the launchers themselves are self-explanatory in the
        // pinned footer; "Sessions" was redundant chrome.
        HStack(spacing: 12) {
            SessionLaunchCard(
                title: "Supervisor",
                icon: "shield.lefthalf.filled",
                tint: .indigo,
                badge: nil,
                action: { SupervisorWindowController.shared.show() }
            )

            // Routes to the in-rail Sessions tab now (the standalone
            // InteractiveSessionsWindowController is dead code — the rail
            // owns this experience).
            SessionLaunchCard(
                title: "Interactive Sessions",
                icon: "bubble.left.and.bubble.right.fill",
                tint: .purple,
                badge: badgeText,
                action: { onOpenInteractiveSessions() }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Active tab count from the in-rail Sessions tab.
    private var badgeText: String? {
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
