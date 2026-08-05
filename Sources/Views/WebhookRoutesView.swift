import SwiftUI
import AppKit

struct WebhookRoutesView: View {
    @StateObject private var vm = WebhookRoutesViewModel()
    @State private var showAddSheet = false
    @State private var editing: WebhookRouteItem?
    @State private var showingDeliveries: WebhookRouteItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Webhook Routes")
                    .font(.headline)
                Spacer()

                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Route", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if vm.routes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "link.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No webhook routes configured")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Add a route to receive third-party webhooks (GitHub, AgentMail, Stripe, …) through the 4a relay and dispatch them to an action, worker, or DM.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(vm.routes) { route in
                        WebhookRouteRow(
                            route: route,
                            stats: vm.stats[route.slug],
                            hookURL: vm.hookURL(slug: route.slug),
                            onToggle: { enabled in
                                Task { _ = await vm.setEnabled(route: route, enabled: enabled) }
                            },
                            onShowDeliveries: { showingDeliveries = route },
                            onEdit: { editing = route },
                            onDelete: {
                                Task { _ = await vm.delete(slug: route.slug) }
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
            WebhookRouteEditSheet(vm: vm, route: nil)
        }
        .sheet(item: $editing) { route in
            WebhookRouteEditSheet(vm: vm, route: route)
        }
        .sheet(item: $showingDeliveries) { route in
            WebhookDeliveryListSheet(vm: vm, route: route)
        }
        .task { await vm.fetch() }
    }
}

// MARK: - Row

