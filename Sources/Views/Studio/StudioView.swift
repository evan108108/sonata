import Foundation
import SwiftUI
import GRDB

struct StudioView: View {
    @Environment(\.dbPool) private var dbPool: DatabasePool?
    @StateObject private var store = StudioStore()

    @State private var selectedRoom: StudioRoom?

    var body: some View {
        NavigationSplitView {
            StudioRoomList(
                store: store,
                selectedRoom: $selectedRoom
            )
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            if let room = selectedRoom {
                StudioRoomDetail(store: store, room: room)
                    .id(room.id)
            } else {
                StudioPickRoomPlaceholder()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            if let pool = dbPool {
                store.start(dbPool: pool)
            }
        }
        .onChange(of: dbPool.map(ObjectIdentifier.init)) { _, _ in
            if let pool = dbPool {
                store.start(dbPool: pool)
            }
        }
        .onDisappear {
            store.stop()
        }
    }
}

private struct StudioPickRoomPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.3.group.bubble.fill")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Pick a room")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Select a room from the sidebar, or press ⌘N to create one.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

/// T1 stub for the room detail pane. T2 (§9.2) replaces this with the real
/// `StudioRoomDetail` containing the track bar and card list. T1 just needs
/// the type to exist so `StudioView` compiles and renders a useful empty
/// state when a room is selected.
struct StudioRoomDetail: View {
    @ObservedObject var store: StudioStore
    let room: StudioRoom

    var body: some View {
        VStack(spacing: 10) {
            Text(room.title.isEmpty ? room.slug : room.title)
                .font(.system(size: 16, weight: .semibold))
            Text("Room detail arrives in T2.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("No cards yet.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            store.openRoom(room.slug)
            store.markRoomSeen(room.slug)
        }
        .onDisappear {
            store.closeRoom(room.slug)
        }
    }
}
