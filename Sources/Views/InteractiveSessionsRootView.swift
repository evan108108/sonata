import SwiftUI
import SwiftTerm
import AppKit

/// Top-level SwiftUI body for the Interactive Sessions window. Tab strip on top,
/// SwiftTerm-embedded subprocess body below, with an empty state when no tabs exist.
struct InteractiveSessionsRootView: View {
    @ObservedObject var vm: InteractiveSessionsViewModel

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            body(for: vm.activeTabId.flatMap { id in vm.tabs.first(where: { $0.id == id }) })
        }
        .background(KeyEquivalentCatcher(
            onNewTab: { vm.addTab() },
            onCloseTab: { vm.closeActiveTab() },
            onNextTab: { vm.cycleActiveTab(delta: 1) },
            onPrevTab: { vm.cycleActiveTab(delta: -1) }
        ))
        .frame(minWidth: 600, minHeight: 400)
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(vm.tabs) { tab in
                        TabCellView(
                            tab: tab,
                            isActive: tab.id == vm.activeTabId,
                            onSelect: { vm.selectTab(id: tab.id) },
                            onClose: { vm.closeTab(id: tab.id) },
                            onRename: { newName in vm.renameTab(id: tab.id, name: newName) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Button {
                vm.addTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.plain)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .padding(.trailing, 8)
            .help("New session (⌘T)")
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Body for the active tab

    @ViewBuilder
    private func body(for tab: InteractiveSessionTab?) -> some View {
        if vm.tabs.isEmpty {
            emptyState
        } else if let tab {
            ActiveTabBody(tab: tab, vm: vm)
        } else {
            // Tabs exist but none selected — pick the first.
            Color.clear
                .onAppear { vm.selectTab(id: vm.tabs[0].id) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No active sessions")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Each session is a full Claude Code subprocess.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Start new session") {
                vm.addTab()
            }
            .controlSize(.large)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tab cell

private struct TabCellView: View {
    @ObservedObject var tab: InteractiveSessionTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void

    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var editText = ""
    @FocusState private var isEditingFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            statusDot
            ZStack {
                Text(tab.name)
                    .font(.system(.caption, design: .default))
                    .lineLimit(1)
                    .opacity(isRenaming ? 0 : 1)
                if isRenaming {
                    TextField("", text: $editText)
                        .textFieldStyle(.plain)
                        .font(.system(.caption, design: .default))
                        .focused($isEditingFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { cancelRename() }
                        .onChange(of: isEditingFocused) { _, focused in
                            if !focused && isRenaming {
                                commitRename()
                            }
                        }
                }
            }
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(Color.secondary.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered || isActive ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.secondary.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if !isRenaming { beginRename() }
        }
        .onTapGesture {
            if !isRenaming { onSelect() }
        }
        .onHover { isHovered = $0 }
    }

    private func beginRename() {
        editText = tab.name
        isRenaming = true
        DispatchQueue.main.async {
            isEditingFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                if let editor = NSApp.keyWindow?.firstResponder as? NSText {
                    editor.selectAll(nil)
                }
            }
        }
    }

    private func commitRename() {
        guard isRenaming else { return }
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onRename(trimmed)
        }
        isRenaming = false
    }

    private func cancelRename() {
        isRenaming = false
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 6, height: 6)
    }

    private var dotColor: SwiftUI.Color {
        switch tab.state {
        case .starting: return .yellow
        case .running: return .green
        case .stopped: return .secondary
        case .spawnFailed: return .red
        }
    }
}

// MARK: - Active tab body

private struct ActiveTabBody: View {
    @ObservedObject var tab: InteractiveSessionTab
    let vm: InteractiveSessionsViewModel

    var body: some View {
        switch tab.state {
        case .starting, .running:
            if let content = tab.contentView {
                InteractiveSessionContentView(contentInstance: content)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .stopped(let exitCode):
            stoppedView(exitCode: exitCode)
        case .spawnFailed(let message):
            spawnFailedView(message: message)
        }
    }

    private func stoppedView(exitCode: Int32?) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "stop.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Session ended")
                .font(.title3)
                .foregroundStyle(.secondary)
            if let code = exitCode, code != 0 {
                Text("exit code \(code)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Button("Restart") {
                    vm.restartTab(id: tab.id)
                }
                .controlSize(.regular)
                Button("Start new") {
                    vm.addTab()
                }
                .controlSize(.regular)
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func spawnFailedView(message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Couldn't start session")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Restart") {
                vm.restartTab(id: tab.id)
            }
            .controlSize(.regular)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - SwiftTerm host

/// Thin NSViewRepresentable that hosts a single session content view (a
/// SwiftTerm terminal or a WKWebView). Reuses the autoresizing-mask trick so
/// the hosted view fills the SwiftUI parent without being recreated.
private struct InteractiveSessionContentView: NSViewRepresentable {
    let contentInstance: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        contentInstance.frame = container.bounds
        contentInstance.autoresizingMask = [.width, .height]
        container.addSubview(contentInstance)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if contentInstance.superview !== container {
            contentInstance.removeFromSuperview()
            contentInstance.frame = container.bounds
            contentInstance.autoresizingMask = [.width, .height]
            container.addSubview(contentInstance)
        }
    }
}

// MARK: - Keyboard shortcuts

/// Hidden NSView that installs `keyDown` monitoring on the window so cmd-T,
/// cmd-W, cmd-shift-] and cmd-shift-[ can manage tabs even while the SwiftTerm
/// terminal has first responder.
private struct KeyEquivalentCatcher: NSViewRepresentable {
    let onNewTab: () -> Void
    let onCloseTab: () -> Void
    let onNextTab: () -> Void
    let onPrevTab: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onNewTab = onNewTab
        view.onCloseTab = onCloseTab
        view.onNextTab = onNextTab
        view.onPrevTab = onPrevTab
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MonitorView else { return }
        view.onNewTab = onNewTab
        view.onCloseTab = onCloseTab
        view.onNextTab = onNextTab
        view.onPrevTab = onPrevTab
    }

    final class MonitorView: NSView {
        var onNewTab: (() -> Void)?
        var onCloseTab: (() -> Void)?
        var onNextTab: (() -> Void)?
        var onPrevTab: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if monitor == nil, window != nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, event.window === self.window else { return event }
                    if event.modifierFlags.contains(.command) {
                        let chars = event.charactersIgnoringModifiers ?? ""
                        let shift = event.modifierFlags.contains(.shift)
                        switch chars {
                        case "t" where !shift:
                            self.onNewTab?()
                            return nil
                        case "w" where !shift:
                            self.onCloseTab?()
                            return nil
                        case "}" where shift, "]" where shift:
                            self.onNextTab?()
                            return nil
                        case "{" where shift, "[" where shift:
                            self.onPrevTab?()
                            return nil
                        default: break
                        }
                    }
                    return event
                }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
