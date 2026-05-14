import Foundation
import SwiftUI

struct StudioRoomList: View {
    @ObservedObject var store: StudioStore
    @Binding var selectedRoom: StudioRoom?

    @State private var showCreateSheet: Bool = false
    @State private var showJoinSheet: Bool = false
    @State private var filterText: String = ""
    @State private var pendingAction: PendingRoomAction?
    @State private var joinToast: InlineToast?
    @State private var actionToast: InlineToast?
    /// Identifier+slug for the just-created-or-joined room. Drives the
    /// profile-picker sheet that surfaces after the create/join sheet
    /// dismisses. Non-nil ↔ picker is presented.
    @State private var pickerContext: PickerContext? = nil

    private struct PickerContext: Identifiable, Equatable {
        let id = UUID()
        let slug: String
        let title: String
    }

    /// Confirmation-dialog selector for room-level actions. Boot lives on
    /// the Members tab and is added in step 5.
    enum PendingRoomAction: Identifiable {
        case deleteLocally(StudioRoom)
        case leave(StudioRoom)
        case close(StudioRoom)
        case reopen(StudioRoom)

        var id: String {
            switch self {
            case .deleteLocally(let r): return "delete:\(r.id)"
            case .leave(let r):         return "leave:\(r.id)"
            case .close(let r):         return "close:\(r.id)"
            case .reopen(let r):        return "reopen:\(r.id)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            filterField
        }
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) { joinToastOverlay }
        .sheet(isPresented: $showCreateSheet) {
            StudioCreateRoomSheet(store: store) { slug, title in
                handleCreated(slug: slug, title: title)
            }
        }
        .sheet(isPresented: $showJoinSheet) {
            StudioJoinRoomSheet(store: store) { slug, state in
                handleJoined(slug: slug, state: state)
            }
        }
        .sheet(item: $pickerContext) { ctx in
            StudioProfilePickerSheet(
                store: store,
                roomSlug: ctx.slug,
                roomTitle: ctx.title
            )
        }
        .alert(item: $pendingAction) { action in
            actionAlert(for: action)
        }
    }

