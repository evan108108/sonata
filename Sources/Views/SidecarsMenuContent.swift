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
    @State private var names: [String] = SidecarRegistry.shared.all().map(\.name).sorted()
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if names.isEmpty {
                Text("No sidecars registered")
            } else {
                ForEach(names, id: \.self) { name in
                    Menu(name) {
                        Button("Show terminal") {
                            _ = SidecarWindowController.shared.show(name: name)
                        }
                        Button("Show stats") {
                            SidecarDetailWindowController.shared.show(name: name)
                        }
                    }
                }
            }
        }
        .onReceive(ticker) { _ in
            let latest = SidecarRegistry.shared.all().map(\.name).sorted()
            if latest != names { names = latest }
        }
    }
}
