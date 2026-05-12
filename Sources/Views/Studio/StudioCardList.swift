import SwiftUI

/// Row source for the room-detail card list. Three modes:
///   1. dispatchTrace == false && track == nil → union of all cards in the
///      room, sorted DESC by `createdAtSeconds`.
///   2. dispatchTrace == false && track != nil → just the slice for that track.
///   3. dispatchTrace == true → `store.dispatchIntents[room.slug]`, sorted
///      DESC by `createdAtMs` (falls back to `createdAtSeconds * 1000`).
struct StudioCardList: View {
    let room: StudioRoom
    let track: String?
    let dispatchTrace: Bool
    @ObservedObject var store: StudioStore
    @Binding var selectedCard: StudioCard?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if dispatchTrace {
                    dispatchRows
                } else {
                    cardRows
                }
                Color.clear.frame(height: 60) // §9.4 inline compose strip safe area
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentMargins(.bottom, 16, for: .scrollContent)
    }

    // MARK: - Card rows

    @ViewBuilder
    private var cardRows: some View {
        let cards = sourceCards
        if cards.isEmpty {
            emptyState(
                symbol: "tray",
                title: track == nil ? "No cards yet" : "No cards in this track",
                subtitle: "Posts from this room will appear here in real time."
            )
        } else {
            ForEach(cards, id: \.id) { card in
                let optimistic = optimisticIds.contains(card.id)
                StudioCardRow(
                    card: card,
                    authorName: store.displayName(for: card.createdByPubkey),
                    commentCount: store.comments(forCard: card.eventId).count,
                    isOptimistic: optimistic,
                    selectedCard: $selectedCard
                )
                Divider().opacity(0.4)
            }
        }
    }

    /// IDs of optimistic cards currently being merged into the list. Used to
    /// flag rows with a spinner + opacity treatment until SSE reconciles.
    private var optimisticIds: Set<String> {
        Set(optimisticCardsForView.map(\.id))
    }

    private var optimisticCardsForView: [StudioCard] {
        store.optimisticCards.values.filter { c in
            guard c.roomSlug == room.slug else { return false }
            if let track { return c.trackSlug == track }
            return true
        }
    }

    private var sourceCards: [StudioCard] {
        let real: [StudioCard]
        if let track {
            real = store.cards(in: room.slug, track: track)
        } else {
            let prefix = "\(room.slug)|"
            var union: [StudioCard] = []
            for (key, slice) in store.cardsByRoomTrack where key.hasPrefix(prefix) {
                union.append(contentsOf: slice)
            }
            real = union
        }
        let optimistic = optimisticCardsForView
        return (optimistic + real).sorted { $0.createdAtSeconds > $1.createdAtSeconds }
    }

    // MARK: - Dispatch rows

    @ViewBuilder
    private var dispatchRows: some View {
        let intents = (store.dispatchIntents[room.slug] ?? [])
            .sorted { a, b in
                let av = a.createdAtMs ?? (a.createdAtSeconds * 1000)
                let bv = b.createdAtMs ?? (b.createdAtSeconds * 1000)
                return av > bv
            }
        if intents.isEmpty {
            emptyState(
                symbol: "arrow.up.right.diamond",
                title: "No dispatches recorded",
                subtitle: "Worker selection traces will appear here as dispatches fire."
            )
        } else {
            ForEach(intents, id: \.id) { intent in
                DispatchIntentRow(intent: intent)
                Divider().opacity(0.4)
            }
        }
    }

    // MARK: - Empty state

    private func emptyState(symbol: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

// MARK: - Dispatch intent row

/// One row in the dispatch-trace view. Drawer-level signals rendering lands
/// in §9.3 alongside the card drawer.
private struct DispatchIntentRow: View {
    let intent: StudioDispatchIntent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right.diamond")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(headline)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !intent.candidates.isEmpty {
                Text("candidates: " + intent.candidates.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headline: String {
        let worker = intent.chosen.map { "→ chose \($0)" } ?? "→ no worker chosen"
        let event = intent.busEventId.isEmpty
            ? "(no event id)"
            : String(intent.busEventId.prefix(12)) + "…"
        return "\(worker) for \(event)"
    }

    private var relativeTime: String {
        let stamp = intent.createdAtMs ?? (intent.createdAtSeconds * 1000)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let dt = max(0, (nowMs - stamp) / 1000)
        switch dt {
        case 0..<60:       return "just now"
        case 60..<3600:    return "\(dt / 60)m ago"
        case 3600..<86400: return "\(dt / 3600)h ago"
        default:           return "\(dt / 86400)d ago"
        }
    }
}
