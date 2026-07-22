import Foundation
import GRDB
import Logging

/// The in-process handler for the memory sidecar.
///
/// Replaces the tier-1 architecture (Claude Code dispatcher + Haiku sub-agent
/// per event, 20-60s per hint pass, 20-46K tokens) with a Swift closure that
/// runs `mem_recall` server-side, filters against `already_injected`, formats
/// the top hits, and inserts a row into `sidecarHints`. Total wall time is
/// dominated by `mem_recall` itself — typically under 500ms for a scoped
/// query. Zero LLM tokens per event.
///
/// The design's core rules survive: precision over recall (limit to 3),
/// silence beats noise (skip write when nothing is judged worth surfacing).
/// The judgment step is `mem_recall`'s existing 7-layer ranking — the tier-1
/// sub-agent's LLM judgment was mostly cutting the bottom of that ranked list,
/// which `limit: 3` does for free.
///
/// The dispatcher and worker-prompt files (`SKILL.md`, `worker-prompt.md`)
/// are dead code as of this handler; they may or may not be removed from the
/// bundle in the same commit, but they can be — nothing here needs them.
enum MemorySidecarHandler {

    /// Sonata's local HTTP port — the same value the hooks use. Cached at
    /// process start; changing `$SONATA_PORT` mid-flight is not a supported
    /// mode. Loopback HTTP for `mem_recall` is a pragmatic choice: extracting
    /// the recall closure out of `recallActions` would be a lot more surgery
    /// than one localhost call is worth, and localhost round-trip on a warm
    /// process is measured in single-digit milliseconds.
    private static let sonataPort: Int = SonataInstance.port

    /// Build a handler closure for `SidecarInProcessRegistry.register`.
    ///
    /// Captures a logger so log lines land in the same file the LLM-driven
    /// sidecar's did. Everything else it needs is a singleton or the payload.
    static func handler(logger: Logger) -> SidecarInProcessHandler {
        return { @Sendable payload in
            let handlerLogger = logger
            do {
                try await run(payload: payload, logger: handlerLogger)
            } catch {
                handlerLogger.warning("memory sidecar handler failed on event \(payload.eventId): \(error)")
                throw error
            }
        }
    }

    // MARK: - Payload decode

    /// Slice of the memory_request payload the handler actually reads. Every
    /// other field the hook sends (budget_tier, judge_model, dedup_window)
    /// is either ignored or handled elsewhere; `top_k` is honored but capped
    /// at 3 because higher fan-out on advisory hints just makes noise.
    private struct Request: Decodable {
        let source_session_id: String
        let recent_context: RecentContext
        let already_injected: [String]?
        let top_k: Int?

        struct RecentContext: Decodable {
            let last_user_prompt: String?
            let last_assistant_head: String?
        }
    }

    // MARK: - Synchronous synthesize path (UserPromptSubmit hook)

