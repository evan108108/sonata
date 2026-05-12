import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var secrets: [SecretEntry] = []
    @State private var showingAddSheet = false
    @State private var showingImportPicker = false
    @State private var showingPathInput = false
    @State private var importPath = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var ownerEmail = ""
    @State private var ownerEmailSaved = false
    @State private var secretsExpanded = false
    @State private var emailExpanded = true
    @State private var mcpExpanded = false
    @State private var workerExpanded = false
    @State private var supervisorExpanded = false
    @State private var studioExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title.bold())
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    // MARK: - General Section
                    VStack(spacing: 0) {
                        HStack {
                            Text("General")
                                .font(.headline)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Launch at Login")
                                    .font(.body)
                                Text("Start Sonata automatically when you log in")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $launchAtLogin)
                                .toggleStyle(.switch)
                                .onChange(of: launchAtLogin) { _, enabled in
                                    do {
                                        if enabled {
                                            try SMAppService.mainApp.register()
                                        } else {
                                            try SMAppService.mainApp.unregister()
                                        }
                                    } catch {
                                        launchAtLogin = SMAppService.mainApp.status == .enabled
                                    }
                                }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Owner Email")
                                    .font(.body)
                                Text("Health alerts and failure notifications are sent here")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            TextField("you@example.com", text: $ownerEmail)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 250)
                                .onSubmit { saveOwnerEmail() }
                            if ownerEmailSaved {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))

                    // MARK: - Secrets Section
                    VStack(spacing: 0) {
                        Button { withAnimation(.easeInOut(duration: 0.2)) { secretsExpanded.toggle() } } label: {
                            HStack {
                                Image(systemName: secretsExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text("Secrets")
                                    .font(.headline)
                                if !secretsExpanded && !secrets.isEmpty {
                                    Text("\(secrets.count)")
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                                Spacer()
                                if secretsExpanded {
                                    Button {
                                        showingImportPicker = true
                                    } label: {
                                        Label("Import .env", systemImage: "doc.badge.plus")
                                    }
                                    .buttonStyle(.bordered)

                                    Button {
                                        showingAddSheet = true
                                    } label: {
                                        Label("Add Secret", systemImage: "plus")
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)

                        if secretsExpanded {
                            // Inline path import (fallback)
                            HStack {
                                TextField("Path to .env file", text: $importPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Import") {
                                    let expanded = NSString(string: importPath).expandingTildeInPath
                                    let url = URL(fileURLWithPath: expanded)
                                    importEnvFile(url)
                                }
                                .buttonStyle(.bordered)
                                .disabled(importPath.isEmpty)
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 8)

                            Divider()

                            if secrets.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "key.fill")
                                        .font(.system(size: 36))
                                        .foregroundStyle(.secondary)
                                    Text("No secrets stored")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(secrets) { secret in
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(secret.name)
                                                    .font(.headline.monospaced())
                                                if !secret.description.isEmpty {
                                                    Text(secret.description)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                Text(maskedValue(secret.value))
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(.tertiary)
                                            }
                                            Spacer()
                                            Button(role: .destructive) {
                                                deleteSecret(secret)
                                            } label: {
                                                Image(systemName: "trash")
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                        .padding(.horizontal)
                                        .padding(.vertical, 6)
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))

                    // MARK: - Email Inboxes Section
                    collapsibleSection("Email Inboxes", icon: "envelope.fill", expanded: $emailExpanded) {
                        EmailConfigView()
                    }

                    // MARK: - MCP Servers Section
                    collapsibleSection("MCP Servers", icon: "server.rack", expanded: $mcpExpanded) {
                        MCPManagerView()
                    }

                    // MARK: - Workers Section
                    collapsibleSection("Workers", icon: "arrow.triangle.2.circlepath", expanded: $workerExpanded) {
                        WorkerCyclingSettingsView()
                    }

                    // MARK: - Studio Section
                    collapsibleSection("Studio", icon: "rectangle.split.3x1.fill", expanded: $studioExpanded) {
                        StudioSettingsView()
                    }

                    // MARK: - Supervisor Schedule Section
                    collapsibleSection("Supervisor", icon: "eye.fill", expanded: $supervisorExpanded) {
                        SupervisorConfigView()
                    }
                }
                .padding()
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddSecretSheet { name, value, description in
                addSecret(name: name, value: value, description: description)
            }
        }
        .onChange(of: showingImportPicker) { _, isShowing in
            if isShowing {
                showingImportPicker = false
                let panel = NSOpenPanel()
                panel.title = "Import .env or dev.vars file"
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.showsHiddenFiles = true
                panel.treatsFilePackagesAsDirectories = true
                panel.allowedContentTypes = [.data]  // .data is the base type — matches ALL files including extensionless dotfiles
                panel.allowsOtherFileTypes = true
                if panel.runModal() == .OK, let url = panel.url {
                    importEnvFile(url)
                }
            }
        }
        .onAppear {
            loadSecrets()
            loadOwnerEmail()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .sheet(isPresented: $showingPathInput) {
            VStack(spacing: 16) {
                Text("Import .env File")
                    .font(.headline)
                Text("Enter the full path to your .env file:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Path", text: $importPath)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 400)
                HStack {
                    Button("Cancel") { showingPathInput = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Import") {
                        let expanded = NSString(string: importPath).expandingTildeInPath
                        let url = URL(fileURLWithPath: expanded)
                        importEnvFile(url)
                        showingPathInput = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(importPath.isEmpty)
                }
            }
            .padding(24)
            .frame(minWidth: 450)
        }
    }

    // MARK: - Persistence (UserDefaults for now)

    private func loadSecrets() {
        guard let data = UserDefaults.standard.data(forKey: "sonata.secrets"),
              let decoded = try? JSONDecoder().decode([SecretEntry].self, from: data) else {
            return
        }
        secrets = decoded
    }

    private func saveSecrets() {
        if let data = try? JSONEncoder().encode(secrets) {
            UserDefaults.standard.set(data, forKey: "sonata.secrets")
        }
    }

    private func addSecret(name: String, value: String, description: String) {
        if let idx = secrets.firstIndex(where: { $0.name == name }) {
            secrets[idx] = SecretEntry(name: name, value: value, description: description)
        } else {
            secrets.append(SecretEntry(name: name, value: value, description: description))
        }
        saveSecrets()
    }

    private func deleteSecret(_ secret: SecretEntry) {
        secrets.removeAll { $0.id == secret.id }
        saveSecrets()
    }

    private func importEnvFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            var val = String(parts[1]).trimmingCharacters(in: .whitespaces)

            if (val.hasPrefix("\"") && val.hasSuffix("\"")) ||
               (val.hasPrefix("'") && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }

            addSecret(name: key, value: val, description: "Imported from .env")
        }
    }

    @ViewBuilder
    private func collapsibleSection<Content: View>(_ title: String, icon: String, expanded: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue.toggle() } } label: {
                HStack {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Label(title, systemImage: icon)
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if expanded.wrappedValue {
                content()
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
    }

    private func loadOwnerEmail() {
        Task {
            guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/core/get?key=owner_email") else { return }
            if let (data, response) = try? await URLSession.shared.data(from: url),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = json["content"] as? String {
                await MainActor.run { ownerEmail = value }
            }
        }
    }

    private func saveOwnerEmail() {
        guard !ownerEmail.isEmpty else { return }
        Task {
            guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/core") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["key": "owner_email", "category": "config", "content": ownerEmail]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode < 300 {
                await MainActor.run {
                    ownerEmailSaved = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        await MainActor.run { ownerEmailSaved = false }
                    }
                }
            }
        }
    }

    private func maskedValue(_ value: String) -> String {
        if value.count <= 8 {
            return String(repeating: "*", count: value.count)
        }
        return String(value.prefix(4)) + String(repeating: "*", count: value.count - 8) + String(value.suffix(4))
    }
}

