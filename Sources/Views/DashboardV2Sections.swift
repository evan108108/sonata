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
