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
                StudioRoomDetail(room: room, store: store)
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

