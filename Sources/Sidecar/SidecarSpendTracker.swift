import Foundation

/// Tracks what each sidecar spends and decides when one has to be throttled.
///
/// ## The window
///
/// Spend is measured over a **rolling 7 days**, matching the `seven_day` bar
/// that Claude subscriptions are actually limited on. The 5-hour bar is the
/// wrong shape here: a sidecar idles for hours and then bursts through a batch
/// of events, so a 5-hour view would throttle it for a spike that a weekly
/// budget absorbs without noticing.
///
/// Rolling rather than a fixed week anchored to some arbitrary reset hour.
/// Headroom then returns gradually as old spend ages out, instead of a sidecar
/// sitting throttled for three days and being handed the whole budget back in
/// one step. It also means there is no "when does the week start" question to
/// get wrong across time zones. Note that recovering *headroom* is not the same
/// as recovering *tier*: this type never restores a tier it dropped, because
/// the user may have tuned it in the meantime.
///
/// ## The allowance
///
/// A sidecar's cap is expressed as a percent of subscription usage
/// (`Sidecar.subscriptionCapPct`, default 20%). Claude Code exposes no local
/// "you have used X% of your quota" number — not in `~/.claude`, not anywhere
/// on disk — so the denominator cannot be read, only assumed. It lives in
/// `assumedWeeklyCeilingTokens` as an explicit, user-settable figure rather
/// than being inferred from `system_token_usage`, which sums only Sonata's own
/// activity and would make an invented number look like a measured one.
///
/// The defaults are chosen to agree: 20% of 25M tokens/week is 5M, so a user
/// who never opens the advanced knobs gets the same ceiling whether they think
/// in percentages or in tokens.
///
/// An actor because every live sidecar session records into the same ledger
/// concurrently.
actor SidecarSpendTracker: SidecarSpendReader {

    /// Knob values, named rather than inlined so the settings panel and the
    /// tracker read the same numbers.
    enum Defaults {
        /// Length of the rolling spend window.
        static let windowDays = 7
        /// Assumed tokens a subscription affords per week — the denominator
        /// the percentage cap is taken against. Sized for a Max plan; a Pro
        /// user is expected to dial this down.
        static let assumedWeeklyCeilingTokens = 25_000_000
        /// Percent of the allowance at which the sidecar drops one tier.
        static let dropTierAtPct = 80
        /// Percent of the allowance at which the sidecar is switched off.
        static let offAtPct = 100

        /// Tokens a default-configured sidecar may spend per window — 5M, for
        /// display in the settings panel so it does not hardcode the figure.
        ///
        /// Derived from the other two defaults rather than written out, so the
        /// headline number cannot drift away from the arithmetic that produces
        /// it. This is the *default* only: the live allowance always comes from
        /// `allowanceTokens(capPct:)`, which reads the user's actual ceiling.
        static let weeklyCapTokens =
            (assumedWeeklyCeilingTokens * Sidecar.Defaults.subscriptionCapPct) / 100
    }

    /// Spend is bucketed by the hour rather than kept as one row per event.
    /// A busy sidecar can log thousands of events a week; 168 hourly buckets
    /// bound the memory regardless, and hour-granularity aging is far finer
    /// than a 7-day window needs.
    private static let bucketMs: Int64 = 60 * 60 * 1000
    private static var windowMs: Int64 { Int64(Defaults.windowDays) * 24 * bucketMs }
    private static var bucketsInWindow: Int64 { Self.windowMs / Self.bucketMs }

    /// sidecar name → (hour bucket → tokens spent in that hour).
    private var buckets: [String: [Int64: Int]] = [:]

    /// Most severe action already handed to `applyThrottle` for a sidecar.
    /// Without this, every single `record` past the threshold would re-fire the
    /// callback and a sidecar would be told to drop a tier hundreds of times.
    private var lastFired: [String: ThrottleAction] = [:]

    /// Assumed weekly subscription ceiling, in tokens. Settable so the settings
    /// panel can hand over the user's real figure; see the type comment for why
    /// this is an assumption rather than a reading.
    private(set) var assumedWeeklyCeilingTokens: Int

    /// Concrete throttle handler, plugged in by registration (Task D). Left nil
    /// here deliberately: this type decides *that* a sidecar should be throttled
    /// and stays out of *how* — it holds no reference to the config store and
    /// cannot restart or reconfigure a session itself.
    var applyThrottle: (@Sendable (String, ThrottleAction) async -> Void)?

    /// Injected clock. Production passes `nowMs`; tests pass a controllable one
    /// so window aging can be exercised without sleeping for a week.
    private let now: @Sendable () -> Int64

    init(
        assumedWeeklyCeilingTokens: Int = Defaults.assumedWeeklyCeilingTokens,
        applyThrottle: (@Sendable (String, ThrottleAction) async -> Void)? = nil,
        now: @escaping @Sendable () -> Int64 = { nowMs() }
    ) {
        self.assumedWeeklyCeilingTokens = assumedWeeklyCeilingTokens
        self.applyThrottle = applyThrottle
        self.now = now
    }

    func setApplyThrottle(_ handler: (@Sendable (String, ThrottleAction) async -> Void)?) {
        applyThrottle = handler
    }

    /// Update the assumed ceiling. Does not re-evaluate throttling on its own —
    /// the next `record` picks up the new denominator, which is soon enough for
    /// a value the user changes by hand.
    func setAssumedWeeklyCeilingTokens(_ tokens: Int) {
        assumedWeeklyCeilingTokens = max(0, tokens)
    }

    // MARK: - Recording

    /// Add one event's usage to the ledger and act on the result.
    ///
    /// Input and output tokens are summed without weighting. This is a budget
    /// guard, not a billing system: what matters is roughly how much of the
    /// subscription a sidecar is eating, and the cost ratio between the two is
    /// well inside the slack of an assumed ceiling.
    ///
    /// `at` is a unix-ms timestamp. Firing the throttle callback from here — as
    /// opposed to from a polling monitor — means a sidecar that blows its cap in
    /// one burst is caught on the event that did it.
    func record(sidecar: String, inputTokens: Int, outputTokens: Int, at: Int64) async {
        let tokens = max(0, inputTokens) + max(0, outputTokens)
        guard tokens > 0 else { return }

        let bucket = at / Self.bucketMs
        buckets[sidecar, default: [:]][bucket, default: 0] += tokens
        prune(sidecar: sidecar)

        guard let capPct = SidecarRegistry.shared.lookup(byName: sidecar)?.subscriptionCapPct else {
            // Nothing registered under this name, so no cap to enforce. The
            // spend is still recorded — registration may land afterwards.
            return
        }
        await fireThrottleIfEscalated(sidecar: sidecar, capPct: capPct)
    }

    /// Drop buckets that have aged out of the window. Called on write rather
    /// than on a timer: a sidecar that stops spending stops needing pruning,
    /// and its stale buckets are filtered out of every read anyway.
    private func prune(sidecar: String) {
        guard var sidecarBuckets = buckets[sidecar] else { return }
        let oldest = (now() / Self.bucketMs) - Self.bucketsInWindow
        sidecarBuckets = sidecarBuckets.filter { $0.key > oldest }
        if sidecarBuckets.isEmpty {
            buckets.removeValue(forKey: sidecar)
        } else {
            buckets[sidecar] = sidecarBuckets
        }
    }

    // MARK: - Reading

    /// Total tokens spent by `sidecar` inside the current rolling window.
    /// Zero for an unknown sidecar — no spend recorded genuinely is no spend.
    func windowSpend(sidecar: String) -> Int {
        guard let sidecarBuckets = buckets[sidecar] else { return 0 }
        let oldest = (now() / Self.bucketMs) - Self.bucketsInWindow
        return sidecarBuckets.reduce(0) { total, entry in
            entry.key > oldest ? total + entry.value : total
        }
    }

    /// Tokens a sidecar on `capPct` may spend per window, or nil when no
    /// ceiling is configured and the percentage therefore means nothing.
    func allowanceTokens(capPct: Int) -> Int? {
        guard assumedWeeklyCeilingTokens > 0, capPct > 0 else { return nil }
        return (assumedWeeklyCeilingTokens * capPct) / 100
    }

    /// Percent of its allowance `sidecar` has consumed this window.
    ///
    /// Nil rather than zero when there is no allowance to measure against —
    /// callers must be able to tell "hasn't spent anything" from "we have no
    /// idea what the ceiling is", and a display that renders the second as an
    /// empty progress bar is lying.
    func spendPercent(sidecar: String, capPct: Int) -> Int? {
        guard let allowance = allowanceTokens(capPct: capPct) else { return nil }
        return max(0, (windowSpend(sidecar: sidecar) * 100) / allowance)
    }

    // MARK: - Throttling

    /// What should be done about `sidecar` right now.
    ///
    /// `.none` when the cap cannot be computed: an unknown ceiling is not
    /// grounds for switching a sidecar off. Failing open is the right default
    /// for a guard built on an assumption — the honest response to "we don't
    /// know" is to leave the user's configuration alone.
    func shouldThrottle(sidecar: String, capPct: Int) -> ThrottleAction {
        guard let pct = spendPercent(sidecar: sidecar, capPct: capPct) else {
            return ThrottleAction.none
        }
        if pct >= Defaults.offAtPct { return .off }
        if pct >= Defaults.dropTierAtPct { return .dropTier }
        return ThrottleAction.none
    }

    /// Hand the action to `applyThrottle`, but only when it is more severe than
    /// whatever was last fired for this sidecar.
    ///
    /// De-escalation is deliberately never reported. As spend ages out of the
    /// window a sidecar regains headroom, but restoring its tier is not ours to
    /// do — the spec is explicit that a tier the user has since tuned must not
    /// be overwritten. What a drop back below the threshold *does* do is re-arm
    /// the latch, so a later climb throttles again instead of being swallowed.
    private func fireThrottleIfEscalated(sidecar: String, capPct: Int) async {
        let action = shouldThrottle(sidecar: sidecar, capPct: capPct)
        let previous = lastFired[sidecar] ?? ThrottleAction.none

        guard action > previous else {
            if action == ThrottleAction.none {
                lastFired.removeValue(forKey: sidecar)
            }
            return
        }

        lastFired[sidecar] = action
        await applyThrottle?(sidecar, action)
    }

    // MARK: - SidecarSpendReader

    func spendSnapshot(for sidecarName: String) async -> SidecarSpendSnapshot? {
        guard let sidecar = SidecarRegistry.shared.lookup(byName: sidecarName),
              let allowance = allowanceTokens(capPct: sidecar.subscriptionCapPct) else {
            return nil
        }
        return SidecarSpendSnapshot(
            spentTokens: windowSpend(sidecar: sidecarName),
            allowanceTokens: allowance
        )
    }

    // MARK: - Introspection

    /// Forget a sidecar's spend history. Exists for tests and for a future
    /// "reset this sidecar's budget" affordance; nothing in the running app
    /// calls it today.
    func reset(sidecar: String) {
        buckets.removeValue(forKey: sidecar)
        lastFired.removeValue(forKey: sidecar)
    }
}
