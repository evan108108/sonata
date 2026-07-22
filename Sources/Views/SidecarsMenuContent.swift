import SwiftUI

/// The dynamic body of the Window ▸ Sidecars submenu.
///
/// One nested `Menu` per REGISTERED sidecar (from `SidecarRegistry.shared.all()`),
/// each carrying "Show terminal" and "Show stats" entries. Reading from the
/// registry (configured-and-immutable-after-boot) rather than
/// `SidecarWindowController.shared.runningNames()` (in-memory dict, no
/// observable subject) sidesteps the SwiftUI reactivity gap: the Menu body
/// wasn't re-evaluating on spawn/rotation, producing an "empty menu even though
/// the sidecar is running" bug (2026-07-22).
///
/// Semantic shift worth naming: a sidecar is a service, not a task, so "what's
/// currently spawned" is the wrong question for a menu. "What's registered in
/// this build" is what a user actually wants to click. `show(name:)` still
/// no-ops gracefully when there's no live window to bring forward.
@MainActor
struct SidecarsMenuContent: View {
    var body: some View {
        let names = SidecarRegistry.shared.all().map(\.name).sorted()
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
}
