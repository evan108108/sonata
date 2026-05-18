import SwiftUI

/// Dashboard section that lists EVERY claude session Sonata knows about,
/// grouped into three sub-sections:
///   - Workers — pool workers + supervisor (Sonata-spawned)
///   - Connected — MCP-attached interactive sessions (sona-launched
///     or anon-handshake-identified)
///   - Unconnected — live claude processes (per ~/.claude/sessions/)
///     that aren't MCP-attached to Sonata
///
/// Each row carries a DM button. Three Broadcast buttons in the header
/// (Workers / Humans / All) hit /api/dm/broadcast (sonar_dm_broadcast)
/// — the "DMAll" affordance.
struct AllSessionsSection: View {
    @ObservedObject var vm: AllSessionsViewModel
    @State private var dmTarget: AllSessionsRow?
    @State private var broadcastFilter: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
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
        .sheet(isPresented: Binding(
            get: { broadcastFilter != nil },
            set: { if !$0 { broadcastFilter = nil } }
        )) {
            if let f = broadcastFilter {
                DMComposerSheet(target: .broadcast(f)) { body in
                    Task { await vm.broadcast(filter: f, body: body) }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(.teal)
            Text("Sessions")
                .font(.headline)
            Text("\(vm.rows.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu("Broadcast") {
                Button("All sessions") { broadcastFilter = "all" }
                Button("Workers") { broadcastFilter = "workers" }
                Button("Interactive (humans)") { broadcastFilter = "interactive" }
                Button("Supervisor") { broadcastFilter = "supervisor" }
            }
            .menuStyle(.borderlessButton)
            .font(.caption)
            .help("Send a DM to many sessions at once")
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
    }

    @ViewBuilder
    private var content: some View {
        if vm.rows.isEmpty {
            VStack(spacing: 4) {
                Text(vm.hasLoadedOnce ? "No sessions" : "Loading…")
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
            subSection("Workers", rows: vm.workers, emptyHint: "Worker pool is empty.")
            subSection("Connected", rows: vm.connected, emptyHint: "No interactive sessions attached.")
            subSection("Unconnected", rows: vm.unconnected,
                emptyHint: "All live claudes are connected to Sonata.")
        }
    }

    @ViewBuilder
    private func subSection(_ title: String, rows: [AllSessionsRow], emptyHint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Text("\(rows.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            if rows.isEmpty {
                Text(emptyHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            } else {
                VStack(spacing: 2) {
                    ForEach(rows) { row in
                        AllSessionsRowView(row: row) { dmTarget = row }
                    }
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
                .fill(row.hasSSE ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
                .help(row.hasSSE ? "MCP attached" : (row.section == .unconnected ? "Live process, no MCP" : "MCP detached"))

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
            .help(row.section == .unconnected
                  ? "DM (will queue — recipient not currently MCP-attached)"
                  : "Send a DM to this session")
            .opacity(isHovered ? 1 : 0.6)
            .disabled(row.section == .unconnected)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .opacity(row.hasSSE ? 1.0 : 0.65)
        .onHover { isHovered = $0 }
    }
}

private struct DMComposerSheet: View {
    enum Target {
        case session(AllSessionsRow)
        case broadcast(String)  // filter
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
