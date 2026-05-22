import SwiftUI

struct EmailView: View {
    @StateObject private var vm = EmailViewModel()
    @State private var selectedEmail: EmailItem?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Email")
                    .font(.title.bold())
                if vm.unreadCount > 0 {
                    Text("\(vm.unreadCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer()
                RefreshButton(isStale: vm.isStale) {
                    Task { await vm.fetch() }
                }
            }
            .padding()

            Divider()

            if let error = vm.error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    Text("Cannot load emails")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.emails.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No emails")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    // Email list
                    List(selection: $selectedEmail) {
                        ForEach(vm.emails) { email in
                            EmailListRow(email: email)
                                .tag(email)
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: Theme.Sidebar.minWidth,
                           idealWidth: Theme.Sidebar.idealWidth,
                           maxWidth: Theme.Sidebar.maxWidth)
                    .warmSidebar()

                    // Detail pane
                    if let email = selectedEmail {
                        EmailDetailView(email: email, onAction: {
                            await vm.fetch()
                            // Update selected email with refreshed data
                            if let updated = vm.emails.first(where: { $0._id == email._id }) {
                                selectedEmail = updated
                            }
                        })
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "envelope.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text("Select an email to read")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .task {
            await vm.fetch()
            vm.startMonitoring()
        }
        .onAppear { Task { await vm.fetch() } }
    }
}

// MARK: - Email List Row

private struct EmailListRow: View {
    let email: EmailItem

    var body: some View {
        HStack(spacing: 8) {
            // Unread indicator
            Circle()
                .fill(email.status == "unread" ? .blue : .clear)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(email.subject)
                        .font(email.status == "unread" ? .headline : .headline.weight(.regular))
                        .lineLimit(1)
                    Spacer()
                    EmailStatusBadge(status: email.status)
                }
                HStack {
                    Text(email.from)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(email.dateString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Email Detail

private struct EmailDetailView: View {
    let email: EmailItem
    let onAction: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Email header
            VStack(alignment: .leading, spacing: 8) {
                Text(email.subject)
                    .font(.title2.bold())
                    .textSelection(.enabled)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("From:")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(email.from)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                        HStack(spacing: 4) {
                            Text("To:")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(email.to)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                        HStack(spacing: 4) {
                            Text("Date:")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(email.fullDateString)
                                .font(.caption)
                        }
                    }
                    Spacer()
                    EmailStatusBadge(status: email.status)
                }

                // Action buttons
                HStack(spacing: 8) {
                    if email.status == "unread" {
                        Button {
                            Task {
                                await markEmail("mark-read", id: email._id)
                                await onAction()
                            }
                        } label: {
                            Label("Mark Read", systemImage: "envelope.open")
                        }
                        .buttonStyle(.bordered)
                    }

                    if email.status == "read" || email.status == "unread" {
                        Button {
                            Task {
                                await markEmail("mark-replied", id: email._id)
                                await onAction()
                            }
                        } label: {
                            Label("Mark Replied", systemImage: "arrowshape.turn.up.left.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    }

                    if email.status != "unread" {
                        Button {
                            Task {
                                await markEmail("mark-unread", id: email._id)
                                await onAction()
                            }
                        } label: {
                            Label("Mark Unread", systemImage: "envelope.badge")
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }
                }
            }
            .padding()

            Divider()

            // Body
            ScrollView {
                Text(email.body)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(minWidth: 400)
    }

    private func markEmail(_ action: String, id: String) async {
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/email/\(action)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ["id": id]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            request.httpBody = data
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}

// MARK: - Status Badge

private struct EmailStatusBadge: View {
    let status: String

    var color: Color {
        switch status {
        case "unread": return .blue
        case "read": return .secondary
        case "replied": return .green
        default: return .secondary
        }
    }

    var icon: String {
        switch status {
        case "unread": return "envelope.badge.fill"
        case "read": return "envelope.open"
        case "replied": return "arrowshape.turn.up.left.fill"
        default: return "envelope"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(status.capitalized)
        }
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}

// MARK: - Model

struct EmailItem: Identifiable, Hashable, Decodable {
    let _id: String
    let messageId: String
    let threadId: String
    let from: String
    let to: String
    let subject: String
    let body: String
    let status: String
    let receivedAt: Int64
    let repliedAt: Int64?

    var id: String { _id }

    var dateString: String {
        let seconds = (Date().timeIntervalSince1970 * 1000 - Double(receivedAt)) / 1000
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }

    var fullDateString: String {
        let date = Date(timeIntervalSince1970: Double(receivedAt) / 1000)
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    func hash(into hasher: inout Hasher) { hasher.combine(_id) }
    static func == (lhs: EmailItem, rhs: EmailItem) -> Bool { lhs._id == rhs._id }
}
