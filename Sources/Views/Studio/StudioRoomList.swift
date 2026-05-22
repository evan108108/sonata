import Foundation
import SwiftUI

struct StudioRoomList: View {
    @ObservedObject var store: StudioStore
    @Binding var selectedRoom: StudioRoom?

    @State private var showCreateSheet: Bool = false
    @State private var showJoinSheet: Bool = false
    @State private var filterText: String = ""
    @State private var roomPendingDelete: StudioRoom?
    @State private var showDeleteAlert: Bool = false
    @State private var joinToast: InlineToast?
    /// Identifier+slug for the just-created-or-joined room. Drives the
    /// profile-picker sheet that surfaces after the create/join sheet
    /// dismisses. Non-nil ↔ picker is presented.
    @State private var pickerContext: PickerContext? = nil

    private struct PickerContext: Identifiable, Equatable {
        let id = UUID()
        let slug: String
        let title: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            filterField
        }
        // Don't paint a system-gray background — the parent NavigationSplitView
        // sidebar applies `.warmSidebar()` which fills with the warm chrome
        // token + texture. A hardcoded color here would clobber it.
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
        .alert(
            "Delete '\(roomPendingDelete?.title ?? "")'?",
            isPresented: $showDeleteAlert,
            presenting: roomPendingDelete
        ) { room in
            Button("Cancel", role: .cancel) {
                roomPendingDelete = nil
            }
            Button("Delete", role: .destructive) {
                let target = room
                Task { @MainActor in
                    do {
                        try await store.deleteRoom(slug: target.slug)
                        if selectedRoom?.id == target.id { selectedRoom = nil }
                    } catch {
                        NSLog("[StudioRoomList] deleteRoom failed slug=\(target.slug): \(error)")
                    }
                    roomPendingDelete = nil
                }
            }
        } message: { _ in
            Text("Removes the local copy and its keys. Other members keep their copies.")
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
                    .foregroundStyle(Theme.Color.selectionAccent)
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
        if let toast = joinToast {
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
                        Button(role: .destructive) {
                            roomPendingDelete = room
                            showDeleteAlert = true
                        } label: {
                            Label("Delete Room", systemImage: "trash")
                        }
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
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isSelected ? Theme.Color.selectionAccent.opacity(0.55) : Color.clear,
                        lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.10)) {
                isHovering = hovering
            }
        }
        .help("\(room.members.count) member\(room.members.count == 1 ? "" : "s")")
    }

    private var displayTitle: String {
        room.title.isEmpty ? room.slug : room.title
    }

    private var subtitleText: String? {
        if room.state == "pending-grant" {
            return "joining…"
        }
        return nil
    }

    private var titleColor: Color {
        if room.state == "pending-grant" { return .secondary }
        return .primary
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
        case "left":          return .secondary
        default:              return .secondary
        }
    }

    private var unreadBadge: some View {
        Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Theme.Color.selectionAccent, in: Capsule())
    }

    private var rowBackground: Color {
        if isSelected {
            return Theme.Color.selectionTint
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

