import AppKit
import SwiftUI

// MARK: - TextBlockView

/// Markdown body. `AttributedString(markdown:)` only handles INLINE syntax on
/// macOS — block-level (headings, lists, blockquotes, fenced code) is
/// ignored. We pre-parse the text into block segments (heading, blockquote,
/// fenced code, paragraph) and render each one appropriately; inline syntax
/// inside paragraphs/headings/quotes still goes through AttributedString.
struct TextBlockView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parseBlocks(text).enumerated()), id: \.offset) { _, segment in
                render(segment)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private enum Segment {
        case heading(level: Int, text: String)
        case quote(String)
        case fence(language: String, body: String)
        case paragraph(String)
    }

    private func parseBlocks(_ source: String) -> [Segment] {
        var out: [Segment] = []
        let lines = source.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Fenced code block — opens with ``` (optionally followed by a
            // language hint). Consume until the closing ``` line (or EOF).
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var bodyLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    bodyLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // skip the closing fence
                out.append(.fence(language: language, body: bodyLines.joined(separator: "\n")))
                continue
            }
            if line.hasPrefix("### ") {
                out.append(.heading(level: 3, text: String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                out.append(.heading(level: 2, text: String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                out.append(.heading(level: 1, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("> ") {
                out.append(.quote(String(line.dropFirst(2))))
            } else {
                out.append(.paragraph(line))
            }
            i += 1
        }
        return out
    }

    @ViewBuilder
    private func render(_ segment: Segment) -> some View {
        switch segment {
        case .heading(let level, let s):
            let font: Font = (level == 1) ? .title2.bold()
                : (level == 2) ? .title3.bold()
                : .headline
            inline(s).font(font).textSelection(.enabled)
        case .quote(let s):
            HStack(spacing: 8) {
                Rectangle()
                    .frame(width: 3)
                    .foregroundStyle(.secondary.opacity(0.6))
                inline(s).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
        case .fence(let language, let body):
            CodeBlockView(language: language, code: body)
        case .paragraph(let s):
            inline(s).textSelection(.enabled)
        }
    }

    private func inline(_ s: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(s)
    }
}

// MARK: - CodeBlockView

/// Monospaced code block with hover-revealed copy button.
struct CodeBlockView: View {
    let language: String
    let code: String

    @State private var hovering: Bool = false
    @State private var copied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                if hovering {
                    Button {
                        copy()
                    } label: {
                        Label(copied ? "Copied" : "Copy",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.gray.opacity(0.18))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color.gray.opacity(0.10))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}

// MARK: - LinkBlockView

/// Clickable text. SwiftUI's `Link` is specifically designed to survive
/// parent `.onTapGesture` / List-row gestures that swallow Button clicks,
/// so the link reliably fires no matter where it's mounted (card row, card
/// drawer, comment list, audit fold). Only `http`/`https` URLs are
/// clickable; everything else degrades to plain text.
struct LinkBlockView: View {
    let href: String
    let label: String?

    var body: some View {
        if let url = Self.validURL(href) {
            Link(destination: url) {
                HStack(spacing: 4) {
                    Text(label?.isEmpty == false ? label! : href)
                        .underline()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
        } else {
            Text(label?.isEmpty == false ? label! : href)
                .foregroundStyle(.secondary)
        }
    }

    static func validURL(_ s: String) -> URL? {
        // Accept whatever the user typed. If there's a scheme, hand it to the
        // OS as-is. If there's no scheme, assume https:// — that's the right
        // default 99% of the time (typing "example.com" should be clickable).
        // macOS silently no-ops on garbage URLs, so nothing dangerous slips
        // through. Worst case the click does nothing — better than rendering
        // as gray non-clickable text.
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://" + trimmed)
    }
}

// MARK: - FieldBlockView

/// Two-column key/value row. v0 ragged-alignment per W5 R3.
struct FieldBlockView: View {
    let key: String
    let value: String

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                Text(key)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Text(value)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - ImageBlockView

/// Three states: loading, loaded, failed. The fetcher is the `StudioImageFetcher`
/// actor; `roomSlug` and `authorPubHex` come from the drawer's containing card.
struct ImageBlockView: View {
    let block: StudioImageBlock
    let room: String
    let authorPubHex: String
    let fetcher: StudioImageFetcher

    @State private var image: CGImage? = nil
    @State private var error: StudioImageError? = nil
    @State private var fullscreenOpen: Bool = false

    var body: some View {
        Group {
            if let img = image {
                Image(decorative: img, scale: 1.0, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { fullscreenOpen = true }
                    .sheet(isPresented: $fullscreenOpen) {
                        ImageFullscreen(cgImage: img, dismiss: { fullscreenOpen = false })
                    }
            } else if let err = error {
                failed(err)
            } else {
                loading
            }
        }
        .task(id: block.sha256) {
            await load()
        }
    }

    @ViewBuilder
    private var loading: some View {
        VStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("decrypting…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    @ViewBuilder
    private func failed(_ err: StudioImageError) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.fill")
                .foregroundStyle(.secondary)
            Text(Self.toastText(for: err))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func load() async {
        do {
            let cg = try await fetcher.image(
                for: block,
                room: room,
                authorPubHex: authorPubHex
            )
            await MainActor.run {
                self.image = cg
                self.error = nil
            }
        } catch let e as StudioImageError {
            await MainActor.run { self.error = e }
        } catch {
            await MainActor.run { self.error = .decodeFailed }
        }
    }

    /// Toast text from spec §13. Drawer-local strings match the global toast.
    static func toastText(for err: StudioImageError) -> String {
        switch err {
        case .allMirrorsFailed:
            return "Image unavailable on any mirror."
        case .integrityMismatch(let host):
            return "Image integrity check failed on \(host)."
        case .decryptFailed:
            return "Image cannot be decrypted (wrong epoch)."
        case .missingEpochKey(let n):
            return "Image references epoch \(n); key not yet received."
        case .decodeFailed:
            return "Image data could not be decoded."
        }
    }
}

/// Full-screen sheet. Renders the CGImage at native size, scrollable.
struct ImageFullscreen: View {
    let cgImage: CGImage
    let dismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            ScrollView([.horizontal, .vertical]) {
                Image(decorative: cgImage, scale: 1.0, orientation: .up)
                    .frame(
                        width: CGFloat(cgImage.width),
                        height: CGFloat(cgImage.height)
                    )
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(16)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

// MARK: - FileBlockView

/// Phase 5 file-attachment block view. Renders the filename + human-readable
/// size, a download button that triggers the decrypt path via
/// `StudioFileFetcher`, and (for authors) a Re-share button that re-wraps the
/// file_key to the room's current epoch so newly-admitted members can decrypt.
struct FileBlockView: View {
    let block: StudioFileBlock
    let room: String
    let authorPubHex: String
    /// True when the local user is the card's author, gating the Re-share UI.
    let canReshare: Bool
    /// Invoked when the user taps Re-share. The drawer's handler triggers the
    /// re-pick-file flow + studio_card_update path.
    var onReshare: (() -> Void)? = nil

    @Environment(\.studioToast) private var toast
    @State private var downloading: Bool = false
    @State private var lastError: String? = nil
    @State private var lastSavedPath: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: Self.icon(for: block.mimeType))
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.filename)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(Self.humanSize(block.sizeBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await runDownload() }
                } label: {
                    if downloading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Decrypting…")
                        }
                    } else {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(downloading)

                if canReshare, let cb = onReshare {
                    Button {
                        cb()
                    } label: {
                        Label("Re-share", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Re-share by picking the file again from your machine; this re-wraps the encryption key to the current room epoch.")
                }
                Spacer(minLength: 0)
            }

            if let saved = lastSavedPath {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Saved to \(saved)")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let err = lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @MainActor
    private func runDownload() async {
        downloading = true
        lastError = nil
        defer { downloading = false }
        do {
            let url = try await StudioFileFetcher.shared.download(
                block: block,
                room: room,
                authorPubHex: authorPubHex
            )
            lastSavedPath = url.path
            toast.show(severity: .info, text: "Saved \(block.filename).")
        } catch StudioFileError.userCancelled {
            // No-op: user closed the save panel.
        } catch let e as StudioFileError {
            let msg = Self.errorText(for: e)
            lastError = msg
            toast.show(severity: .error, text: msg)
        } catch {
            lastError = error.localizedDescription
            toast.show(severity: .error, text: error.localizedDescription)
        }
    }

    static func icon(for mime: String) -> String {
        let lower = mime.lowercased()
        if lower.hasPrefix("image/") { return "photo.fill" }
        if lower.hasPrefix("video/") { return "film.fill" }
        if lower.hasPrefix("audio/") { return "music.note" }
        if lower == "application/pdf" { return "doc.richtext.fill" }
        if lower == "application/zip" || lower == "application/gzip" || lower == "application/x-tar" {
            return "archivebox.fill"
        }
        if lower.hasPrefix("text/") || lower == "application/json" { return "doc.text.fill" }
        return "doc.fill"
    }

    static func humanSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func errorText(for err: StudioFileError) -> String {
        switch err {
        case .allMirrorsFailed:
            return "File unavailable on any mirror."
        case .integrityMismatch(let host):
            return "File integrity check failed on \(host)."
        case .wrappedKeyDecryptFailed:
            return "Couldn't decrypt — ask the room to re-share."
        case .fileDecryptFailed:
            return "File contents could not be decrypted."
        case .missingEpochKey(let n):
            return "File references epoch \(n); key not yet received."
        case .userCancelled:
            return ""
        case .saveFailed(let reason):
            return "Couldn't save: \(reason)"
        }
    }
}

// MARK: - UnknownBlockView

/// "Unsupported block: <type>" line; debug disclosure visible when the room's
/// `dispatchTraceOn` is true.
struct UnknownBlockView: View {
    let type: String
    let raw: [String: AnyCodableValue]
    let dispatchTraceOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Unsupported block: \(type)")
                .font(.body.italic())
                .foregroundStyle(.secondary)
            if dispatchTraceOn {
                DisclosureGroup("debug info") {
                    Text(Self.prettyJSON(raw))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.gray.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .font(.caption)
            }
        }
    }

    static func prettyJSON(_ raw: [String: AnyCodableValue]) -> String {
        struct Box: Encodable {
            let raw: [String: AnyCodableValue]
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: K.self)
                for (k, v) in raw {
                    try c.encode(v, forKey: K(stringValue: k)!)
                }
            }
            struct K: CodingKey {
                let stringValue: String
                init?(stringValue s: String) { self.stringValue = s }
                var intValue: Int? { nil }
                init?(intValue: Int) { return nil }
            }
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(Box(raw: raw)),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: raw)
    }
}

// MARK: - AnyCodableValue Encodable extension

/// `AnyCodableValue` is `Decodable` in StudioModels but not `Encodable`.
/// Pretty-printing JSON for `UnknownBlockView`'s debug disclosure needs encode;
/// added here as a renderer-local concern (W5 R4).
extension AnyCodableValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let b):   try c.encode(b)
        case .int(let i):    try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
