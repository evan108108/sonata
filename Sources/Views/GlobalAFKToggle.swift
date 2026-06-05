import SwiftUI

/// Always-visible Global AFK toggle for the title bar. Color-coded when ON so
/// the AFK state is obvious at a glance — the toggle is the canonical
/// affordance, everything else (broadcast, email, persistence) is plumbing
/// behind a flip of this one control.
///
/// Reads + writes `GlobalAFKController.shared`. The controller's @Published
/// `isEnabled` drives the visual state; tapping the toggle calls setEnabled
/// with source `.ui`, which both persists to DB and posts a notification that
/// Pass-2 subscribers (directive broadcaster, kickoff email) react to.
struct GlobalAFKToggle: View {
    @ObservedObject private var controller = GlobalAFKController.shared

    var body: some View {
        Button {
            controller.setEnabled(!controller.isEnabled, source: .ui)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: controller.isEnabled ? "moon.fill" : "moon")
                    .font(.system(size: 11, weight: .semibold))
                Text(controller.isEnabled ? "AFK" : "AFK")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(controller.isEnabled ? Theme.Color.accentRust.opacity(0.85) : Color.secondary.opacity(0.15))
            )
            .foregroundStyle(controller.isEnabled ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .help(controller.isEnabled
              ? "Global AFK is ON — all connected sessions are routing questions to email. Click to disable."
              : "Toggle Global AFK — broadcast 'enter AFK' to every connected interactive session.")
    }
}
