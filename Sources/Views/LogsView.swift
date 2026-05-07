import SwiftUI
import AppKit

/// Live-streaming view of ~/Library/Logs/Sonata.log. Reads the existing tail on
/// open, then polls for appended bytes and renders into a monospaced text view.
/// Caps memory by trimming to the last MAX_LINES lines. Auto-scrolls to the
/// bottom unless the user has scrolled away from the bottom.
struct LogsView: View {
    @StateObject private var tail = LogTail(
        url: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Sonata.log")
    )

    var body: some View {
        content
            // Belt-and-suspenders sizing: the hosting controller pins a 1000×700
            // preferredContentSize, but advertise a min size on the SwiftUI side
            // too so resize gestures can't collapse the window into uselessness.
            .frame(minWidth: 720, minHeight: 480)
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(tail.url.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Toggle("Auto-scroll", isOn: $tail.autoScrollEnabled)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                Button("Clear View") { tail.clearView() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            LogTextScroll(text: tail.text, scrollTrigger: tail.scrollTrigger, autoScroll: $tail.autoScrollEnabled)
        }
        .onAppear { tail.start() }
        .onDisappear { tail.stop() }
    }
}

/// NSTextView-backed scroller. We avoid SwiftUI's TextEditor because it
/// re-lays-out the whole document on every append, which gets expensive once
/// the log is a few hundred KB.
private struct LogTextScroll: NSViewRepresentable {
    let text: String
    let scrollTrigger: Int
    @Binding var autoScroll: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.string = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false

        // Watch user scroll to flip autoScroll off when they scroll up.
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { _ in
            let clip = scroll.contentView
            let docHeight = clip.documentRect.height
            let visibleMax = clip.bounds.origin.y + clip.bounds.height
            let nearBottom = (docHeight - visibleMax) < 24
            if !nearBottom && autoScroll {
                autoScroll = false
            } else if nearBottom && !autoScroll {
                autoScroll = true
            }
        }
        scroll.contentView.postsBoundsChangedNotifications = true

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
        }
        if autoScroll {
            // Defer to the next runloop turn so layout settles before we scroll.
            DispatchQueue.main.async {
                tv.scrollToEndOfDocument(nil)
            }
        }
        _ = scrollTrigger
    }
}

@MainActor
final class LogTail: ObservableObject {
    let url: URL
    @Published var text: String = ""
    @Published var autoScrollEnabled: Bool = true
    @Published var scrollTrigger: Int = 0

    private static let maxLines = 5000
    private static let initialTailBytes = 256 * 1024

    private var handle: FileHandle?
    private var pollTimer: Timer?
    private var lastSize: UInt64 = 0
    private var started = false

    init(url: URL) {
        self.url = url
    }

    func start() {
        guard !started else { return }
        started = true
        loadInitialTail()
        openHandle()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        try? handle?.close()
        handle = nil
        started = false
    }

    func clearView() {
        text = ""
        scrollTrigger &+= 1
    }

    private func loadInitialTail() {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            text = "(log file not yet created at \(url.path))\n"
            return
        }
        let slice: Data
        if data.count > Self.initialTailBytes {
            slice = data.suffix(Self.initialTailBytes)
        } else {
            slice = data
        }
        let str = String(data: slice, encoding: .utf8) ?? ""
        text = trimToMaxLines(str)
        lastSize = UInt64(data.count)
        scrollTrigger &+= 1
    }

    private func openHandle() {
        do {
            let h = try FileHandle(forReadingFrom: url)
            try h.seek(toOffset: lastSize)
            handle = h
        } catch {
            handle = nil
        }
    }

    private func poll() {
        // Reopen if the file was rotated/truncated.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let currentSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        if currentSize < lastSize {
            try? handle?.close()
            handle = nil
            lastSize = 0
            text = ""
            openHandle()
        } else if handle == nil {
            openHandle()
        }

        guard let h = handle else { return }
        let data = h.availableData
        if data.isEmpty { return }
        lastSize += UInt64(data.count)
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        text = trimToMaxLines(text + chunk)
        scrollTrigger &+= 1
    }

    private func trimToMaxLines(_ s: String) -> String {
        // Cheap line-cap: count newlines; if over the cap, drop the prefix.
        let newlineCount = s.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        guard newlineCount > Self.maxLines else { return s }
        var keep = newlineCount - Self.maxLines
        var idx = s.startIndex
        while keep > 0, idx < s.endIndex {
            if s[idx] == "\n" { keep -= 1 }
            idx = s.index(after: idx)
        }
        return String(s[idx...])
    }
}
