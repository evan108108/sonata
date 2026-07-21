import Foundation

/// What the framework wants done about a sidecar that is spending too much.
///
/// Ordered by severity so escalation can be compared rather than pattern-matched
/// at every call site — `SidecarSpendTracker` uses that ordering to fire its
/// throttle callback only when things get *worse*, never on a repeat of the
/// same verdict.
enum ThrottleAction: Int, Sendable, Comparable, CaseIterable {
    /// Under the drop threshold — leave the sidecar alone.
    case none = 0
    /// Approaching the cap: step the sidecar down one budget tier.
    case dropTier = 1
    /// At or over the cap: stop the sidecar entirely.
    case off = 2

    static func < (lhs: ThrottleAction, rhs: ThrottleAction) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A sidecar's spend in the current window, next to what it is allowed.
///
/// `spentTokens` and `allowanceTokens` are both carried rather than just the
/// percentage because the settings panel and detail page want to show the raw
/// numbers ("3.2M / 5M") alongside the bar — a percentage alone cannot be
/// un-divided back into them.
struct SidecarSpendSnapshot: Sendable, Equatable {
    /// Tokens this sidecar has spent inside the current window.
    let spentTokens: Int

    /// Tokens it may spend before hitting its cap.
    let allowanceTokens: Int

    /// Percent of the allowance consumed, clamped at 0 and uncapped above 100
    /// so an overspend reads honestly as "112%" rather than a silent 100%.
    var percentUsed: Int {
        guard allowanceTokens > 0 else { return 0 }
        return max(0, (spentTokens * 100) / allowanceTokens)
    }
}

/// Read-only access to sidecar spend, for anything that displays it.
///
/// Exists so the settings panel and the sidecar detail page can render a spend
/// bar without holding a reference to the concrete tracker — and, more to the
/// point, without being able to `record()` into it. Display code has no
/// business mutating the ledger.
///
/// Async because the concrete implementation is an actor; a synchronous shape
/// would force the tracker to give up its actor isolation.
protocol SidecarSpendReader: Sendable {
    /// Current-window spend for `sidecarName`, or nil when the sidecar is
    /// unknown to the registry or has no allowance configured — both mean
    /// "there is no meaningful bar to draw" rather than "zero spend".
    func spendSnapshot(for sidecarName: String) async -> SidecarSpendSnapshot?
}
