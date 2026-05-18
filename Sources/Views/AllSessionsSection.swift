import SwiftUI

// Two dashboard sections styled to match LiveWorkersSection (icon + title
// + count + meta + actions header; row list inside; tinted card background).
// Both share AllSessionsViewModel and surface a Broadcast affordance.
//
//   ConnectedSessionsSection — MCP-attached interactive sessions
//     (sona-launched + anon-handshake-identified)
//   UnconnectedSessionsSection — live claude processes (per
//     ~/.claude/sessions/<pid>.json) of kind="interactive" that AREN'T
//     MCP-attached to Sonata. Sonata-spawned workers/supervisor are
//     excluded — they show up in the Workers section above.

// MARK: - Connected

struct ConnectedSessionsSection: View {
    @ObservedObject var vm: AllSessionsViewModel
    @State private var dmTarget: AllSessionsRow?
    @State private var showBroadcast: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(.teal)
                Text("Connected")
                    .font(.headline)
                Text("\(vm.connected.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                let live = vm.connected.filter(\.hasSSE).count
                Text("· \(live) live")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showBroadcast = true
                } label: {
                    Label("Broadcast", systemImage: "megaphone")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Send a DM to all connected sessions")
                Button {
                    Task { await vm.fetch() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            if vm.connected.isEmpty {
                VStack(spacing: 4) {
                    Text(vm.hasLoadedOnce ? "No connected sessions" : "Loading…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if vm.hasLoadedOnce {
                        Text("Run `sona` in a terminal to start one.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 2) {
                    ForEach(vm.connected) { row in
                        ConnectedSessionRow(row: row) { dmTarget = row }
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
            DMComposerSheet(target: .session(row)) { body in
                Task { await vm.sendDM(target: row.sessionKey, body: body) }
            }
        }
        .sheet(isPresented: $showBroadcast) {
            DMComposerSheet(target: .broadcast("interactive")) { body in
                Task { await vm.broadcast(filter: "interactive", body: body) }
            }
        }
    }
}

private struct ConnectedSessionRow: View {
    let row: AllSessionsRow
    let onDM: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(row.hasSSE ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
                .help(row.hasSSE ? "MCP attached" : "MCP detached")

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
                .help(row.sessionKey)

            if let cwd = row.cwd {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text((cwd as NSString).lastPathComponent)
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(cwd)
            }

            Spacer()

            if row.inFlightEventId != nil {
                Text("· busy")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Text(row.lastSeenRelative)
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
        .opacity(row.hasSSE ? 1.0 : 0.65)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Unconnected

struct UnconnectedSessionsSection: View {
    @ObservedObject var vm: AllSessionsViewModel

    /// Filter Unconnected to claude processes of kind="interactive".
    /// kind="worker" / "supervisor" are Sonata-managed and already shown
    /// in the Workers section above — including them here would
    /// double-list them just because they haven't called sonata_identify.
    private var rows: [AllSessionsRow] {
        vm.unconnected.filter { $0.kind == .interactive }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "powersleep")
                    .foregroundStyle(.gray)
                Text("Unconnected")
                    .font(.headline)
                Text("\(rows.count)")
                    .font(.subheadline.weight(.semibold))
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
                .help("Refresh")
            }

            if rows.isEmpty {
                VStack(spacing: 4) {
                    Text(vm.hasLoadedOnce
                         ? "Every live claude is connected to Sonata"
                         : "Loading…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if vm.hasLoadedOnce {
                        Text("Claude sessions launched without `sona` (or without SONA_SESSION_ID set) appear here.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 2) {
                    ForEach(rows) { row in
                        UnconnectedSessionRow(row: row)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct UnconnectedSessionRow: View {
    let row: AllSessionsRow

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.gray)
                .frame(width: 8, height: 8)
                .help("Live claude process; not MCP-attached to Sonata")

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
                .help(row.sessionKey)

            if let cwd = row.cwd {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text((cwd as NSString).lastPathComponent)
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(cwd)
            }

            Spacer()

            if let pid = row.pid {
                Text("pid \(pid)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text(row.lastSeenRelative)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .opacity(0.75)
    }
}

// MARK: - DM composer (shared between Connected section's per-row DM
// and broadcast button)

private struct DMComposerSheet: View {
    enum Target {
        case session(AllSessionsRow)
        case broadcast(String)
    }
    let target: Target
    let onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var messageBody: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(.teal)
                switch target {
                case .session(let row):
                    Text("DM \(row.kind.displayName)")
                        .font(.headline)
                    Text(row.sessionKey)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                case .broadcast(let f):
                    Text("Broadcast → \(f)")
                        .font(.headline)
                }
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
