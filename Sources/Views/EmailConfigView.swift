import SwiftUI

struct EmailConfigView: View {
    @StateObject private var vm = EmailConfigViewModel()
    @State private var showAddSheet = false
    @State private var editing: EmailInboxItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Email Inboxes")
                    .font(.headline)
                Spacer()

                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Inbox", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if vm.inboxes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "envelope")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No inboxes configured")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Add an inbox (AgentMail or your own IMAP/SMTP) to start receiving and replying to email.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(vm.inboxes) { inbox in
                        EmailInboxRow(
                            inbox: inbox,
                            onToggle: { enabled in
                                Task { _ = await vm.setEnabled(id: inbox.id, enabled: enabled) }
                            },
                            onEdit: { editing = inbox },
                            onDelete: {
                                Task { _ = await vm.delete(id: inbox.id) }
                            }
                        )
                        Divider()
                    }
                }
            }

            if let err = vm.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            EmailInboxEditSheet(vm: vm, inbox: nil)
        }
        .sheet(item: $editing) { inbox in
            EmailInboxEditSheet(vm: vm, inbox: inbox)
        }
        .task { await vm.fetch() }
    }
}

// MARK: - Row

private struct EmailInboxRow: View {
    let inbox: EmailInboxItem
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { inbox.enabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(inbox.displayName?.isEmpty == false ? inbox.displayName! : inbox.address)
                    .font(.body.weight(.medium))
                Text(inbox.address)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Role badge
            Text(inbox.role)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(badgeColor(inbox.role).opacity(0.15), in: Capsule())
                .foregroundStyle(badgeColor(inbox.role))

            if inbox.autoReply {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .help("Auto-reply enabled")
            }

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .alert("Delete Inbox", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \(inbox.address)? This stops polling and removes the inbox from Sonata. The AgentMail inbox itself is not affected.")
        }
    }

    private func badgeColor(_ role: String) -> Color {
        switch role {
        case "sona":        return .blue
        case "scoutleader": return .purple
        case "relay":       return .orange
        default:            return .gray
        }
    }
}

// MARK: - Add / Edit Sheet

private struct EmailInboxEditSheet: View {
    @ObservedObject var vm: EmailConfigViewModel
    let inbox: EmailInboxItem?   // nil = add new
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var displayName = ""
    @State private var role = "custom"
    @State private var enabled = true
    @State private var autoReply = true
    @State private var dispatchTo = "worker"
    @State private var systemPrompt = ""
    @State private var saving = false

    // Provider / IMAP connection
    @State private var provider = "agentmail"
    @State private var preset = "gmail"
    @State private var imapHost = ""
    @State private var smtpHost = ""
    @State private var imapPort = "993"
    @State private var smtpPort = "465"
    @State private var imapPassword = ""

    private var isEditing: Bool { inbox != nil }
    private var isValid: Bool {
        guard !address.isEmpty, !role.isEmpty else { return false }
        if provider == "imap" {
            guard !imapHost.isEmpty, !smtpHost.isEmpty else { return false }
            // A new IMAP inbox needs a password; editing may leave it blank to keep current.
            if !isEditing && imapPassword.isEmpty { return false }
        }
        return true
    }

    /// Fill host/port fields from a known provider preset.
    private func applyPreset(_ p: String) {
        switch p {
        case "gmail":
            imapHost = "imap.gmail.com"; smtpHost = "smtp.gmail.com"; imapPort = "993"; smtpPort = "465"
        case "fastmail":
            imapHost = "imap.fastmail.com"; smtpHost = "smtp.fastmail.com"; imapPort = "993"; smtpPort = "465"
        case "icloud":
            imapHost = "imap.mail.me.com"; smtpHost = "smtp.mail.me.com"; imapPort = "993"; smtpPort = "587"
        default:
            break  // custom — leave fields as-is
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit Inbox" : "Add Inbox")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Form {
                Section("Inbox") {
                    TextField("Address (e.g. you@gmail.com or mybot@agentmail.to)", text: $address)
                        .disabled(isEditing)  // address is the natural key
                    TextField("Display Name", text: $displayName)
                    Picker("Role", selection: $role) {
                        Text("Sona (primary)").tag("sona")
                        Text("Scout Leader").tag("scoutleader")
                        Text("Relay").tag("relay")
                        Text("Custom").tag("custom")
                    }
                    Picker("Provider", selection: $provider) {
                        Text("AgentMail").tag("agentmail")
                        Text("IMAP / SMTP (your own email)").tag("imap")
                    }
                }

                if provider == "imap" {
                    Section("IMAP / SMTP Connection") {
                        Picker("Preset", selection: $preset) {
                            Text("Gmail").tag("gmail")
                            Text("Fastmail").tag("fastmail")
                            Text("iCloud").tag("icloud")
                            Text("Custom").tag("custom")
                        }
                        .onChange(of: preset) { _, newValue in applyPreset(newValue) }

                        TextField("IMAP host", text: $imapHost)
                        TextField("IMAP port", text: $imapPort)
                        TextField("SMTP host", text: $smtpHost)
                        TextField("SMTP port", text: $smtpPort)
                        SecureField(isEditing ? "App password (leave blank to keep current)"
                                              : "App password", text: $imapPassword)
                        Text("Use an app-specific password (requires 2-factor on the account), not your login password. Stored in the Secrets keychain, never in the database.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Behavior") {
                    Toggle("Enabled (poll for new email)", isOn: $enabled)
                    Toggle("Auto-reply to incoming email", isOn: $autoReply)
                    Picker("Dispatch to", selection: $dispatchTo) {
                        Text("Worker (auto-reply)").tag("worker")
                        Text("Supervisor (review first)").tag("supervisor")
                        Text("Manual (no auto-reply)").tag("manual")
                    }
                }

                Section("Reply Personality (optional)") {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 120)
                        .font(.body.monospaced())
                    Text("Custom system prompt used when dispatching replies. Leave blank to use the built-in role prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(isEditing ? "Save" : "Add Inbox") {
                    saving = true
                    Task {
                        let ok = await vm.upsert(
                            address: address,
                            role: role,
                            displayName: displayName.isEmpty ? nil : displayName,
                            enabled: enabled,
                            autoReply: autoReply,
                            dispatchTo: dispatchTo.isEmpty ? nil : dispatchTo,
                            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                            provider: provider,
                            imapHost: provider == "imap" ? imapHost : nil,
                            smtpHost: provider == "imap" ? smtpHost : nil,
                            imapPort: provider == "imap" ? Int(imapPort) : nil,
                            smtpPort: provider == "imap" ? Int(smtpPort) : nil,
                            imapPassword: imapPassword.isEmpty ? nil : imapPassword
                        )
                        saving = false
                        if ok { dismiss() }
                    }
                }
                .disabled(!isValid || saving)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
        .onAppear {
            if let c = inbox {
                address = c.address
                displayName = c.displayName ?? ""
                role = c.role
                enabled = c.enabled
                autoReply = c.autoReply
                dispatchTo = c.dispatchTo ?? "worker"
                systemPrompt = c.systemPrompt ?? ""
                provider = c.provider
                // Repopulate IMAP host/ports from providerConfig (password is never
                // echoed back — blank means "keep the stored secret").
                if let cfgStr = c.providerConfig, let data = cfgStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    imapHost = json["imapHost"] as? String ?? ""
                    smtpHost = json["smtpHost"] as? String ?? ""
                    if let p = json["imapPort"] as? Int { imapPort = String(p) }
                    if let p = json["smtpPort"] as? Int { smtpPort = String(p) }
                    preset = "custom"  // show the inbox's actual stored values
                }
            }
        }
    }
}
