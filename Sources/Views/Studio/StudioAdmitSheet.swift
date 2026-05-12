import SwiftUI

/// Founder-facing dialog that lists pending kind:30522 claims for a room and
/// lets the founder admit them (per-row or all at once). Each row shows the
/// joiner's volunteered profile preview (nickname + bio) parsed from the
/// claim content — the gateway must expose that field for the preview to
/// land; older gateways fall back to pubkey-prefix only.
///
/// Per-row deny is deliberately out of scope (per the avatar+picker brief):
/// rejecting a single claim without rotating the entire epoch isn't
/// supported by the current 4A gateway shape, so we just offer Admit / Admit
/// all. "Cancel" closes the sheet without rotating.
struct StudioAdmitSheet: View {
    @ObservedObject var store: StudioStore
    let roomSlug: String
    let roomTitle: String

    @Environment(\.dismiss) private var dismiss

    @State private var pending: [StudioPendingClaimsResult.Pending] = []
    @State private var loading: Bool = true
    @State private var loadError: String? = nil
    @State private var inFlight: Bool = false
    @State private var lastResult: AdmitOutcome? = nil

    struct AdmitOutcome {
        let admittedCount: Int
        let newEpoch: Int
        let failedCount: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520, height: 460)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .foregroundStyle(.secondary)
            Text("Pending claims for \(roomTitle)")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack { ProgressView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(.red)
                Text("Couldn't load pending claims")
                    .font(.headline)
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pending.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("No pending claims")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if let r = lastResult {
                    Text(resultLabel(r))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(pending) { claim in
                        pendingRow(claim)
                        Divider()
                    }
                }
            }
        }
    }

    private func pendingRow(_ claim: StudioPendingClaimsResult.Pending) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: claim))
                    .font(.system(size: 13, weight: .medium))
                if let bio = claim.profile?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Text(pubkeyPrefix(claim.claimPubkey))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func displayName(for claim: StudioPendingClaimsResult.Pending) -> String {
        if let nick = claim.profile?.nickname, !nick.isEmpty {
            return nick
        }
        return "Anonymous · \(pubkeyPrefix(claim.claimPubkey))"
    }

    private func pubkeyPrefix(_ hex: String) -> String {
        let lower = hex.lowercased()
        guard lower.count >= 16 else { return lower }
        return String(lower.prefix(8)) + "…" + String(lower.suffix(4))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(inFlight)
            Button {
                Task { await admitAll() }
            } label: {
                HStack(spacing: 6) {
                    if inFlight { ProgressView().controlSize(.small) }
                    Text(inFlight ? "Admitting…" : "Admit all")
                }
                .frame(minWidth: 90)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(inFlight || pending.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func resultLabel(_ r: AdmitOutcome) -> String {
        let base = "Admitted \(r.admittedCount) — epoch \(r.newEpoch)"
        if r.failedCount > 0 {
            return base + " (\(r.failedCount) failed)"
        }
        return base
    }

    // MARK: - Network

    private func load() async {
        loading = true
        loadError = nil
        do {
            let res = try await store.listPendingClaims(slug: roomSlug)
            await MainActor.run {
                pending = res.pending
                loading = false
            }
        } catch let err as StudioPluginError {
            await MainActor.run {
                loadError = err.message
                loading = false
            }
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
                loading = false
            }
        }
    }

    private func admitAll() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        do {
            let res = try await store.admitRoom(slug: roomSlug, maxAdmit: nil)
            await MainActor.run {
                lastResult = AdmitOutcome(
                    admittedCount: res.admitted.count,
                    newEpoch: res.newEpoch,
                    failedCount: res.failed?.count ?? 0
                )
                pending = []
            }
        } catch let err as StudioPluginError {
            await MainActor.run { loadError = err.message }
        } catch {
            await MainActor.run { loadError = error.localizedDescription }
        }
    }
}
