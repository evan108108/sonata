import AppKit
import Foundation
import SwiftTerm

// SwiftTerm's LocalProcessTerminalView ships text-only paste and no
// drag-and-drop registration — so dropping a file does nothing and
// pasting an image silently fails. This subclass wires both:
//
//   • Drag files / URLs / images onto the terminal → the resolved path
//     is typed into the PTY (shell-quoted, space-separated for multi-drop).
//   • ⌘V with file URLs, PNG, or TIFF on the pasteboard → same path
//     insertion. ⌘V with text falls through to SwiftTerm's existing
//     text paste.
//   • Dropped/pasted images are saved to ~/.sonata/scratch/dropped-images/
//     and the resulting file path is typed.
//
// Used by every terminal Sonata embeds (Workers, Supervisor, Live Sessions,
// Inspector windows). Inherits from LocalProcessTerminalView so existing
// `terminalView: LocalProcessTerminalView` annotations and delegate hookups
// keep working unchanged — only the instantiation sites need to flip.
//
// We deliberately do NOT synthesize Claude Code's `[Image #N]` placeholder.
// When Claude Code receives a file path on stdin it already does the right
// thing (Read tool, image attachment, etc.); doing path-insertion uniformly
// is the same outcome with less guessing about which TUI is running.

final class DropEnabledTerminalView: LocalProcessTerminalView {

    // MARK: Accepted pasteboard types

