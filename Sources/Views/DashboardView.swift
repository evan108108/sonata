import SwiftUI

struct DashboardView: View {
    @Binding var selectedTab: SonataTab
    @State private var status: SystemStatus?
    @State private var error: String?
    @State private var lastRefresh: Date?
    @State private var showingEntityBreakdown = false
    @State private var showingMemoryBreakdown = false
    @State private var showingTaskBreakdown = false
    @State private var showingEmailBreakdown = false
    @ObservedObject private var workerManager = WorkerManager.shared

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
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

            if let error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    Text("Cannot reach Sonata server")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let status {
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
                            StatCard(title: "Workers", value: "\(status.totalWorkers)", icon: "cpu", color: status.workerCount == 0 ? .red : .cyan, detail: status.workersBreakdown)
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
                        }
                        .padding(.horizontal)

                        if !workerManager.workers.isEmpty {
                            LiveWorkersSection(workers: workerManager.workers) { worker in
                                WorkerManager.shared.selectedWorkerId = worker.id
                                selectedTab = .workers
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.bottom)
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading status...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // Small delay to let server start on first launch
            try? await Task.sleep(for: .milliseconds(800))
            await fetchStatus()
        }
        .onReceive(timer) { _ in
            Task { await fetchStatus() }
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
                self.error = "Server returned non-200 status"
                return
            }
            let decoded = try JSONDecoder().decode(StatusResponse.self, from: data)
            self.status = SystemStatus(from: decoded)
            self.error = nil
            self.lastRefresh = Date()
        } catch {
            self.error = error.localizedDescription
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
    let unreadEmails: Int?
    let emailsByStatus: [String: Int]?
    let nextCalendarEvent: NextCalendarEvent?
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
    let unreadEmails: Int
    let emailsByStatus: [String: Int]
    let nextEvent: String
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
        self.unreadEmails = r.unreadEmails ?? 0
        self.emailsByStatus = r.emailsByStatus ?? [:]
        self.nextEvent = r.nextCalendarEvent?.title ?? "None"
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
            }

            VStack(spacing: 2) {
                ForEach(workers) { worker in
                    Button {
                        onTapRow(worker)
                    } label: {
                        LiveWorkerRow(worker: worker)
                    }
                    .buttonStyle(.plain)
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
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .opacity(worker.status == .offline ? 0.6 : 1.0)
    }
}
