import SwiftUI
import SwiftTerm
import AppKit

// MARK: - NSViewRepresentable wrapper for SwiftTerm's LocalProcessTerminalView

struct SwiftTermView: NSViewRepresentable {
    let terminalInstance: LocalProcessTerminalView

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        return terminalInstance
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Nothing to update — the terminal manages its own state
    }
}

// MARK: - Terminal Container that overlays all worker terminals, showing only the selected one

struct TerminalContainerView: NSViewRepresentable {
    @EnvironmentObject var manager: WorkerManager

    final class Coordinator {
        var lastFocusedId: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Add any new terminal views
        for worker in manager.workers {
            if worker.terminalView.superview != container {
                worker.terminalView.frame = container.bounds
                worker.terminalView.autoresizingMask = [.width, .height]
                container.addSubview(worker.terminalView)
            }
        }

        // Remove terminals for workers that no longer exist
        for subview in container.subviews {
            if let termView = subview as? LocalProcessTerminalView,
               !manager.workers.contains(where: { $0.terminalView === termView }) {
                termView.removeFromSuperview()
            }
        }

        // Show only the selected worker's terminal
        for worker in manager.workers {
            worker.terminalView.isHidden = (worker.id != manager.selectedWorkerId)
        }

        // Focus the selected worker's terminal once it's unhidden + in the
        // window so typing lands immediately on worker-switch / section entry —
        // only when the selection actually changes, so we never steal focus
        // mid-use. Mirrors SessionsTerminalContainer's focus routing (doing it
        // here, after isHidden is set, is reliable; .onAppear races visibility).
        if manager.selectedWorkerId != context.coordinator.lastFocusedId {
            context.coordinator.lastFocusedId = manager.selectedWorkerId
            if let id = manager.selectedWorkerId,
               let worker = manager.workers.first(where: { $0.id == id }) {
                let view = worker.terminalView
                DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
            }
        }
    }
}
