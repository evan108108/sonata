import SwiftUI

/// Members tab for a Studio room: three sections, top-to-bottom.
///
///   ┌─────────────────────────────────────────────┐
///   │ Pending claims (founder only; hidden empty) │
///   ├─────────────────────────────────────────────┤
///   │ Active members                              │
///   ├─────────────────────────────────────────────┤
///   │ Removed / left members (hidden empty)       │
///   └─────────────────────────────────────────────┘
///
/// Removed-member derivation lives in `StudioStore.removedMembers(for:)`
/// (currently a no-op pending the step-7 system-event projector) — once that
/// lands, peers who were booted or left show up here automatically.
struct StudioRoomMembersView: View {
    let room: StudioRoom
    @ObservedObject var store: StudioStore

    @State private var pendingClaims: [StudioPendingClaimsResult.Pending] = []
    @State private var loadingPending: Bool = false
    @State private var pendingError: String? = nil
    @State private var bootConfirm: BootConfirm?
    @State private var bootInFlight: Set<String> = []
    @State private var bootError: String? = nil
    @State private var showInviteSheet: Bool = false

    struct BootConfirm: Identifiable {
        let id = UUID()
        let pubkey: String
        let displayName: String
    }

    private var isFounder: Bool {
        let me = store.currentPubkeyHex.lowercased()
        let creator = room.createdByPubkey.lowercased()
        return !me.isEmpty && !creator.isEmpty && me == creator
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isFounder {
                    pendingSection
                }
                activeSection
                removedSection
            }
            .padding(16)
        }
        .alert(item: $bootConfirm) { confirm in
            Alert(
                title: Text("Remove \(confirm.displayName) from '\(room.title)'?"),
                message: Text("They'll lose access to new activity. Their past contributions remain. They can re-join only via a fresh invite from you."),
                primaryButton: .destructive(Text("Remove")) {
                    Task { await performBoot(pubkey: confirm.pubkey) }
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(isPresented: $showInviteSheet) {
            StudioInviteSheet(
                store: store,
                roomSlug: room.slug,
                roomTitle: room.title
            )
        }
        .task { await loadPending() }
    }

    // MARK: - Pending

    @ViewBuilder
    private var pendingSection: some View {
        if loadingPending && pendingClaims.isEmpty {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Loading pending claims…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if !pendingClaims.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Pending claims (\(pendingClaims.count))")
                ForEach(pendingClaims) { claim in
                    pendingRow(claim)
                }
            }
        } else if let err = pendingError {
            Text("Couldn't load pending claims: \(err)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func pendingRow(_ claim: StudioPendingClaimsResult.Pending) -> some View {
        HStack(spacing: 10) {
            StudioAvatarView(store: store, pubkeyHex: claim.claimPubkey, roomSlug: room.slug, diameter: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(claim.profile?.nickname ?? Hex.npubShort(claim.claimPubkey))
                    .font(.system(size: 13, weight: .medium))
                if let bio = claim.profile?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(Hex.npubShort(claim.claimPubkey))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Admit") {
                Task { await admitAll() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(room.state == "closed")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Active

    private var activeSection: some View {
        let activeMembers = room.members
            .filter { $0.lowercased() != "" }
        return VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Active members (\(activeMembers.count))")
            ForEach(activeMembers, id: \.self) { pub in
                activeRow(pubkey: pub)
                    .padding(.vertical, 4)
            }
        }
    }

    private func activeRow(pubkey: String) -> some View {
        let isMe = pubkey.lowercased() == store.currentPubkeyHex.lowercased()
        let isFounderRow = pubkey.lowercased() == room.createdByPubkey.lowercased()
        let member = store.roomMembersList(for: room.slug)
            .first(where: { $0.pubkeyHex.lowercased() == pubkey.lowercased() })
            ?? StudioMember(rawPubkey: pubkey, roomSlug: room.slug)
        return HStack(spacing: 10) {
            StudioAvatarView(store: store, pubkeyHex: pubkey, roomSlug: room.slug, diameter: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(member.displayName)
                        .font(.system(size: 13, weight: .medium))
                    if isFounderRow {
                        Text("founder")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    if isMe {
                        Text("you")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                Text(Hex.npubShort(pubkey))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isFounder && !isMe && !isFounderRow && room.state != "closed" {
                Button(role: .destructive) {
                    bootConfirm = BootConfirm(
                        pubkey: pubkey,
                        displayName: member.displayName
                    )
                } label: {
                    if bootInFlight.contains(pubkey) {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Remove")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(bootInFlight.contains(pubkey))
            }
        }
    }

    // MARK: - Removed

    @ViewBuilder
    private var removedSection: some View {
        let removed = store.removedMembers(for: room.slug)
        if !removed.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Removed / left (\(removed.count))")
                ForEach(removed) { entry in
                    removedRow(entry)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func removedRow(_ entry: StudioStore.RemovedMemberEntry) -> some View {
        HStack(spacing: 10) {
            StudioAvatarView(
                store: store,
                pubkeyHex: entry.pubkey,
                roomSlug: room.slug,
                diameter: 28
            )
            .opacity(0.55)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(entry.kind == .left ? "left" : "removed by founder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    Text(Hex.npubShort(entry.pubkey))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if isFounder && room.state != "closed" {
                Button("Send new invite") {
                    showInviteSheet = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func loadPending() async {
        guard isFounder else { return }
        loadingPending = true
        pendingError = nil
        do {
            let res = try await store.listPendingClaims(slug: room.slug)
            await MainActor.run {
                self.pendingClaims = res.pending
                self.loadingPending = false
            }
        } catch {
            await MainActor.run {
                self.pendingError = error.localizedDescription
                self.loadingPending = false
            }
        }
    }

    private func admitAll() async {
        do {
            _ = try await store.admitRoom(slug: room.slug, maxAdmit: nil)
            await loadPending()
        } catch {
            await MainActor.run {
                pendingError = error.localizedDescription
            }
        }
    }

    private func performBoot(pubkey: String) async {
        bootInFlight.insert(pubkey)
        defer { bootInFlight.remove(pubkey) }
        do {
            _ = try await store.bootMember(slug: room.slug, memberPubkey: pubkey)
        } catch {
            await MainActor.run {
                bootError = error.localizedDescription
                NSLog("[StudioRoomMembersView] bootMember failed pubkey=\(pubkey): \(error)")
            }
        }
    }
}
