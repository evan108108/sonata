import AppKit
import SwiftUI

/// Singleton NSWindow host for the Sonata Logs viewer. Mirrors
/// InteractiveSessionsWindowController — orderOut on close so the tailing view
/// state survives between opens.
@MainActor
final class LogsWindowController: NSObject, NSWindowDelegate {
    static let shared = LogsWindowController()

    private var window: NSWindow?

    func ensureCreated() {
        guard window == nil else { return }

        let host = NSHostingController(rootView: LogsView())
        // Without a preferredContentSize, AppKit sizes the window to the SwiftUI
        // view's intrinsic size — which is tiny on first open before any log
        // lines have rendered. Pin a sensible default so the window opens at a
        // readable size; the user can still resize freely after.
        host.preferredContentSize = NSSize(width: 1000, height: 700)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Sonata Logs"
        win.contentViewController = host
        win.setContentSize(NSSize(width: 1000, height: 700))
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        self.window = win
    }

    func show() {
        ensureCreated()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        DispatchQueue.main.async {
            sender.orderOut(nil)
        }
        return false
    }
}
