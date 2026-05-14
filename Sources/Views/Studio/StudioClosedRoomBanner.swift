import SwiftUI

/// Pill-row banner shown at the top of a room view when the founder has
/// closed it. Visual is intentionally muted (yellow/gray pill, lock icon,
/// secondary text) and carries no action buttons — reopen lives in the
/// settings menu / context menu, surfacing the affordance through normal
/// room controls rather than embedded inside the banner.
struct StudioClosedRoomBanner: View {
    let room: StudioRoom

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(bannerText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.yellow.opacity(0.35), lineWidth: 0.5)
        )
        .help("Founder has closed this room. Members may still read history but cannot post.")
    }

    private var bannerText: String {
        if let ts = room.closedAtSeconds, ts > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .none
            return "Room closed by founder on \(fmt.string(from: date))."
        }
        return "Room closed by founder."
    }
}