    /// Produce a hint block for the current turn synchronously — the design
    /// this file is pivoting to as of 2026-07-22. The bash UserPromptSubmit
    /// hook POSTs Claude Code's raw hook input JSON to
    /// `/api/sidecar/hint/synthesize`; that endpoint calls this function and
    /// returns the wrapped block as the hook's stdout, which Claude Code
    /// prepends to the user's prompt.
    ///
    /// Returns nil when we chose silence (anchor rule / floor filter /
    /// empty candidate set / distillation produced no query). Returns a
    /// non-empty string ready to be printed as-is, wrapped in
    /// `<user-prompt-submit-hook>` tags.
    ///
    /// The old Stop-hook + `sidecarHints` table path (`run(payload:logger:)`
    /// below) is left in place for now but no longer fed by any hook. It
    /// can be removed once we're confident the synchronous path is right.
    static func synthesize(sessionId: String, prompt: String, logger: Logger) async -> String? {
        guard !sessionId.isEmpty else { return nil }

        // Distill distinctive tokens from the raw prompt. Casual prose
        // dilutes FTS scoring on curated surfaces (wiki, memories); a
        // distilled query gives BM25 a chance to weight the tokens that
        // actually identify the topic. Observed 2026-07-22: verbose
        // prompt like "tell me about the social-platform idea using the
        // tool Agent-Reach and the new pilot plan you have created"
        // failed to surface the Agent-Reach wiki page directly, while
        // the bare token "Agent-Reach" surfaced it as #1.
        let distilled = distill(prompt: prompt)
        guard !distilled.isEmpty else {
            logger.debug("memory sidecar: no distinctive tokens in prompt; staying silent")
            return nil
        }

        let userConfig = SidecarConfigStore.shared.config(forName: "memory")
        if userConfig.tier == .off {
            logger.debug("memory sidecar: tier=off; staying silent")
            return nil
        }
        let recencyMode = userConfig.recencyMode
        let minRankScore = userConfig.minRankScore
        let requestedLimit = 3

        let candidates: [Candidate]
        do {
            candidates = try await recall(
                query: distilled,
                limit: max(requestedLimit + 5, requestedLimit),
                recencyMode: recencyMode,
                excludeSessionId: sessionId
            )
        } catch {
            logger.debug("memory sidecar: recall failed: \(error); staying silent")
            return nil
        }
        guard !candidates.isEmpty else {
            logger.debug("memory sidecar: no candidates for prompt; staying silent")
            return nil
        }

        let ranked = candidates
            .filter { ($0.rankScore ?? 0) >= minRankScore }
            .sorted { ($0.rankScore ?? 0) > ($1.rankScore ?? 0) }

        // Anchor rule (see notes on the event-driven path below).
        func isAnchor(_ id: String) -> Bool {
            !id.hasPrefix("conv-") && !id.hasPrefix("email-")
        }
        let anchorHits = ranked.filter { isAnchor($0.id) }
        let rideAlongHits = ranked.filter { !isAnchor($0.id) }
        let filtered: [Candidate]
        if anchorHits.isEmpty {
            filtered = []
        } else {
            let rideAlongFill = max(0, requestedLimit - anchorHits.count)
            filtered = Array(anchorHits.prefix(requestedLimit))
                + Array(rideAlongHits.prefix(rideAlongFill))
        }
        guard !filtered.isEmpty else {
            logger.debug("memory sidecar: no anchor hit for prompt; staying silent")
            return nil
        }

        let hint = formatHint(candidates: filtered, sessionId: sessionId)
        guard !hint.isEmpty else { return nil }
        // Wrap in the same tag the previous JS hook wrote, so Claude
        // Code's existing UserPromptSubmit rendering treats it uniformly.
        return "<user-prompt-submit-hook>\n\(hint)\n</user-prompt-submit-hook>"
    }

    // MARK: - Distillation

