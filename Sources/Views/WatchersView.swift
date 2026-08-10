import SwiftUI
import AppKit

/// Sidebar + detail view for the filesystem-watchers primitive. Peer of
/// TasksView / WorkersView / etc.; slotted into NavRail between Workers and
/// Tasks so it sits between the reactor (workers) and the job (tasks) as an
/// event source.
struct WatchersView: View {
    @StateObject private var vm = WatchersViewModel()
    @State private var showingAddSheet = false
    @State private var editingDraft: WatcherDraft? = nil

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            detail
        }
        .task {
            await vm.fetch()
        }
        .onDisappear {
            vm.stopEventPolling()
        }
        .sheet(isPresented: $showingAddSheet) {
            WatcherEditSheet(vm: vm, initial: .empty) {
                showingAddSheet = false
            }
        }
        .sheet(item: $editingDraft) { draft in
            WatcherEditSheet(vm: vm, initial: draft) {
                editingDraft = nil
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Watchers")
                    .font(.title2.bold())
                Spacer()
                Button {
                    showingAddSheet = true
                } label: {
                    Label("New", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                RefreshButton(isStale: false) {
                    Task { await vm.fetch() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if vm.watchers.isEmpty {
                emptyList
            } else {
                List(selection: $vm.selection) {
                    ForEach(vm.watchers) { w in
                        WatcherRowView(watcher: w)
                            .tag(w.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .onChange(of: vm.selection) { _, new in
            if let id = new {
                Task {
                    await vm.fetchEvents(watcherId: id)
                    vm.startEventPolling(watcherId: id)
                }
            } else {
                vm.stopEventPolling()
            }
        }
    }

    private var emptyList: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "eye.trianglebadge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No watchers yet")
                .font(.headline)
            Text("A watcher runs a task when a file event happens.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                showingAddSheet = true
            } label: {
                Label("Add your first watcher", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = vm.selection, let watcher = vm.watchers.first(where: { $0.id == id }) {
            WatcherDetailView(
                vm: vm,
                watcher: watcher,
                onEdit: {
                    editingDraft = WatcherDraft(
                        id: watcher.id,
                        name: watcher.name,
                        path: watcher.path,
                        pattern: watcher.pattern,
                        recursive: watcher.recursive,
                        trigger: watcher.trigger,
                        prompt: watcher.prompt,
                        enabled: watcher.enabled,
                        cooldownMs: watcher.cooldownMs,
                        retryCount: watcher.retryCount
                    )
                }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "eye.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(.tertiary)
                Text("Select a watcher")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Row (sidebar cell)

private struct WatcherRowView: View {
    let watcher: Watcher

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(watcher.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(watcher.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(watcher.trigger)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let last = watcher.lastFiredAt {
                        Text("· fired \(relativeTime(fromEpochMs: last))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var statusDot: some View {
        let color: Color = {
            if !watcher.enabled { return .gray }
            if watcher.lastError != nil { return .orange }
            return .green
        }()
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}

// MARK: - Detail panel

private struct WatcherDetailView: View {
    @ObservedObject var vm: WatchersViewModel
    let watcher: Watcher
    let onEdit: () -> Void

    @State private var testPath: String = ""
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                configCard
                testCard
                eventsCard
            }
            .padding(20)
            .frame(maxWidth: 780, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: watcher.id) { _, _ in
            testPath = ""
        }
        .alert("Delete watcher?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await vm.delete(id: watcher.id) }
            }
        } message: {
            Text("The watcher config will be removed. Its event history is kept.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(watcher.name)
                    .font(.title2.bold())
                Text(watcher.id)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer()
            HStack(spacing: 10) {
                Toggle("Enabled", isOn: Binding(
                    get: { watcher.enabled },
                    set: { new in
                        Task { await vm.setEnabled(id: watcher.id, enabled: new) }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                Button("Edit") { onEdit() }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Config")
                .font(.headline)
                .foregroundStyle(.secondary)
            configRow(label: "Path", value: watcher.path, mono: true, selectable: true)
            configRow(label: "Pattern", value: watcher.pattern, mono: true, selectable: true)
            configRow(label: "Trigger", value: watcher.trigger)
            configRow(label: "Recursive", value: watcher.recursive ? "yes" : "no")
            configRow(label: "Cooldown", value: "\(watcher.cooldownMs) ms")
            configRow(label: "Retries", value: "\(watcher.retryCount)")
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(watcher.prompt)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if let err = watcher.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last error (\(watcher.consecutiveFailures) consecutive)")
                            .font(.caption.bold())
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private func configRow(label: String, value: String, mono: Bool = false, selectable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Group {
                if selectable {
                    Text(value)
                        .textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .font(mono ? .system(.body, design: .monospaced) : .body)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var testCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Test now")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Fire the dispatch path against an existing file. No FSEvents needed; nothing on the watched dir moves.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Absolute path to test against", text: $testPath)
                    .textFieldStyle(.roundedBorder)
                Button("Pick…") {
                    if let picked = pickFile(startingAt: watcher.path) {
                        testPath = picked
                    }
                }
                Button("Fire") {
                    Task { await vm.testFire(id: watcher.id, path: testPath) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(testPath.isEmpty)
            }
            if let result = vm.lastTestResult {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(result.ok ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        if let taskId = result.taskId {
                            Text("Dispatched task \(taskId)")
                                .font(.callout)
                                .textSelection(.enabled)
                        } else {
                            Text("Failed to dispatch")
                                .font(.callout)
                        }
                        if let err = result.error {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((result.ok ? Color.green : Color.red).opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private var eventsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent triggers")
                .font(.headline)
                .foregroundStyle(.secondary)
            if vm.events.isEmpty {
                Text("No triggers yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(vm.events) { ev in
                        HStack(alignment: .top, spacing: 10) {
                            statusIcon(for: ev.status)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text((ev.path as NSString).lastPathComponent)
                                        .font(.system(.body, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text(absoluteTime(fromEpochMs: ev.firedAt))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                HStack(spacing: 6) {
                                    Text(ev.eventType)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let tid = ev.taskId {
                                        Text("· task \(tid.prefix(8))")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                            .textSelection(.enabled)
                                    }
                                }
                                if let err = ev.error {
                                    Text(err)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    @ViewBuilder
    private func statusIcon(for status: String) -> some View {
        switch status {
        case "dispatched":
            Image(systemName: "arrow.up.right.circle.fill").foregroundStyle(.green)
        case "errored":
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        default:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.secondary.opacity(0.06))
    }
}

// MARK: - Edit sheet (add + edit)

private struct WatcherEditSheet: View {
    @ObservedObject var vm: WatchersViewModel
    let initial: WatcherDraft
    let onClose: () -> Void

    @State private var draft: WatcherDraft
    @State private var showTemplates: Bool
    @State private var showAdvanced = false
    @State private var isSaving = false

    private let triggers = ["file_added", "file_modified", "file_deleted", "size_threshold"]

    init(vm: WatchersViewModel, initial: WatcherDraft, onClose: @escaping () -> Void) {
        self.vm = vm
        self.initial = initial
        self.onClose = onClose
        _draft = State(initialValue: initial)
        // Only show templates when creating (id empty) and no work-in-progress.
        _showTemplates = State(initialValue: initial.id.isEmpty && initial.name.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(initial.id.isEmpty ? "New watcher" : "Edit watcher")
                    .font(.title3.bold())
                Spacer()
                Button("Cancel") { onClose() }
                Button {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        let ok = await vm.upsert(draft)
                        if ok { onClose() }
                    }
                } label: {
                    if isSaving { ProgressView().controlSize(.small) }
                    else { Text("Save") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showTemplates {
                        templatesSection
                        Divider()
                    }
                    form
                    previewCard
                    advancedSection
                }
                .padding(16)
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 560, idealHeight: 640)
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
        && !draft.path.trimmingCharacters(in: .whitespaces).isEmpty
        && !draft.prompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            templatesHeader
            templatesGrid
        }
    }

    private var templatesHeader: some View {
        HStack {
            Text("Start from a template")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Skip") {
                showTemplates = false
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var templatesGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(WatchersViewModel.templates) { tpl in
                TemplateTile(template: tpl) {
                    draft = tpl.draft
                    showTemplates = false
                }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldRow(label: "Name", required: true) {
                TextField("Auto-log meetings", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }
            fieldRow(label: "Watched path", required: true) {
                HStack {
                    TextField("~/Documents/meetings", text: $draft.path)
                        .textFieldStyle(.roundedBorder)
                    Button("Pick…") {
                        if let picked = pickFileOrFolder() {
                            draft.path = picked
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                fieldRow(label: "Pattern") {
                    TextField("*.md", text: $draft.pattern)
                        .textFieldStyle(.roundedBorder)
                }
                fieldRow(label: "Trigger") {
                    Picker("", selection: $draft.trigger) {
                        ForEach(triggers, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Toggle("Recursive", isOn: $draft.recursive)
                    .toggleStyle(.checkbox)
                    .padding(.top, 20)
            }
            fieldRow(label: "Prompt", required: true) {
                TextEditor(text: $draft.prompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }
            Text("Slash-command (e.g. /meeting) OR free-form. Tokens: {{path}}, {{name}}, {{ext}}, {{dir}}, {{event}}, {{watcher}}. With no tokens, a preamble with the file path is prepended.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Enabled after save", isOn: $draft.enabled)
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(previewLine)
                .font(.callout)
                .foregroundStyle(.primary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var previewLine: String {
        let pattern = draft.pattern.isEmpty ? "*" : draft.pattern
        let action: String = {
            let p = draft.prompt.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { return "(no prompt yet)" }
            if p.hasPrefix("/") { return "run \(p)" }
            return "dispatch a task with the prompt (truncated): \(p.prefix(80))…"
        }()
        return "When a file matching \(pattern) is \(triggerVerb) at \(draft.path.isEmpty ? "(no path)" : draft.path), Sonata will \(action)."
    }

    private var triggerVerb: String {
        switch draft.trigger {
        case "file_added": return "added"
        case "file_modified": return "modified"
        case "file_deleted": return "deleted"
        case "size_threshold": return "grown past its size threshold"
        default: return draft.trigger
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Cooldown")
                        .frame(width: 100, alignment: .trailing)
                    Stepper(value: $draft.cooldownMs, in: 0...300000, step: 500) {
                        Text("\(draft.cooldownMs) ms")
                    }
                }
                HStack {
                    Text("Retries")
                        .frame(width: 100, alignment: .trailing)
                    Stepper(value: $draft.retryCount, in: 0...10) {
                        Text("\(draft.retryCount)")
                    }
                }
                Text("Cooldown debounces rapid-fire events on the same file. Retries applies to dispatch failures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        } label: {
            Text("Advanced")
                .font(.subheadline.bold())
        }
    }

    @ViewBuilder
    private func fieldRow<Content: View>(label: String, required: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if required {
                    Text("*").foregroundStyle(.red).font(.caption)
                }
            }
            content()
        }
    }
}

// MARK: - Template tile

private struct TemplateTile: View {
    let template: WatchersViewModel.Template
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: template.icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name)
                        .font(.callout.bold())
                        .foregroundStyle(.primary)
                    Text(template.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Helpers

private func pickFileOrFolder() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    guard panel.runModal() == .OK else { return nil }
    return panel.url?.path
}

private func pickFile(startingAt path: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
        panel.directoryURL = isDir.boolValue ? url : url.deletingLastPathComponent()
    }
    guard panel.runModal() == .OK else { return nil }
    return panel.url?.path
}

private func relativeTime(fromEpochMs ms: Int64) -> String {
    let now = Date()
    let then = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
    let delta = now.timeIntervalSince(then)
    if delta < 60 { return "just now" }
    if delta < 3600 { return "\(Int(delta / 60))m ago" }
    if delta < 86400 { return "\(Int(delta / 3600))h ago" }
    return "\(Int(delta / 86400))d ago"
}

private func absoluteTime(fromEpochMs ms: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
    let f = DateFormatter()
    f.dateFormat = "MMM d, HH:mm:ss"
    return f.string(from: date)
}

// Make WatcherDraft usable with .sheet(item:)
extension WatcherDraft: Identifiable {}
