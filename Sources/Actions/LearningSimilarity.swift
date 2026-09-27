import Foundation
import GRDB

/// Near-duplicate detection for `mem_store(type: learning)`.
///
/// On 2026-09-26 five HS-guide research workers each stored a "reusable techniques"
/// learning for the same tricks (PSAL team-page hash route, Maps depart-at
/// URL, MySchools admissions parsing, …). Nothing noticed until a consolidation
/// run read them side by side. The 7/13 rule — a re-derived technique belongs in
/// the next reader's first artifact, not a sixth memory — needs the writer to be
/// told at write time, so mem_store now names recent learnings that look like the
/// same thing. It never blocks the write.
///
/// Method, all lexical (FTS5, no vectors):
///   1. Pick the new memory's most DISTINCTIVE terms: term frequency in the new
///      text × log(N / document frequency) over the whole memories_fts corpus.
///      Rarity is what separates "psal", "getteamscheduleany", "myschools" from
///      "school", "session", "page".
///   2. OR those terms in an FTS5 query over learnings in the same `project`
///      (NULL is its own bucket) created in the 7 days up to the new memory's
///      createdAt. Rank by bm25.
///   3. Gate each hit on how many of the query terms it actually contains
///      (at least 4 of the 8), and keep the top 3 that pass.
///
/// Why the gate is a shared-term count and not an absolute bm25 cutoff: bm25 is
/// relative to the corpus it's computed over. The same pair of texts scored
/// -46.8 against the live 36k-row table, but a very different number in a
/// 7-row test database, so a fixed bm25 threshold would behave one way in tests
/// and another in production. "At least 4 of the 8 most distinctive terms"
/// means the same thing at any corpus size. bm25 still decides the order.
enum LearningSimilarity {
    /// How far back to look, relative to the new memory's createdAt.
    static let windowMs: Int64 = 7 * 24 * 60 * 60 * 1000
    /// Distinctive terms used for the query.
    static let queryTermCount = 8
    /// A hit must contain at least this many of the query terms (half).
    /// Measured on the live corpus, the 55 learnings of 2026-09-20..27:
    /// 3 would warn on 36 of them (mostly generic overlaps like "school" +
    /// "nyc"), 4 warns on 24 (mostly genuine repeats), 5 warns on 19 but
    /// loses 67aa526c -> 21aba24c, a real twin sharing exactly 4 terms.
    static let minSharedTerms = 4
    /// Maximum similar learnings reported.
    static let maxResults = 3
    /// FTS hits examined before the gate (bm25 order).
    static let candidatePoolSize = 12
    /// Distinct terms whose document frequency we look up. Bounds the number of
    /// FTS count queries for very long memories; the most frequent terms win.
    static let maxTermsConsidered = 120

    static let hint = "If these describe the same technique, update the shared doc (e.g. TECHNIQUES.md) "
        + "instead of adding another memory."

