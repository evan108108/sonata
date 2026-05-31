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
        // Only sessions with a live SSE writer count as "connected" — abandoned
        // POST-only / anon-XXX registry entries that lingered are hidden here
        // (the sweeper's staleness prune evicts them at the source).
        let live = vm.connected.filter(\.hasSSE)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(.teal)
                Text("Connected")
                    .font(.headline)
                Text("\(live.count)")
                    .font(.subheadline.weight(.semibold))
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

            if live.isEmpty {
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
                    sessionColumnHeader
                    ForEach(live) { row in
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

            Text(row.displayName ?? "—")
                .font(.caption)
                .foregroundStyle(row.displayName == nil ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 110, alignment: .leading)

            Text(row.sessionKey)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 180, alignment: .leading)

            Text(row.cwd ?? "—")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(row.cwd == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 200, alignment: .leading)

            Text(row.lastPrompt ?? row.firstPrompt ?? "—")
                .font(.caption)
                .foregroundStyle(row.lastPrompt == nil && row.firstPrompt == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.pid.map { String($0) } ?? "—")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .trailing)

            Text(row.lastSeenRelative)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .trailing)

            Button {
                onDM()
            } label: {
                Image(systemName: "paperplane")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Send a DM to this session")
            .opacity(isHovered ? 1 : 0.6)
            .frame(width: 22)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .help(sessionRowTooltip(row))
        .opacity(row.hasSSE ? 1.0 : 0.65)
        .onHover { isHovered = $0 }
        .overlay(alignment: .topTrailing) {
            if row.inFlightEventId != nil {
                Text("busy")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.orange.opacity(0.12), in: Capsule())
                    .offset(x: -30, y: 6)
            }
        }
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
                    sessionColumnHeader
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

/// Shared column-header row used by both Connected and Unconnected
/// section tables. Mirrors the cell layout of ConnectedSessionRow and
/// UnconnectedSessionRow so the headers line up.
fileprivate var sessionColumnHeader: some View {
    HStack(spacing: 10) {
        // status dot column (8pt circle width)
        Color.clear.frame(width: 8, height: 8)
        Text("KIND")
            .frame(minWidth: 80, alignment: .leading)
        Text("NAME")
            .frame(width: 110, alignment: .leading)
        Text("SESSION ID")
            .frame(width: 180, alignment: .leading)
        Text("CWD")
            .frame(width: 200, alignment: .leading)
        Text("LAST PROMPT")
            .frame(maxWidth: .infinity, alignment: .leading)
        Text("PID")
            .frame(width: 70, alignment: .trailing)
        Text("LAST SEEN")
            .frame(width: 80, alignment: .trailing)
        // action column (paperplane button width)
        Color.clear.frame(width: 22)
    }
    .font(.system(size: 9, weight: .semibold))
    .foregroundStyle(.tertiary)
    .padding(.top, 4)
    .padding(.bottom, 2)
}

/// Compose the row's hover tooltip — full sessionKey, cwd, first
/// prompt, last prompt, all unabridged.
fileprivate func sessionRowTooltip(_ row: AllSessionsRow) -> String {
    var parts: [String] = []
    parts.append("Session: \(row.sessionKey)")
    if let cwd = row.cwd { parts.append("CWD: \(cwd)") }
    if let pid = row.pid { parts.append("PID: \(pid)") }
    if let first = row.firstPrompt { parts.append("First prompt: \(first)") }
    if let last = row.lastPrompt { parts.append("Last prompt: \(last)") }
    return parts.joined(separator: "\n\n")
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

            Text(row.displayName ?? "—")
                .font(.caption)
                .foregroundStyle(row.displayName == nil ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 110, alignment: .leading)

            Text(row.sessionKey)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 180, alignment: .leading)

            Text(row.cwd ?? "—")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(row.cwd == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 200, alignment: .leading)

            Text(row.lastPrompt ?? row.firstPrompt ?? "—")
                .font(.caption)
                .foregroundStyle(row.lastPrompt == nil && row.firstPrompt == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.pid.map { String($0) } ?? "—")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .trailing)

            Text(row.lastSeenRelative)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .trailing)

            Color.clear.frame(width: 22)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .help(sessionRowTooltip(row))
        .opacity(0.75)
    }
}

