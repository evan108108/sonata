import SwiftUI

struct HealthView: View {
    @State private var status: SystemStatus?
    @State private var error: String?
    @State private var lastRefresh: Date?

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
                            StatCard(title: "Memories", value: "\(status.memoryCount)", icon: "brain.head.profile", color: .purple)
                            StatCard(title: "Entities", value: "\(status.entityCount)", icon: "person.3.fill", color: .blue)
                            StatCard(title: "Relations", value: "\(status.relationCount)", icon: "link", color: .cyan)
                            StatCard(title: "Pending Tasks", value: "\(status.pendingTasks)", icon: "checklist", color: status.pendingTasks > 10 ? .orange : .green)
                            StatCard(title: "Unread Emails", value: "\(status.unreadEmails)", icon: "envelope.badge.fill", color: status.unreadEmails > 0 ? .orange : .green)
                            StatCard(title: "Next Event", value: status.nextEvent, icon: "calendar", color: .indigo)
                        }
                        .padding(.horizontal)
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
    let entityCount: Int?
    let relationCount: Int?
    let pendingTasks: Int?
    let unreadEmails: Int?
    let nextEvent: String?
    // Flexible: accept any keys the server returns
    let status: String?

    enum CodingKeys: String, CodingKey {
        case memoryCount = "memory_count"
        case entityCount = "entity_count"
        case relationCount = "relation_count"
        case pendingTasks = "pending_tasks"
        case unreadEmails = "unread_emails"
        case nextEvent = "next_event"
        case status
    }
}

private struct SystemStatus {
    let memoryCount: Int
    let entityCount: Int
    let relationCount: Int
    let pendingTasks: Int
    let unreadEmails: Int
    let nextEvent: String
    let serverStatus: String

    init(from r: StatusResponse) {
        self.memoryCount = r.memoryCount ?? 0
        self.entityCount = r.entityCount ?? 0
        self.relationCount = r.relationCount ?? 0
        self.pendingTasks = r.pendingTasks ?? 0
        self.unreadEmails = r.unreadEmails ?? 0
        self.nextEvent = r.nextEvent ?? "None"
        self.serverStatus = r.status ?? "unknown"
    }

    var healthColor: Color {
        if pendingTasks > 20 || serverStatus == "error" { return .red }
        if pendingTasks > 10 || unreadEmails > 20 { return .yellow }
        return .green
    }

    var healthLabel: String {
        if pendingTasks > 20 || serverStatus == "error" { return "Degraded" }
        if pendingTasks > 10 || unreadEmails > 20 { return "Warning" }
        return "All Systems Healthy"
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.title, design: .rounded).bold())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
