import SwiftUI
import SwiftTerm
import AppKit

/// SwiftUI host for the embedded Claude Code Session subprocess. Pipes terminal
/// output to a SwiftTerm view; user types directly into the terminal.
struct SessionChatPanel: View {
    @ObservedObject var vm: SessionChatViewModel
    @State private var firstMessageDraft: String = ""
    @FocusState private var inputFocused: Bool
    @State private var showRestartConfirm: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Session")
                .font(.subheadline.bold())

            Text("opus")
                .font(.caption2.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.18), in: Capsule())
                .foregroundStyle(.purple)

            stateBadge

            Spacer()

            if vm.state == .running {
                Button {
                    showRestartConfirm = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help("Restart session (SIGTERM and respawn)")

                Button {
                    vm.stop()
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help("Stop session (SIGTERM)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .alert("Restart session?", isPresented: $showRestartConfirm) {
            Button("Restart", role: .destructive) { vm.restart() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current Claude conversation will be terminated and replaced with a fresh session.")
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch vm.state {
        case .uninitialized:
            Text("· not started")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .running:
            EmptyView()
        case .stopped:
            Text("· stopped")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .restarting:
            Text("· restarting")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .uninitialized:
            uninitializedView
        case .running, .restarting:
            runningView
        case .stopped:
            stoppedView
        }
    }

    private var uninitializedView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Start a Claude Code session")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Opus, all MCP tools, runs in ~/.sonata/session/.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            HStack(spacing: 8) {
                TextField("First message…", text: $firstMessageDraft, axis: .horizontal)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit { startWithMessage() }
                Button {
                    startWithMessage()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderless)
                .disabled(firstMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var runningView: some View {
        VStack(spacing: 0) {
            if let err = vm.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
            }
            SessionTerminalView(terminalInstance: vm.terminalView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var stoppedView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "stop.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Session stopped")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let err = vm.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            Button("Start new session") {
                vm.spawn()
            }
            .controlSize(.regular)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startWithMessage() {
        let text = firstMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        firstMessageDraft = ""
        vm.sendFirstMessage(text)
    }
}

/// Dedicated NSViewRepresentable for the Session terminal — separate from the
/// Workers `TerminalContainerView` because Session has exactly one terminal and
/// no selection logic.
private struct SessionTerminalView: NSViewRepresentable {
    let terminalInstance: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        terminalInstance.frame = container.bounds
        terminalInstance.autoresizingMask = [.width, .height]
        container.addSubview(terminalInstance)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if terminalInstance.superview !== container {
            terminalInstance.removeFromSuperview()
            terminalInstance.frame = container.bounds
            terminalInstance.autoresizingMask = [.width, .height]
            container.addSubview(terminalInstance)
        }
    }
}