// MARK: - Agent Webviews

/// Collapsible "Agent Webviews" tree: webview sessions grouped by owning agent.
/// A view over the registry (InteractiveSessionsViewModel.shared.tabs) — headless
/// sessions appear here without ever forcing a panel open. Per Evan's UI rule:
/// NO focus rings — selection/state use background + color only.
struct AgentWebviewsSection: View {
    @ObservedObject var vm: AllSessionsViewModel
    @ObservedObject private var sessions = InteractiveSessionsViewModel.shared
    @State private var expandedOwners: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "globe").foregroundStyle(.blue)
                Text("Agent Webviews").font(.headline)
                let live = sessions.tabs.filter { $0.kind == .webview && $0.lifecycle == .live }.count
                let total = sessions.tabs.filter { $0.kind == .webview }.count
                Text("\(total)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text("· \(live) live").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(vm.webviewGroups) { group in
                DisclosureGroup(isExpanded: bindingFor(group.id)) {
                    ForEach(group.tabs, id: \.id) { tab in
                        WebviewSessionRow(tab: tab, sessions: sessions)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                        Text(group.ownerLabel).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Text("\(group.tabs.count)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding()
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func bindingFor(_ owner: String) -> Binding<Bool> {
        Binding(
            get: { expandedOwners.contains(owner) },
            set: { if $0 { expandedOwners.insert(owner) } else { expandedOwners.remove(owner) } })
    }
}

/// One webview session row: status dot + name + url/title + last-activity, with
/// focus (spy/peek), suspend, and close affordances. Matches the in-rail row
/// idiom (SessionsView SessionSidebarRow) and the no-focus-ring rule.
private struct WebviewSessionRow: View {
    @ObservedObject var tab: InteractiveSessionTab
    let sessions: InteractiveSessionsViewModel
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tab.lifecycle == .live ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
                .help(tab.lifecycle == .live ? "live" : "suspended")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(tab.name).font(.caption).lineLimit(1)
                    if tab.background {
                        Text("bg").font(.caption2)
                            .padding(.horizontal, 4).padding(.vertical, 0.5)
                            .background(.purple.opacity(0.15), in: Capsule()).foregroundStyle(.purple)
                    }
                }
                Text(tab.webView?.url?.absoluteString ?? tab.url?.absoluteString ?? "—")
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Text(Self.relative(tab.lastActivityAt)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            // Affordances appear on hover (match ConnectedSessionRow's DM button).
            Button { sessions.selectTab(id: tab.id); if tab.lifecycle == .suspended { sessions.resumeTab(id: tab.id) } } label: {
                Image(systemName: "eye").foregroundStyle(.secondary)
            }.buttonStyle(.borderless).help("Focus (spy/peek)").opacity(hovered ? 1 : 0.5)
            if tab.lifecycle == .live {
                Button { sessions.suspendTab(id: tab.id) } label: { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).help("Suspend (free memory)").opacity(hovered ? 1 : 0.5)
            }
            Button { sessions.closeTab(id: tab.id) } label: { Image(systemName: "xmark.circle").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).help("Close").opacity(hovered ? 1 : 0.5)
        }
        .frame(height: 30)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Focus") { sessions.selectTab(id: tab.id); if tab.lifecycle == .suspended { sessions.resumeTab(id: tab.id) } }
            if tab.lifecycle == .live { Button("Suspend") { sessions.suspendTab(id: tab.id) } }
            else { Button("Resume") { sessions.resumeTab(id: tab.id) } }
            Divider()
            Button("Close", role: .destructive) { sessions.closeTab(id: tab.id) }
        }
    }

    static func relative(_ ms: Int64) -> String {
        let secs = max(0, Int(Date().timeIntervalSince1970) - Int(ms / 1000))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs/60)m" }
        return "\(secs/3600)h"
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
