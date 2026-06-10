import SwiftUI

/// Settings → Anthropic Models panel. Lists every model row in the v25
/// `anthropicModels` table grouped by tier (Opus / Sonnet / Haiku / Fable),
/// with a checkbox per row that flips the `enabled` flag. The Sessions and
/// Workers model pickers observe the same store, so toggles propagate live.
///
/// "Refresh from binary" re-runs `AnthropicModelExtractor` against the user's
/// `claude` CLI. New IDs default to enabled (per Evan's rule: anything we
/// discover is on by default, the user can untick it). Existing rows keep
/// whatever the user set.
struct AnthropicModelsConfigView: View {
    @ObservedObject private var store = AnthropicModelStore.shared
    @State private var refreshing = false

    private let tierLabels: [String: String] = [
        "opus":   "Opus",
        "sonnet": "Sonnet",
        "haiku":  "Haiku",
        "fable":  "Fable",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if store.entries.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(AnthropicModelExtractor.tiers, id: \.self) { tier in
                        let rows = store.entries.filter { $0.tier == tier }
                        if !rows.isEmpty {
                            tierSection(tier: tier, rows: rows)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Extracted from the installed Claude CLI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(InteractiveSessionTab.claudeBinary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                refresh()
            } label: {
                if refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .disabled(refreshing)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No models extracted yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Click Refresh to scan the installed claude binary.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func tierSection(tier: String, rows: [AnthropicModelRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tierLabels[tier] ?? tier.capitalized)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(rows) { row in
                modelRow(row)
                Divider().padding(.leading, 32)
            }
        }
    }

    private func modelRow(_ row: AnthropicModelRow) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { row.enabled },
                set: { newValue in
                    Task { await store.setEnabled(newValue, for: row.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(row.id)
                    .font(.body.monospaced())
                HStack(spacing: 6) {
                    Text("v\(row.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if row.isDated, let date = row.releaseDate {
                        Text("· dated \(formatDate(date))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func refresh() {
        refreshing = true
        Task {
            await store.refresh(binaryPath: InteractiveSessionTab.claudeBinary)
            await MainActor.run { refreshing = false }
        }
    }

    /// "20251114" → "2025-11-14" for readability.
    private func formatDate(_ raw: String) -> String {
        guard raw.count == 8 else { return raw }
        let y = raw.prefix(4)
        let m = raw.dropFirst(4).prefix(2)
        let d = raw.dropFirst(6)
        return "\(y)-\(m)-\(d)"
    }
}
