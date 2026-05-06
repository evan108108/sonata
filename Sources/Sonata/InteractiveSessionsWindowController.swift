import AppKit
import SwiftUI

/// Singleton NSWindow host for the Interactive Sessions tabbed window. Mirror of
/// SupervisorWindowController — the window survives close events (orderOut, not
/// destroy) so subprocess tabs keep running in the background.
@MainActor
final class InteractiveSessionsWindowController: NSObject, NSWindowDelegate {
    static let shared = InteractiveSessionsWindowController()

    private var window: NSWindow?

    /// Create the window if needed. We do NOT auto-spawn a tab — the user
    /// chooses when to start their first session via the empty state CTA.
    func ensureCreated() {
        guard window == nil else { return }

        let host = NSHostingController(
            rootView: InteractiveSessionsRootView(vm: InteractiveSessionsViewModel.shared)
        )

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Interactive Sessions"
        win.contentViewController = host
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        self.window = win
    }

    func show() {
        ensureCreated()
        InteractiveSessionsViewModel.shared.restoreLastActiveIfPossible()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// True when the window exists AND is currently visible on screen.
    var isVisible: Bool {
        window?.isVisible ?? false
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        DispatchQueue.main.async {
            sender.orderOut(nil)
        }
        return false
    }
}
