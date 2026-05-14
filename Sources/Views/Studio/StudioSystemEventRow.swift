import SwiftUI

/// Single muted one-liner for a `studio_room_system_event` in the card feed.
/// Visual: light row with an arrow glyph + verb phrase + relative time.
/// Less vertical padding than card rows so a sequence of transitions stays
/// compact and doesn't dominate the feed.
struct StudioSystemEventRow: View {
    let event: StudioRoomSystemEvent
    @ObservedObject var store: StudioStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(phrase)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(relativeTime)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var glyph: String {
        switch event.kind {
        case .joined:   return "person.crop.circle.badge.plus"
        case .left:     return "rectangle.portrait.and.arrow.right"
        case .removed:  return "person.crop.circle.badge.minus"
        case .closed:   return "lock.fill"
        case .reopened: return "lock.open.fill"
        }
    }

    /// Sentence-style summary using whatever member names we have available.
    /// Falls back to npub-short hex when the pubkey hasn't projected a
    /// per-room profile yet.
    private var phrase: String {
        switch event.kind {
        case .joined:
            return "\(subjectName) joined"
        case .left:
            return "\(subjectName) left"
        case .removed:
            return "\(subjectName) was removed by \(actorName)"
        case .closed:
            return "\(actorName) closed the room"
        case .reopened:
            return "\(actorName) reopened the room"
        }
    }

    private var subjectName: String {
        guard let pub = event.subject, !pub.isEmpty else { return "someone" }
        return displayName(for: pub)
    }

    private var actorName: String {
        guard let pub = event.actor, !pub.isEmpty else { return "the founder" }
        return displayName(for: pub)
    }

    private func displayName(for pubkey: String) -> String {
        if let member = store.roomMembersList(for: event.roomSlug)
            .first(where: { $0.pubkeyHex.lowercased() == pubkey.lowercased() }) {
            return member.displayName
        }
        return Hex.npubShort(pubkey)
    }

    private var relativeTime: String {
        let d = Date(timeIntervalSince1970: TimeInterval(event.atSeconds))
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: d, relativeTo: Date())
    }
}
