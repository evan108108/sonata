import Foundation

/// Hardcoded Anthropic Claude pricing per million tokens for the v0
/// dashboard token-usage card. Quarterly drift is fine — when prices move
/// enough to matter, edit this file. Moving to a config source is a v2.
///
/// Sources are Anthropic's public published rates as of 2026-Q2.
enum ModelPricing {

    /// Per-million-token prices in USD. `input` is per million input tokens,
    /// `output` is per million output tokens. Cache reads bill at ~10% of
    /// the input rate, but for the v0 blended estimator we ignore that
    /// nuance — the card just wants ballpark spend.
    struct Price {
        let input: Double
        let output: Double
    }

    /// Known model → price map. The keys are the canonical model IDs the
    /// dispatcher writes into `tasks.model` and worker event payloads.
    static let prices: [String: Price] = [
        "claude-opus-4-7":   Price(input: 15.0, output: 75.0),
        "claude-sonnet-4-6": Price(input:  3.0, output: 15.0),
        "claude-haiku-4-5":  Price(input:  1.0, output:  5.0),
    ]

    /// Default model assumed when a workerEvent has no recorded model. The
    /// rest of the system assumes Opus by default for dispatched tasks, so
    /// this matches that bias and keeps cost numbers honest.
    static let defaultModel = "claude-opus-4-7"

    /// Compute USD spend given a model id, separate input/output tokens.
    /// Unknown models return 0 and log a warning — the v0 card prefers
    /// "missed it" over "guessed wrong by 5×."
    static func costUSD(model: String, inputTokens: Int64, outputTokens: Int64) -> Double {
        guard let p = prices[model] else {
            warnUnknown(model)
            return 0
        }
        let inUSD = Double(inputTokens) / 1_000_000.0 * p.input
        let outUSD = Double(outputTokens) / 1_000_000.0 * p.output
        return inUSD + outUSD
    }

    /// We track only `totalTokens` per event in v0 (input + cache + output combined),
    /// not a separate input/output split. Assume an 80/20 input/output blend — what
    /// agent workloads actually look like — so the card can show a reasonable
    /// dollar figure without a schema change. When we later split tokens by side,
    /// callers can switch to `costUSD(model:inputTokens:outputTokens:)` directly.
    static func blendedCostUSD(model: String, totalTokens: Int64) -> Double {
        let resolved = prices[model] != nil ? model : defaultModel
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
            Data("[ModelPricing] unknown model '\(model)' — attributing $0. Update Sources/Lib/ModelPricing.swift to add it.\n".utf8)
        )
    }
}
