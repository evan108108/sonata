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
                    Text("Add an AgentMail inbox to start receiving and replying to email.")
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

    private var isEditing: Bool { inbox != nil }
    private var isValid: Bool { !address.isEmpty && !role.isEmpty }

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
                    TextField("Address (e.g. mybot@agentmail.to)", text: $address)
                        .disabled(isEditing)  // address is the natural key
                    TextField("Display Name", text: $displayName)
                    Picker("Role", selection: $role) {
                        Text("Sona (primary)").tag("sona")
                        Text("Scout Leader").tag("scoutleader")
                        Text("Relay").tag("relay")
                        Text("Custom").tag("custom")
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
                            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt
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
            }
        }
    }
}
