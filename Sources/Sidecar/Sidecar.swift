import Foundation

/// Coarse budget preset for a sidecar.
///
/// The framework only carries the tier; resolving it to concrete knob values
/// (judge model, context depth, top-K) is the sidecar's own business and
/// happens in its SKILL.md when it builds a per-request agent prompt.
/// `.off` means registered but not spawned — the monitor skips it.
enum SidecarBudgetTier: String, Codable, Sendable, CaseIterable {
    case off
    case low
    case standard
    case high
}

/// Configuration for one sidecar: a long-lived Sonata-hosted Claude Code
/// session that receives events by `event_type`, dispatches each to a headless
/// internal Agent, and rotates when its context fills up.
///
/// This type is configuration only — it holds no running state. The live
/// session key and rotation bookkeeping live in `SidecarLifecycle`; the
/// event-type index that routing reads lives in `SidecarRegistry`. Keeping
/// config immutable means a `Sidecar` value can be handed around freely
/// without carrying a session that may since have been rotated away.
struct Sidecar: Sendable, Identifiable, Equatable {

    /// Default knob values, named rather than inlined so the settings panel,
    /// any future presets, and the framework all read the same numbers.
    enum Defaults {
        static let budgetTier: SidecarBudgetTier = .standard
        /// Percent of subscription usage this sidecar may consume per window.
        static let subscriptionCapPct = 20
        /// Percent of the context window at which `rotate_me` is posted.
        static let rotationThreshold = 70
    }

    /// Unique registry key.
    let name: String

    /// Path to this sidecar's SKILL.md in bundle Resources. Stored as given;
    /// existence is checked at spawn time rather than construction time so a
    /// registry can be built before the bundle is consulted.
    let skillPath: String

    /// Event types this sidecar owns. Routing is exact-match on `event_type`.
    /// A sidecar with no event types is legal — it simply never gets routed
    /// to, which is the right shape for a future timer-driven sidecar.
    let eventTypes: [String]

    let budgetTier: SidecarBudgetTier

    /// Ceiling on this sidecar's share of subscription usage, as a percent.
    /// Enforcement is framework-side and lands with spend tracking; the value
    /// is carried here so registration is the single source of truth.
    let subscriptionCapPct: Int

    /// Trigger names this sidecar responds to, e.g. `["stop_hook",
    /// "submit_refine"]`. Interpreted by the sidecar, not the framework.
    let triggers: Set<String>

    /// Percent of the context window at which the monitor posts `rotate_me`.
    let rotationThreshold: Int

    var id: String { name }

    init(
        name: String,
        skillPath: String,
        eventTypes: [String],
        budgetTier: SidecarBudgetTier = Defaults.budgetTier,
        subscriptionCapPct: Int = Defaults.subscriptionCapPct,
        triggers: Set<String> = [],
        rotationThreshold: Int = Defaults.rotationThreshold
    ) {
        self.name = name
        self.skillPath = skillPath
        self.eventTypes = eventTypes
        self.budgetTier = budgetTier
        self.subscriptionCapPct = subscriptionCapPct
        self.triggers = triggers
        self.rotationThreshold = rotationThreshold
    }

    /// Whether `skillPath` resolves on disk right now.
    ///
    /// `SidecarLifecycle.spawn` treats a miss as fatal: a session started
    /// without its instructions would sit there consuming events and doing the
    /// wrong thing, which is worse than not booting. Per the design spec's
    /// launch behavior, sidecars fail loudly rather than silently.
    var skillFileExists: Bool {
        FileManager.default.fileExists(atPath: skillPath)
    }
}
