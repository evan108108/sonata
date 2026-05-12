import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Modal compose sheet — full-form card post. Per W6.2.
///
/// Posts on Cmd+↩ or Post-button click. On success the sheet dismisses; on
/// failure the sheet stays open with `formError` populated for an inline
/// error band — per spec §13's "sheet preserved" retry semantics.
struct StudioComposeSheet: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.studioToast) private var toast
    @Environment(\.dismiss) private var dismiss

    let roomSlug: String
    let trackSlug: String
    /// When non-nil the sheet runs in edit mode: fields pre-populate from this
    /// card, the submit button reads "Save", the cancel-discard copy changes,
    /// and submit routes through `store.updateCard` instead of `postCard`.
    var editingCard: StudioCard? = nil

    @State private var kind: CardKind = .note
    @State private var title: String = ""
    @State private var summary: String = ""
    @State private var blocks: [BlockDraft] = []
    @State private var tagsRaw: String = ""
    /// In edit mode, the effective track is editable — the field is set
    /// from `editingCard.trackSlug` on appear and patched by the user via a
    /// picker. In new-card mode it's pinned to the parent's `trackSlug` so
    /// the sheet's existing semantics don't change.
    @State private var editingTrackSlug: String = ""
    /// Blocks the renderer cannot reconstruct via the BlockDraft editor
    /// (currently: `.unknown(...)`). Preserved verbatim so a save doesn't
    /// silently drop forward-compatible payload shapes.
    @State private var passthroughBlocks: [[String: Any]] = []
    /// Snapshot taken on appear so we can diff against the live form state
    /// to detect "any unsaved changes" for the cancel-discard prompt.
    @State private var initialSnapshot: FormSnapshot? = nil

    @State private var posting: Bool = false
    @State private var formError: String? = nil
    @State private var didLoadEditingCard: Bool = false

    private var isEditMode: Bool { editingCard != nil }
    private var effectiveTrack: String {
        isEditMode ? editingTrackSlug : trackSlug
    }

    enum CardKind: String, CaseIterable, Identifiable {
        case note, lead, review, task, question, answer
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .note:     return "note.text"
            case .lead:     return "person.crop.rectangle.badge.plus"
            case .review:   return "checkmark.seal"
            case .task:     return "checklist"
            case .question: return "questionmark.bubble"
            case .answer:   return "text.bubble.fill"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    kindRow
                    if isEditMode { trackRow }
                    titleRow
                    summaryRow
                    blocksSection
                    tagsRow
                }
                .padding(.horizontal, 20)
            }

            if let formError {
                errorBand(formError)
            }

            footer
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 640)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear(perform: loadEditingCardIfNeeded)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text(isEditMode
                 ? "Edit card in #\(effectiveTrack)"
                 : "New card in #\(trackSlug)")
                .font(.headline)
            Spacer()
            Button("Cancel") { cancel() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    /// Edit-mode-only: lets the author move the card between tracks. The list
    /// of available tracks comes from `store.tracks[roomSlug]`; the current
    /// track is always included so a card in an auto-created/forgotten track
    /// still has a representable selection.
    private var trackRow: some View {
        let candidates = availableTrackSlugs
        return HStack(spacing: 12) {
            Text("Track")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Picker("", selection: $editingTrackSlug) {
                ForEach(candidates, id: \.self) { slug in
                    Text("#\(slug)").tag(slug)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var availableTrackSlugs: [String] {
        var set = Set<String>()
        for t in store.tracks[roomSlug] ?? [] { set.insert(t.name) }
        if !editingTrackSlug.isEmpty { set.insert(editingTrackSlug) }
        if let card = editingCard, !card.trackSlug.isEmpty { set.insert(card.trackSlug) }
        return set.sorted()
    }

    private var kindRow: some View {
        HStack(spacing: 12) {
            Text("Kind")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Picker("", selection: $kind) {
                ForEach(CardKind.allCases) { k in
                    Label(k.label, systemImage: k.symbol).tag(k)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Title")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                TextField("Required (1-200 chars)", text: $title)
                    .textFieldStyle(.roundedBorder)
                Text("\(title.count) / 200")
                    .font(.caption2)
                    .foregroundStyle(title.count > 200 ? .red : .secondary)
            }
        }
    }

    private var summaryRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Summary")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                TextField("Required (1-240 chars)", text: $summary)
                    .textFieldStyle(.roundedBorder)
                Text("\(summary.count) / 240")
                    .font(.caption2)
                    .foregroundStyle(summary.count > 240 ? .red : .secondary)
            }
        }
    }

    private var blocksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Blocks")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    blocks.append(BlockDraft())
                } label: {
                    Label("Add block", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("b", modifiers: .command)
            }
            ForEach($blocks) { $row in
                BlockEditorRow(draft: $row, roomSlug: roomSlug) {
                    let id = row.id
                    blocks.removeAll { $0.id == id }
                }
            }
        }
    }

    private var tagsRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Tags")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            TextField("Comma-separated (parsed on submit)", text: $tagsRaw)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func errorBand(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(msg)
                .font(.callout)
                .foregroundStyle(.red)
            Spacer()
        }
        .padding(10)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 20)
    }

    private var footer: some View {
        HStack {
            if posting {
                ProgressView().controlSize(.small)
                Text(isEditMode ? "Saving…" : "Posting…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                submit()
            } label: {
                Text(isEditMode ? "Save" : "Post")
                    .frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!isValid || posting)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Validation

    var isValid: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleOK   = (1...200).contains(t.count)
        let summaryOK = (1...240).contains(s.count)
        let blocksOK  = blocks.allSatisfy { $0.isValid }
        return titleOK && summaryOK && blocksOK
    }

    var parsedTags: [String] {
        tagsRaw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Submit / cancel

    private func submit() {
        guard isValid, !posting else { return }
        if isEditMode { submitEdit() } else { submitNew() }
    }

    private func submitNew() {
        let clientId = UUID().uuidString
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let blockPayload = blocks.map { $0.toPayload() }
        let tagsParsed = parsedTags
        let cardKindRaw = kind.rawValue
        let roomCapture = roomSlug
        let trackCapture = trackSlug

        formError = nil
        posting = true

        store.optimisticallyInsertCard(
            clientId: clientId,
            roomSlug: roomCapture,
            trackSlug: trackCapture,
            kind: cardKindRaw,
            title: trimmedTitle,
            summary: trimmedSummary,
            blocks: blockPayload,
            tagsList: tagsParsed,
            relatedTo: []
        )

        Task { @MainActor in
            defer { posting = false }
            do {
                let eventId = try await store.postCard(
                    room: roomCapture,
                    track: trackCapture,
                    kind: cardKindRaw,
                    title: trimmedTitle,
                    summary: trimmedSummary,
                    blocks: blockPayload,
                    relatedTo: [],
                    tagsList: tagsParsed,
                    dTag: nil
                )
                store.setOptimisticEventId(clientId: clientId, eventId: eventId)
                dismiss()
            } catch {
                store.rollbackOptimisticCard(clientId: clientId)
                formError = error.localizedDescription
                toast.show(
                    severity: .error,
                    text: "Post failed; reverted. \(error.localizedDescription)"
                )
            }
        }
    }

    private func submitEdit() {
        guard let card = editingCard else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let editableBlockPayload = blocks.map { $0.toPayload() }
        // Unknown blocks the editor can't represent are preserved verbatim so
        // forward-compatible payloads survive a round trip through edit mode.
        let blockPayload = editableBlockPayload + passthroughBlocks
        let tagsParsed = parsedTags
        let cardKindRaw = kind.rawValue
        let trackCapture = editingTrackSlug

        formError = nil
        posting = true

        Task { @MainActor in
            defer { posting = false }
            do {
                _ = try await store.updateCard(
                    roomSlug: card.roomSlug,
                    dTag: card.dTag,
                    eventId: card.eventId,
                    track: trackCapture,
                    kind: cardKindRaw,
                    title: trimmedTitle,
                    summary: trimmedSummary,
                    blocks: blockPayload,
                    tagsList: tagsParsed,
                    relatedTo: card.relatedTo
                )
                dismiss()
            } catch {
                // Optimistic patch is rolled back inside store.updateCard on
                // failure; surface the error here for the user.
                formError = error.localizedDescription
                toast.show(
                    severity: .error,
                    text: "Save failed; reverted. \(error.localizedDescription)"
                )
            }
        }
    }

    private func cancel() {
        let dirty = dirtyAgainstSnapshot
        if dirty {
            let alert = NSAlert()
            alert.messageText = isEditMode ? "Discard changes?" : "Discard this draft?"
            alert.informativeText = isEditMode
                ? "Your edits won't be saved."
                : "Your in-progress card will be lost."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Keep editing")
            if alert.runModal() == .alertFirstButtonReturn {
                dismiss()
            }
        } else {
            dismiss()
        }
    }

    /// True if any field has diverged from the pre-edit snapshot (edit mode)
    /// or from the empty-form baseline (new-card mode). The snapshot is
    /// taken on appear so block-only edits also trip the prompt.
    private var dirtyAgainstSnapshot: Bool {
        let now = FormSnapshot(
            kind: kind, title: title, summary: summary, tagsRaw: tagsRaw,
            track: effectiveTrack, blocks: blocks
        )
        if let snap = initialSnapshot { return snap != now }
        // No snapshot yet (shouldn't happen if onAppear ran) — fall back to
        // the heuristic dirty check.
        return !title.isEmpty || !summary.isEmpty || !blocks.isEmpty || !tagsRaw.isEmpty
    }

    // MARK: - Edit-mode pre-population

    private func loadEditingCardIfNeeded() {
        guard !didLoadEditingCard else { return }
        didLoadEditingCard = true
        guard let card = editingCard else {
            // Snapshot the empty form so cancel works consistently for new-card.
            initialSnapshot = FormSnapshot(
                kind: kind, title: title, summary: summary, tagsRaw: tagsRaw,
                track: trackSlug, blocks: blocks
            )
            return
        }
        if let k = CardKind(rawValue: card.cardKind ?? "") { kind = k }
        title = card.title
        summary = card.summary
        tagsRaw = card.tagsList.joined(separator: ", ")
        editingTrackSlug = card.trackSlug

        var drafts: [BlockDraft] = []
        var passthrough: [[String: Any]] = []
        for b in card.blocks {
            switch b {
            case .text(let body):
                var d = BlockDraft()
                d.kind = .text
                d.body = body
                drafts.append(d)
            case .code(let lang, let body):
                var d = BlockDraft()
                d.kind = .code
                d.language = lang
                d.body = body
                drafts.append(d)
            case .link(let href, let label):
                var d = BlockDraft()
                d.kind = .link
                d.href = href
                d.linkLabel = label ?? ""
                drafts.append(d)
            case .field(let key, let value):
                var d = BlockDraft()
                d.kind = .field
                d.fieldKey = key
                d.fieldValue = value
                drafts.append(d)
            case .image(let img):
                var d = BlockDraft()
                d.kind = .image
                let dict: [String: Any] = [
                    "type": "image",
                    "sha256": img.sha256,
                    "mirrors": img.mirrors,
                    "decrypt_hint": [
                        "kind": img.decryptHint.kind,
                        "epoch_n": img.decryptHint.epochN,
                    ],
                    "mime_type": img.mimeType,
                    "blake3": img.blake3,
                ]
                d.imageBlockRaw = dict
                d.imageBlock = dict.compactMapValues { $0 as? String }
                drafts.append(d)
            case .unknown(let type, _):
                // We can't reconstruct an editor for unknown shapes — preserve
                // them verbatim. The original JSON dict isn't available here
                // (the projection decoded into AnyCodableValue), so we serialize
                // the typed view back out into a dict via JSONEncoder fallback.
                if let dict = unknownBlockAsDict(type: type, raw: b) {
                    passthrough.append(dict)
                }
            }
        }
        blocks = drafts
        passthroughBlocks = passthrough
        initialSnapshot = FormSnapshot(
            kind: kind, title: title, summary: summary, tagsRaw: tagsRaw,
            track: editingTrackSlug, blocks: blocks
        )
    }

    /// Best-effort serialization of an unknown block back to a `[String: Any]`
    /// dict suitable for replay through `studio_card_update`. Returns nil if
    /// the typed view can't be re-encoded (very rare).
    private func unknownBlockAsDict(type: String, raw: StudioBlock) -> [String: Any]? {
        // Round-trip via JSONEncoder/Decoder: encode the StudioBlock to JSON,
        // re-decode it as a generic dict. The StudioBlock enum doesn't conform
        // to Encodable, so re-emit the unknown via its parts. For v0 we only
        // know `type`; values are lost across the typed boundary. Preserve at
        // least the type so the projector keeps a placeholder.
        return ["type": type]
    }
}

private struct FormSnapshot: Equatable {
    let kind: StudioComposeSheet.CardKind
    let title: String
    let summary: String
    let tagsRaw: String
    let track: String
    let blocks: [BlockDraft]
}

// MARK: - BlockDraft (in-flight editor state)

/// Mutable per-row state for the blocks editor. Converts to the plugin
/// payload shape via `toPayload()`. Image rows hold their fully-resolved
/// block JSON in `imageBlock` once the `studio_image_attach` call returns;
/// `isValid` only flips true once that has happened.
struct BlockDraft: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case text, code, link, field, image
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    let id: UUID = UUID()
    var kind: Kind = .text

    // text / code body
    var body: String = ""

    // code language
    var language: String = ""

    // link
    var href: String = ""
    var linkLabel: String = ""

    // field
    var fieldKey: String = ""
    var fieldValue: String = ""

    // image — populated by studio_image_attach response
    var imageBlock: [String: String]? = nil   // serialized JSON kept as string map for Equatable
    var imageBlockRaw: [String: Any]? = nil   // live dict used for payload assembly
    var imagePath: String? = nil
    var imageError: String? = nil

    var isValid: Bool {
        switch kind {
        case .text:
            return !body.trimmingCharacters(in: .whitespaces).isEmpty
        case .code:
            return !body.isEmpty
        case .link:
            return !href.trimmingCharacters(in: .whitespaces).isEmpty
        case .field:
            let k = fieldKey.trimmingCharacters(in: .whitespaces)
            let v = fieldValue.trimmingCharacters(in: .whitespaces)
            return !k.isEmpty && !v.isEmpty
        case .image:
            return imageBlockRaw != nil
        }
    }

    func toPayload() -> [String: Any] {
        switch kind {
        case .text:
            return ["type": "text", "body": body]
        case .code:
            return ["type": "code", "language": language, "body": body]
        case .link:
            var p: [String: Any] = ["type": "link", "href": href]
            if !linkLabel.isEmpty { p["label"] = linkLabel }
            return p
        case .field:
            return ["type": "field", "key": fieldKey, "value": fieldValue]
        case .image:
            return imageBlockRaw ?? ["type": "image"]
        }
    }

    static func == (lhs: BlockDraft, rhs: BlockDraft) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.body == rhs.body
            && lhs.language == rhs.language
            && lhs.href == rhs.href
            && lhs.linkLabel == rhs.linkLabel
            && lhs.fieldKey == rhs.fieldKey
            && lhs.fieldValue == rhs.fieldValue
            && lhs.imageBlock == rhs.imageBlock
            && lhs.imagePath == rhs.imagePath
            && lhs.imageError == rhs.imageError
    }
}