    private static let acceptedDropTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        .png,
        .tiff,
    ]

    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.acceptedDropTypes)
        observeTerminalColorChanges()
        configureMouseBehavior()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.acceptedDropTypes)
        observeTerminalColorChanges()
        configureMouseBehavior()
    }

    private func configureMouseBehavior() {
        // SwiftTerm's feedPrepare() clears the selection on EVERY output chunk
        // while this is true — with Claude Code's spinner redrawing several
        // times a second, a selection dies the instant it's made. False
        // switches SwiftTerm onto its preserve-selection-while-streaming path
        // (Terminal.app-like). Cost: mouse events are no longer forwarded to
        // TUI apps that request mouse mode; the wheel scrolls our scrollback
        // instead. Live-toggleable if a TUI ever needs the mouse back.
        allowMouseReporting = false
        _ = Self.installWheelSwizzle
    }

    // MARK: Wheel scrollback (alt-screen aware)
    //
    // SwiftTerm's scrollWheel unconditionally scrolls terminal.displayBuffer,
    // which resolves to the *alt* buffer when a full-screen TUI (Claude Code,
    // vim, htop) is active. Alt buffers have no history above the viewport, so
    // the wheel does nothing visible — the user's "can't scroll back in Sona
    // sessions" bug. Mirror SwiftTerm's own pageUp/pageDown convention: on alt-
    // screen, forward wheel deltas as PgUp/PgDn keystrokes so the TUI can walk
    // its own transcript; on primary buffer, defer to SwiftTerm to walk our
    // scrollback the normal way.
    //
    // MacTerminalView declared scrollWheel `public` (not `open`), which seals
    // it against a Swift-level override. Swizzling the ObjC method table at
    // class-load time is the pragmatic escape hatch — the original IMP is
    // captured so the primary-buffer path still gets SwiftTerm's own scroller.
    private static let installWheelSwizzle: Void = {
        let cls: AnyClass = DropEnabledTerminalView.self
        let sel = #selector(NSResponder.scrollWheel(with:))
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        typealias IMPType = @convention(c) (AnyObject, Selector, NSEvent) -> Void
        let originalIMP = unsafeBitCast(method_getImplementation(method), to: IMPType.self)
        let block: @convention(block) (DropEnabledTerminalView, NSEvent) -> Void = { instance, event in
            if event.deltaY != 0, instance.getTerminal().isCurrentBufferAlternate {
                let steps = max(1, min(6, Int(abs(event.deltaY).rounded())))
                let seq: [UInt8] = event.deltaY > 0
                    ? EscapeSequences.cmdPageUp
                    : EscapeSequences.cmdPageDown
                var payload: [UInt8] = []
                payload.reserveCapacity(seq.count * steps)
                for _ in 0..<steps { payload.append(contentsOf: seq) }
                instance.process.send(data: payload[...])
                return
            }
            originalIMP(instance, sel, event)
        }
        let newIMP = imp_implementationWithBlock(block)
        method_setImplementation(method, newIMP)
    }()

    deinit {
        NotificationCenter.default.removeObserver(self, name: .sonataTerminalColorsChanged, object: nil)
        try? scrollbackHandle?.close()
    }

    private func observeTerminalColorChanges() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTerminalColorsChanged),
            name: .sonataTerminalColorsChanged, object: nil)
    }

    @objc private func handleTerminalColorsChanged() {
        // Only terminals that opted into the themed colors re-apply (workers
        // stay on the neutral default).
        if warmColorsEnabled { applyWarmTerminalColors() }
    }

    // MARK: Scrollback capture
    //
    // When `scrollbackLogURL` is set (Terminal-kind sessions only), every byte
    // the process prints is appended to that file so the session's on-screen
    // history can be replayed after a restart. dataReceived is delivered on the
    // main queue (LocalProcess default), so this stays on the main actor.

    static let scrollbackMaxBytes = 5 * 1024 * 1024

    /// File the session's output is teed into. Set by InteractiveSessionTab for
    /// `.terminal` sessions; nil for everything else (Sona/Workers/Supervisor),
    /// which don't capture scrollback.
    var scrollbackLogURL: URL?

    private var scrollbackHandle: FileHandle?
    private var scrollbackBytes: Int = 0

    override func dataReceived(slice: ArraySlice<UInt8>) {
        appendScrollback(slice)
        super.dataReceived(slice: slice)
    }

    private func appendScrollback(_ slice: ArraySlice<UInt8>) {
        guard let url = scrollbackLogURL else { return }
        if scrollbackHandle == nil { openScrollbackHandle(url) }
        guard let handle = scrollbackHandle else { return }
        do {
            try handle.write(contentsOf: Data(slice))
            scrollbackBytes += slice.count
            if scrollbackBytes > Self.scrollbackMaxBytes { trimScrollback(url) }
        } catch {
            // Capture is best-effort; never let a logging failure disrupt the PTY.
        }
    }

    private func openScrollbackHandle(_ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        scrollbackHandle = try? FileHandle(forWritingTo: url)
        // Append after any existing content (so replay history is preserved
        // across restarts) and seed the byte counter from the current size.
        scrollbackBytes = Int((try? scrollbackHandle?.seekToEnd()) ?? 0)
    }

    /// Keep only the last half of the cap when the log grows past it, so a
    /// long-running session can't grow the file unbounded. Trimming may clip an
    /// escape sequence, which is acceptable for a replay buffer.
    private func trimScrollback(_ url: URL) {
        try? scrollbackHandle?.close()
        scrollbackHandle = nil
        if let data = try? Data(contentsOf: url) {
            let kept = data.suffix(Self.scrollbackMaxBytes / 2)
            try? kept.write(to: url)
        }
        openScrollbackHandle(url)
    }

    // MARK: Warm terminal colors (sticky)
    //
    // SwiftTerm's `setupOptions(width:height:)` resets `terminal.foregroundColor`
    // and the palette to defaults on every layout/resize, which clobbers a
    // one-shot color application. So we remember the intent and re-assert the
    // warm palette whenever the view mounts or finishes resizing.

    private var warmColorsEnabled = false

    /// Turn on the warm color treatment for this terminal and apply it now. Safe
    /// to call before the view is in a window — it'll re-assert on mount.
    func enableWarmTerminalColors() {
        warmColorsEnabled = true
        applyWarmTerminalColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-assert after the mount/layout pass (which runs setupOptions and
        // resets colors) has completed.
        if warmColorsEnabled, window != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.warmColorsEnabled else { return }
                self.applyWarmTerminalColors()
            }
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if warmColorsEnabled { applyWarmTerminalColors() }
    }

    // MARK: Drag-and-drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return acceptedDragOperation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return acceptedDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = Self.resolvePaths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        insertPaths(paths)
        return true
    }

    private func acceptedDragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Match Terminal.app / iTerm: drop reads as a copy (the file isn't
        // moved, just its path-as-text is inserted into the shell).
        return Self.resolvePaths(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    // MARK: Paste

    override func paste(_ sender: Any) {
        let pb = NSPasteboard.general

        // 1) A real file on the pasteboard → insert its FULL path. Finder's
        // Cmd-C puts both the file URL *and* the bare filename (as a string)
        // on the pasteboard, so we must check the file URL before the string
        // branch below — otherwise pasting a copied file yields just the name.
        let fileURLOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let fileURLs = pb.readObjects(forClasses: [NSURL.self], options: fileURLOptions) as? [URL],
           case let paths = fileURLs.filter({ $0.isFileURL }).map({ $0.path }),
           !paths.isEmpty {
            insertPaths(paths)
            return
        }

        // 2) Plain text (including URL-looking text) → SwiftTerm's normal text
        // paste, which already honors bracketed-paste mode.
        if pb.string(forType: .string) != nil {
            super.paste(sender)
            return
        }

        // 3) Non-file URL or raw image data → resolved path.
        let paths = Self.resolvePaths(from: pb)
        if !paths.isEmpty {
            insertPaths(paths)
            return
        }

        // 4) Nothing usable — fall through (SwiftTerm empty-paste no-op).
        super.paste(sender)
    }

    // MARK: Path resolution

    /// Pull a list of filesystem paths out of a pasteboard, ordered by how
    /// they appear in the drag/paste. Handles file URLs, http(s) URLs,
    /// and raw image data (saved to a scratch directory and the resulting
    /// path returned).
    static func resolvePaths(from pasteboard: NSPasteboard) -> [String] {
        var out: [String] = []

        // File URLs come through as NSURL instances — most reliable.
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL] {
            for url in urls where url.isFileURL {
                out.append(url.path)
            }
        }

        if !out.isEmpty { return out }

        // Non-file URL (e.g. dragged from Safari) → use the absolute string.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                out.append(url.isFileURL ? url.path : url.absoluteString)
            }
        }
        if !out.isEmpty { return out }

        // Image data on the clipboard (e.g. Cmd+Shift+Ctrl+4 screenshot to
        // clipboard, dragged image from Preview, etc.) → save to scratch.
        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            if let saved = saveImageToScratch(data: imageData,
                                              preferPng: pasteboard.data(forType: .png) != nil) {
                out.append(saved.path)
            }
        }

        return out
    }

    /// Type each path into the PTY, shell-quoted to survive spaces and
    /// special chars. Multi-path drops are space-separated, matching how
    /// macOS Terminal.app handles a multi-file drop. Public so an app-level
    /// drop catcher can forward paths here (see SessionDropCatcher).
    func insertPaths(_ paths: [String]) {
        let joined = paths.map(Self.shellQuote).joined(separator: " ")
        // Trailing space so the cursor lands ready for the next argument
        // (matches macOS Terminal.app behavior).
        let typed = joined + " "
        let bytes = Array(typed.utf8)

        // When the foreground program has bracketed-paste mode enabled (Claude
        // Code's TUI, vim, etc.), wrap the path in the paste markers so it's
        // inserted as literal text. Without this the raw bytes are read as
        // keystrokes — and a path's leading "/" opens Claude Code's slash-
        // command menu instead of dropping the path. Plain shells leave
        // bracketed paste off, so they keep getting the raw bytes as before.
        if getTerminal().bracketedPasteMode {
            var out = EscapeSequences.bracketedPasteStart
            out.append(contentsOf: bytes)
            out.append(contentsOf: EscapeSequences.bracketedPasteEnd)
            process.send(data: out[...])
        } else {
            process.send(data: bytes[...])
        }
    }

    // POSIX-shell-safe quoting: wrap in single quotes, escape any embedded
    // single quotes via the classic `'\''` trick. Works for bash, zsh, sh.
    static func shellQuote(_ path: String) -> String {
        // Fast path: no characters that need quoting → leave alone.
        let needsQuote = path.contains { ch in
            !ch.isLetter && !ch.isNumber && !"./_-".contains(ch)
        }
        if !needsQuote { return path }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: Image scratch directory

    private static func saveImageToScratch(data: Data, preferPng: Bool) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".sonata/scratch/dropped-images", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            NSLog("[DropEnabledTerminalView] failed to mkdir scratch dir: \(error)")
            return nil
        }

        // Always normalize to PNG on disk — TIFF is bulky and Claude Code's
        // image tools prefer PNG. Preview/screenshot puts PNG directly on
        // the pasteboard; clipboard from Photoshop etc. comes as TIFF and
        // we re-encode.
        let imageData: Data
        let ext: String
        if preferPng {
            imageData = data
            ext = "png"
        } else if let rep = NSBitmapImageRep(data: data),
                  let png = rep.representation(using: .png, properties: [:]) {
            imageData = png
            ext = "png"
        } else {
            imageData = data
            ext = "tiff"
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "drop-\(timestamp).\(ext)"
        let dest = dir.appendingPathComponent(filename)

        do {
            try imageData.write(to: dest)
            return dest
        } catch {
            NSLog("[DropEnabledTerminalView] failed to write \(dest.path): \(error)")
            return nil
        }
    }
}
