import SwiftUI

/// Settings → Sidecars panel (Phase 1). One row per sidecar registered in
/// `SidecarRegistry`, with a tier preset, a subscription cap, and an Advanced
/// disclosure for the per-request knobs.
///
/// Renders generically off the registry rather than naming any sidecar, so a
/// newly registered sidecar appears here with no UI work. The only per-sidecar
/// content in this file is the description table below, which exists because
/// `Sidecar` carries no description field.
///
/// This panel records *intent* only. Writing a tier here does not spawn, stop
/// or rotate anything — the boot-time registration path reads the stored config
/// when it constructs each `Sidecar`, and `SidecarLifecycle` acts on that.
struct SidecarsConfigView: View {
    @State private var rows: [SidecarRow] = []
    @State private var expandedAdvanced: Set<String> = []
    @State private var lastError: String? = nil

    /// Latest spend snapshot per sidecar name, or absent when the installed
    /// reader had nothing to report. Loaded asynchronously because
    /// `SidecarSpendReader` is async (the concrete tracker is an actor), so it
    /// can't be read inline while building the row.
    @State private var spend: [String: SidecarSpendSnapshot] = [:]

    /// Width of the label column inside the Advanced disclosure. Fixed so the
    /// controls of every knob line up in one column.
    private static let knobLabelWidth: CGFloat = 150

    /// One-line descriptions keyed by sidecar name.
    ///
    /// `Sidecar` is frozen Phase 0 config with no description field, so the
    /// copy lives here. A sidecar missing from this table falls back to a
    /// description built from its event types — new sidecars stay legible
    /// without a UI change, they just read less well until someone writes one.
    private static let descriptions: [String: String] = [
        "memory": "Surfaces relevant memories as hints that other sessions pick up on their next turn.",
    ]

