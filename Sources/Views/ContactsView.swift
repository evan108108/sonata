import SwiftUI

struct ContactsView: View {
    @StateObject private var vm = ContactViewModel()
    @State private var selectedContact: ContactItem?
    @State private var showAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            header

            searchBar

            Divider()

            HSplitView {
                contactList
                    .frame(minWidth: 300)

                if let contact = selectedContact, let live = liveContact(for: contact) {
                    ContactDetailView(
                        contact: live,
                        vm: vm,
                        onDelete: { selectedContact = nil }
                    )
                    .frame(minWidth: 400)
                } else {
                    emptyDetail
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ContactEditSheet(vm: vm, contact: nil)
        }
        .task { await vm.fetch() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("People")
                .font(.title.bold())
            Text("\(vm.contacts.count)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.2), in: Capsule())

            Spacer()

            Picker("Type", selection: $vm.filterType) {
                Text("All").tag(nil as String?)
                Text("Human").tag("human" as String?)
                Text("AI").tag("ai" as String?)
                Text("Service").tag("service" as String?)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            Button {
                Task { await vm.fetch() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")

            Button {
                showAddSheet = true
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search by name, email, or notes…", text: $vm.searchQuery)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - Contact list

    private var contactList: some View {
        Group {
            if vm.contacts.isEmpty && !vm.isLoading {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No contacts yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Button("Add your first contact") {
                        showAddSheet = true
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(vm.filteredContacts) { contact in
                            ContactListRow(contact: contact)
                                .sidebarRowSelection(selectedContact?.id == contact.id)
                                .onTapGesture { selectedContact = contact }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: Theme.Sidebar.minWidth,
               idealWidth: Theme.Sidebar.idealWidth,
               maxWidth: Theme.Sidebar.maxWidth)
        .warmSidebar()
    }

    // MARK: - Empty detail

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Select a contact")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Keep the detail view in sync when the list is refetched.
    private func liveContact(for contact: ContactItem) -> ContactItem? {
        vm.contacts.first(where: { $0.id == contact.id })
    }
}

// MARK: - List Row

struct ContactListRow: View {
    let contact: ContactItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconForType(contact.type))
                .font(.title3)
                .foregroundStyle(colorForType(contact.type))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .font(.body.weight(.medium))
                Text(contact.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if contact.messageCount > 0 {
                Text("\(contact.messageCount)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15), in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    func iconForType(_ type: String) -> String {
        switch type {
        case "human": return "person.fill"
        case "ai": return "cpu"
        case "service": return "server.rack"
        default: return "questionmark.circle"
        }
    }

    func colorForType(_ type: String) -> Color {
        switch type {
        case "human": return .blue
        case "ai": return .purple
        case "service": return .orange
        default: return .gray
        }
    }
}

// MARK: - Detail View

struct ContactDetailView: View {
    let contact: ContactItem
    @ObservedObject var vm: ContactViewModel
    let onDelete: () -> Void
    @State private var showEditSheet = false
    @State private var showDeleteConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contact.name)
                            .font(.title2.bold())
                        Text(contact.email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("Edit") { showEditSheet = true }
                        Button("Delete", role: .destructive) { showDeleteConfirm = true }
                    }
                }

                // Inbound-email approval toggle. Flipping this updates
                // contacts.autoAllowEmail so EmailHandler will dispatch
                // inbound messages from this sender to a worker. Unapproved
                // senders are quarantined as pending_approval and surface
                // via the [APPROVAL NEEDED] reply flow.
                Toggle(isOn: Binding(
                    get: { contact.autoAllowEmail },
                    set: { newValue in
                        Task { await vm.setEmailApproval(email: contact.email, approved: newValue) }
                    }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: contact.autoAllowEmail ? "envelope.badge.shield.half.filled" : "envelope.badge")
                            .foregroundStyle(contact.autoAllowEmail ? .green : .secondary)
                        Text(contact.autoAllowEmail ? "Approved — inbound email is dispatched" : "Unapproved — inbound email is quarantined")
                            .font(.subheadline)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                LazyVGrid(
                    columns: [
                        GridItem(.fixed(120), alignment: .trailing),
                        GridItem(.flexible(), alignment: .leading),
                    ],
                    alignment: .leading,
                    spacing: 12
                ) {
                    Text("Type").foregroundStyle(.secondary)
                    Text(contact.type.capitalized)

                    if let role = contact.role, !role.isEmpty {
                        Text("Role").foregroundStyle(.secondary)
                        Text(role.capitalized)
                    }

                    if let provider = contact.provider, !provider.isEmpty {
                        Text("Provider").foregroundStyle(.secondary)
                        Text(provider)
                    }

                    if let model = contact.model, !model.isEmpty {
                        Text("Model").foregroundStyle(.secondary)
                        Text(model)
                    }

                    Text("Messages").foregroundStyle(.secondary)
                    Text("\(contact.messageCount)")

                    if let lastContact = contact.lastContactAt {
                        Text("Last Contact").foregroundStyle(.secondary)
                        Text(lastContact, style: .relative)
                    }

                    Text("Added").foregroundStyle(.secondary)
                    Text(contact.createdAt, style: .date)
                }

                if let notes = contact.notes, !notes.isEmpty {
                    Divider()
                    Text("Notes")
                        .font(.headline)
                    Text(notes)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let prompt = contact.systemPrompt, !prompt.isEmpty {
                    Divider()
                    Text("System Prompt")
                        .font(.headline)
                    Text(prompt)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding()
        }
        .sheet(isPresented: $showEditSheet) {
            ContactEditSheet(vm: vm, contact: contact)
        }
        .alert("Delete Contact", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task {
                    await vm.delete(id: contact.id)
                    onDelete()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \(contact.name)? This cannot be undone.")
        }
    }
}

// MARK: - Add/Edit Sheet

struct ContactEditSheet: View {
    @ObservedObject var vm: ContactViewModel
    let contact: ContactItem?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var type = "human"
    @State private var role = ""
    @State private var provider = "local"   // new contacts default to local; line 512 overrides on edit
    @State private var model = ""
    @State private var systemPrompt = ""
    @State private var notes = ""
    @State private var peerKind = "invoked"   // 'invoked' (default) | 'federated'
    @State private var peerEndpoint = ""
    @State private var peerPubkey = ""
    @State private var saving = false

    var isEditing: Bool { contact != nil }
    var isValid: Bool { !name.isEmpty && !email.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit Contact" : "Add Contact")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Form {
                Section("Basic Info") {
                    TextField("Name", text: $name)
                    TextField("Email", text: $email)
                        .disabled(isEditing)
                    Picker("Type", selection: $type) {
                        Text("Human").tag("human")
                        Text("AI").tag("ai")
                        Text("Service").tag("service")
                    }
                    TextField("Role (collaborator, peer, friend)", text: $role)
                }

                if type == "ai" {
                    Section("Peer Kind") {
                        Picker("Kind", selection: $peerKind) {
                            Text("Invoked (Sona calls the model)").tag("invoked")
                            Text("Federated (peer runs itself)").tag("federated")
                        }
                        .pickerStyle(.segmented)
                        Text(peerKind == "invoked"
                            ? "Sona makes API calls on the peer's behalf using the Provider/Model/System Prompt below."
                            : "Peer runs its own Sonata + Claude Code instance. Sona communicates over the network using Endpoint and Pubkey.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if peerKind == "invoked" {
                        Section("AI Details") {
                            Picker("Provider", selection: $provider) {
                                Text("Local (Llama 3.1 8B)").tag("local")
                                Text("OpenRouter").tag("openrouter")
                                Text("OpenAI").tag("openai")
                            }
                            .onChange(of: provider) { _, newValue in
                                // Local has only one chat model right now — auto-fill
                                // the field so it's discoverable. If the user picks a
                                // hosted provider, clear it back so they can type.
                                if newValue == "local" {
                                    model = "llama-3.1-8b-instruct"
                                } else if model == "llama-3.1-8b-instruct" {
                                    model = ""
                                }
                            }

                            if provider == "local" {
                                TextField("Model", text: $model)
                                    .disabled(true)
                                Text("Local serving is single-model today. Multi-model local serving + arbitrary-GGUF download is on the roadmap.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                TextField(
                                    provider == "openrouter"
                                        ? "Model (e.g. anthropic/claude-3.5-sonnet, openai/gpt-4o)"
                                        : "Model (e.g. gpt-4o, gpt-4o-mini)",
                                    text: $model
                                )
                                Text(provider == "openrouter"
                                    ? "Requires OPENROUTER_API_KEY in environment."
                                    : "Requires OPENAI_API_KEY in environment.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("System Prompt")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextEditor(text: $systemPrompt)
                                    .font(.body.monospaced())
                                    .frame(minHeight: 100)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(.separator, lineWidth: 0.5)
                                    )
                            }
                        }
                    } else {
                        Section("Federation") {
                            TextField("Peer endpoint (e.g. 192.168.0.17:3211)", text: $peerEndpoint)
                            TextField("Peer pubkey (hex)", text: $peerPubkey)
                                .font(.body.monospaced())
                        }
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator, lineWidth: 0.5)
                        )
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let err = vm.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button(isEditing ? "Save" : "Add Contact") {
                    saving = true
                    Task {
                        // For federated peers, deliberately clear invoked-only
                        // fields. Same in reverse: an invoked peer doesn't keep
                        // a stale endpoint/pubkey.
                        let isFederated = type == "ai" && peerKind == "federated"
                        let ok = await vm.upsert(
                            name: name,
                            email: email,
                            type: type,
                            role: role.isEmpty ? nil : role,
                            provider: (type == "ai" && peerKind == "invoked" && !provider.isEmpty) ? provider : nil,
                            model: (type == "ai" && peerKind == "invoked" && !model.isEmpty) ? model : nil,
                            systemPrompt: (type == "ai" && peerKind == "invoked" && !systemPrompt.isEmpty) ? systemPrompt : nil,
                            notes: notes.isEmpty ? nil : notes,
                            peerKind: type == "ai" ? peerKind : nil,
                            peerEndpoint: isFederated && !peerEndpoint.isEmpty ? peerEndpoint : nil,
                            peerPubkey: isFederated && !peerPubkey.isEmpty ? peerPubkey : nil
                        )
                        saving = false
                        if ok { dismiss() }
                    }
                }
                .disabled(!isValid || saving)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 520, height: 620)
        .onAppear {
            if let c = contact {
                name = c.name
                email = c.email
                type = c.type
                role = c.role ?? ""
                // Default empty provider to "local" so the Picker always shows
                // a valid selection (an empty string matches no tag → blank UI).
                // Existing non-empty values pass through unchanged.
                let storedProvider = c.provider ?? ""
                provider = storedProvider.isEmpty ? "local" : storedProvider
                model = c.model ?? ""
                // If we defaulted to local AND there's no stored model, auto-fill
                // the local model name to match what the picker's onChange would do.
                if provider == "local" && model.isEmpty {
                    model = "llama-3.1-8b-instruct"
                }
                systemPrompt = c.systemPrompt ?? ""
                notes = c.notes ?? ""
                // Default to 'invoked' when the row predates v13 and has
                // no peerKind — preserves backward-compat for older AI contacts.
                peerKind = c.peerKind ?? "invoked"
            }
        }
    }
}
