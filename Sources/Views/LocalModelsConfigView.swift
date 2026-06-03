import SwiftUI

/// Settings panel for managing user-installed local chat models (Phase F.3).
/// Lists the hardcoded built-in model (Llama 3.1 8B) read-only at the top,
/// then any user-installed entries below with a Delete button each, and an
/// "Add Model" button that opens a sheet for pasting a HuggingFace GGUF URL.
struct LocalModelsConfigView: View {
    @State private var installed: [InstalledChatModel] = []
    @State private var showingAddSheet = false
    @State private var inflight: InstallProgress? = nil
    @State private var lastError: String? = nil
    @State private var deletingId: String? = nil
    @State private var confirmingDeleteId: String? = nil
    @State private var editingRow: InstalledChatModel? = nil

    /// Transient state shown while a download is in flight. The actor doesn't
    /// surface byte-level progress yet (BinaryProvisioner downloads the whole
    /// file then verifies), so this is mostly a "yes, we're working on it"
    /// indicator rather than a percent bar.
    struct InstallProgress: Equatable {
        let modelName: String
        let stage: String  // "downloading" | "verifying" | etc.
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            description

            VStack(spacing: 0) {
                ForEach(LocalChatModelRegistry.hardcoded, id: \.modelName) { spec in
                    builtInRow(spec)
                    Divider().opacity(0.3)
                }
                ForEach(installed, id: \.id) { row in
                    installedRow(row)
                    Divider().opacity(0.3)
                }
                if installed.isEmpty && inflight == nil {
                    emptyHint
                }
                if let progress = inflight {
                    inflightRow(progress)
                }
            }
            .background(Color.black.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Model", systemImage: "plus")
                }
                .disabled(inflight != nil)
                Spacer()
                Text("Port range: \(LocalChatModelRegistry.basePort)+")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .sheet(isPresented: $showingAddSheet) {
            AddLocalModelSheet { modelName, displayName, urlString, sha, extra in
                Task { await runInstall(modelName: modelName, displayName: displayName, urlString: urlString, sha: sha, extra: extra) }
            }
        }
        .sheet(item: $editingRow) { row in
            EditLocalModelSheet(row: row) { displayName, extra in
                Task { await runEdit(id: row.id, displayName: displayName, extra: extra) }
            }
        }
        .onAppear { refresh() }
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Locally hosted chat models available in the worker and session model pickers.")
                .font(.subheadline)
            Text("Add a model by pasting a direct GGUF download URL (typically HuggingFace `resolve/main/...gguf`). The download lives in ~/.sonata/bin/ and is loaded by llama.cpp at first use.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyHint: some View {
        Text("No user-installed models yet. Click Add Model to install one from a GGUF URL.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding()
    }

    private func builtInRow(_ spec: LocalChatModelRegistry.Spec) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.displayName).font(.system(.body, design: .default))
                Text("\(spec.modelName) · port \(spec.port) · built-in")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func installedRow(_ row: InstalledChatModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.ggufPath == nil ? "arrow.down.circle" : "cube")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName).font(.system(.body, design: .default))
                Text("\(row.modelName) · port \(row.port)\(row.ggufPath == nil ? " · downloading…" : "")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let path = row.ggufPath {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let extra = row.extraArgs, !extra.isEmpty {
                    Text("extra: \(extra)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if confirmingDeleteId == row.id {
                Button("Confirm delete") {
                    Task { await runUninstall(id: row.id) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                Button("Cancel") { confirmingDeleteId = nil }
                    .controlSize(.small)
            } else {
                Button {
                    editingRow = row
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .disabled(deletingId != nil || row.ggufPath == nil)
                .help("Edit display name and extra llama-server args")
                Button {
                    confirmingDeleteId = row.id
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(deletingId != nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func inflightRow(_ progress: InstallProgress) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Installing \(progress.modelName)…").font(.system(.body, design: .default))
                Text(progress.stage)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func refresh() {
        Task {
            let rows = await InstalledChatModelManager.shared.listInstalled()
            await MainActor.run { installed = rows }
        }
    }

    private func runInstall(modelName: String, displayName: String, urlString: String, sha: String?, extra: String?) async {
        guard let url = URL(string: urlString) else {
            await MainActor.run { lastError = "Invalid URL" }
            return
        }
        await MainActor.run {
            inflight = InstallProgress(modelName: modelName, stage: "downloading…")
            lastError = nil
        }
        do {
            _ = try await InstalledChatModelManager.shared.install(
                modelName: modelName,
                displayName: displayName,
                sourceURL: url,
                sha256: sha?.isEmpty == false ? sha : nil,
                extraArgs: extra?.isEmpty == false ? extra : nil
            )
            await MainActor.run {
                inflight = nil
                refresh()
            }
        } catch {
            await MainActor.run {
                inflight = nil
                lastError = "\(error)"
            }
        }
    }

    private func runEdit(id: String, displayName: String, extra: String?) async {
        do {
            try await InstalledChatModelManager.shared.updateMetadata(
                id: id,
                displayName: displayName,
                extraArgs: extra?.isEmpty == false ? extra : nil
            )
            await MainActor.run {
                lastError = nil
                editingRow = nil
                refresh()
            }
        } catch {
            await MainActor.run { lastError = "\(error)" }
        }
    }

    private func runUninstall(id: String) async {
        await MainActor.run {
            deletingId = id
            confirmingDeleteId = nil
        }
        do {
            try await InstalledChatModelManager.shared.uninstall(id: id)
            await MainActor.run {
                deletingId = nil
                lastError = nil
                refresh()
            }
        } catch {
            await MainActor.run {
                deletingId = nil
                lastError = "\(error)"
            }
        }
    }
}

/// Sheet for editing the two user-mutable fields on an installed model:
/// displayName and extraArgs. Other fields (modelName, URL, sha256, port,
/// ggufPath) are immutable post-install — renaming them would orphan
/// references in session rows / running server PIDs / on-disk files.
private struct EditLocalModelSheet: View {
    @Environment(\.dismiss) private var dismiss

    let row: InstalledChatModel
    let onSubmit: (_ displayName: String, _ extra: String?) -> Void

    @State private var displayName: String
    @State private var extraArgs: String

    init(row: InstalledChatModel, onSubmit: @escaping (_ displayName: String, _ extra: String?) -> Void) {
        self.row = row
        self.onSubmit = onSubmit
        _displayName = State(initialValue: row.displayName)
        _extraArgs = State(initialValue: row.extraArgs ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit \(row.modelName)")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Form {
                Section {
                    LabeledContent("Model name", value: row.modelName)
                        .font(.system(.caption, design: .monospaced))
                    LabeledContent("Port", value: "\(row.port)")
                        .font(.system(.caption, design: .monospaced))
                    if let path = row.ggufPath {
                        LabeledContent("GGUF") {
                            Text(path)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                } header: {
                    Text("Read-only")
                }
                Section {
                    TextField("Display name", text: $displayName)
                        .autocorrectionDisabled()
                    TextField("Extra llama-server args", text: $extraArgs,
                              prompt: Text("--rope-scaling yarn --rope-scale 4 --yarn-orig-ctx 32768"),
                              axis: .vertical)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1...3)
                        .autocorrectionDisabled()
                } header: {
                    Text("Editable")
                } footer: {
                    Text("Saving restarts the llama-server process for this model so the new spawn args take effect. Any in-flight session's next message will pause briefly while it respawns.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Save") {
                    let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedExtra = extraArgs.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSubmit(trimmedName.isEmpty ? row.displayName : trimmedName,
                             trimmedExtra.isEmpty ? nil : trimmedExtra)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 600, height: 480)
    }
}

/// Sheet for entering a new local model. Captures the four user inputs
/// (modelName, displayName, GGUF URL, optional sha256) and forwards them
/// to the parent on Install.
private struct AddLocalModelSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var modelName: String = ""
    @State private var displayName: String = ""
    @State private var urlString: String = ""
    @State private var sha256: String = ""
    @State private var extraArgs: String = ""

    let onSubmit: (_ modelName: String, _ displayName: String, _ url: String, _ sha: String?, _ extra: String?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Local Model")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Form {
                Section {
                    TextField("Model name", text: $modelName, prompt: Text("qwen-2.5-7b-instruct"))
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                    TextField("Display name", text: $displayName, prompt: Text("Qwen 2.5 7B Instruct"))
                        .autocorrectionDisabled()
                    // Multi-line so long URLs wrap rather than truncate. The
                    // earlier single-line + .truncationMode(.middle) combo had
                    // a SwiftUI rendering bug on macOS where defocusing the
                    // field made the truncated value invisible and the
                    // placeholder reappeared — looking exactly like the URL
                    // had been "reset" to a sibling field's prompt.
                    TextField("GGUF URL", text: $urlString,
                              prompt: Text("https://huggingface.co/…/resolve/main/…Q4_K_M.gguf"),
                              axis: .vertical)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2...4)
                        .autocorrectionDisabled()
                    TextField("sha256 (optional)", text: $sha256,
                              prompt: Text("paste to enable integrity check"))
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                    TextField("Extra llama-server args (optional)", text: $extraArgs,
                              prompt: Text("--rope-scaling yarn --rope-scale 4 --yarn-orig-ctx 32768"),
                              axis: .vertical)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1...3)
                        .autocorrectionDisabled()
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model name must be lowercase letters, digits, hyphens, dots. It's what you'll see in the worker/session model picker and what's passed to Claude Code as --model.")
                        Text("Extra args are appended to the llama-server command. Use for per-model quirks: Qwen 2.5 32B needs YaRN to reach its 128K context (the placeholder above is the right value); DeepSeek R1 needs `--jinja` for its chat template; etc.")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Install") {
                    onSubmit(modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                             displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                             urlString.trimmingCharacters(in: .whitespacesAndNewlines),
                             sha256.trimmingCharacters(in: .whitespacesAndNewlines),
                             extraArgs.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(modelName.isEmpty || displayName.isEmpty || urlString.isEmpty)
            }
            .padding()
        }
        .frame(width: 600, height: 460)
    }
}