// MARK: - BlockEditorRow

/// Per-row editor sub-view. Private to this file — see W6.2 R4.
private struct BlockEditorRow: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.studioToast) private var toast

    @Binding var draft: BlockDraft
    let roomSlug: String
    let onRemove: () -> Void

    @State private var attaching: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $draft.kind) {
                    ForEach(BlockDraft.Kind.allCases) { k in
                        Text(k.label).tag(k)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 110)
                .labelsHidden()

                Spacer()

                Button(role: .destructive) { onRemove() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }

            content
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var content: some View {
        switch draft.kind {
        case .text:
            TextEditor(text: $draft.body)
                .frame(minHeight: 64)
                .font(.body)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)))
        case .code:
            VStack(spacing: 6) {
                TextField("Language (e.g. swift, ts)", text: $draft.language)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $draft.body)
                    .frame(minHeight: 96)
                    .font(.system(.body, design: .monospaced))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)))
            }
        case .link:
            VStack(spacing: 6) {
                TextField("https://…", text: $draft.href)
                    .textFieldStyle(.roundedBorder)
                TextField("Optional label", text: $draft.linkLabel)
                    .textFieldStyle(.roundedBorder)
            }
        case .field:
            HStack(spacing: 6) {
                TextField("Key", text: $draft.fieldKey)
                    .textFieldStyle(.roundedBorder)
                TextField("Value", text: $draft.fieldValue)
                    .textFieldStyle(.roundedBorder)
            }
        case .image:
            imageRow
        }
    }

    private var imageRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    pickFile()
                } label: {
                    Label(draft.imageBlockRaw == nil ? "Attach image…" : "Replace image…",
                          systemImage: "photo.on.rectangle.angled")
                }
                .disabled(attaching)
                if attaching {
                    ProgressView().controlSize(.small)
                    Text("Uploading to Blossom…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let path = draft.imagePath, draft.imageBlockRaw != nil {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text(path.components(separatedBy: "/").last ?? path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let err = draft.imageError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, .heif]
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cacheDir = home.appendingPathComponent("Library/Caches/com.sonata")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        panel.directoryURL = cacheDir
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let path = url.path
        let allowedPrefixes = [
            cacheDir.path,
            home.appendingPathComponent("Downloads").path,
        ]
        guard allowedPrefixes.contains(where: { path.hasPrefix($0) }) else {
            draft.imageError = "Image must be under ~/Library/Caches/com.sonata or ~/Downloads."
            return
        }

        // 20 MiB local cap matches the plugin's defense.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64, size > 20 * 1024 * 1024 {
            draft.imageError = "Image is larger than 20 MiB."
            return
        }

        attaching = true
        draft.imageError = nil
        let roomCapture = roomSlug
        Task { @MainActor in
            defer { attaching = false }
            do {
                let block = try await store.attachImage(
                    filePath: path,
                    roomSlug: roomCapture,
                    mimeType: nil
                )
                draft.imageBlockRaw = block
                draft.imageBlock = block.compactMapValues { v -> String? in
                    if let s = v as? String { return s }
                    return nil
                }
                draft.imagePath = path
            } catch {
                draft.imageBlockRaw = nil
                draft.imageBlock = nil
                draft.imagePath = nil
                draft.imageError = error.localizedDescription
                toast.show(
                    severity: .error,
                    text: "Image upload failed: \(error.localizedDescription). Sheet preserved."
                )
            }
        }
    }
}
