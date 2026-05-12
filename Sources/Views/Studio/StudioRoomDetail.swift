import SwiftUI

/// Main pane of the Studio tab when a room is selected. Renders header,
/// horizontal track bar, and the card list. Two `@State` values are local:
///   - `selectedTrack`: nil ↔ "all tracks"; non-nil ↔ a specific track name
///     (or the dispatch-trace sentinel — see `StudioTrackBar.dispatchTraceTag`).
///   - `showDispatchTrace`: mirrors `studio_room.attributes.dispatch_trace_on`,
///     initialized from the `room` snapshot, persisted back via
///     `store.setDispatchTraceOn(slug:_:)` on toggle.
struct StudioRoomDetail: View {
    let room: StudioRoom
    @ObservedObject var store: StudioStore

    @State private var selectedTrack: String? = nil
    @State private var showDispatchTrace: Bool = false
    @State private var selectedCard: StudioCard? = nil
    @State private var showComposeSheet: Bool = false
    /// Non-nil while the edit-mode compose sheet is presented. Distinct from
    /// `showComposeSheet` so the "+ new card" path and the pencil-edit path
    /// don't clobber each other if a user opens both in quick succession.
    @State private var editingCard: StudioCard? = nil
    @State private var showInviteSheet: Bool = false
    @State private var showProfileSheet: Bool = false
    @State private var showAdmitSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            StudioTrackBar(
                room: room,
                store: store,
                selectedTrack: $selectedTrack,
                showDispatchTrace: $showDispatchTrace
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            StudioCardList(
                room: room,
                track: selectedTrack,
                dispatchTrace: dispatchTraceActive,
                store: store,
                selectedCard: $selectedCard,
                onEditCard: { card in editingCard = card }
            )
            if let trackForCompose = effectiveTrackForCompose {
                Divider()
                StudioComposeInline(roomSlug: room.slug, trackSlug: trackForCompose)
                    .environmentObject(store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.textBackgroundColor))
        .overlay(alignment: .trailing) { drawerOverlay }
        .sheet(isPresented: $showComposeSheet) {
            if let trackForCompose = effectiveTrackForCompose {
                StudioComposeSheet(roomSlug: room.slug, trackSlug: trackForCompose)
                    .environmentObject(store)
            }
        }
        .sheet(item: $editingCard) { card in
            // Edit-mode sheet — `trackSlug` is the seed value; the picker in
            // edit mode lets the user pick a different track on save.
            StudioComposeSheet(
                roomSlug: room.slug,
                trackSlug: card.trackSlug,
                editingCard: card
            )
                .environmentObject(store)
        }
        .sheet(isPresented: $showInviteSheet) {
            StudioInviteSheet(
                store: store,
                roomSlug: room.slug,
                roomTitle: room.title
            )
        }
        .sheet(isPresented: $showProfileSheet) {
            StudioProfilePickerSheet(
                store: store,
                roomSlug: room.slug,
                roomTitle: room.title,
                forceImmediatePublish: true,
                initialPerRoomNickname: store.currentRoomNickname(for: room.slug),
                initialPerRoomAvatarPath: nil
            )
        }
        .sheet(isPresented: $showAdmitSheet) {
            StudioAdmitSheet(
                store: store,
                roomSlug: room.slug,
                roomTitle: room.title
            )
        }
        .animation(.easeOut(duration: 0.18), value: selectedCard?.eventId)
        .onChange(of: room.slug) { _, _ in selectedCard = nil }
        .onAppear {
            showDispatchTrace = room.dispatchTraceOn
            store.openRoom(room.slug)
            store.markRoomSeen(room.slug)
        }
        .onDisappear {
            store.closeRoom(room.slug)
        }
        .onChange(of: room.slug) { _, newSlug in
            store.closeRoom(room.slug)
            selectedTrack = nil
            showDispatchTrace = room.dispatchTraceOn
            store.openRoom(newSlug)
            store.markRoomSeen(newSlug)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(room.title.isEmpty ? room.slug : room.title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if room.state == "pending-grant" {
                        pendingPill
                    }
                }
                Text(memberLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            newCardButton
            settingsMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var newCardButton: some View {
        Button {
            showComposeSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(effectiveTrackForCompose == nil)
        .keyboardShortcut("n", modifiers: .command)
        .help(effectiveTrackForCompose == nil
              ? "Pick a track to compose into"
              : "New card (⌘N)")
    }

    /// Compose surfaces only render when a real track is selected — empty
    /// state ("all tracks") and the dispatch-trace pseudo-tab both suppress
    /// the strip + button, since "what track does this drop into?" has no
    /// answer in either case.
    private var effectiveTrackForCompose: String? {
        guard let t = selectedTrack else { return nil }
        if t == StudioTrackBar.dispatchTraceTag { return nil }
        return t
    }

    private var pendingPill: some View {
        Text("joining…")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.yellow.opacity(0.85), in: Capsule())
            .help("Awaiting epoch-key grant from the room founder.")
    }

    private var memberLine: String {
        let n = room.members.count
        return n == 1 ? "1 member" : "\(n) members"
    }

    /// Founder gate per task spec: `currentPubkeyHex == room.createdByPubkey`.
    /// While we don't yet know our own pubkey (e.g. plugin identity endpoint
    /// hadn't responded at launch) we suppress founder affordances entirely
    /// rather than show disabled buttons.
    private var isFounder: Bool {
        let me = store.currentPubkeyHex.lowercased()
        let creator = room.createdByPubkey.lowercased()
        return !me.isEmpty && !creator.isEmpty && me == creator
    }

    private var settingsMenu: some View {
        Menu {
            if isFounder {
                Button {
                    showInviteSheet = true
                } label: {
                    Label("Invite people…", systemImage: "person.crop.circle.badge.plus")
                }
                Button {
                    showAdmitSheet = true
                } label: {
                    Label("Admit pending member(s)…",
                          systemImage: "checkmark.seal")
                }
                Divider()
            }
            Button {
                showProfileSheet = true
            } label: {
                Label("Your profile in this room…", systemImage: "person.text.rectangle")
            }
            Divider()
            Toggle(isOn: dispatchTraceBinding) {
                Label("Show dispatch trace", systemImage: "arrow.up.right.diamond")
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(6)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Room settings")
    }

    // MARK: - Bindings

    private var dispatchTraceBinding: Binding<Bool> {
        Binding(
            get: { showDispatchTrace },
            set: { newValue in
                showDispatchTrace = newValue
                Task { await store.setDispatchTraceOn(slug: room.slug, newValue) }
                if !newValue && selectedTrack == StudioTrackBar.dispatchTraceTag {
                    selectedTrack = nil
                }
            }
        )
    }

    // MARK: - Derived

    private var dispatchTraceActive: Bool {
        showDispatchTrace && selectedTrack == StudioTrackBar.dispatchTraceTag
    }

    // MARK: - Drawer overlay

    @ViewBuilder
    private var drawerOverlay: some View {
        if let card = selectedCard, let fetcher = store.imageFetcher {
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedCard = nil }
                StudioCardDetailDrawer(
                    card: card,
                    store: store,
                    fetcher: fetcher,
                    selectedCard: $selectedCard,
                    onEnrich: { _ in /* T5 */ },
                    onOpenPR: { c in openPRLink(card: c) },
                    onAnswer: { _ in /* T5 */ },
                    onEdit: { c in editingCard = c }
                )
            }
        }
    }

    private func openPRLink(card: StudioCard) {
        for b in card.blocks {
            if case .link(let href, let label) = b,
               (label ?? "").trimmingCharacters(in: .whitespaces) == "PR",
               let url = URL(string: href),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
}