private struct WebhookRouteRow: View {
    let route: WebhookRouteItem
    let stats: WebhookRouteStats?
    let hookURL: String?   // nil while the 4a plugin isn't registered yet
    let onToggle: (Bool) -> Void
    let onShowDeliveries: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirm = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { route.enabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(route.name.isEmpty ? route.slug : route.name)
                    .font(.body.weight(.medium))
                Text(route.slug)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(destinationSummary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                if let last = stats?.lastDeliveryAt {
                    Text(Self.relativeFormatter.localizedString(for: last, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Last delivery")
                } else {
                    Text("no deliveries")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let s = stats, s.deliveryCount > 0 {
                    Text("\(Int((s.verifiedRate * 100).rounded()))% verified")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(verifiedColor(s.verifiedRate).opacity(0.15), in: Capsule())
                        .foregroundStyle(verifiedColor(s.verifiedRate))
                }
            }

            Button {
                copyURL()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(hookURL == nil)
            .help(hookURL == nil ? "Waiting for 4a plugin" : "Copy webhook URL")

            Button(action: onShowDeliveries) {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(.borderless)
            .help("Recent deliveries")

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
        .alert("Delete Route", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \(route.slug)? Third parties posting to its URL will get 404s. The stored secret is not removed from the keychain.")
        }
    }

    private var destinationSummary: String {
        switch route.destKind {
        case "action": return "Action → \(route.destTarget)"
        case "worker": return "Worker → \(route.destTarget)"
        case "dm":     return "DM → \(route.destTarget)"
        case "log":    return "Log only"
        default:       return route.destKind
        }
    }

    private func verifiedColor(_ rate: Double) -> Color {
        if rate >= 0.9 { return .green }
        if rate >= 0.5 { return .orange }
        return .red
    }

    private func copyURL() {
        guard let url = hookURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

// MARK: - Add / Edit Sheet

private struct WebhookRouteEditSheet: View {
    @ObservedObject var vm: WebhookRoutesViewModel
    let route: WebhookRouteItem?   // nil = add new
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var slug = ""
    @State private var enabled = true
    @State private var authScheme = "none"
    @State private var authHeaderName = ""
    @State private var secret = ""
    @State private var destKind = "action"
    @State private var destTarget = ""
    @State private var actionFilter = ""
    @State private var promptTemplate = ""
    @State private var workerPool = ""
    @State private var dispatchFilter = ""
    @State private var actionParams = ""
    @State private var saving = false

    private var isEditing: Bool { route != nil }

    private var slugValid: Bool {
        slug.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    /// Returns nil when the form can be saved, or a short reason string
    /// that names the field blocking it. Rendered under the Save button so
    /// the user sees WHY the button is dead instead of the button just
    /// being inert with no explanation (a real UX bug earlier: five gates,
    /// zero feedback).
    private var validationError: String? {
        if name.isEmpty { return "Name is required." }
        if slug.isEmpty { return "Slug is required." }
        if !slugValid {
            return "Slug can only contain letters, digits, dashes, and underscores."
        }
        if destKind != "log" && destTarget.isEmpty {
            // Worker + promptTemplate is the sole case where destTarget is
            // genuinely unused (dispatch flows through mem_task_create with
            // the rendered template as the prompt; no workerEvents.type is
            // constructed from destTarget). Every other destKind reads the
            // field, so the check stays on for them.
            let workerWithTemplate =
                destKind == "worker" && !promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !workerWithTemplate {
                switch destKind {
                case "action": return "Pick an action to dispatch to."
                case "worker": return "Fill 'Slug (event type suffix)' — or set a Prompt template to make it optional."
                case "dm":     return "Fill 'DM target' (session id, worker id, or name)."
                default:       return "Destination target is required."
                }
            }
        }
        if authScheme == "hmacSha256" && authHeaderName.isEmpty {
            return "Signature header name is required for HMAC-SHA256 (e.g. X-Hub-Signature-256)."
        }
        // A new route with auth needs its secret up front; editing may leave
        // it blank to keep the stored one.
        if authScheme != "none" && !isEditing && secret.isEmpty {
            return "Shared secret is required for a new route with auth."
        }
        return nil
    }

    private var isValid: Bool { validationError == nil }

    private var filteredActionNames: [String] {
        let names = actionFilter.isEmpty
            ? vm.actionNames
            : vm.actionNames.filter { $0.localizedCaseInsensitiveContains(actionFilter) }
        // Keep the current selection pickable even when the filter excludes it.
        if !destTarget.isEmpty && !names.contains(destTarget) {
            return [destTarget] + names
        }
        return names
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit Route" : "Add Route")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Form {
                Section("Route") {
                    TextField("Name (e.g. GitHub — sonata repo)", text: $name)
                    TextField("Slug (e.g. github-sonata)", text: $slug)
                        .disabled(isEditing)  // slug keys the URL and the stored secret
                    if !slug.isEmpty && !slugValid {
                        Text("Slug may only contain letters, digits, hyphens, and underscores.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("The slug becomes part of the webhook URL and cannot change after creation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Enabled", isOn: $enabled)
                }

                Section("Authentication") {
                    Picker("Scheme", selection: $authScheme) {
                        Text("None").tag("none")
                        Text("Bearer token").tag("bearer")
                        Text("HMAC-SHA256").tag("hmacSha256")
                        Text("Svix (AgentMail, many others)").tag("svix")
                    }

                    if authScheme == "hmacSha256" {
                        TextField("Signature header (e.g. X-Hub-Signature-256)", text: $authHeaderName)
                    }

                    if authScheme != "none" {
                        SecureField(isEditing ? "Shared secret (leave blank to keep current)"
                                              : "Shared secret", text: $secret)
                        Text("Stored in the Secrets keychain as webhook_secret_\(slugValid ? slug : "<slug>"), never in the database.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Deliveries are accepted without verifying the sender. Prefer HMAC or a bearer token whenever the provider supports one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Destination") {
                    Picker("Dispatch to", selection: $destKind) {
                        Text("Action").tag("action")
                        Text("Worker").tag("worker")
                        Text("DM").tag("dm")
                        Text("Log only").tag("log")
                    }

                    switch destKind {
                    case "action":
                        TextField("Search actions", text: $actionFilter)
                        Picker("Action", selection: $destTarget) {
                            Text("Select an action…").tag("")
                            ForEach(filteredActionNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Action params (JSON template)")
                                .font(.subheadline)
                            TextEditor(text: $actionParams)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 90)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                            Text("JSON rendered against payload, parsed, and spread into the action's params. Example for prstar_review: {\"pr\":\"{{ body.pull_request.number }}\",\"repo\":\"{{ body.repository.full_name }}\"}. Blank → pass the raw envelope (backward compat).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case "worker":
                        TextField("Slug (event type suffix)", text: $destTarget)
                            .help("Used as workerEvents.type = webhook_<destTarget> when NO prompt template is set. Optional when a template is set — dispatch flows through mem_task_create instead.")
                        TextField("Pool hint (optional)", text: $workerPool)
                            .help("Which worker pool the dispatched task should target. Blank → dispatcher default.")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Prompt template")
                                .font(.subheadline)
                            TextEditor(text: $promptTemplate)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 100)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                            Text("Rendered against payload; result becomes the worker's prompt. Supports {{ path.to.value }} substitutions, plus {{ payload }} for the whole envelope. Objects/arrays render as fenced JSON. Blank → raw workerEvents enqueue (backward compat).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case "dm":
                        TextField("DM target (session id, worker id, or name)", text: $destTarget)
                    default:
                        Text("Deliveries are recorded in the audit log without further dispatch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Applies to all destinations that dispatch (action/worker/dm).
                    if destKind != "log" {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Dispatch filter (optional)", text: $dispatchFilter)
                                .font(.system(.body, design: .monospaced))
                            Text("Shape: <json.path>=<v1>|<v2>|<v3>. Only dispatch when the resolved payload value matches one of the allowed values. Example: body.action=opened|synchronize|reopened for GitHub PRs. Blank → always dispatch.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            VStack(alignment: .trailing, spacing: 6) {
                // Surface the failing gate right under the Save button so
                // the dead-button case reads as an actionable message
                // instead of a form that "just doesn't work".
                if let reason = validationError {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                HStack {
                    Spacer()
                    Button(isEditing ? "Save" : "Add Route") {
                        saving = true
                        Task {
                            let ok = await save()
                            saving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(!isValid || saving)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 520, height: 560)
        .onAppear {
            if let r = route {
                name = r.name
                slug = r.slug
                enabled = r.enabled
                authScheme = r.authScheme
                authHeaderName = r.authHeaderName ?? ""
                destKind = r.destKind
                destTarget = r.destTarget
                promptTemplate = r.promptTemplate ?? ""
                workerPool = r.workerPool ?? ""
                dispatchFilter = r.dispatchFilter ?? ""
                actionParams = r.actionParams ?? ""
                // Secret is never echoed back — blank means "keep the stored one".
            }
        }
    }

    private func save() async -> Bool {
        var secretRef = route?.authSecretRef
        if authScheme == "none" {
            secretRef = nil
        } else if !secret.isEmpty {
            guard await vm.saveSecret(slug: slug, secret: secret) else { return false }
            secretRef = "webhook_secret_\(slug)"
        }

        return await vm.upsert(
            name: name,
            slug: slug,
            destKind: destKind,
            destTarget: destKind == "log" ? "" : destTarget,
            authScheme: authScheme,
            authSecretRef: secretRef,
            authHeaderName: authScheme == "hmacSha256" ? authHeaderName : nil,
            promptTemplate: destKind == "worker" ? promptTemplate : nil,
            workerPool: destKind == "worker" ? workerPool : nil,
            dispatchFilter: destKind == "log" ? nil : (dispatchFilter.isEmpty ? nil : dispatchFilter),
            actionParams: destKind == "action" ? (actionParams.isEmpty ? nil : actionParams) : nil,
            enabled: enabled
        )
    }
}

// MARK: - Delivery List Sheet

private struct WebhookDeliveryListSheet: View {
    @ObservedObject var vm: WebhookRoutesViewModel
    let route: WebhookRouteItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Deliveries — \(route.name.isEmpty ? route.slug : route.name)")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if vm.deliveries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No deliveries yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(vm.deliveries) { delivery in
                            WebhookDeliveryRow(delivery: delivery)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 420)
        .task { await vm.fetchDeliveries(slug: route.slug) }
    }
}

private struct WebhookDeliveryRow: View {
    let delivery: WebhookDeliveryItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(delivery.verified ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
                .help(delivery.verified ? "Signature verified" : "Verification failed")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: delivery.receivedAt))
                        .font(.caption.weight(.medium))
                    if let ip = delivery.sourceIp, !ip.isEmpty {
                        Text(ip)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if let result = delivery.handlerResult, !result.isEmpty {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let err = delivery.error, !err.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm:ss"
        return f
    }()
}
