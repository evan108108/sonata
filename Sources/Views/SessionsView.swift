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
                .sonataSidebar(flame: true)
        } detail: {
            detailPane
        }
        .sheet(isPresented: $showNewSessionSheet) {
            NewSessionSheet(vm: vm) { showNewSessionSheet = false }
        }
        // Entering the Sessions section drops focus into the active session so
        // the user can start typing immediately (terminal-backed kinds).
        .onAppear { vm.focusActiveContent() }
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
        // Background, flame, and trailing stroke now come from
        // `.sonataSidebar(flame: true)` applied in the NavigationSplitView
        // sidebar closure — single source of truth shared with every sidebar.
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
            Text("A session can be Claude Code (Sona), a plain terminal, or a web view.")
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
        // Baseline-align the kind icon with the title row rather than centering
        // it across the title + subtitle stack.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            kindIcon
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
                Text(tab.subtitle)
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

    /// Kind icon (flame / terminal / globe) tinted + glowing in the session's
    /// state color, so the row conveys both *what* the session is and *how*
    /// it's doing without a separate status dot.
    private var kindIcon: some View {
        Image(systemName: tab.kind.iconName)
            .font(.system(size: 12))
            .foregroundStyle(stateColor)
            .shadow(color: stateColor.opacity(0.75), radius: 4)
            .frame(width: 16, alignment: .center)
    }

    private var stateColor: SwiftUI.Color {
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

    final class Coordinator {
        weak var catcher: SessionDropCatcher?
        var lastFocusedId: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true

        // App-level drop target layered on top of the session content. The
        // embedded SwiftTerm view declines file drops while Claude Code's TUI
        // is running (the raw path would hit Claude's input instead), so we
        // catch the drop here and forward the resolved path into the active
        // session's terminal. hitTest → nil keeps mouse/clicks passing through
        // to the terminal below.
        let catcher = SessionDropCatcher(frame: container.bounds)
        catcher.autoresizingMask = [.width, .height]
        catcher.onPaths = { [vm] paths in vm.handleDroppedPaths(paths) }
        container.addSubview(catcher)
        context.coordinator.catcher = catcher

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let catcher = context.coordinator.catcher

        // Mount any session content views (terminal or webview) not yet
        // attached — below the drop catcher so it stays frontmost.
        for tab in vm.tabs {
            let content = tab.contentView
            if content.superview !== container {
                content.frame = container.bounds
                content.autoresizingMask = [.width, .height]
                container.addSubview(content, positioned: .below, relativeTo: catcher)
            }
        }
        // Drop content views for sessions that no longer exist (identity-based
        // so it works for both terminals and webviews). Never remove the catcher.
        for subview in container.subviews {
            if subview === catcher { continue }
            if !vm.tabs.contains(where: { $0.contentView === subview }) {
                subview.removeFromSuperview()
            }
        }
        // Show only the active session's content.
        for tab in vm.tabs {
            tab.contentView.isHidden = (tab.id != vm.activeTabId)
        }
        // Keep the catcher frontmost (re-adding moves it to the top of the
        // z-order in case a freshly-mounted content view jumped ahead).
        if let catcher, catcher.superview === container {
            container.addSubview(catcher)
        }

        // Focus the active session's content once it's unhidden + in the window
        // so typing lands immediately on tab switch / section entry — only when
        // the active tab actually changes, so we never steal focus mid-use.
        // (The VM's focusContent races the SwiftUI visibility update; doing it
        // here, after isHidden is set, is reliable.)
        if vm.activeTabId != context.coordinator.lastFocusedId {
            context.coordinator.lastFocusedId = vm.activeTabId
            if let id = vm.activeTabId,
               let tab = vm.tabs.first(where: { $0.id == id }),
               tab.kind.isTerminalBacked {
                let content = tab.contentView
                DispatchQueue.main.async { content.window?.makeFirstResponder(content) }
            }
        }
    }
}

/// Transparent, top-most drop target for the sessions detail pane. Registered
/// for file / URL / image drags but returns nil from `hitTest` so mouse events
/// fall through to the terminal/webview below. AppKit resolves drag
/// destinations by view geometry + registered types (not `hitTest`), so this
/// still receives drops — letting the app accept file drops even when the
/// embedded SwiftTerm view declines them under Claude Code's full-screen TUI.
final class SessionDropCatcher: NSView {
    var onPaths: (([String]) -> Void)?

    private static let acceptedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .png, .tiff]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = DropEnabledTerminalView.resolvePaths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        onPaths?(paths)
        return true
    }

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        DropEnabledTerminalView.resolvePaths(from: sender.draggingPasteboard).isEmpty ? [] : .copy
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
    @State private var urlString: String = ""
    @State private var kind: SessionKind = .sona

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
                    Picker("Type", selection: $kind) {
                        ForEach(SessionKind.allCases) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("Name", text: $name, prompt: Text(defaultName(for: kind)))
                    if kind == .webview {
                        TextField("URL", text: $urlString, prompt: Text("https://example.com"))
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textContentType(.URL)
                    } else {
                        HStack {
                            TextField("Working directory", text: $cwdPath, prompt: Text(defaultCwd(for: kind).path))
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Browse…") { browse() }
                        }
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
        .frame(width: 520, height: 290)
        .onAppear {
            // Prefill defaults once so the form reflects what would happen
            // if the user just hits Start without touching anything.
            if name.isEmpty { name = defaultName(for: kind) }
            if cwdPath.isEmpty { cwdPath = defaultCwd(for: kind).path }
        }
        .onChange(of: kind) { old, new in
            // Refresh the prefilled defaults to match the newly-picked type,
            // but only while the user hasn't customized them.
            if name == defaultName(for: old) { name = defaultName(for: new) }
            if cwdPath == defaultCwd(for: old).path { cwdPath = defaultCwd(for: new).path }
        }
    }

    private func defaultName(for kind: SessionKind) -> String {
        let nextIndex = (vm.tabs.count + 1)
        switch kind {
        case .sona: return "Session \(nextIndex)"
        case .terminal: return "Terminal \(nextIndex)"
        case .webview: return "Web \(nextIndex)"
        }
    }

    private func defaultCwd(for kind: SessionKind) -> URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        switch kind {
        case .sona:
            return URL(fileURLWithPath: "\(home)/.sonata/session/session\(vm.tabs.count + 1)")
        case .terminal, .webview:
            // A plain shell / web session has no meaningful scratch dir, so
            // anchor at home rather than a throwaway per-session directory.
            return URL(fileURLWithPath: home)
        }
    }

    /// Parse the user's URL text, prepending `https://` when no scheme is
    /// given (so "example.com" works). Returns nil for empty/invalid input.
    private func normalizedURL() -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return url
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
        let useName = trimmedName.isEmpty ? defaultName(for: kind) : trimmedName

        if kind == .webview {
            // Require a valid URL; if it's missing/garbage, keep the sheet open.
            guard let url = normalizedURL() else { return }
            vm.addTab(name: useName, cwd: defaultCwd(for: kind), kind: kind, url: url)
            onClose()
            return
        }

        let trimmedPath = cwdPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let useCwd  = trimmedPath.isEmpty
            ? defaultCwd(for: kind)
            : URL(fileURLWithPath: (trimmedPath as NSString).expandingTildeInPath)
        vm.addTab(name: useName, cwd: useCwd, kind: kind)
        onClose()
    }
}
