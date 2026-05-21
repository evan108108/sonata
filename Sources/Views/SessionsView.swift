import AppKit
import SwiftTerm
import SwiftUI

// In-rail equivalent of the previous "Interactive Sessions" separate window.
// Mirrors WorkersView's layout 1:1: a sidebar with one row per session, an
// ember gradient + HouseFire flame background, the selected session's
// terminal filling the right pane. "+" button in the sidebar header opens
// the New Session sheet (name + directory picker). Right-click row → Rename
// / Close.

struct SessionsView: View {
    @ObservedObject private var vm = InteractiveSessionsViewModel.shared
    @State private var showNewSessionSheet = false

    var body: some View {
        NavigationSplitView {
            sessionsSidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detailPane
        }
        .sheet(isPresented: $showNewSessionSheet) {
            NewSessionSheet(vm: vm) { showNewSessionSheet = false }
        }
    }

    // MARK: - Sidebar

    private var sessionsSidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(vm.tabs) { tab in
                        SessionSidebarRow(tab: tab)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(vm.activeTabId == tab.id
                                          ? Theme.Color.selectionTint
                                          : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(vm.activeTabId == tab.id
                                            ? Theme.Color.selectionAccent.opacity(0.55)
                                            : Color.clear,
                                            lineWidth: 0.5)
                            )
                            .onTapGesture {
                                vm.selectTab(id: tab.id)
                            }
                            .contextMenu {
                                Button("Rename…") { tab.beginRenameRequested = true }
                                Button("Restart") { vm.restartTab(id: tab.id) }
                                Divider()
                                Button("Close", role: .destructive) {
                                    vm.closeTab(id: tab.id)
                                }
                            }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }

            HStack(spacing: 8) {
                Spacer()
                Text("\(vm.tabs.count) session\(vm.tabs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // Same flame + warm-gradient treatment as the Workers sidebar.
        // Keep this in sync visually if WorkersView's background ever
        // changes; an extracted helper feels like premature DRY.
        .background(
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: Theme.Color.bgEmberDeep, location: 0.00),
                        .init(color: Theme.Color.bgEmberDeep, location: 0.35),
                        .init(color: Theme.Color.bgEmberMid,  location: 0.70),
                        .init(color: Theme.Color.bgEmberTop,  location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                MetalFlameView()
                    .opacity(0.30)
                    .allowsHitTesting(false)
                LinearGradient(
                    colors: [
                        Theme.Color.bgDeep.opacity(0.55),
                        Theme.Color.bgDeep.opacity(0.20),
                        Color.clear,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .clipped()
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.Color.dividerWarm)
                .frame(width: 0.5)
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Text("Sessions")
                .font(Theme.Typography.displayMedium)
            Spacer()
            Button {
                showNewSessionSheet = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .help("New session…")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if vm.tabs.isEmpty {
            emptyState
        } else {
            ZStack {
                // All session terminals are mounted in one stable container;
                // only the active one is visible (isHidden toggle). This
                // mirrors WorkersView's TerminalContainerView and avoids the
                // NSViewRepresentable-reuse bug where switching the active
                // tab kept showing the previous tab's terminal (SwiftUI
                // reused the host view in place instead of rebuilding it).
                SessionsTerminalContainer(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Cover the terminal with a stopped/failed state view when
                // the active session isn't running. EmptyView for running/
                // starting so the live terminal shows through.
                if let activeId = vm.activeTabId,
                   let tab = vm.tabs.first(where: { $0.id == activeId }) {
                    SessionStateOverlay(tab: tab, vm: vm)
                } else {
                    Color.clear
                        .onAppear { vm.selectTab(id: vm.tabs[0].id) }
                }
            }
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
            Button("New session…") { showNewSessionSheet = true }
                .controlSize(.large)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar row

private struct SessionSidebarRow: View {
    @ObservedObject var tab: InteractiveSessionTab
    @State private var isRenaming = false
    @State private var editText = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("", text: $editText)
                        .textFieldStyle(.plain)
                        .font(.system(.body))
                        .focused($renameFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { cancelRename() }
                        .onChange(of: renameFocused) { _, focused in
                            if !focused && isRenaming { commitRename() }
                        }
                } else {
                    Text(tab.name)
                        .font(.system(.body))
                        .lineLimit(1)
                }
                Text(tab.cwd.lastPathComponent)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .onTapGesture(count: 2) {
            if !isRenaming { beginRename() }
        }
        .onChange(of: tab.beginRenameRequested) { _, newValue in
            if newValue { beginRename(); tab.beginRenameRequested = false }
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
    }

    private var dotColor: SwiftUI.Color {
        switch tab.state {
        case .starting: return .yellow
        case .running: return .green
        case .stopped: return .secondary
        case .spawnFailed: return .red
        }
    }

    private func beginRename() {
        editText = tab.name
        isRenaming = true
        DispatchQueue.main.async {
            renameFocused = true
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
            InteractiveSessionsViewModel.shared.renameTab(id: tab.id, name: trimmed)
        }
        isRenaming = false
    }

    private func cancelRename() {
        isRenaming = false
    }
}

// MARK: - Terminal container (all sessions mounted, active one visible)

/// Mounts every session's terminal NSView in a single stable container and
/// toggles `isHidden` so only the active session's terminal shows. Mirrors
/// WorkersView.TerminalContainerView. The key property: the container NSView
/// is never rebuilt when the active tab changes — we just flip visibility —
/// so SwiftUI can't get into the "host reused, wrong terminal shown" state
/// that a per-tab NSViewRepresentable falls into.
private struct SessionsTerminalContainer: NSViewRepresentable {
    @ObservedObject var vm: InteractiveSessionsViewModel

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Mount any session terminals not yet attached.
        for tab in vm.tabs {
            if tab.terminalView.superview !== container {
                tab.terminalView.frame = container.bounds
                tab.terminalView.autoresizingMask = [.width, .height]
                container.addSubview(tab.terminalView)
            }
        }
        // Drop terminals for sessions that no longer exist.
        for subview in container.subviews {
            if let term = subview as? LocalProcessTerminalView,
               !vm.tabs.contains(where: { $0.terminalView === term }) {
                term.removeFromSuperview()
            }
        }
        // Show only the active session's terminal.
        for tab in vm.tabs {
            tab.terminalView.isHidden = (tab.id != vm.activeTabId)
        }
    }
}

// MARK: - Non-running state overlay

/// Covers the terminal with a "Session ended" / "Couldn't start session"
/// view when the active tab isn't running. Renders nothing (lets the live
/// terminal show through) for .starting / .running.
private struct SessionStateOverlay: View {
    @ObservedObject var tab: InteractiveSessionTab
    let vm: InteractiveSessionsViewModel

    var body: some View {
        switch tab.state {
        case .starting, .running:
            EmptyView()
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
            Button("Restart") {
                vm.restartTab(id: tab.id)
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bgDeep)
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
            Button("Restart") { vm.restartTab(id: tab.id) }
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bgDeep)
    }
}

// MARK: - New Session sheet

private struct NewSessionSheet: View {
    @ObservedObject var vm: InteractiveSessionsViewModel
    let onClose: () -> Void

    @State private var name: String = ""
    @State private var cwdPath: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Session")
                    .font(.headline)
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(defaultName))
                    HStack {
                        TextField("Working directory", text: $cwdPath, prompt: Text(defaultCwd.path))
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Browse…") { browse() }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 520, height: 240)
        .onAppear {
            // Prefill defaults once so the form reflects what would happen
            // if the user just hits Start without touching anything.
            if name.isEmpty { name = defaultName }
            if cwdPath.isEmpty { cwdPath = defaultCwd.path }
        }
    }

    private var defaultName: String {
        // Match InteractiveSessionsViewModel's auto-numbering scheme.
        let nextIndex = (vm.tabs.count + 1)
        return "Session \(nextIndex)"
    }

    private var defaultCwd: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: "\(home)/.sonata/session/session\(vm.tabs.count + 1)")
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if let url = URL(string: "file://\(cwdPath)") {
            panel.directoryURL = url
        }
        if panel.runModal() == .OK, let url = panel.url {
            cwdPath = url.path
        }
    }

    private func start() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = cwdPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let useName = trimmedName.isEmpty ? defaultName : trimmedName
        let useCwd  = trimmedPath.isEmpty
            ? defaultCwd
            : URL(fileURLWithPath: (trimmedPath as NSString).expandingTildeInPath)
        vm.addTab(name: useName, cwd: useCwd)
        onClose()
    }
}