    /// Common English and memory-boilerplate words that carry no topic.
    /// Rarity weighting already discounts most of these; listing them keeps a
    /// small corpus (fresh install, tests) from treating them as distinctive.
    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "these", "those", "them", "they",
        "there", "then", "than", "have", "has", "had", "was", "were", "been", "being",
        "will", "would", "could", "should", "shall", "must", "your", "yours", "our",
        "ours", "their", "theirs", "his", "her", "him", "she", "some", "any", "each",
        "every", "what", "when", "where", "why", "how", "who", "which", "whose", "into",
        "onto", "from", "about", "over", "under", "again", "before", "after", "while",
        "until", "unless", "though", "although", "because", "since", "still", "just",
        "only", "even", "also", "very", "much", "many", "more", "most", "less", "least",
        "such", "same", "here", "does", "doing", "done", "make", "made", "using", "used",
        "use", "uses", "give", "gave", "know", "knew", "think", "thought", "want",
        "wanted", "need", "needs", "not", "but", "are", "its", "can", "one", "two",
        "all", "out", "get", "got", "via", "per", "don", "doesn", "isn", "aren", "won",
        "didn", "you", "yes", "now", "new", "way", "first", "other",
        "like", "well", "back", "take", "see", "run", "runs", "set", "put", "may",
    ]

    /// A recent learning that looks like the one being stored.
    struct Match: Equatable {
        let id: String
        /// Query terms the match contains, in query order.
        let sharedTerms: [String]
        /// FTS5 bm25 rank (lower is a stronger match).
        let rank: Double
    }

    /// Lowercased, diacritic-folded tokens split on every non-letter/non-digit,
    /// which is how FTS5's default unicode61 tokenizer splits, so a term chosen
    /// here is exactly one FTS token ("team-profile.aspx" -> team, profile,
    /// aspx). Drops tokens under 3 characters, pure numbers, and stopwords.
    static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        var out: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out.filter { token in
            token.count >= 3
                && !token.allSatisfy(\.isNumber)
                && !stopwords.contains(token)
        }
    }

    /// Corpus statistics behind the rarity weighting: N and per-term document
    /// frequency. Production reads them from memories_fts; the replay tests
    /// inject frozen live-corpus numbers, because rarity is meaningless in a
    /// 2-7 row test database (every shared word looks rare there).
    struct TermStatistics {
        let total: () throws -> Int
        let documentFrequency: (String) throws -> Int

        static func fts(_ db: Database) -> TermStatistics {
            TermStatistics(
                total: { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories") ?? 0 },
                documentFrequency: { term in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM memories_fts WHERE memories_fts MATCH ?",
                        arguments: ["\"\(term)\""]
                    ) ?? 0
                }
            )
        }
    }

    /// Test seam: when set, mem_store uses these statistics instead of
    /// memories_fts. Only the tests set it.
    nonisolated(unsafe) static var statisticsOverride: TermStatistics?

    /// The `limit` most distinctive terms of `content`, strongest first:
    /// tf in `content` × ln(N / df), df counted over all of memories_fts.
    /// Terms present in every memory score zero and are dropped. Ties break
    /// alphabetically so the choice is deterministic.
    static func distinctiveTerms(
        _ db: Database,
        content: String,
        limit: Int = queryTermCount,
        statistics: TermStatistics? = nil
    ) throws -> [String] {
        let stats = statistics ?? statisticsOverride ?? .fts(db)
        var tf: [String: Int] = [:]
        for token in tokens(content) { tf[token, default: 0] += 1 }
        guard !tf.isEmpty else { return [] }

        let considered = tf
            .sorted { $0.value != $1.value ? $0.value > $1.value : ($0.key.count != $1.key.count ? $0.key.count > $1.key.count : $0.key < $1.key) }
            .prefix(maxTermsConsidered)

        let total = Double(try stats.total())
        guard total > 0 else { return [] }

        var scored: [(term: String, score: Double)] = []
        for (term, count) in considered {
            let df = try stats.documentFrequency(term)
            let idf = log(total / Double(max(1, df)))
            guard idf > 0 else { continue }
            scored.append((term, Double(count) * idf))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.term < $1.term }
        return scored.prefix(limit).map(\.term)
    }

    /// Recent same-project learnings that share at least `minSharedTerms` of the
    /// new memory's distinctive terms, strongest bm25 first, at most `maxResults`.
    /// `memoryId` is excluded, so this is safe to call after the INSERT.
    static func findSimilar(
        _ db: Database,
        memoryId: String,
        content: String,
        project: String?,
        createdAt: Int64
    ) throws -> [Match] {
        let terms = try distinctiveTerms(db, content: content)
        guard terms.count >= minSharedTerms else { return [] }

        let query = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT m.id AS id, m.content AS content, bm25(memories_fts) AS rank
            FROM memories_fts
            JOIN memories m ON m.rowid = memories_fts.rowid
            WHERE memories_fts MATCH ?
              AND m.type = 'learning'
              AND m.id != ?
              AND m.project IS ?
              AND m.createdAt >= ?
              AND m.createdAt <= ?
              AND (m.status IS NULL OR m.status NOT IN ('archived', 'superseded'))
            ORDER BY rank ASC, m.id ASC
            LIMIT ?
            """,
            arguments: [query, memoryId, project, createdAt - windowMs, createdAt, candidatePoolSize]
        )

        var matches: [Match] = []
        for row in rows {
            let candidateTokens = Set(tokens(row["content"] as String? ?? ""))
            let shared = terms.filter { candidateTokens.contains($0) }
            guard shared.count >= minSharedTerms else { continue }
            matches.append(Match(id: row["id"], sharedTerms: shared, rank: row["rank"]))
            if matches.count == maxResults { break }
        }
        return matches
    }

    /// The caller-facing `warnings` line for a non-empty match list. Full ids,
    /// because the remedy is a patch/supersede by id and truncated ids don't
    /// resolve.
    static func warning(for matches: [Match]) -> String {
        let named = matches
            .map { "\($0.id) (shares: \($0.sharedTerms.joined(separator: ", ")))" }
            .joined(separator: "; ")
        return "similar_recent_learnings: this learning looks like \(matches.count) same-project learning"
            + "\(matches.count == 1 ? "" : "s") from the last 7 days: \(named). \(hint)"
    }
}

/// Structured form of the similar-learnings warning, returned alongside the
/// human-readable `warnings` line so a caller can act on the ids directly.
struct SimilarLearningsWarning: Encodable, Equatable {
    let kind = "similar_recent_learnings"
    let ids: [String]
    let hint: String
}
