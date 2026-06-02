import Foundation
import Logging

/// Generates LOD (Level-of-Detail) summaries for memory content using the
/// local Llama 3.1 8B chat server. L0/L1 are stored on the `memories` row at
/// store time so budget-aware recall can fit more memories per token budget
/// by picking the appropriate tier per memory.
///
/// - L0: one sentence, ~15 words — the thesis / essence
/// - L1: 2–3 sentences, ~60 words — the argument arc / key facts
///
/// The model + system prompt + sampling config are FROZEN. Any change must be
/// matched in `Tests/SonataTests/fixtures/pith-golden/record-goldens.sh` and
/// the regenerated goldens reviewed before commit. See
/// `Tests/SonataTests/PithRegressionTests.swift`.
enum Pith {

    /// The locked system prompt. If you change this, regenerate goldens (see
    /// `Tests/SonataTests/fixtures/pith-golden/README.md`).
    static let systemPrompt = (
        "You generate LOD summaries for memories. " +
        "Return STRICT JSON with two fields: l0 and l1. " +
        "l0 = one sentence, max ~15 words, the thesis or essence. " +
        "l1 = 2-3 sentences, max ~60 words, the argument arc or key facts. " +
        "Be abstractive — distill, don't quote. " +
        "Match the voice of the source (first-person for reflections, third-person for technical notes). " +
        "For very short input, l0/l1 may equal input. " +
        "Output ONLY the JSON. No preamble, no markdown fences."
    )

    struct Result: Sendable, Equatable {
        let l0: String
        let l1: String
    }

    enum PithError: Error {
        case parseFailed(raw: String)
        case missingField(String, raw: String)
    }

    /// Generate L0/L1 for `content`. Spawns the chat server on first use; the
    /// 4.6 GB GGUF is fetched via `BinaryProvisioner` on absolute first use.
    ///
    /// `maxTokens` is overridden (vs `ChatServerManager`'s 400 default) because
    /// 400 truncated ~14% of responses mid-JSON during the initial backfill —
    /// Llama 3.1 8B happily produces 250-300 word L1 paragraphs for dense
    /// technical memories, blowing past the budget and emitting un-parseable
    /// half-strings. Running locally there's no per-token cost, so this is
    /// generous on purpose — it's a runaway-protection ceiling, not a target.
    /// The model stops at the closing `}` for well-formed JSON regardless.
    /// Regression goldens are unaffected: temp+seed are locked, and at fixed
    /// sampling the same input deterministically produces the same bytes as
    /// long as the cap allows the response to complete.
    static let generateMaxTokens = 1500

    static func generate(content: String) async throws -> Result {
        let raw = try await ChatServerManager.shared.chatCompletion(
            systemPrompt: systemPrompt,
            userContent: content,
            maxTokens: generateMaxTokens
        )
        return try parse(raw)
    }

    /// Fail-soft variant used by store/patch paths: returns nil on any error so
    /// the write itself never fails because of pith trouble (server down, parse
    /// failure, network blip). The backfill task picks up NULL rows later.
    /// Errors are logged at warn level for visibility.
    static func generateOrNil(content: String, logger: Logger? = nil) async -> Result? {
        do {
            return try await generate(content: content)
        } catch {
            (logger ?? Logger(label: "sonata.pith"))
                .warning("pith generation failed; storing NULL l0/l1 (\(error))")
            return nil
        }
    }

    /// Compress `text` to roughly `maxLength` characters, preserving key info.
    /// Used by the legacy `/api/pith` endpoint (separate use case from L0/L1
    /// generation — this returns plain text, not structured tiers).
    ///
    /// NOTE: model is asked to honor `maxLength` but doesn't strictly — small
    /// models routinely blow past character budgets when source is dense. The
    /// existing endpoint behavior was the same (gpt-4o-mini blew budget on 3/5
    /// of our bake-off inputs), so this is contract-preserving. Callers that
    /// need a hard length cap should clip the returned string themselves.
    static func compress(text: String, maxLength: Int) async throws -> String {
        let system = (
            "You are a text compressor. " +
            "Compress the user's text to at most \(maxLength) characters while " +
            "preserving all key information. " +
            "Return ONLY the compressed text, nothing else."
        )
        let raw = try await ChatServerManager.shared.chatCompletion(
            systemPrompt: system,
            userContent: text,
            maxTokens: max(maxLength * 2, 64),  // tokens, not chars — generous
            jsonObject: false
        )
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Defensive parse: strip any markdown fences (Llama 3.1 8B usually
    /// complies but Qwen/Falcon variants wrap in ```json``` blocks; we keep the
    /// stripper to be robust to model swaps), then JSON-decode and extract
    /// `l0`/`l1`. Throws on parse failure or missing fields.
    static func parse(_ raw: String) throws -> Result {
        let cleaned = stripFences(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let data = cleaned.data(using: .utf8),
           let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            candidate = cleaned
        } else if let start = cleaned.firstIndex(of: "{"),
                  let end = cleaned.lastIndex(of: "}"), end > start {
            candidate = String(cleaned[start...end])
        } else {
            throw PithError.parseFailed(raw: raw)
        }
        guard let data = candidate.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PithError.parseFailed(raw: raw)
        }
        guard let l0 = obj["l0"] as? String, !l0.isEmpty else {
            throw PithError.missingField("l0", raw: raw)
        }
        guard let l1 = obj["l1"] as? String, !l1.isEmpty else {
            throw PithError.missingField("l1", raw: raw)
        }
        return Result(l0: l0, l1: l1)
    }

    // ```json … ``` → … and ``` … ``` → …
    private static let fencePattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^\s*```(?:json)?\s*|\s*```\s*$"#,
            options: [.anchorsMatchLines]
        )
    }()

    static func stripFences(_ s: String) -> String {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return fencePattern.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    }
}
