import SwiftUI

// MARK: - Models

struct ActivityFeedItem: Identifiable, Decodable, Equatable {
    let id: String
    let type: String
    let title: String
    let subtitle: String
    let timestamp: Int64
    let icon: String
    let collapsedCount: Int?
}

private struct RecentActivityPayload: Decodable {
    let items: [ActivityFeedItem]
    let generatedAt: Int64
}

// MARK: - View Model

@MainActor
final class ActivityFeedViewModel: ObservableObject {
    @Published var items: [ActivityFeedItem] = []
    @Published var hasLoadedOnce = false

    func fetch() async {
        do {
            let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/recent_activity")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(RecentActivityPayload.self, from: data)
            self.items = decoded.items
            self.hasLoadedOnce = true
        } catch {
            // Quiet on transient failures — keep last-known data.
        }
    }
}

// MARK: - Section

struct ActivityFeedSection: View {
    @ObservedObject var vm: ActivityFeedViewModel
    let onTapItem: (ActivityFeedItem) -> Void

    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Recent Activity")
                    .font(.headline)
                Text("last 24h")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !vm.hasLoadedOnce {
                // Quiet boot loader — match Dashboard's overall pattern.
                Color.clear.frame(height: 28)
            } else if vm.items.isEmpty {
                Text("No recent activity")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 2) {
                    ForEach(vm.items) { item in
                        ActivityFeedRow(
                            item: item,
                            relativeText: Self.relativeTimestamp(item.timestamp),
                            onTap: onTapItem
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private static func relativeTimestamp(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        return relFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Row

private struct ActivityFeedRow: View {
    let item: ActivityFeedItem
    let relativeText: String
    let onTap: (ActivityFeedItem) -> Void

    @State private var isHovered = false

    private var iconColor: Color {
        switch item.type {
        case "worker_completed":          return .green
        case "email_replied":             return .blue
        case "scheduled_job_run":         return .indigo
        case "calendar_event_fired":      return .indigo
        case "supervisor_alert":          return .orange
        case "background_thinking_output": return .purple
        default:                          return .secondary
        }
    }

    var body: some View {
        Button {
            onTap(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(item.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                Text(relativeText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isHovered ? 0.04 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
