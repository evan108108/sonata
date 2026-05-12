// Settings → Studio → "Auto-run cards assigned to you" pane.
//
// Reads + writes the same `studio:user_profile` singleton entity that the
// plugin's auto-run hook uses (state.ts). The plugin's token-bucket and
// daily-counter writes race with these UI writes — both go through
// EntityHTTP.mergeIntoUserProfile which preserves unknown keys, so the
// renderer never clobbers per-room buckets and the plugin never clobbers
// the user's allow-list edits.
//
// Per §15 decisions:
//   - Daily cap default 50, range 0-500.
//   - Per-room bucket is read-only here (10 cards/h, 1 refill / 6 min).
//   - Founder allow-list + once/always/never decisions kept under
//     auto_run_allowed_founders + auto_run_founder_decisions.

import SwiftUI

private let kAutoRunEnabledKey = "auto_run_enabled"
private let kAutoRunMaxPerDayKey = "auto_run_max_per_day"
private let kAutoRunAllowedFoundersKey = "auto_run_allowed_founders"
private let kAutoRunFounderDecisionsKey = "auto_run_founder_decisions"
private let kAutoRunTodayCountKey = "auto_run_today_count"
private let kAutoRunTodayDateKey = "auto_run_today_date"
private let kDefaultDailyCap = 50

struct StudioAutoRunSettingsView: View {
    @State private var enabled: Bool = false
    @State private var dailyCap: Int = kDefaultDailyCap
    @State private var allowedFounders: [String] = []
    @State private var founderDecisions: [String: String] = [:]
    @State private var todayCount: Int = 0
    @State private var todayDate: String = ""
    @State private var loading: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-run cards assigned to you")
                        .font(.body)
                    Text("When enabled, Sonata will auto-run cards assigned to you from rooms you've allow-listed. Output streams as comments back to the room. Founders you trust must be added to your allow-list before their cards fire.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(loading)
                    .onChange(of: enabled) { _, newValue in
                        Task { await persistField(kAutoRunEnabledKey, newValue) }
                    }
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily cap")
                        .font(.body)
                    Text("Maximum number of cards auto-run will fire per day across every room. Resets at local midnight.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if todayCount > 0 {
                        Text("Today (\(todayDate)): \(todayCount) of \(dailyCap)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Stepper(value: $dailyCap, in: 0...500, step: 5) {
                    Text("\(dailyCap)")
                        .monospacedDigit()
                }
                .disabled(loading)
                .onChange(of: dailyCap) { _, newValue in
                    Task { await persistField(kAutoRunMaxPerDayKey, newValue) }
                }
                .frame(width: 140, alignment: .trailing)
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Per-room rate limit")
                        .font(.body)
                    Text("10 cards/hour per room (refill 1 per 6 min). Not configurable in v0.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Founder allow-list")
                            .font(.body)
                        Text("Founders whose cards auto-run will fire without prompting. Empty until you accept a consent banner with \"Always\".")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if allowedFounders.isEmpty {
                    Text("No founders allow-listed yet. The first time an eligible card arrives, a consent banner will let you allow that founder.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(allowedFounders, id: \.self) { pub in
                            HStack {
                                Text(shortPub(pub))
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                Button("Remove") { Task { await removeFounder(pub) } }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.gray.opacity(0.08))
                            .cornerRadius(6)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .onAppear { Task { await load() } }
    }

    private func shortPub(_ pub: String) -> String {
        guard pub.count > 16 else { return pub }
        let prefix = pub.prefix(8)
        let suffix = pub.suffix(8)
        return "\(prefix)…\(suffix)"
    }

    private func load() async {
        let attrs = await EntityHTTP.readUserProfileAttributes()
        let enabledLocal = (attrs[kAutoRunEnabledKey] as? Bool) ?? false
        var cap = (attrs[kAutoRunMaxPerDayKey] as? Int)
            ?? (attrs[kAutoRunMaxPerDayKey] as? Double).map { Int($0) }
            ?? kDefaultDailyCap
        cap = max(0, min(500, cap))
        let founders = (attrs[kAutoRunAllowedFoundersKey] as? [String]) ?? []
        let decisions = (attrs[kAutoRunFounderDecisionsKey] as? [String: String]) ?? [:]
        let count = (attrs[kAutoRunTodayCountKey] as? Int)
            ?? (attrs[kAutoRunTodayCountKey] as? Double).map { Int($0) }
            ?? 0
        let date = (attrs[kAutoRunTodayDateKey] as? String) ?? ""
        await MainActor.run {
            enabled = enabledLocal
            dailyCap = cap
            allowedFounders = founders.map { $0.lowercased() }
            founderDecisions = decisions
            todayCount = count
            todayDate = date
            loading = false
        }
    }

    private func persistField(_ key: String, _ value: Any) async {
        await EntityHTTP.mergeIntoUserProfile([key: value])
    }

    private func removeFounder(_ pub: String) async {
        let lower = pub.lowercased()
        let updated = allowedFounders.filter { $0 != lower }
        // Also clear any "always" decision for this founder so the next card
        // re-prompts. "never" decisions stay — those represent active refusal.
        var decisions = founderDecisions
        if decisions[lower] == "always" || decisions[lower] == "once" {
            decisions.removeValue(forKey: lower)
        }
        await EntityHTTP.mergeIntoUserProfile([
            kAutoRunAllowedFoundersKey: updated,
            kAutoRunFounderDecisionsKey: decisions,
        ])
        await MainActor.run {
            allowedFounders = updated
            founderDecisions = decisions
        }
    }
}
