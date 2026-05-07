import SwiftUI

// Dashboard v2 — four additions: Attention card (failed/blocked tasks),
// Plugin state StatCard, Upcoming calendar events panel, and a Background
// Thoughts panel. View models follow the same quiet-boot/30s-timer pattern as
// ActivityFeedViewModel and TokenUsageViewModel.

// MARK: - Plugins

private struct PluginStatusPayload: Decodable {
    let total: Int
    let byStatus: [String: Int]
    let generatedAt: Int64
}

@MainActor
final class PluginStatusViewModel: ObservableObject {
    @Published var total: Int = 0
    @Published var byStatus: [String: Int] = [:]
    @Published var hasLoadedOnce = false

    func fetch() async {
        do {
            let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/plugins_status")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(PluginStatusPayload.self, from: data)
            self.total = decoded.total
            self.byStatus = decoded.byStatus
            self.hasLoadedOnce = true
        } catch {
            // Quiet on transient failures.
        }
    }

    var hasError: Bool {
        (byStatus["error"] ?? 0) > 0
    }

    /// Top 3 statuses by count, "+N more" tail when there are extras.
    var breakdown: String? {
        guard !byStatus.isEmpty else { return nil }
        let sorted = byStatus.sorted { $0.value > $1.value }
        let top = sorted.prefix(3).map { "\($0.value) \($0.key)" }
        let remainder = sorted.count - top.count
        var parts = Array(top)
        if remainder > 0 { parts.append("+\(remainder) more") }
        return parts.joined(separator: " · ")
    }
}

struct PluginStatCard: View {
    @ObservedObject var vm: PluginStatusViewModel
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.title2)
                    .foregroundStyle(tint)
                Text("\(vm.total)")
                    .font(.system(.title, design: .rounded).bold())
                Text("Plugins")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail = vm.breakdown {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var tint: Color {
        vm.hasError ? .orange : .green
    }
}

// MARK: - Attention zone: failed / blocked tasks

struct AttentionTasksCard: View {
    let failedTasks: Int
    let blockedTasks: Int
    let onTap: () -> Void

    private var total: Int { failedTasks + blockedTasks }

