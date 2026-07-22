import SwiftUI

/// The dynamic body of the Window ▸ Sidecars submenu.
///
/// One nested `Menu` per REGISTERED sidecar (from `SidecarRegistry.shared.all()`),
/// each carrying "Show terminal" and "Show stats" entries.
///
/// Reactivity: SwiftUI evaluates this view's body once when the `CommandGroup`
/// is first built, which is BEFORE `bootSidecars()` finishes populating the
/// registry. Reading `SidecarRegistry.shared.all()` directly in `body` would
/// therefore cache "no sidecars registered" forever — the empty-menu bug
/// hit 2026-07-22 post-deploy. Fix is a small polling `@State`: refresh the
/// snapshot every 2s, only rewrite state when it actually differs so SwiftUI
/// doesn't rebuild the whole menu on ticks that don't change anything.
///
/// Registry membership only changes at boot and (in the future) at hot-add,
/// both extremely rare, so a 2s tick is cheap enough to be invisible.
@MainActor
struct SidecarsMenuContent: View {
    /// One row per registered sidecar, snapshotted so the menu body can read
    /// both name and kind without hitting the registry lock per-item on
    /// every tick. Sorted by name for stable display order.
    private struct Row: Equatable {
        let name: String
        let kind: SidecarKind
    }

    @State private var rows: [Row] = Self.snapshot()
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if rows.isEmpty {
                Text("No sidecars registered")
            } else {
                ForEach(rows, id: \.name) { row in
                    Menu(row.name) {
                        // Terminal only exists for Claude-Code-backed sidecars.
                        // In-process sidecars run as a Swift closure — there's
                        // no NSWindow, no terminal view, nothing to show. Hide
                        // the button entirely rather than showing a disabled
                        // one; a greyed-out entry reads as "broken", but
                        // "in-process has no terminal" is by design.
                        if row.kind == .claudeCode {
                            Button("Show terminal") {
                                _ = SidecarWindowController.shared.show(name: row.name)
                            }
                        }
                        Button("Show stats") {
                            SidecarDetailWindowController.shared.show(name: row.name)
                        }
                    }
                }
            }
        }
        .onReceive(ticker) { _ in
            let latest = Self.snapshot()
            if latest != rows { rows = latest }
        }
    }

    private static func snapshot() -> [Row] {
        SidecarRegistry.shared.all()
            .map { Row(name: $0.name, kind: $0.kind) }
            .sorted { $0.name < $1.name }
    }
}
