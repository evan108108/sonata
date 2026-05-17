import SwiftUI

/// Dashboard section that lists EVERY MCPSessionRegistry-connected session —
/// not just workers. Each row has a type chip (worker / orchestrator /
/// supervisor / inspector / adhoc) and a DM action that hits
/// `/api/dm/send` directly so the operator can ping any live session
/// without leaving the dashboard.
struct AllSessionsSection: View {
    @ObservedObject var vm: AllSessionsViewModel
    @State private var dmTarget: AllSessionsRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(.teal)
                Text("All Sessions")
                    .font(.headline)
                Text("\(vm.rows.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                let live = vm.rows.filter(\.isAlive).count
                Text("· \(live) live")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await vm.fetch() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Refresh session list")
            }

            if vm.rows.isEmpty {
                VStack(spacing: 4) {
                    Text(vm.hasLoadedOnce ? "No sessions registered" : "Loading…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if vm.hasLoadedOnce {
                        Text("Sessions appear here once they attach to /mcp/{sessionKey}.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 2) {
                    ForEach(vm.rows) { row in
                        AllSessionsRowView(row: row) {
                            dmTarget = row
                        }
                    }
                }
            }

            if let result = vm.dmResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .sheet(item: $dmTarget) { row in
            DMComposerSheet(target: row) { body in
                Task {
                    await vm.sendDM(target: row.sessionKey, body: body)
                }
            }
        }
    }
}

private struct AllSessionsRowView: View {
    let row: AllSessionsRow
    let onDM: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(row.isAlive ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
                .help(row.isAlive ? "SSE attached, recent contact" : "Offline or no SSE")

            Text(row.kind.displayName)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(row.kind.tint.opacity(0.18), in: Capsule())
                .foregroundStyle(row.kind.tint)
                .frame(minWidth: 80, alignment: .leading)

            Text(row.sessionKey)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if row.inFlightEventId != nil {
                Text("· busy")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Text(row.lastContactedRelative)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

            Button {
                onDM()
            } label: {
                Image(systemName: "paperplane")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Send a DM to this session")
            .opacity(isHovered ? 1 : 0.6)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .opacity(row.isAlive ? 1.0 : 0.65)
        .onHover { isHovered = $0 }
    }
}

private struct DMComposerSheet: View {
    let target: AllSessionsRow
    let onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var messageBody: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(target.kind.tint)
                Text("DM \(target.kind.displayName)")
                    .font(.headline)
                Text(target.sessionKey)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
            }

            TextEditor(text: $messageBody)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .padding(6)
                .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Text("\(messageBody.utf8.count) bytes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Send") {
                    onSend(messageBody)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 260)
    }
}
