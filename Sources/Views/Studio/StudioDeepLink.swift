import Combine
import Foundation
import SwiftUI

/// Receives `4a://...` URLs handed to the app via `.onOpenURL` and queues them
/// for a Studio-tab consumer to present.
///
/// SwiftUI's `.onOpenURL` fires for both runtime opens and the boot-time
/// pending-URL case (macOS replays the URL after launch finishes), so the
/// router doesn't need a separate "did finish launching" hook. Consumers
/// observe `pendingInvite` from the Studio view tree and clear it once a
/// confirm sheet is in flight.
@MainActor
final class StudioDeepLinkRouter: ObservableObject {
    static let shared = StudioDeepLinkRouter()

    /// Set when a `4a://invite/...` URL is delivered. The Studio view tree
    /// observes this and presents `StudioInviteConfirmSheet`. The consumer
    /// is responsible for setting this back to nil after consuming.
    @Published var pendingInvite: PendingInvite?

    private init() {}

    /// One incoming invite URL plus the slug/epoch hints we managed to pluck
    /// off it client-side. The plugin's `room/join` action remains the
    /// authority — these are display-only previews for the confirm sheet so
    /// it doesn't render "Join unknown room?" while the join request is
    /// in flight.
    struct PendingInvite: Identifiable, Equatable {
        let id = UUID()
        /// Full original URL — exactly what gets forwarded to the plugin.
        let rawURL: String
        /// Best-effort slug parsed from the URL (`4a://invite/<slug>/<epoch>...`).
        let previewSlug: String?
        /// Best-effort epoch number (display-only).
        let previewEpoch: Int?
    }

    /// Entry point from SonataApp's `.onOpenURL`. Currently we only handle
    /// the `4a://invite/<slug>/<epoch>...` shape — other 4a:// paths are
    /// dropped silently so the URL handler doesn't grow into a generic
    /// router by accident. Adding more routes means adding more explicit
    /// cases here, not pattern-matching by scheme alone.
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "4a" else { return }
        let host = url.host?.lowercased() ?? ""
        let firstPathPart = url.pathComponents
            .first(where: { $0 != "/" && !$0.isEmpty })?
            .lowercased() ?? ""
        // URL parsing inserts host vs. path inconsistently depending on whether
        // the URL has authority components. `4a://invite/foo` puts `invite` in
        // .host on some macOS versions and in the first path segment on others;
        // accept either.
        guard host == "invite" || firstPathPart == "invite" else { return }

        let (slug, epoch) = Self.previewSlugAndEpoch(from: url)
        pendingInvite = PendingInvite(
            rawURL: url.absoluteString,
            previewSlug: slug,
            previewEpoch: epoch
        )
    }

    /// Pull the slug + epoch out of a `4a://invite/<slug>/<epoch>...` URL
    /// for the confirm-sheet preview. The plugin re-parses the URL itself
    /// during join (this is purely cosmetic); return `(nil, nil)` on any
    /// parse failure rather than rejecting the URL.
    static func previewSlugAndEpoch(from url: URL) -> (String?, Int?) {
        // Drop the "/" root + "invite" segment if it sits in the path.
        var parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if (url.host?.lowercased() ?? "") != "invite",
           parts.first?.lowercased() == "invite" {
            parts.removeFirst()
        }
        let slug = parts.first
        let epoch = parts.count >= 2 ? Int(parts[1]) : nil
        return (slug, epoch)
    }

    /// True when the URL looks like a 4a:// invite — used as a cheap gate
    /// for "do anything at all" in the app receiver.
    static func isInviteURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "4a" else { return false }
        let host = url.host?.lowercased() ?? ""
        let first = url.pathComponents
            .first(where: { $0 != "/" && !$0.isEmpty })?
            .lowercased() ?? ""
        return host == "invite" || first == "invite"
    }
}