    private var subtitle: String {
        var parts: [String] = []
        if failedTasks > 0 { parts.append("\(failedTasks) failed") }
        if blockedTasks > 0 { parts.append("\(blockedTasks) blocked") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(total)")
                            .font(.system(.title, design: .rounded).bold())
                        Text(total == 1 ? "stuck task" : "stuck tasks")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.red.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Deadlines (Attention zone)

struct DeadlineItemModel: Identifiable, Decodable, Equatable {
    let id: String
    let source: String       // "task" | "memory"
    let title: String
    let subtitle: String?
    let dueAt: Int64
}

private struct DeadlinesPayload: Decodable {
    let items: [DeadlineItemModel]
    let generatedAt: Int64
}

@MainActor
final class DeadlinesViewModel: ObservableObject {
    @Published var items: [DeadlineItemModel] = []
    @Published var hasLoadedOnce = false

    func fetch() async {
        do {
            let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/deadlines")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(DeadlinesPayload.self, from: data)
            self.items = decoded.items
            self.hasLoadedOnce = true
        } catch {
            // Quiet on transient failures.
        }
    }
}

struct DeadlinesCard: View {
    let items: [DeadlineItemModel]
    let onTapItem: (DeadlineItemModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "clock.badge.exclamationmark.fill")
                    .foregroundStyle(.red)
                Text("Deadlines")
                    .font(.headline)
                Text("today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 2) {
                ForEach(items) { item in
                    Button {
                        onTapItem(item)
                    } label: {
                        deadlineRow(item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.red.opacity(0.20), lineWidth: 1)
        )
    }

    private func deadlineRow(_ item: DeadlineItemModel) -> some View {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let isOverdue = item.dueAt < nowMs
        let isDueToday = !isOverdue && item.dueAt < endOfTodayMs()
        let tint: Color = isOverdue ? .red : (isDueToday ? .orange : .secondary)

        return HStack(spacing: 10) {
            Image(systemName: item.source == "task" ? "checklist" : "brain")
                .font(.callout)
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(Self.relativeDeadline(to: item.dueAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// "due in 3h", "due in 23m", "overdue 1d", "overdue 2h".
    static func relativeDeadline(to dueAtMs: Int64) -> String {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let deltaSec = (dueAtMs - nowMs) / 1000
        let absSec = abs(deltaSec)
        let prefix = deltaSec >= 0 ? "due in" : "overdue"
        let amount = absSec
        if amount < 60 { return deltaSec >= 0 ? "due now" : "overdue" }
        let mins = amount / 60
        if mins < 60 { return "\(prefix) \(mins)m" }
        let hours = mins / 60
        if hours < 24 { return "\(prefix) \(hours)h" }
        let days = hours / 24
        return "\(prefix) \(days)d"
    }

    /// Local end-of-today as epoch ms. Used to color "due today" rows orange.
    private func endOfTodayMs() -> Int64 {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        return Int64(end.timeIntervalSince1970 * 1000)
    }
}

// MARK: - Upcoming calendar events

struct UpcomingEventInfo: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let startTime: Int64
}

struct UpcomingEventsSection: View {
    let events: [UpcomingEventInfo]
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "calendar")
                    .foregroundStyle(.indigo)
                Text("Upcoming")
                    .font(.headline)
                Text("next \(events.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            VStack(spacing: 2) {
                ForEach(events) { event in
                    Button(action: onTap) {
                        HStack(spacing: 10) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.callout)
                                .foregroundStyle(.indigo)
                                .frame(width: 18)
                            Text(event.title)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer()
                            Text(Self.relativeCountdown(to: event.startTime))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    /// "in 23m", "in 3h 12m", "in 2d 4h" — short and unambiguous.
    static func relativeCountdown(to startMs: Int64) -> String {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let delta = max(0, startMs - nowMs) / 1000   // seconds
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

// MARK: - AFK Questions (Attention zone)

struct AFKActiveEntryModel: Identifiable, Decodable, Equatable {
    let token: String
    let workerId: String
    let registeredAt: Int64
    let workerLabel: String?
    let lastQuestion: String?

    var id: String { token }
}

private struct AFKActiveResponse: Decodable {
    let entries: [AFKActiveEntryModel]
    let generatedAt: Int64
}

@MainActor
final class AFKQuestionsViewModel: ObservableObject {
    @Published var entries: [AFKActiveEntryModel] = []
    @Published var hasLoadedOnce = false

    func fetch() async {
        do {
            let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/afk/active")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(AFKActiveResponse.self, from: data)
            self.entries = decoded.entries
            self.hasLoadedOnce = true
        } catch {
            // Quiet on transient failures.
        }
    }
}

struct AFKQuestionsCard: View {
    let entries: [AFKActiveEntryModel]
    /// Worker `sessionId → Worker` lookup so taps can navigate to the live row.
    let workersBySessionId: [String: Worker]
    let onTapWorker: (Worker) -> Void

    @State private var unmatchedToken: String?

    private static let userEmail = "evan108108@gmail.com"

    private var countText: String {
        "\(entries.count) pending"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(.orange)
                Text("AFK Questions")
                    .font(.headline)
                Text(countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            VStack(spacing: 2) {
                ForEach(entries) { entry in
                    Button {
                        if let worker = workersBySessionId[entry.workerId] {
                            onTapWorker(worker)
                        } else {
                            unmatchedToken = entry.token
                        }
                    } label: {
                        afkRow(entry)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Reply via email at \(Self.userEmail) — subject [AFK:<token>]")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        )
        .alert("AFK token", isPresented: Binding(
            get: { unmatchedToken != nil },
            set: { if !$0 { unmatchedToken = nil } }
        )) {
            Button("OK", role: .cancel) { unmatchedToken = nil }
        } message: {
            Text("No live worker matches this AFK session. Token: \(unmatchedToken ?? "")")
        }
    }

    private func afkRow(_ entry: AFKActiveEntryModel) -> some View {
        let label = entry.workerLabel ?? Self.shortWorkerId(entry.workerId)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(width: 18)

                Text(label)
                    .font(.system(.callout, design: .monospaced))

                Text(entry.token)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text("registered \(Self.relativeAgo(entry.registeredAt))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let q = entry.lastQuestion, !q.isEmpty {
                Text(Self.truncate(q, to: 120))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// "5m ago", "2h ago", "1d ago" — short and unambiguous.
    static func relativeAgo(_ ms: Int64) -> String {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let deltaSec = max(0, nowMs - ms) / 1000
        if deltaSec < 60 { return "\(deltaSec)s ago" }
        let mins = deltaSec / 60
        if mins < 60 { return "\(mins)m ago" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }

    private static func shortWorkerId(_ id: String) -> String {
        guard id.count > 12 else { return id }
        let prefix = id.prefix(8)
        let suffix = id.suffix(4)
        return "\(prefix)…\(suffix)"
    }

    private static func truncate(_ s: String, to n: Int) -> String {
        guard s.count > n else { return s }
        return String(s.prefix(n)) + "…"
    }
}

// MARK: - Background thoughts

struct RecentThoughtItemModel: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let body: String
    let source: String
    let timestamp: Int64
}

private struct RecentThoughtsPayload: Decodable {
    let items: [RecentThoughtItemModel]
    let generatedAt: Int64
}

@MainActor
final class RecentThoughtsViewModel: ObservableObject {
    @Published var items: [RecentThoughtItemModel] = []
    @Published var hasLoadedOnce = false

    func fetch() async {
        do {
            let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/recent_thoughts")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(RecentThoughtsPayload.self, from: data)
            self.items = decoded.items
            self.hasLoadedOnce = true
        } catch {
            // Quiet on transient failures.
        }
    }
}

struct BackgroundThoughtsSection: View {
    @ObservedObject var vm: RecentThoughtsViewModel
    @State private var selected: RecentThoughtItemModel?

    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "brain")
                    .foregroundStyle(.purple)
                Text("Background Thinking")
                    .font(.headline)
                Text("last 24h")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            VStack(spacing: 2) {
                ForEach(vm.items) { item in
                    Button {
                        selected = item
                    } label: {
                        thoughtRow(item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .sheet(item: $selected) { item in
            ThoughtDetailSheet(item: item)
        }
    }

    private func thoughtRow(_ item: RecentThoughtItemModel) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(item.source)
                .font(.caption2.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.18), in: Capsule())
                .foregroundStyle(.purple)

            Text(item.title)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(Self.relativeText(item.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private static func relativeText(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return relFormatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct ThoughtDetailSheet: View {
    let item: RecentThoughtItemModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.source)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.18), in: Capsule())
                    .foregroundStyle(.purple)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            ScrollView {
                Text(item.body)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}