    /// Render the appropriate confirmation alert for a `PendingRoomAction`.
    /// Each case carries its own title, body, and destructive button label
    /// so the user sees consistent copy whether they trigger from the
    /// context menu or a Members-tab row.
    private func actionAlert(for action: PendingRoomAction) -> Alert {
        switch action {
        case .close(let room):
            return Alert(
                title: Text("Close '\(room.title)'?"),
                message: Text("Members will lose write access. You can reopen later."),
                primaryButton: .destructive(Text("Close room")) {
                    let target = room
                    Task { @MainActor in
                        do {
                            _ = try await store.closeRoomFederated(slug: target.slug)
                            withAnimation(.easeOut(duration: 0.2)) {
                                actionToast = InlineToast(
                                    text: "Closed '\(target.title)'.",
                                    symbol: "lock.fill",
                                    tint: .secondary
                                )
                            }
                        } catch {
                            NSLog("[StudioRoomList] closeRoom failed slug=\(target.slug): \(error)")
                            withAnimation(.easeOut(duration: 0.2)) {
                                actionToast = InlineToast(
                                    text: "Close queued — will retry when online.",
                                    symbol: "exclamationmark.arrow.circlepath",
                                    tint: .yellow
                                )
                            }
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        case .reopen(let room):
            return Alert(
                title: Text("Reopen '\(room.title)'?"),
                message: Text("Members regain write access. The room is fully functional again."),
                primaryButton: .default(Text("Reopen")) {
                    let target = room
                    Task { @MainActor in
                        do {
                            _ = try await store.reopenRoom(slug: target.slug)
                            withAnimation(.easeOut(duration: 0.2)) {
                                actionToast = InlineToast(
                                    text: "Reopened '\(target.title)'.",
                                    symbol: "lock.open.fill",
                                    tint: .green
                                )
                            }
                        } catch {
                            NSLog("[StudioRoomList] reopenRoom failed slug=\(target.slug): \(error)")
                            withAnimation(.easeOut(duration: 0.2)) {
                                actionToast = InlineToast(
                                    text: "Reopen queued — will retry when online.",
                                    symbol: "exclamationmark.arrow.circlepath",
                                    tint: .yellow
                                )
                            }
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        case .deleteLocally(let room):
            return Alert(
                title: Text("Delete '\(room.title)' locally?"),
                message: Text("Removes from this Mac only. Other members are unaffected."),
                primaryButton: .destructive(Text("Delete")) {
                    let target = room
                    Task { @MainActor in
                        do {
                            try await store.deleteRoom(slug: target.slug)
                            if selectedRoom?.id == target.id { selectedRoom = nil }
                        } catch {
                            NSLog("[StudioRoomList] deleteRoom failed slug=\(target.slug): \(error)")
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        case .leave(let room):
            return Alert(
                title: Text("Leave '\(room.title)'?"),
                message: Text("You'll keep your local copy of past content but won't see new activity. To re-join, ask the room owner for a new invite."),
                primaryButton: .destructive(Text("Leave")) {
                    let target = room
                    Task { @MainActor in
                        do {
                            _ = try await store.leaveRoom(slug: target.slug)
                            withAnimation(.easeOut(duration: 0.2)) {
                                actionToast = InlineToast(
                                    text: "Left '\(target.title)'.",
                                    symbol: "rectangle.portrait.and.arrow.right",
                                    tint: .secondary
                                )
                            }
                        } catch {
                            NSLog("[StudioRoomList] leaveRoom failed slug=\(target.slug): \(error)")
                            withAnimation(.easeOut(duration: 0.2)) {
                                actionToast = InlineToast(
                                    text: "Couldn't leave room.",
                                    symbol: "exclamationmark.triangle",
                                    tint: .red
                                )
                            }
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Rooms")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            // Hidden ⌘N captor: SwiftUI's Menu drops keyboard shortcuts on
            // its items, so the shortcut lives on a sibling 0×0 button that
            // mirrors the "New Room" action.
            Button("New Room") { showCreateSheet = true }
                .keyboardShortcut("n", modifiers: [.command])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            Menu {
                Button {
                    showCreateSheet = true
                } label: {
                    Label("New Room…", systemImage: "plus.rectangle.on.rectangle")
                }
                Button {
                    showJoinSheet = true
                } label: {
                    Label("Join Room…", systemImage: "person.crop.circle.badge.plus")
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New or Join (⌘N for New)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var joinToastOverlay: some View {
        // Single overlay slot for whichever toast is currently active. The
        // join/leave/close toasts share styling; the in-flight one always
        // pre-empts the previous one (newer action wins).
        let toast = actionToast ?? joinToast
        if let toast {
            HStack(spacing: 8) {
                Image(systemName: toast.symbol)
                    .foregroundStyle(toast.tint)
                Text(toast.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thickMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear { scheduleToastDismiss(id: toast.id) }
        }
    }

    private func handleJoined(slug: String, state: String) {
        if let room = store.rooms.first(where: { $0.slug == slug }) {
            selectedRoom = room
        }
        let toast: InlineToast
        if state == "pending-grant" {
            toast = InlineToast(
                text: "Joined room. Waiting for the owner to admit you.",
                symbol: "hourglass",
                tint: .yellow
            )
        } else {
            toast = InlineToast(
                text: "Joined!",
                symbol: "checkmark.circle.fill",
                tint: .green
            )
        }
        withAnimation(.easeOut(duration: 0.2)) {
            joinToast = toast
        }
        // Present the profile picker. For pending-grant the picker queues a
        // deferred publish that fires when the room transitions to active.
        let title = store.rooms.first(where: { $0.slug == slug })?.title ?? slug
        pickerContext = PickerContext(slug: slug, title: title)
    }

    private func handleCreated(slug: String, title: String) {
        if let room = store.rooms.first(where: { $0.slug == slug }) {
            selectedRoom = room
        }
        // Founder is already active in the room they just created, so the
        // picker publishes immediately on Save. "Skip" preserves the legacy
        // auto-publish-on-first-post behavior.
        pickerContext = PickerContext(slug: slug, title: title)
    }

    private func scheduleToastDismiss(id: UUID) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if joinToast?.id == id {
                withAnimation(.easeIn(duration: 0.2)) { joinToast = nil }
            }
            if actionToast?.id == id {
                withAnimation(.easeIn(duration: 0.2)) { actionToast = nil }
            }
        }
    }

    /// Role-aware context menu for a sidebar row. The set of items shown
    /// depends on whether the local pubkey is the founder (holds aud_id_priv)
    /// vs a member, and on the room's current state. Trailing ellipsis on
    /// each label signals "this opens a confirmation."
    @ViewBuilder
    private func roomContextMenu(for room: StudioRoom) -> some View {
        let isFounder = !room.createdByPubkey.isEmpty
            && room.createdByPubkey.lowercased() == store.currentPubkeyHex.lowercased()
        let isLeft = room.state == "left" || room.state == "removed"
        let isClosed = room.state == "closed"

        if isFounder {
            if isClosed {
                Button {
                    pendingAction = .reopen(room)
                } label: {
                    Label("Reopen room…", systemImage: "lock.open")
                }
            } else {
                Button(role: .destructive) {
                    pendingAction = .close(room)
                } label: {
                    Label("Close room…", systemImage: "lock")
                }
            }
            Divider()
        } else if !isLeft && !isClosed {
            // Members of an active room see Leave as the destructive primary.
            // Closed-room members can only read history; Leave is hidden
            // (still wired locally, but the surface here is "delete" only).
            Button(role: .destructive) {
                pendingAction = .leave(room)
            } label: {
                Label("Leave Room…", systemImage: "rectangle.portrait.and.arrow.right")
            }
            Divider()
        }
        Button(role: .destructive) {
            pendingAction = .deleteLocally(room)
        } label: {
            Label("Delete Locally…", systemImage: "trash")
        }
    }

    private var visibleRooms: [StudioRoom] {
        let trimmed = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return store.rooms }
        return store.rooms.filter { room in
            room.slug.lowercased().contains(trimmed)
                || room.title.lowercased().contains(trimmed)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(visibleRooms) { room in
                    StudioRoomRow(
                        room: room,
                        unreadCount: store.unreadCount(forRoom: room.slug),
                        isSelected: selectedRoom?.id == room.id
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedRoom = room
                        store.markRoomSeen(room.slug)
                    }
                    .contextMenu {
                        roomContextMenu(for: room)
                    }
                }
                if visibleRooms.isEmpty {
                    emptyState
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: store.rooms.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(store.rooms.isEmpty ? "No rooms yet" : "No matches")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if store.rooms.isEmpty {
                Text("Press the + button to create one.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Filter rooms…", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct StudioRoomRow: View {
    let room: StudioRoom
    let unreadCount: Int
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            stateDot
            // Lock glyph in front of the title for closed rooms — single-
            // glance signal that the row is read-only without needing to
            // open the room.
            if room.state == "closed" {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if unreadCount > 0 {
                unreadBadge
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.10)) {
                isHovering = hovering
            }
        }
        .help(rowHelp)
    }

    private var rowHelp: String {
        if room.state == "closed" { return "Closed by founder." }
        return "\(room.members.count) member\(room.members.count == 1 ? "" : "s")"
    }

    private var displayTitle: String {
        room.title.isEmpty ? room.slug : room.title
    }

    private var subtitleText: String? {
        switch room.state {
        case "pending-grant": return "joining…"
        case "left":          return "left"
        case "removed":       return "removed"
        case "closed":        return "closed"
        default:              return nil
        }
    }

    private var titleColor: Color {
        if isSelected { return Color.accentColor }
        switch room.state {
        case "pending-grant", "left", "removed", "closed":
            return .secondary
        default:
            return .primary
        }
    }

    private var stateDot: some View {
        Circle()
            .fill(stateColor)
            .frame(width: 6, height: 6)
    }

    private var stateColor: Color {
        switch room.state {
        case "active":        return .green
        case "pending-grant": return .yellow
        case "left", "removed", "closed":
            return .gray
        default:              return .secondary
        }
    }

    private var unreadBadge: some View {
        Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.accentColor, in: Capsule())
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.15)
        }
        if isHovering {
            return Color.primary.opacity(0.06)
        }
        return Color.clear
    }
}

/// Bottom-of-sidebar transient pill. Auto-dismisses 4s after appearing.
/// Lives here (not in StudioToast.swift) because the env-keyed toast client
/// is a logger passthrough today and the room-list needed something visible
/// without spinning up a renderer-wide toast surface.
struct InlineToast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let symbol: String
    let tint: Color
}

