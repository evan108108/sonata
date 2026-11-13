import Foundation
import GRDB

/// Possibly-overturned detection for `mem_store(type: decision)`.
///
/// On 2026-11-12 decision c9e931e1 (importance 7: do NOT rotate the credentials
/// the AE-193 hole exposed) was stored beside runbook a564073f (importance 8),
/// which still said to rotate them. mem_recall settles a disagreement between
/// two live memories by rank, not by date, so a "how do I…" query surfaces the
/// louder, older runbook. Nothing flagged the pair; an inner-life pass caught it
/// the next day (learning 150f95a2).
///
/// The remedy is to edit the instruction in place, and the writer is the one
/// who knows whether the decision changes it. So when a decision is stored,
/// name the recent instructions it looks like. Advisory only: it never blocks
/// the write and never edits anything itself.
///
/// Method: the same lexical match as LearningSimilarity (most distinctive terms
/// by tf × idf, FTS5 OR query in bm25 order, shared-term gate), with more terms
/// (16, gate 5; see queryTermCount for why) and a wider net. Candidates are
/// any project, of type learning/decision/fact, created in
/// the 30 days up to the new decision, with importance at least one below the
/// decision's. A memory well below the decision's importance is unlikely to be
/// the one that outranks it in recall, and that outranking is the harm.
enum DecisionOverturn {
    /// How far back to look, relative to the new decision's createdAt.
    /// Wider than the learnings window: a runbook stays in use for weeks.
    static let windowMs: Int64 = 30 * 24 * 60 * 60 * 1000
    /// A candidate needs importance >= the decision's importance minus this.
    static let importanceSlack: Double = 1
    /// Memory types that carry instructions or settled facts a decision can reverse.
    static let candidateTypes = ["learning", "decision", "fact"]
    /// FTS hits examined before the shared-term gate. Larger than the learnings
    /// pool because the net covers three types and every project.
    static let candidatePoolSize = 24
    /// Distinctive terms used for the query. Twice the learnings check's 8,
    /// because a decision's rarest words are its REASONING, which the
    /// instruction it reverses never contains. c9e931e1's top 8 against the
    /// live corpus (2026-11-13) are access, rotate, rotation, overly, cautious,
    /// client, regenerate, audits: four of them argue the call. Against the
    /// pre-patch runbook that leaves 3 shared terms at 8 or 12, a miss; at 16
    /// the subject terms (exec, key, api) enter and 6 are shared.
    static let queryTermCount = 16
    /// A candidate must share at least this many of the 16 terms. Measured on
    /// the 312 active decisions of 2026-10-14..11-13 replayed against the live
    /// corpus: 4-of-8 warns on 175 (and misses the incident), 5-of-16 on 218,
    /// 4-of-16 on 276. About two-thirds of decisions are prStar verdicts, and
    /// most of their warnings name earlier verdicts on related PRs; without
    /// them, 5-of-16 warns on 56 of 100.
    static let minSharedTerms = 5

    static let hint = "If this decision changes how one of these says to do something, "
        + "mem_patch/mem_revise it with a revisionNote citing this decision."

    /// Recent learning/decision/fact memories that share at least
    /// `minShared` of the decision's `termCount` most distinctive terms
    /// and are no more than `importanceSlack` below it, strongest bm25 first,
    /// at most `LearningSimilarity.maxResults`. `memoryId` is excluded, so this
    /// is safe to call after the INSERT.
    static func findPossiblyOverturned(
        _ db: Database,
        memoryId: String,
        content: String,
        importance: Double,
        createdAt: Int64,
        termCount: Int = queryTermCount,
        minShared: Int = minSharedTerms
    ) throws -> [LearningSimilarity.Match] {
        let terms = try LearningSimilarity.distinctiveTerms(db, content: content, limit: termCount)
        guard terms.count >= minShared else { return [] }

        let query = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        let typeList = candidateTypes.map { "'\($0)'" }.joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT m.id AS id, m.content AS content, bm25(memories_fts) AS rank
            FROM memories_fts
            JOIN memories m ON m.rowid = memories_fts.rowid
            WHERE memories_fts MATCH ?
              AND m.type IN (\(typeList))
              AND m.id != ?
              AND m.importance >= ?
              AND m.createdAt >= ?
              AND m.createdAt <= ?
              AND (m.status IS NULL OR m.status NOT IN ('archived', 'superseded'))
            ORDER BY rank ASC, m.id ASC
            LIMIT ?
            """,
            arguments: [
                query, memoryId, importance - importanceSlack,
                createdAt - windowMs, createdAt, candidatePoolSize,
            ]
        )
        return LearningSimilarity.gate(rows, terms: terms, minShared: minShared)
    }

    /// The caller-facing `warnings` line for a non-empty match list. Full ids,
    /// because the remedy is a patch/revise by id and truncated ids don't resolve.
    static func warning(for matches: [LearningSimilarity.Match]) -> String {
        let named = matches
            .map { "\($0.id) (shares: \($0.sharedTerms.joined(separator: ", ")))" }
            .joined(separator: "; ")
        return "possibly_overturned: this decision looks like \(matches.count) recent instruction"
            + "\(matches.count == 1 ? "" : "s") at similar or higher importance: \(named). "
            + "Recall ranks by importance, not date, so an unedited one will outrank this decision. \(hint)"
    }
}

/// Structured form of the possibly-overturned warning, returned alongside the
/// human-readable `warnings` line so a caller can act on the ids directly.
struct PossiblyOverturnedWarning: Encodable, Equatable {
    let kind = "possibly_overturned"
    let ids: [String]
    let hint: String
}
