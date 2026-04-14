import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var secrets: [SecretEntry] = []
    @State private var showingAddSheet = false
    @State private var showingImportPicker = false
    @State private var showingPathInput = false
    @State private var importPath = "~/memory/.env"

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
                    // MARK: - Secrets Section
                    VStack(spacing: 0) {
                        HStack {
                            Text("Secrets")
                                .font(.headline)
                            Spacer()

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
                        .padding(.horizontal)
                        .padding(.vertical, 8)

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
                                Text("Add API keys and other secrets here.\nKeychain in Phase 5.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
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
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))

                    // MARK: - MCP Servers Section
                    MCPManagerView()
                        .background(.background)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
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