    struct SidecarRow: Identifiable, Equatable {
        let sidecar: Sidecar
        var config: SidecarUserConfig
        var id: String { sidecar.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            description

            VStack(spacing: 0) {
                if rows.isEmpty {
                    emptyHint
                }
                ForEach(rows) { row in
                    sidecarRow(row)
                    if row.id != rows.last?.id {
                        Divider().opacity(0.3)
                    }
                }
            }
            .background(Color.black.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if !SidecarConfigStore.shared.isLoaded {
                Label(
                    "Saved sidecar settings haven't been loaded this launch. Changes persist, but what's shown may not reflect the file on disk.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Text(SidecarConfigStore.defaultPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding()
        // Both in `.task` rather than splitting `refresh()` into `.onAppear`:
        // the spend load reads `rows`, and the relative order of `onAppear` and
        // `task` isn't something to rely on.
        .task {
            refresh()
            await loadSpend()
        }
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Local sidecars that Sonata runs to enrich sessions in the background. Not selectable in chat pickers.")
                .font(.subheadline)
            Text("A sidecar is a long-lived Claude Code session that receives events by type and dispatches each to a headless agent. The preset sets how much it's allowed to spend; Advanced tunes how it works. Settings take effect on the next launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyHint: some View {
        Text("No sidecars registered.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding()
    }

    // MARK: - Row

    private func sidecarRow(_ row: SidecarRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: row.config.isEnabled ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                    .font(.caption)
                    .foregroundStyle(row.config.isEnabled ? Color.accentColor : .secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.sidecar.name)
                        .font(.system(.body, design: .default))
                    Text(Self.description(for: row.sidecar))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle(for: row))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Picker("", selection: tierBinding(row.id)) {
                    ForEach(SidecarBudgetTier.allCases, id: \.self) { tier in
                        Text(Self.label(for: tier)).tag(tier)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .help("Off doesn't spawn this sidecar at all. Higher tiers use a stronger judge and look at more context.")
            }

            HStack(spacing: 12) {
                Text("Subscription cap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(
                    value: binding(row.id, \.subscriptionCapPct),
                    in: SidecarUserConfig.Bounds.subscriptionCapPct,
                    step: 5
                ) {
                    Text("\(row.config.subscriptionCapPct)%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 40, alignment: .leading)
                }
                .help("Ceiling on this sidecar's share of subscription usage per window. It drops a tier as it approaches the cap and stops near it.")

                if let snapshot = spend[row.sidecar.name] {
                    Text("\(Self.tokens(snapshot.spentTokens)) / \(Self.tokens(snapshot.allowanceTokens)) this window · \(snapshot.percentUsed)%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(snapshot.percentUsed >= 100 ? .secondary : .tertiary)
                }

                Spacer()
            }
            .disabled(!row.config.isEnabled)

            advancedDisclosure(row)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .opacity(row.config.isEnabled ? 1 : 0.6)
    }

    /// `memory_request · haiku · top-K 10 · rotate at 70%`
    private func subtitle(for row: SidecarRow) -> String {
        var parts: [String] = []
        if !row.sidecar.eventTypes.isEmpty {
            parts.append(row.sidecar.eventTypes.joined(separator: ", "))
        }
        if row.config.isEnabled {
            parts.append(row.config.judgeModel.rawValue)
            parts.append("top-K \(row.config.topK)")
            parts.append("rotate at \(row.config.rotationThreshold)%")
        } else {
            parts.append("not spawned")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Advanced

    private func advancedDisclosure(_ row: SidecarRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expandedAdvanced.contains(row.id) {
                        expandedAdvanced.remove(row.id)
                    } else {
                        expandedAdvanced.insert(row.id)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expandedAdvanced.contains(row.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2.bold())
                    Text("Advanced")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expandedAdvanced.contains(row.id) {
                VStack(alignment: .leading, spacing: 6) {
                    knob("Judge model") {
                        Picker("", selection: binding(row.id, \.judgeModel)) {
                            ForEach(SidecarUserConfig.JudgeModel.allCases, id: \.self) { model in
                                Text(model.label).tag(model)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }

                    knob("Context depth") {
                        Picker("", selection: binding(row.id, \.contextDepth)) {
                            ForEach(SidecarUserConfig.ContextDepth.allCases, id: \.self) { depth in
                                Text(depth.label).tag(depth)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }

                    knob("Top-K") {
                        Stepper(
                            value: binding(row.id, \.topK),
                            in: SidecarUserConfig.Bounds.topK
                        ) {
                            Text("\(row.config.topK)")
                                .font(.caption.monospacedDigit())
                                .frame(width: 30, alignment: .leading)
                        }
                    }

                    knob("Triggers") {
                        HStack(spacing: 14) {
                            ForEach(SidecarUserConfig.Trigger.all, id: \.self) { trigger in
                                Toggle(
                                    SidecarUserConfig.Trigger.label(trigger),
                                    isOn: triggerBinding(row.id, trigger)
                                )
                                .toggleStyle(.checkbox)
                                .font(.caption)
                                .disabled(!Self.triggerAvailable(trigger, at: row.config.tier))
                                .help(Self.triggerHelp(trigger))
                            }
                        }
                    }

                    knob("Dedup window") {
                        Stepper(
                            value: binding(row.id, \.dedupWindow),
                            in: SidecarUserConfig.Bounds.dedupWindow,
                            step: 5
                        ) {
                            Text("\(row.config.dedupWindow) turns")
                                .font(.caption.monospacedDigit())
                                .frame(width: 70, alignment: .leading)
                        }
                        .help("How far back the sidecar remembers what it already surfaced, so the same memory isn't injected twice.")
                    }

                    knob("Rotation threshold") {
                        Picker("", selection: binding(row.id, \.rotationThreshold)) {
                            ForEach(SidecarUserConfig.rotationThresholdChoices, id: \.self) { pct in
                                Text("\(pct)%").tag(pct)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        .help("Context fullness at which the sidecar asks to be replaced by a fresh session.")
                    }
                }
                .padding(.leading, 4)
                .disabled(!row.config.isEnabled)
            }
        }
    }

    private func knob<Control: View>(
        _ label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: Self.knobLabelWidth, alignment: .leading)
            control()
            Spacer()
        }
    }

    // MARK: - Labels

    private static func label(for tier: SidecarBudgetTier) -> String {
        switch tier {
        case .off:      return "Off"
        case .low:      return "Low"
        case .standard: return "Standard"
        case .high:     return "High"
        }
    }

    private static func description(for sidecar: Sidecar) -> String {
        if let written = descriptions[sidecar.name] {
            return written
        }
        guard !sidecar.eventTypes.isEmpty else {
            return "No description."
        }
        return "Handles \(sidecar.eventTypes.joined(separator: ", ")) events."
    }

    /// Submit-refine is High-tier only, per the design spec. Mirrors the rule
    /// `SidecarUserConfig.normalized()` enforces on the stored value — this
    /// only stops the user reaching for a control that would be undone.
    private static func triggerAvailable(_ trigger: String, at tier: SidecarBudgetTier) -> Bool {
        guard tier != .off else { return false }
        if trigger == SidecarUserConfig.Trigger.submitRefine {
            return tier == .high
        }
        return true
    }

    /// Compact token count: `3.2M`, `450K`, `900`. Spend is read at a glance
    /// next to a cap, where exact digits are noise.
    private static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private static func triggerHelp(_ trigger: String) -> String {
        switch trigger {
        case SidecarUserConfig.Trigger.stopHook:
            return "Fires when an assistant turn completes, so hints are ready before the next prompt."
        case SidecarUserConfig.Trigger.submitRefine:
            return "Fires at prompt submit to refine against the actual new prompt. High tier only."
        default:
            return ""
        }
    }

    // MARK: - Bindings

    /// Binding over one field of a row's config, writing through to the store.
    ///
    /// Reads come from `rows` rather than the store so the view updates on the
    /// same tick as the write; the store is the durable copy, `rows` is what's
    /// on screen. `save` normalizes, so the value read back may differ from the
    /// one written — which is why the row is refreshed from the store after.
    private func binding<Value>(
        _ name: String,
        _ keyPath: WritableKeyPath<SidecarUserConfig, Value>
    ) -> Binding<Value> {
        Binding(
            get: { config(for: name)[keyPath: keyPath] },
            set: { newValue in
                var updated = config(for: name)
                updated[keyPath: keyPath] = newValue
                save(updated, for: name)
            }
        )
    }

    /// Tier gets its own binding because changing it can invalidate triggers —
    /// dropping out of High strips submit-refine. `normalized()` does the
    /// stripping; this just makes sure the row picks the change up.
    private func tierBinding(_ name: String) -> Binding<SidecarBudgetTier> {
        binding(name, \.tier)
    }

    private func triggerBinding(_ name: String, _ trigger: String) -> Binding<Bool> {
        Binding(
            get: { config(for: name).triggers.contains(trigger) },
            set: { isOn in
                var updated = config(for: name)
                if isOn {
                    updated.triggers.insert(trigger)
                } else {
                    updated.triggers.remove(trigger)
                }
                save(updated, for: name)
            }
        )
    }

    private func config(for name: String) -> SidecarUserConfig {
        rows.first(where: { $0.id == name })?.config ?? .default
    }

    // MARK: - Actions

    private func refresh() {
        let store = SidecarConfigStore.shared
        rows = SidecarRegistry.shared.all()
            .sorted { $0.name < $1.name }
            .map { SidecarRow(sidecar: $0, config: store.config(for: $0)) }
    }

    /// Pull a spend snapshot per sidecar from whatever reader is installed.
    ///
    /// Absent entries are the normal case, not an error: until the spend
    /// tracker installs itself the null reader answers nil for everything and
    /// no indicator is drawn. Sequential rather than concurrent — there are a
    /// handful of sidecars, and a task group would buy nothing but ordering
    /// questions.
    private func loadSpend() async {
        var loaded: [String: SidecarSpendSnapshot] = [:]
        for name in rows.map(\.sidecar.name) {
            if let snapshot = await SidecarSpendRegistry.shared.spendSnapshot(for: name) {
                loaded[name] = snapshot
            }
        }
        spend = loaded
    }

    /// Persist a config and reflect the normalized result back into the row.
    private func save(_ config: SidecarUserConfig, for name: String) {
        guard let index = rows.firstIndex(where: { $0.id == name }) else { return }
        do {
            try SidecarConfigStore.shared.setConfig(config, forName: name)
            lastError = nil
        } catch {
            // The in-memory value still updated, so the panel isn't lying about
            // the running config — only about what survives a relaunch.
            lastError = "Couldn't save sidecar settings: \(error.localizedDescription)"
        }
        rows[index].config = SidecarConfigStore.shared.config(for: rows[index].sidecar)
    }
}
