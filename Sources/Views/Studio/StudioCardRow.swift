import SwiftUI

/// One row in the card-list `LazyVStack`. Stateless except for a hover flag.
/// Selection state is owned by the parent (`StudioCardList`); this view only
/// reads/writes the binding on tap. Layout follows plan §3.4; SF Symbol
/// mapping follows the T3 task-brief override (see W5 R1).
struct StudioCardRow: View {
    let card: StudioCard
    let authorName: String
    let commentCount: Int
    var isOptimistic: Bool = false
    @Binding var selectedCard: StudioCard?
    var store: StudioStore? = nil

    @State private var hovering: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var deleteErrorMessage: String? = nil

    private var isSelected: Bool {
        selectedCard?.eventId == card.eventId && !card.eventId.isEmpty
    }

    private var canDelete: Bool {
        guard let store else { return false }
        return !card.createdByPubkey.isEmpty &&
            card.createdByPubkey.lowercased() == store.currentPubkeyHex.lowercased() &&
            !card.dTag.isEmpty &&
            !isOptimistic
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            kindIcon
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(card.title.isEmpty ? "(untitled)" : card.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !card.summary.isEmpty {
                    Text(card.summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                HStack(spacing: 6) {
                    Text(authorName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·").font(.caption).foregroundStyle(.secondary)
                    Text(Self.relativeTime(from: card.createdAtSeconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if commentCount > 0 {
                        Text("·").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "bubble.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(commentCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(rowFill)
        .contentShape(Rectangle())
        .opacity(isOptimistic ? 0.55 : 1.0)
        .overlay(alignment: .trailing) {
            if isOptimistic {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 16)
            }
        }
        .onHover { hovering = $0 }
        .onTapGesture {
            // Optimistic rows have no eventId yet; tapping into the drawer
            // with an empty eventId would break comment-thread lookup, so
            // suppress the selection until reconcile lands the real card.
            guard !isOptimistic else { return }
            selectedCard = card
        }
        .contextMenu {
            if canDelete {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete card", systemImage: "trash")
                }
            }
        }
        .confirmationDialog(
            "Delete this card?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let store else { return }
                let eventId = card.eventId
                let dTag = card.dTag
                let roomSlug = card.roomSlug
                Task {
                    do {
                        try await store.deleteCard(roomSlug: roomSlug, dTag: dTag, eventId: eventId)
                    } catch {
                        await MainActor.run {
                            deleteErrorMessage = (error as? StudioPluginError)?.message ?? error.localizedDescription
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Deleted cards can't be restored.")
        }
        .alert(
            "Couldn't delete card",
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private var kindIcon: some View {
        Image(systemName: Self.symbol(for: card.cardKind))
            .resizable()
            .scaledToFit()
    }

    private var rowFill: some View {
        Group {
            if isSelected {
                Color.accentColor.opacity(0.18)
            } else if hovering {
                Color.primary.opacity(0.06)
            } else {
                Color.clear
            }
        }
    }

    // MARK: - Static helpers

    static func symbol(for kind: String?) -> String {
        switch kind {
        case "note":     return "bubble.left.fill"
        case "lead":     return "target"
        case "review":   return "checkmark.seal.fill"
        case "task":     return "checklist"
        case "question": return "questionmark.bubble.fill"
        case "answer":   return "checkmark.bubble.fill"
        default:         return "doc.fill"
        }
    }

    /// "just now", "2m ago", "3h ago", "yesterday", "Apr 14".
    static func relativeTime(from createdAtSeconds: Int64) -> String {
        let then = Date(timeIntervalSince1970: TimeInterval(createdAtSeconds))
        let now = Date()
        let delta = now.timeIntervalSince(then)

        if delta < 60 { return "just now" }
        if delta < 3600 { return "\(Int(delta / 60))m ago" }
        if delta < 86_400 { return "\(Int(delta / 3600))h ago" }
        if delta < 172_800 { return "yesterday" }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: then)
    }
}
