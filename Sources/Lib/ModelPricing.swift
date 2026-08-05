import Foundation

/// Hardcoded Anthropic Claude pricing per million tokens for the v0
/// dashboard token-usage card. Quarterly drift is fine — when prices move
/// enough to matter, edit this file. Moving to a config source is a v2.
///
/// Sources are Anthropic's public published rates, verified 2026-07-31 against
/// platform.claude.com/docs/en/about-claude/models/overview.
enum ModelPricing {

    /// Per-million-token prices in USD. `input` is per million input tokens,
    /// `output` is per million output tokens.
    struct Price {
        let input: Double
        let output: Double
    }

    /// Known model → price map. The keys are the canonical model IDs the
    /// dispatcher writes into `tasks.model` and worker event payloads.
    ///
    /// Legacy models are kept here deliberately: an id that drops out of the
    /// map does not stop being billed, it just starts being mispriced through
    /// `defaultModel`. Removing a row is a pricing change, not a cleanup.
    static let prices: [String: Price] = [
        // Current
        "claude-fable-5":    Price(input: 10.0, output: 50.0),
        "claude-mythos-5":   Price(input: 10.0, output: 50.0),
        "claude-opus-5":     Price(input:  5.0, output: 25.0),
        "claude-sonnet-5":   Price(input:  3.0, output: 15.0),
        "claude-haiku-4-5":  Price(input:  1.0, output:  5.0),
        // Legacy, still served and still billable
        "claude-opus-4-8":   Price(input:  5.0, output: 25.0),
        "claude-opus-4-7":   Price(input:  5.0, output: 25.0),
        "claude-opus-4-6":   Price(input:  5.0, output: 25.0),
        "claude-opus-4-5":   Price(input:  5.0, output: 25.0),
        "claude-opus-4-1":   Price(input: 15.0, output: 75.0),
        "claude-sonnet-4-6": Price(input:  3.0, output: 15.0),
        "claude-sonnet-4-5": Price(input:  3.0, output: 15.0),
    ]

    /// Default model assumed when a workerEvent has no recorded model. The
    /// rest of the system assumes Opus by default for dispatched tasks, so
    /// this matches that bias and keeps cost numbers honest.
    ///
    /// NOTE: this constant is also the *write-side* attribution fallback in
    /// `WorkerActions` — an event whose payload carries no `model` field is
    /// persisted with this id. Changing it changes what future rows claim to
    /// have run on, so treat it as an attribution decision, not a constant.
    static let defaultModel = "claude-opus-4-7"

    /// We track only `totalTokens` per event in v0 (input + cache + output combined),
    /// not a separate input/output split. Assume an 80/20 input/output blend — what
    /// agent workloads actually look like — so the card can show a reasonable
    /// dollar figure without a schema change.
    ///
    /// KNOWN BIAS — this figure is an overestimate, likely by a large factor.
    /// Two separate reasons:
    ///
    /// 1. Cache reads bill at ~10% of the input rate, and this estimator prices
    ///    them at the full input rate. That is not a rounding nuance on the real
    ///    workload: a live worker sampled 2026-07-31 showed 58,568,689 cache-read
    ///    tokens out of 59,716,797 total — 98%. Pricing 98% of the input side at
    ///    10x its true rate is the dominant error term in this card.
    /// 2. The 80/20 split is a guess, not a measurement.
    ///
    /// Fixing (1) needs a schema change: `workerEvents` has a single
    /// `totalTokens` column and no cache-read column, so the split cannot be
    /// recovered from stored data. When that column lands, price cache reads at
    /// 0.1x `input` and add back a direct `costUSD(model:inputTokens:cacheReadTokens:outputTokens:)`
    /// for callers with a real split. Until then this card is a ceiling, not an estimate.
    ///
    /// Unknown models fall back to `defaultModel` rather than returning 0, so the
    /// card never silently under-reports a model we forgot to add — but the
    /// fallback logs once per unknown id so it cannot happen invisibly.
    static func blendedCostUSD(model: String, totalTokens: Int64) -> Double {
        let resolved: String
        if prices[model] != nil {
            resolved = model
        } else {
            warnUnknown(model)
            resolved = defaultModel
        }
        guard let p = prices[resolved] else { return 0 }
        let inputShare = 0.8
        let outputShare = 0.2
        let mTok = Double(totalTokens) / 1_000_000.0
        return mTok * (p.input * inputShare + p.output * outputShare)
    }

    // MARK: - Private

    private static let warnedLock = NSLock()
    private static var warnedModels: Set<String> = []

    /// Log once per unknown model to keep the noise down on long-running boxes.
    private static func warnUnknown(_ model: String) {
        warnedLock.lock()
        defer { warnedLock.unlock() }
        guard !warnedModels.contains(model) else { return }
        warnedModels.insert(model)
        FileHandle.standardError.write(
            Data("[ModelPricing] unknown model '\(model)' — pricing it as '\(defaultModel)'. Update Sources/Lib/ModelPricing.swift to add it.\n".utf8)
        )
    }
}
