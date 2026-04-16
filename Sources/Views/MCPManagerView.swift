import SwiftUI

// MARK: - MCP Server Config Model

struct MCPServerConfig: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var type: String  // "stdio" or "http"
    var command: String
    var args: [String]
    var env: [String: String]
    var url: String  // for http type
    var enabled: Bool

    var displayCommand: String {
        if type == "http" { return url }
        return ([command] + args).joined(separator: " ")
    }

    var isHTTP: Bool { type == "http" }
}

// MARK: - MCP Manager View

struct MCPManagerView: View {
    @State private var servers: [MCPServerConfig] = []
    @State private var selectedServer: MCPServerConfig?
    @State private var showingAddSheet = false
    @State private var showingEditSheet = false
    @State private var editingServer: MCPServerConfig?
    @State private var testResults: [String: TestResult] = [:]
    @State private var loadError: String?

    enum TestResult {
        case testing
        case success(String)
        case failure(String)
    }

    // Claude Code uses ~/.claude/mcp.json; Claude Desktop uses ~/.claude.json
    // The Settings UI manages Claude Code's config (what workers/supervisor use)
    private let claudeConfigPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/mcp.json")

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("MCP Servers")
                    .font(.headline)
                Spacer()
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if let loadError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }

            Divider()

            if servers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No MCP servers configured")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Add servers to ~/.claude/mcp.json")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(servers, selection: $selectedServer.mapped(\.name)) {
                    TableColumn("") { server in
                        Circle()
                            .fill(server.enabled ? .green : .gray)
                            .frame(width: 8, height: 8)
                    }
                    .width(20)

                    TableColumn("Name") { server in
                        Text(server.name)
                            .font(.body.monospaced())
                    }
                    .width(min: 100, ideal: 140)

                    TableColumn("Command") { server in
                        Text(server.displayCommand)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 200, ideal: 300)

                    TableColumn("Status") { server in
                        statusView(for: server.name)
                    }
                    .width(min: 80, ideal: 120)

                    TableColumn("Actions") { server in
                        HStack(spacing: 8) {
                            Toggle("", isOn: bindingForEnabled(server))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.small)

                            Button {
                                testServer(server)
                            } label: {
                                Image(systemName: "bolt.fill")
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.borderless)
                            .help("Test connection")

                            Button {
                                editingServer = server
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.borderless)
                            .help("Edit")

                            Button(role: .destructive) {
                                deleteServer(server)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Delete")
                        }
                    }
                    .width(min: 160, ideal: 180)
                }
            }
        }
        .frame(minHeight: 200)
        .onAppear { loadServers() }
        .sheet(isPresented: $showingAddSheet) {
            MCPServerEditSheet(mode: .add) { config in
                servers.append(config)
                saveServers()
            }
        }
        .sheet(item: $editingServer) { editing in
            MCPServerEditSheet(mode: .edit(editing)) { updated in
                if let idx = servers.firstIndex(where: { $0.name == editing.name }) {
                    servers[idx] = updated
                    saveServers()
                }
                editingServer = nil
            }
        }
    }

    // MARK: - Status indicator

    @ViewBuilder
    private func statusView(for name: String) -> some View {
        if let result = testResults[name] {
            switch result {
            case .testing:
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Testing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .success(let msg):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
            case .failure(let msg):
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
        } else {
            Text("--")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Enable/Disable toggle binding

    private func bindingForEnabled(_ server: MCPServerConfig) -> Binding<Bool> {
        Binding(
            get: { server.enabled },
            set: { newValue in
                if let idx = servers.firstIndex(where: { $0.name == server.name }) {
                    servers[idx].enabled = newValue
                    saveServers()
                }
            }
        )
    }

    // MARK: - Load from ~/.claude.json

    func loadServers() {
        do {
            let data = try Data(contentsOf: claudeConfigPath)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mcpServers = json["mcpServers"] as? [String: Any] else {
                loadError = "No mcpServers key found"
                return
            }

            // Check for disabled servers list
            let disabledList = json["mcpServersDisabled"] as? [String] ?? []

            var result: [MCPServerConfig] = []
            for (name, value) in mcpServers {
                guard let dict = value as? [String: Any] else { continue }
                // Detect type: if "url" is present it's http, otherwise stdio
                let explicitType = dict["type"] as? String
                let url = dict["url"] as? String ?? ""
                let type = explicitType ?? (url.isEmpty ? "stdio" : "http")
                let command = dict["command"] as? String ?? ""
                let args = dict["args"] as? [String] ?? []
                let env = dict["env"] as? [String: String] ?? [:]
                let enabled = !disabledList.contains(name)

                result.append(MCPServerConfig(
                    name: name, type: type, command: command,
                    args: args, env: env, url: url, enabled: enabled
                ))
            }
            servers = result.sorted { $0.name < $1.name }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Save to ~/.claude.json

    private func saveServers() {
        do {
            let data = try Data(contentsOf: claudeConfigPath)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            // Preserve existing config — only update servers we know about
            var mcpDict = json["mcpServers"] as? [String: Any] ?? [:]
            var disabledList: [String] = []

            // Track which servers should exist
            let serverNames = Set(servers.map(\.name))

            // Remove servers that were deleted in the UI
            for key in mcpDict.keys {
                if !serverNames.contains(key) {
                    mcpDict.removeValue(forKey: key)
                }
            }

            // Update/add servers from the UI state
            for server in servers {
                // Preserve existing entry's unknown fields, merge our known fields on top
                var entry = mcpDict[server.name] as? [String: Any] ?? [:]

                if server.isHTTP {
                    entry["type"] = "http"
                    entry["url"] = server.url
                    entry.removeValue(forKey: "command")
                    entry.removeValue(forKey: "args")
                } else {
                    entry.removeValue(forKey: "type")  // stdio is default, omit
                    entry.removeValue(forKey: "url")
                    entry["command"] = server.command
                    if !server.args.isEmpty {
                        entry["args"] = server.args
                    } else {
                        entry.removeValue(forKey: "args")
                    }
                }

                if !server.env.isEmpty {
                    entry["env"] = server.env
                }
                // Don't remove env if we didn't load any — it may have env vars we didn't parse

                mcpDict[server.name] = entry

                if !server.enabled {
                    disabledList.append(server.name)
                }
            }

            json["mcpServers"] = mcpDict
            if disabledList.isEmpty {
                json.removeValue(forKey: "mcpServersDisabled")
            } else {
                json["mcpServersDisabled"] = disabledList
            }

            let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: claudeConfigPath)
        } catch {
            loadError = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Delete

    private func deleteServer(_ server: MCPServerConfig) {
        servers.removeAll { $0.name == server.name }
        testResults.removeValue(forKey: server.name)
        saveServers()
    }

    // MARK: - Test Connection

    private func testServer(_ server: MCPServerConfig) {
        testResults[server.name] = .testing

        Task.detached {
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: server.command.hasPrefix("/")
                    ? server.command
                    : "/usr/bin/env")
                if server.command.hasPrefix("/") {
                    process.arguments = server.args
                } else {
                    process.arguments = [server.command] + server.args
                }

                // Merge env
                var environment = ProcessInfo.processInfo.environment
                for (k, v) in server.env { environment[k] = v }
                process.environment = environment

                let stdin = Pipe()
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr

                try process.run()

                // Send MCP initialize request
                let initRequest = """
                {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"Sonata","version":"1.0"}}}
                """
                let requestData = "Content-Length: \(initRequest.utf8.count)\r\n\r\n\(initRequest)"
                stdin.fileHandleForWriting.write(requestData.data(using: .utf8)!)

                // Wait for response with timeout
                let startTime = Date()
                var responseData = Data()
                let handle = stdout.fileHandleForReading

                while Date().timeIntervalSince(startTime) < 5.0 {
                    let available = handle.availableData
                    if !available.isEmpty {
                        responseData.append(available)
                        // Check if we got a complete response
                        if let text = String(data: responseData, encoding: .utf8),
                           text.contains("\"result\"") || text.contains("\"error\"") {
                            break
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }

                process.terminate()

                if let text = String(data: responseData, encoding: .utf8), text.contains("\"result\"") {
                    await MainActor.run {
                        testResults[server.name] = .success("Connected")
                    }
                } else if responseData.isEmpty {
                    await MainActor.run {
                        testResults[server.name] = .failure("No response (5s)")
                    }
                } else {
                    await MainActor.run {
                        testResults[server.name] = .failure("Bad response")
                    }
                }
            } catch {
                await MainActor.run {
                    testResults[server.name] = .failure(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Selection binding helper

private extension Optional where Wrapped == MCPServerConfig {
    func mapped(_ keyPath: KeyPath<MCPServerConfig, String>) -> Binding<String?> {
        fatalError("Use the overload below")
    }
}

extension Binding where Value == MCPServerConfig? {
    func mapped(_ keyPath: KeyPath<MCPServerConfig, String>) -> Binding<String?> {
        Binding<String?>(
            get: { self.wrappedValue?[keyPath: keyPath] },
            set: { _ in }  // Table selection is read-only for our purposes
        )
    }
}

// MARK: - Add/Edit Sheet

enum MCPEditMode {
    case add
    case edit(MCPServerConfig)
}

private struct MCPServerEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: MCPEditMode
    let onSave: (MCPServerConfig) -> Void

    @State private var name: String = ""
    @State private var serverType: String = "stdio"
    @State private var command: String = ""
    @State private var argsText: String = ""
    @State private var url: String = ""
    @State private var envPairs: [(key: String, value: String)] = []

    init(mode: MCPEditMode, onSave: @escaping (MCPServerConfig) -> Void) {
        self.mode = mode
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(isEdit ? "Edit MCP Server" : "Add MCP Server")
                .font(.headline)

            Form {
                TextField("Server name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEdit)

                Picker("Type", selection: $serverType) {
                    Text("stdio").tag("stdio")
                    Text("http").tag("http")
                }
                .pickerStyle(.segmented)

                if serverType == "http" {
                    TextField("URL (e.g. http://localhost:8787/mcp)", text: $url)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField("Command (e.g. npx, /usr/bin/myserver)", text: $command)
                        .textFieldStyle(.roundedBorder)

                    TextField("Arguments (one per line)", text: $argsText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)
                }

                Section("Environment Variables") {
                    ForEach(envPairs.indices, id: \.self) { i in
                        HStack {
                            TextField("KEY", text: Binding(
                                get: { envPairs[i].key },
                                set: { envPairs[i] = ($0, envPairs[i].value) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)

                            TextField("VALUE", text: Binding(
                                get: { envPairs[i].value },
                                set: { envPairs[i] = (envPairs[i].key, $0) }
                            ))
                            .textFieldStyle(.roundedBorder)

                            Button(role: .destructive) {
                                envPairs.remove(at: i)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Variable") {
                        envPairs.append(("", ""))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    let args = argsText
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    var env: [String: String] = [:]
                    for pair in envPairs where !pair.key.isEmpty {
                        env[pair.key] = pair.value
                    }
                    let config = MCPServerConfig(
                        name: name, type: serverType,
                        command: serverType == "http" ? "" : command,
                        args: serverType == "http" ? [] : args,
                        env: env,
                        url: serverType == "http" ? url : "",
                        enabled: true
                    )
                    onSave(config)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || (serverType == "http" ? url.isEmpty : command.isEmpty))
            }
        }
        .padding()
        .frame(width: 520)
        .onAppear {
            if case .edit(let server) = mode {
                name = server.name
                serverType = server.type
                command = server.command
                argsText = server.args.joined(separator: "\n")
                url = server.url
                envPairs = server.env.map { ($0.key, $0.value) }.sorted { $0.key < $1.key }
            }
        }
    }

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }
}
