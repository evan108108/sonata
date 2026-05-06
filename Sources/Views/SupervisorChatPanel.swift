import SwiftUI

struct SupervisorChatPanel: View {
    @ObservedObject var vm: SupervisorChatViewModel
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    private var lastThree: [SupervisorMessage] {
        // Keep order ascending so newest is at the bottom (chat-style).
        let sorted = vm.messages.sorted { $0.createdAt < $1.createdAt }
        return Array(sorted.suffix(3))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            messageStack

            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Supervisor")
                .font(.subheadline.bold())

            if !vm.supervisorRunning {
                Text("offline")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.18), in: Capsule())
                    .foregroundStyle(.red)
            } else if let label = vm.lastActivityLabel {
                Text("· last active \(label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                SupervisorWindowController.shared.show()
            } label: {
                Text("Open full conversation")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var messageStack: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if vm.messages.isEmpty {
                    emptyState
                } else {
                    ForEach(lastThree) { msg in
                        MessageRow(message: msg)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ask the supervisor about anything Sonata is doing —")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("workers, scheduled jobs, recent emails, system health.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            if let err = vm.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                TextField("Message supervisor…", text: $draft, axis: .horizontal)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .disabled(vm.inFlight)
                    .onSubmit { submit() }

                if vm.inFlight {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        submit()
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
    }

    private func submit() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await vm.submit(text) }
    }
}

private struct MessageRow: View {
    let message: SupervisorMessage

    private var roleColor: Color {
        switch message.role {
        case "user": return .blue
        case "assistant": return .purple
        case "alert": return .red
        case "system": return .orange
        default: return .secondary
        }
    }

    private var roleLabel: String {
        switch message.role {
        case "user": return "you"
        case "assistant": return "supervisor"
        default: return message.role
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(roleLabel)
                    .font(.caption2.bold())
                    .foregroundStyle(roleColor)
                Text(relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(message.content)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var relativeTime: String {
        guard message.createdAt > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(message.createdAt) / 1000.0)
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "now" }
        if secs < 3_600 { return "\(secs / 60)m" }
        if secs < 86_400 { return "\(secs / 3_600)h" }
        return "\(secs / 86_400)d"
    }
}
