import SwiftUI
import UniformTypeIdentifiers

struct PluginsView: View {
    @State private var plugins: [PluginInfo] = []
    @State private var error: String?
    @State private var loading = false
    @State private var lastRefresh: Date?

    @State private var showingConnect = false
    @State private var showingInstall = false
    @State private var configTarget: PluginInfo?
    @State private var uninstallTarget: PluginInfo?
    @State private var inFlightPlugin: String?
    @State private var actionError: String?

    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Plugins")
                    .font(.title.bold())
                Spacer()
                if let lastRefresh {
                    Text("Updated \(lastRefresh.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await fetchPlugins() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)

                Button {
                    showingConnect = true
                } label: {
                    Label("Connect External", systemImage: "link")
                }
                .buttonStyle(.bordered)

                Button {
                    showingInstall = true
                } label: {
                    Label("Install from File", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            if let actionError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        self.actionError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
            }

            if let error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    Text("Cannot reach Sonata server")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if plugins.isEmpty && !loading {
                VStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No plugins installed")
                        .font(.headline)
                    Text("Use **Connect External** to register a running service, or **Install from File** to unpack a plugin tarball.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loading && plugins.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading plugins...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(plugins) { plugin in
                            PluginCard(
                                plugin: plugin,
                                inFlight: inFlightPlugin == plugin.name,
                                onEnable: { Task { await enablePlugin(plugin.name) } },
                                onDisable: { Task { await disablePlugin(plugin.name) } },
                                onConfig: { configTarget = plugin },
                                onUninstall: { uninstallTarget = plugin }
                            )
                        }
                    }
                    .padding()
                }
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(800))
            await fetchPlugins()
        }
        .onReceive(timer) { _ in
            Task { await fetchPlugins() }
        }
        .sheet(isPresented: $showingConnect) {
            ConnectSheet { name, url, manifestPath in
                await connectPlugin(name: name, url: url, manifestPath: manifestPath)
            }
        }
        .sheet(item: $configTarget) { plugin in
            ConfigSheet(pluginName: plugin.name) { json in
                await updateConfig(name: plugin.name, json: json)
            }
        }
        .fileImporter(
            isPresented: $showingInstall,
            allowedContentTypes: installContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await installPlugin(path: url.path) }
            case .failure(let err):
                actionError = err.localizedDescription
            }
        }
        .confirmationDialog(
            "Uninstall plugin?",
            isPresented: Binding(
                get: { uninstallTarget != nil },
                set: { if !$0 { uninstallTarget = nil } }
            ),
            presenting: uninstallTarget
        ) { plugin in
            Button("Uninstall \(plugin.name)", role: .destructive) {
                Task { await uninstallPlugin(plugin.name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { plugin in
            Text("This stops \(plugin.name), removes it from the registry, and deletes \(plugin.path).")
        }
    }

    private var installContentTypes: [UTType] {
        var types: [UTType] = []
        if let gz = UTType(filenameExtension: "gz") { types.append(gz) }
        if let tgz = UTType(filenameExtension: "tgz") { types.append(tgz) }
        types.append(.gzip)
        types.append(.archive)
        return types
    }

    // MARK: - Actions

    private func fetchPlugins() async {
        if plugins.isEmpty { loading = true }
        defer { loading = false }
        do {
            let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/plugins")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                self.error = "Server returned non-200 status"
                return
            }
            let decoded = try JSONDecoder().decode([PluginInfo].self, from: data)
            self.plugins = decoded
            self.error = nil
            self.lastRefresh = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func enablePlugin(_ name: String) async {
        await postAction(name: name, path: "/api/plugins/\(name)/enable")
    }

    private func disablePlugin(_ name: String) async {
        await postAction(name: name, path: "/api/plugins/\(name)/disable")
    }

    private func uninstallPlugin(_ name: String) async {
        inFlightPlugin = name
        defer { inFlightPlugin = nil }
        do {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(sonataPort)/api/plugins/\(name)")!)
            req.httpMethod = "DELETE"
            let (data, response) = try await URLSession.shared.data(for: req)
            try throwIfNotOK(data: data, response: response)
            await fetchPlugins()
        } catch {
            actionError = "Uninstall failed: \(error.localizedDescription)"
        }
    }

    private func connectPlugin(name: String, url: String, manifestPath: String?) async {
        inFlightPlugin = name
        defer { inFlightPlugin = nil }
        do {
            var body: [String: Any] = ["name": name, "url": url]
            if let manifestPath, !manifestPath.isEmpty {
                body["manifest_path"] = manifestPath
            }
            try await postJSON(path: "/api/plugins/connect", body: body)
            await fetchPlugins()
        } catch {
            actionError = "Connect failed: \(error.localizedDescription)"
        }
    }

    private func installPlugin(path: String) async {
        do {
            try await postJSON(path: "/api/plugins/install", body: ["path": path])
            await fetchPlugins()
        } catch {
            actionError = "Install failed: \(error.localizedDescription)"
        }
    }

    private func updateConfig(name: String, json: String) async {
        do {
            guard let data = json.data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                actionError = "Config must be a JSON object"
                return
            }
            try await postJSON(path: "/api/plugins/\(name)/config", body: ["config": parsed])
            await fetchPlugins()
        } catch {
            actionError = "Config save failed: \(error.localizedDescription)"
        }
    }

    private func postAction(name: String, path: String) async {
        inFlightPlugin = name
        defer { inFlightPlugin = nil }
        do {
            try await postJSON(path: path, body: [:])
            await fetchPlugins()
        } catch {
            actionError = "\(path) failed: \(error.localizedDescription)"
        }
    }

    private func postJSON(path: String, body: [String: Any]) async throws {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(sonataPort)\(path)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try throwIfNotOK(data: data, response: response)
    }

    private func throwIfNotOK(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "PluginsView", code: -1, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard http.statusCode < 400 else {
            let message: String
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = (json["error"] as? String) ?? (json["message"] as? String) {
                message = err
            } else {
                message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            }
            throw NSError(domain: "PluginsView", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

// MARK: - Models

private struct PluginInfo: Codable, Identifiable {
    let name: String
    let version: String
    let description: String?
    let port: Int
    let status: String
    let mode: String
    let url: String?
    let path: String
    let pid: Int?
    let installedAt: Int64
    let updatedAt: Int64

    var id: String { name }

    var statusColor: Color {
        switch status {
        case "running": return .green
        case "failed": return .red
        case "starting": return .yellow
        case "disabled", "installed": return .gray
        default: return .gray
        }
    }

    var isRunning: Bool { status == "running" || status == "starting" }
}

// MARK: - Plugin Card

private struct PluginCard: View {
    let plugin: PluginInfo
    let inFlight: Bool
    let onEnable: () -> Void
    let onDisable: () -> Void
    let onConfig: () -> Void
    let onUninstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(plugin.statusColor)
                    .frame(width: 12, height: 12)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(plugin.name)
                            .font(.headline)
                        Text("v\(plugin.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        modeBadge
                        statusBadge
                    }
                    if let description = plugin.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 12) {
                        Label("port \(plugin.port)", systemImage: "network")
                        if let pid = plugin.pid, pid > 0 {
                            Label("pid \(pid)", systemImage: "cpu")
                        }
                        if let url = plugin.url, !url.isEmpty {
                            Label(url, systemImage: "link")
                                .lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Spacer()

                if inFlight {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                if plugin.isRunning {
                    Button {
                        onDisable()
                    } label: {
                        Label("Disable", systemImage: "pause.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(inFlight)
                } else {
                    Button {
                        onEnable()
                    } label: {
                        Label("Enable", systemImage: "play.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                    .disabled(inFlight)
                }

                Button {
                    onConfig()
                } label: {
                    Label("Config", systemImage: "slider.horizontal.3")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(inFlight)

                Spacer()

                Button {
                    onUninstall()
                } label: {
                    Label("Uninstall", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(inFlight)
            }
        }
        .padding()
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var modeBadge: some View {
        Text(plugin.mode)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (plugin.mode == "external" ? Color.purple : Color.blue).opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(plugin.mode == "external" ? .purple : .blue)
    }

    private var statusBadge: some View {
        Text(plugin.status)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(plugin.statusColor.opacity(0.15), in: Capsule())
            .foregroundStyle(plugin.statusColor)
    }
}

// MARK: - Connect External Sheet

private struct ConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onConnect: (String, String, String?) async -> Void

    @State private var name: String = ""
    @State private var url: String = "http://localhost:"
    @State private var manifestPath: String = ""
    @State private var submitting = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Connect External Plugin")
                .font(.headline)

            Form {
                TextField("Plugin name (e.g. sonar)", text: $name)
                    .textFieldStyle(.roundedBorder)

                TextField("Base URL (e.g. http://localhost:4000)", text: $url)
                    .textFieldStyle(.roundedBorder)

                TextField("Manifest path (optional)", text: $manifestPath)
                    .textFieldStyle(.roundedBorder)
                    .help("Absolute path to <name>.plugin.json — only needed if the plugin can't serve its own manifest.")
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect") {
                    Task {
                        submitting = true
                        await onConnect(
                            name.trimmingCharacters(in: .whitespaces),
                            url.trimmingCharacters(in: .whitespaces),
                            manifestPath.isEmpty ? nil : manifestPath.trimmingCharacters(in: .whitespaces)
                        )
                        submitting = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(submitting || name.isEmpty || url.isEmpty)
            }
        }
        .padding()
        .frame(width: 520)
    }
}

// MARK: - Config Sheet

private struct ConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pluginName: String
    let onSave: (String) async -> Void

    @State private var json: String = "{\n  \n}"
    @State private var submitting = false
    @State private var validationError: String?

    var body: some View {
        VStack(spacing: 12) {
            Text("Config — \(pluginName)")
                .font(.headline)

            Text("JSON object merged into the plugin's configuration. Sent as-is to POST /api/plugins/\(pluginName)/config.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextEditor(text: $json)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 260)
                .padding(6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard let data = json.data(using: .utf8),
                          (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                        validationError = "Must be a valid JSON object"
                        return
                    }
                    validationError = nil
                    Task {
                        submitting = true
                        await onSave(json)
                        submitting = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(submitting)
            }
        }
        .padding()
        .frame(width: 560)
    }
}