    /// Extract distinctive tokens from a raw user prompt. The goal is a
    /// short high-signal query for FTS + vector recall.
    ///
    /// Kept tokens:
    /// - Words with an internal capital or a hyphen (`Agent-Reach`, `iOS`).
    /// - Quoted strings (single and double), verbatim contents.
    /// - Capitalized words that aren't at a sentence start.
    /// - Any token ≥ 6 chars that isn't in the stopword list.
    ///
    /// Dropped tokens:
    /// - Stopwords ("that", "them", "which", …).
    /// - Numbers-only tokens.
    /// - Punctuation and single characters.
    ///
    /// Output is the distinct tokens joined by spaces, preserving
    /// first-seen order. Caller decides what to do with an empty result
    /// (typically: stay silent).
    private static let distillStopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "these", "those", "them",
        "they", "there", "then", "than", "have", "has", "had", "was", "were",
        "been", "being", "will", "would", "could", "should", "shall", "must",
        "your", "yours", "our", "ours", "their", "theirs", "his", "her", "him",
        "she", "some", "any", "each", "every", "what", "when", "where", "why",
        "how", "who", "which", "whose", "into", "onto", "from", "about", "over",
        "under", "again", "before", "after", "while", "until", "unless", "though",
        "although", "because", "since", "still", "just", "only", "even", "also",
        "very", "much", "many", "more", "most", "less", "least", "such", "same",
        "here", "does", "doing", "done", "make", "made", "using", "used", "give",
        "gave", "know", "knew", "think", "thought", "want", "wanted", "need",
        "please", "yeah", "okay", "hello", "let", "lets", "gonna", "wanna",
        "kind", "sort", "type", "thing", "things", "stuff", "point", "part",
        "case", "cases", "detail", "details", "idea", "ideas", "plan", "plans",
    ]

    static func distill(prompt: String) -> String {
        guard !prompt.isEmpty else { return "" }
        var seen = Set<String>()
        var out: [String] = []

        // First pass: extract quoted spans verbatim; keep them intact.
        let quoted = extractQuotedSpans(prompt)
        for span in quoted {
            let key = span.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(span)
        }

        // Tokenize by whitespace + basic punctuation; keep hyphens inside
        // tokens so `Agent-Reach` and `slot-auto-1` stay one token.
        let scanned = tokenize(prompt)
        var index = 0
        for tok in scanned {
            defer { index += 1 }
            let cleaned = tok.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'"))
            guard cleaned.count > 1 else { continue }
            if isPureNumber(cleaned) { continue }
            let lower = cleaned.lowercased()
            if distillStopwords.contains(lower) { continue }

            let keep: Bool
            if hasInternalCapitalOrHyphen(cleaned) {
                keep = true
            } else if isCapitalized(cleaned) && index > 0 {
                keep = true
            } else if cleaned.count >= 6 {
                keep = true
            } else {
                keep = false
            }
            guard keep else { continue }
            guard seen.insert(lower).inserted else { continue }
            out.append(cleaned)
        }
        // Cap at ~200 chars so pathological prompts don't blow up
        // the FTS query. Tokens are ordered by first appearance, so
        // truncation drops the tail (less-important) first.
        var joined = out.joined(separator: " ")
        if joined.count > 200 {
            joined = String(joined.prefix(200))
        }
        return joined
    }

    private static func extractQuotedSpans(_ text: String) -> [String] {
        var spans: [String] = []
        let quoteChars: [Character] = ["\"", "'", "`"]
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if quoteChars.contains(ch) {
                let start = text.index(after: i)
                if let end = text[start...].firstIndex(of: ch) {
                    let span = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
                    if !span.isEmpty && span.count <= 60 { spans.append(span) }
                    i = text.index(after: end)
                    continue
                }
            }
            i = text.index(after: i)
        }
        return spans
    }

    private static func tokenize(_ text: String) -> [String] {
        // Split on whitespace and a small punctuation set; keep hyphens
        // and dots inside tokens so URLs and hyphenated names survive.
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",;:!?()[]{}\"'"))
        return text.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    private static func isPureNumber(_ s: String) -> Bool {
        return !s.isEmpty && s.allSatisfy { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
    }

    private static func hasInternalCapitalOrHyphen(_ s: String) -> Bool {
        guard s.count > 1 else { return false }
        if s.contains("-") { return true }
        // Internal capital: capital letter after the first character.
        let after = s.dropFirst()
        return after.contains(where: { $0.isUppercase })
    }

    private static func isCapitalized(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        return first.isUppercase
    }

    // MARK: - Core (event-driven, deprecated as of 2026-07-22)
    //
    // Retained for now so the sidecar event delivery path keeps compiling
    // and any not-yet-drained memory_request events don't hard-crash.
    // Once the synchronous synthesize path is proven and hooks are cut
    // over, this and its supporting Request struct can go.

    private static func run(payload: SidecarEventPayload, logger: Logger) async throws {
        guard let data = payload.payloadJSON.data(using: .utf8) else {
            logger.warning("memory sidecar: payload for \(payload.eventId) is not UTF-8")
            return
        }
        let request: Request
        do {
            request = try JSONDecoder().decode(Request.self, from: data)
        } catch {
            logger.warning("memory sidecar: payload for \(payload.eventId) failed decode: \(error)")
            return
        }

        let sessionId = request.source_session_id
        guard !sessionId.isEmpty else {
            logger.warning("memory sidecar: event \(payload.eventId) has empty source_session_id")
            return
        }

        let query = queryText(from: request)
        guard !query.isEmpty else {
            logger.info("memory sidecar: event \(payload.eventId) has no usable query text — skipping")
            return
        }

        // Read the two tunables from the settings-panel-owned config. Every
        // invocation reads afresh — the SidecarConfigStore lock is cheap
        // and it means a user tweaking the knobs sees them apply on the
        // very next event.
        let userConfig = SidecarConfigStore.shared.config(forName: "memory")
        let recencyMode = userConfig.recencyMode
        let minRankScore = userConfig.minRankScore

        let alreadyInjected = Set(request.already_injected ?? [])
        // Cap top_k at 3. The tier-1 design's default was 10 with a judge step
        // that trimmed hard; here there's no judge, so a wide fan-out would
        // inject noise. Three high-confidence hints beat ten mixed-quality ones.
        let requestedLimit = request.top_k.map { max(1, min(3, $0)) } ?? 3

        let candidates = try await recall(
            query: query,
            limit: max(requestedLimit + alreadyInjected.count, requestedLimit),
            recencyMode: recencyMode,
            excludeSessionId: sessionId
        )
        guard !candidates.isEmpty else {
            logger.debug("memory sidecar: no candidates for event \(payload.eventId)")
            return
        }

        let ranked = candidates
            .filter { !alreadyInjected.contains($0.id) }
            .filter { ($0.rankScore ?? 0) >= minRankScore }
            .sorted { ($0.rankScore ?? 0) > ($1.rankScore ?? 0) }

        // Anchor rule. Anchor-qualifying hits are memories and wiki
        // pages — both are curated / structured surfaces where a
        // present hit is a strong topic signal. Conv chunks and emails
        // are ride-along only: raw FTS on session transcripts / inbox
        // with no floor of their own, prone to returning "best
        // word-matched thing" for casual queries. Without an anchoring
        // hit above the score floor, ride-alongs are almost always
        // noise, so we drop them too and stay silent.
        //
        // Observed 2026-07-22: casual prompts routinely surfaced 3
        // unrelated conv chunks and zero memory hits — silence would
        // have been more useful. Initial anchor rule counted only
        // memory rows; refined shortly after to include wiki pages
        // because a wiki hit on Agent-Reach was being silenced despite
        // being the correct answer.
        func isAnchor(_ id: String) -> Bool {
            !id.hasPrefix("conv-") && !id.hasPrefix("email-")
        }
        let anchorHits = ranked.filter { isAnchor($0.id) }
        let rideAlongHits = ranked.filter { !isAnchor($0.id) }
        let filtered: [Candidate]
        if anchorHits.isEmpty {
            filtered = []
        } else {
            let rideAlongFill = max(0, requestedLimit - anchorHits.count)
            filtered = Array(anchorHits.prefix(requestedLimit))
                + Array(rideAlongHits.prefix(rideAlongFill))
        }
        guard !filtered.isEmpty else {
            logger.debug("memory sidecar: no anchor hit for event \(payload.eventId); staying silent (anchor rule)")
            return
        }

        let hint = formatHint(candidates: filtered, sessionId: sessionId)
        guard !hint.isEmpty else { return }
        try await writeHint(sessionId: sessionId, content: hint)
        logger.info("memory sidecar: wrote \(filtered.count) hint(s) for session \(sessionId) on event \(payload.eventId)")
    }

    // MARK: - Query

    /// The query text passed to `mem_recall`. Prompt + assistant head
    /// concatenated when both are present.
    ///
    /// Continuation prompts ("what did we find out?", "keep going", "same but
    /// simpler") are casual by construction — the distinctive topic nouns
    /// live in the assistant's previous reply, not the user's short follow-up.
    /// Concatenating both lets mem_recall's FTS + vector layers pick up those
    /// nouns and rank the right memories.
    ///
    /// Observed 2026-07-22: with prompt only, "okay so what did we find out
    /// about scouts paranoia" ranked the target memory c59e17db off the top
    /// 10 entirely (top hit dropped to 0.555, below default floor 0.60). The
    /// same day's dense-noun rephrasing ("Scout paranoia protocol-seam prompt
    /// injection") pulled c59e17db to rank 0.833. Assistant head carries the
    /// dense nouns forward across the casual follow-up.
    ///
    /// Tradeoff: on a true topic shift, the previous head's nouns pollute the
    /// query. mem_recall's vector layer leans toward the user prompt in that
    /// case because the topic-shift prompt clusters near its own memories
    /// semantically, so this usually degrades gracefully rather than
    /// misrouting.
    ///
    /// Capped at 3000 chars — mem_recall's tokenizer truncates beyond ~2k
    /// anyway, and the prompt gets first-position priority.
    private static func queryText(from request: Request) -> String {
        let prompt = request.recent_context.last_user_prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let head = request.recent_context.last_assistant_head?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !prompt.isEmpty && !head.isEmpty {
            return String((prompt + "\n\n" + head).prefix(3000))
        }
        if !prompt.isEmpty {
            return String(prompt.prefix(2000))
        }
        return String(head.prefix(2000))
    }

    // MARK: - Recall

    /// One hit from `mem_recall`. `rankScore` is the ranking signal we filter
    /// by (the score floor); `l0` / `l1` are the abstract lines the hint
    /// formatter uses. Every other field the endpoint returns
    /// (`_scoreComponents`, `updatedAt`, tags, …) is dropped on decode.
    private struct Candidate: Decodable {
        let id: String
        let rankScore: Double?
        let l0: String?
        let l1: String?

        enum CodingKeys: String, CodingKey {
            case id = "_id"
            case rankScore = "_rankScore"
            case l0
            case l1
        }
    }

    /// One hit from the conversations layer of mem_recall — a chunk of a
    /// past Claude Code session transcript that matched the query text.
    ///
    /// Conversations don't come with a `_rankScore` field (they're ordered
    /// by the FTS engine that produced them), so we synthesize a
    /// respectable-looking score for the score-floor filter. `.transcript`
    /// score of 0.70 puts them above the default 0.60 floor without
    /// pretending to be top-tier memories.
    private struct ConversationHit: Decodable {
        let sessionId: String
        let chunk: String?
        let snippet: String
        let project: String?
    }

    /// One hit from the emails layer of mem_recall — a past inbound or
    /// outbound email whose FTS matched the query. Same synthetic-rank
    /// treatment as conversations: no `_rankScore` in the response.
    private struct EmailHit: Decodable {
        let id: String
        let subject: String?
        let snippet: String?
        let fromAddr: String?

        enum CodingKeys: String, CodingKey {
            case id = "_id"
            case subject, snippet, fromAddr
        }
    }

    /// One hit from the wiki layer of mem_recall — a page in the local
    /// wiki tree. The `slug` (e.g. "sonata/backlog") is stable enough to
    /// use as the synthetic id.
    private struct WikiHit: Decodable {
        let slug: String
        let title: String?
        let snippet: String?
    }

    private struct RecallResponse: Decodable {
        let memories: [Candidate]?
        let conversations: [ConversationHit]?
        let emails: [EmailHit]?
        let wikiPages: [WikiHit]?
    }

    /// Score we assign to non-memory hits (conversations, emails, wiki)
    /// so they can pass through the same rank-floor filter as memories
    /// without needing a real ranking signal. Above the tested default
    /// floor (0.60) so at-default settings still surface them; not so
    /// high that a user tightening to 0.75+ can't tune them out.
    ///
    /// Note: these hits only surface when a real memory anchor clears
    /// the floor (see the memory-anchor rule in `run`), so this constant
    /// controls whether they can ride along at all rather than whether
    /// they can beat memories on their own.
    private static let conversationSynthesizedRank: Double = 0.70
    private static let emailSynthesizedRank: Double = 0.70
    private static let wikiSynthesizedRank: Double = 0.70

    private static func recall(
        query: String,
        limit: Int,
        recencyMode: SidecarUserConfig.RecencyMode,
        excludeSessionId: String
    ) async throws -> [Candidate] {
        var components = URLComponents(string: "http://127.0.0.1:\(sonataPort)/api/recall")!
        components.queryItems = [
            URLQueryItem(name: "topic", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "tier", value: "l0"),
            URLQueryItem(name: "recencyMode", value: recencyMode.rawValue),
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw HandlerError.recallFailed("HTTP \(code)")
        }

        let decoded = try JSONDecoder().decode(RecallResponse.self, from: data)
        let memories = decoded.memories ?? []

        // Merge conversation hits into the memory candidate stream. Every
        // conversation gets a synthetic id (`conv-<session>-<chunk>`) so
        // the already_injected ledger and the hint markdown's `[memory:
        // <id>]` link work uniformly. Snippets get trimmed to 180 chars
        // so a single injected hint line stays readable.
        //
        // Conversations were being silently dropped in the original decode
        // — sidecar tests on 2026-07-22 showed 5 conversation hits, 5
        // email hits and 3 wiki hits all being thrown out on a Scout topic
        // where the extracted-memory layer was thin but the transcript
        // layer had the story.
        let conversationCandidates: [Candidate] = (decoded.conversations ?? []).compactMap { c in
            // Exclude the source session's own transcript. The FTS layer
            // otherwise ranks the current session's chunks highest for
            // any topic we're discussing here — by construction those
            // chunks add zero information because the reader already has
            // them in active context. Observed 2026-07-22: on questions
            // about Scout paranoia, the top conversation hit was
            // consistently a snippet from THIS session (my own words back
            // at me) rather than the older Scout-paranoia discussions we
            // actually needed.
            guard c.sessionId != excludeSessionId else { return nil }
            let snippet = c.snippet.replacingOccurrences(of: "\n", with: " ")
                                   .replacingOccurrences(of: "\r", with: " ")
                                   .trimmingCharacters(in: .whitespaces)
            guard !snippet.isEmpty else { return nil }
            let takeaway = String(snippet.prefix(180))
            let sid = c.sessionId.replacingOccurrences(of: "-", with: "").prefix(12)
            let chunk = c.chunk ?? "?"
            return Candidate(
                id: "conv-\(sid)-\(chunk)",
                rankScore: conversationSynthesizedRank,
                l0: "past session · \(takeaway)",
                l1: nil
            )
        }

        // Emails: subject + one-line snippet takeaway. Prefix ids with
        // `email-` so the memory-anchor rule treats them as non-memory
        // hits (they only surface when a real memory anchor exists).
        let emailCandidates: [Candidate] = (decoded.emails ?? []).compactMap { e in
            let subject = (e.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = (e.snippet ?? "").replacingOccurrences(of: "\n", with: " ")
                                       .replacingOccurrences(of: "\r", with: " ")
                                       .trimmingCharacters(in: .whitespaces)
            let snippet = String(raw.prefix(160))
            let head = subject.isEmpty ? snippet : subject
            guard !head.isEmpty else { return nil }
            let takeaway = subject.isEmpty
                ? "past email · \(head)"
                : "past email · \(head)\(snippet.isEmpty ? "" : " — \(snippet)")"
            return Candidate(
                id: "email-\(e.id)",
                rankScore: emailSynthesizedRank,
                l0: takeaway,
                l1: nil
            )
        }

        // Wiki pages: title + snippet takeaway. Prefix ids with `wiki-`
        // for the same anchor-rule reason as emails and conversations.
        let wikiCandidates: [Candidate] = (decoded.wikiPages ?? []).compactMap { w in
            let title = (w.title ?? w.slug).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let raw = (w.snippet ?? "").replacingOccurrences(of: "\n", with: " ")
                                       .replacingOccurrences(of: "\r", with: " ")
                                       .trimmingCharacters(in: .whitespaces)
            let snippet = String(raw.prefix(160))
            let takeaway = snippet.isEmpty ? "wiki · \(title)" : "wiki · \(title) — \(snippet)"
            return Candidate(
                id: "wiki-\(w.slug)",
                rankScore: wikiSynthesizedRank,
                l0: takeaway,
                l1: nil
            )
        }

        let all = memories + conversationCandidates + emailCandidates + wikiCandidates
        return await applyNoiseDownweight(all)
    }

    /// Look up how many times each candidate id has been flagged as
    /// noise in the last 7 days and multiply the rank score by a
    /// per-flag penalty. Noise is hint-specific — we deliberately do
    /// not apply this in `/api/recall` itself, since a memory that's
    /// noise for an auto-injected hint block can still be the right
    /// answer for a deliberate chat recall. Applying it here keeps the
    /// feedback loop scoped to the sidecar.
    ///
    /// **Split-penalty curve.** Anchors (memories, wiki pages) get a
    /// gentle penalty, ride-alongs (conv chunks, emails) get an
    /// aggressive one. The two classes represent different failure
    /// modes:
    ///
    /// - Ride-along noise = "this specific chunk / email is spammy /
    ///   generic and shouldn't ride along" → we WANT to silence it fast.
    ///   `penalty = min(0.50, n × 0.15)` — 15% off after 1 flag, kills
    ///   at ~3 flags (0.70 base × 0.55 = 0.385, below default floor).
    ///
    /// - Anchor noise = "this curated page came up wrong for THIS query"
    ///   → doesn't mean the page is generally noisy; the topic mismatch
    ///   might be one-off. `penalty = min(0.10, n × 0.02)` — capped at
    ///   10% regardless of flag count, enough to be a tiebreaker but
    ///   never enough to push a legit anchor below the 0.60 floor.
    ///
    /// Rationale for the split: today's failure mode was that flagging
    /// wiki pages as noise for irrelevant queries would eventually kill
    /// them for direct-topic queries where they ARE the right answer.
    /// Uniform penalty punished anchors as harshly as ride-alongs; the
    /// split preserves anchor visibility while retiring bad ride-alongs.
    private static let noiseWindowMs: Int64 = 7 * 24 * 60 * 60 * 1000

    private static func applyNoiseDownweight(_ candidates: [Candidate]) async -> [Candidate] {
        guard !candidates.isEmpty else { return candidates }
        guard let dbPool = SonataApp.sharedDbPool else { return candidates }
        let ids = candidates.map { $0.id }
        let cutoff = nowMs() - noiseWindowMs
        let counts: [String: Int]
        do {
            counts = try await dbPool.read { db -> [String: Int] in
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                let sql = """
                    SELECT memoryId, COUNT(*) AS n
                    FROM sidecarHintNoise
                    WHERE recordedAtMs >= ?
                      AND memoryId IN (\(placeholders))
                    GROUP BY memoryId
                """
                var arguments: [DatabaseValueConvertible] = [cutoff]
                arguments.append(contentsOf: ids)
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                var out: [String: Int] = [:]
                for row in rows {
                    let mid: String = row["memoryId"] ?? ""
                    let n: Int = row["n"] ?? 0
                    if !mid.isEmpty { out[mid] = n }
                }
                return out
            }
        } catch {
            return candidates
        }
        return candidates.map { c in
            let n = counts[c.id] ?? 0
            guard n > 0, let base = c.rankScore else { return c }
            let isRideAlong = c.id.hasPrefix("conv-") || c.id.hasPrefix("email-")
            let penalty: Double = isRideAlong
                ? min(0.50, Double(n) * 0.15)
                : min(0.10, Double(n) * 0.02)
            return Candidate(
                id: c.id,
                rankScore: base * (1.0 - penalty),
                l0: c.l0,
                l1: c.l1
            )
        }
    }

    // MARK: - Format

    /// Produce the same markdown-block shape the tier-1 sub-agent used to
    /// write. The UserPromptSubmit hook's `extractMemoryIds` regex still
    /// matches `[memory: <id>]` here, so `already_injected` tracking works
    /// with no hook change.
    ///
    /// One takeaway line per candidate. Uses the memory's `l0` (compact
    /// abstract) as the takeaway if present; falls back to a trimmed `l1`
    /// (short summary) if only that landed. Never inlines the full body —
    /// that would explode the hint block past what a reader will actually
    /// read.
    private static func formatHint(candidates: [Candidate], sessionId: String) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        lines.append("<!-- Sidecar · \(now) · judge=none · \(candidates.count) hint\(candidates.count == 1 ? "" : "s") -->")
        lines.append("## Possibly relevant")
        lines.append("")
        for c in candidates {
            let takeaway = (c.l0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? c.l0 : c.l1)
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? c.id
            let oneLine = takeaway
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            lines.append("- **\(oneLine)** — [memory: \(c.id)]")
        }
        lines.append("")
        // Persistent nudge for the receiver. Any hint the receiver judges as
        // noise gets flagged via sidecar_hint_noise. Batched by hint block
        // — one tool call, list all noise ids. Silence means the block
        // was fine. Repeated here in every hint so the reader is prompted
        // without needing to remember a global rule.
        let ids = candidates.map { "\"\($0.id)\"" }.joined(separator: ", ")
        lines.append("<!-- feedback: if any of these were noise, call sidecar_hint_noise(sessionId=\"\(sessionId)\", memoryIds=[\(ids)]) with just the noise ids -->")
        lines.append("<!-- /end -->")
        return lines.joined(separator: "\n")
    }

    // MARK: - Write

    /// Persist the hint via a direct DB insert. Avoids another loopback HTTP
    /// hop through `/api/sidecar/hint/write` (which the hooks use) — that
    /// endpoint's validation (empty-content rejection, whitespace checks)
    /// isn't relevant here because this code is the only writer and we've
    /// already decided the content is worth writing.
    private static func writeHint(sessionId: String, content: String) async throws {
        guard let dbPool = SonataApp.sharedDbPool else {
            throw HandlerError.noDBPool
        }
        let now = nowMs()
        try await dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO sidecarHints (sessionId, content, writtenAtMs)
                VALUES (?, ?, ?)
            """, arguments: [sessionId, content, now])
        }
    }

    // MARK: - Errors

    enum HandlerError: Error, CustomStringConvertible {
        case recallFailed(String)
        case noDBPool

        var description: String {
            switch self {
            case .recallFailed(let msg): return "mem_recall failed: \(msg)"
            case .noDBPool:              return "SonataApp.sharedDbPool is nil at hint write"
            }
        }
    }
}