// MARK: - Secret Entry Model

struct SecretEntry: Identifiable, Codable {
    var id: String { name }
    let name: String
    let value: String
    let description: String
}

// MARK: - Worker Cycling Settings

struct WorkerCyclingSettingsView: View {
    @State private var defaultWorkerCount: Int = WorkerManager.defaultWorkerCount
    @State private var restartRecoveryEnabled: Bool = WorkerManager.restartRecoveryEnabled
    @State private var cycleTasks: Int = {
        let val = UserDefaults.standard.integer(forKey: "sonata.cycleTasks")
        return val > 0 ? val : 4
    }()
    @State private var spawnTimeout: Int = {
        let val = UserDefaults.standard.integer(forKey: "sonata.spawnTimeout")
        return val > 0 ? val : 30
    }()
    @State private var sigtermGrace: Int = {
        let val = UserDefaults.standard.integer(forKey: "sonata.sigtermGrace")
        return val > 0 ? val : 10
    }()
    @State private var cycleFailAlert: Int = {
        let val = UserDefaults.standard.integer(forKey: "sonata.cycleFailAlert")
        return val > 0 ? val : 3
    }()
    @State private var pauseCycling: Bool = UserDefaults.standard.bool(forKey: "sonata.pauseCycling")

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workers")
                    .font(.headline)
                Spacer()
                if pauseCycling {
                    Text("PAUSED")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.yellow.opacity(0.2), in: Capsule())
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            VStack(spacing: 12) {
                settingRow(label: "Default workers on launch", description: "Pool size at app boot. Pool grows automatically when restart-recovery resurrects more.", value: $defaultWorkerCount, range: 1...16, key: "defaultWorkerCount")

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restart recovery")
                            .font(.body)
                        Text("On launch, respawn workers that died holding active tasks; resume their prior claude sessions via --resume.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $restartRecoveryEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: restartRecoveryEnabled) { _, newValue in
                            WorkerManager.restartRecoveryEnabled = newValue
                        }
                }
                .padding(.horizontal)

                settingRow(label: "Cycle after N tasks", description: "Replace worker process after this many completed tasks. 0 = disabled.", value: $cycleTasks, range: 0...50, key: "sonata.cycleTasks")

                settingRow(label: "Spawn timeout", description: "Seconds to wait for replacement to register.", value: $spawnTimeout, range: 5...300, key: "sonata.spawnTimeout")

                settingRow(label: "SIGTERM grace", description: "Seconds after SIGTERM before SIGKILL.", value: $sigtermGrace, range: 1...60, key: "sonata.sigtermGrace")

                settingRow(label: "Failure alert threshold", description: "Consecutive spawn failures before supervisor alert.", value: $cycleFailAlert, range: 1...20, key: "sonata.cycleFailAlert")

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pause cycling")
                            .font(.body)
                        Text("Temporarily disable cycling without changing threshold")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $pauseCycling)
                        .toggleStyle(.switch)
                        .onChange(of: pauseCycling) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "sonata.pauseCycling")
                            WorkerManager.shared.isCyclingPaused = newValue
                        }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
        }
    }

    private func settingRow(label: String, description: String, value: Binding<Int>, range: ClosedRange<Int>, key: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue)")
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 30, alignment: .trailing)
            }
            .onChange(of: value.wrappedValue) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: key)
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Add Secret Sheet

private struct AddSecretSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""
    @State private var description = ""
    let onSave: (String, String, String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Secret")
                .font(.headline)

            Form {
                TextField("Key name (e.g. ANTHROPIC_API_KEY)", text: $name)
                    .textFieldStyle(.roundedBorder)

                SecureField("Value", text: $value)
                    .textFieldStyle(.roundedBorder)

                TextField("Description (optional)", text: $description)
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard !name.isEmpty, !value.isEmpty else { return }
                    onSave(name, value, description)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || value.isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

// MARK: - Studio Settings

/// Settings pane for Studio. Today: just the default nickname surfaced to
/// other members. Persisted in the `studio:user_profile` singleton entity;
/// the per-room `_profile` card auto-publishes from it on first post / join
/// (see StudioStore). Reads + writes through EntityHTTP directly so this
/// pane doesn't need a shared `StudioStore` env object — the live store
/// observes the same row and picks up changes automatically.
struct StudioSettingsView: View {
    @State private var nickname: String = ""
    @State private var avatarPath: String? = nil
    @State private var savedFlash: Bool = false
    @State private var saving: Bool = false
    @State private var pickerError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                StudioLocalAvatarPreview(path: avatarPath, diameter: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default avatar")
                        .font(.body)
                    Text("Federated alongside your nickname on the next room you post in or join. Re-encoded as a small JPEG and re-encrypted per room.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Choose…") { pickAvatar() }
                            .buttonStyle(.bordered)
                        Button("Clear") { clearAvatar() }
                            .buttonStyle(.bordered)
                            .disabled(avatarPath == nil)
                    }
                    if let err = pickerError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
            }
            .padding(.horizontal)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Default nickname")
                        .font(.body)
                    Text("How you appear to other members in new rooms. Federated via the next card you post or room you join.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("e.g. Sona", text: $nickname)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit { save() }
                Button(action: save) {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else if savedFlash {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(saving)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .onAppear(perform: load)
    }

    private func load() {
        Task {
            async let nick = EntityHTTP.readDefaultNickname()
            async let path = EntityHTTP.readDefaultAvatarLocalPath()
            let (n, p) = await (nick, path)
            await MainActor.run {
                if let n = n { nickname = n }
                avatarPath = p
            }
        }
    }

    private func pickAvatar() {
        pickerError = nil
        do {
            guard let path = try StudioAvatarPicker.pickAndStage() else { return }
            avatarPath = path
            persistProfile()
        } catch {
            pickerError = error.localizedDescription
        }
    }

    private func clearAvatar() {
        avatarPath = nil
        pickerError = nil
        persistProfile()
    }

    private func save() {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        nickname = trimmed
        saving = true
        Task {
            await EntityHTTP.upsertEntity(
                name: "studio:user_profile",
                type: "studio_user_profile",
                description: "Local default profile (machine-only, not federated directly)",
                attributes: profileAttributes()
            )
            await MainActor.run {
                saving = false
                savedFlash = true
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { savedFlash = false }
        }
    }

    private func persistProfile() {
        Task {
            await EntityHTTP.upsertEntity(
                name: "studio:user_profile",
                type: "studio_user_profile",
                description: "Local default profile (machine-only, not federated directly)",
                attributes: profileAttributes()
            )
        }
    }

    private func profileAttributes() -> [String: Any] {
        var attrs: [String: Any] = [
            "default_nickname": nickname.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        // Persist the avatar path even when empty so a Clear action erases
        // it server-side rather than leaving the prior value behind.
        attrs["default_avatar_local_path"] = avatarPath ?? ""
        return attrs
    }
}
