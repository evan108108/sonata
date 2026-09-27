import Foundation
import GRDB

// MARK: - Entity identity: one rule, shared by every door
//
// The knowledge graph had two write paths that disagreed about what identifies
// an entity, and the disagreement was silently destructive:
//
//   * mem_store's inline `entities` annotation matched on (name, type). A type
//     that didn't match the stored row INSERTed a fork with an empty
//     description and returned success — and because relations resolve by NAME
//     against the just-upserted set first, the fork also STOLE the edge that
//     belonged on the original. This is how `score-hybrid`/component forked off
//     `score-hybrid`/code_component (2026-08-12) and `Sona`/agent off
//     `Sona`/person (2026-07-22, next to a 1035-edge hub).
//
//   * mem_entity_upsert matched on NAME ALONE and ignored its own `type`
//     argument, so once a fork existed it could never be addressed: the name
//     resolved to whichever row SQLite handed back first, and the caller's
//     description overwrote it. Observed live 2026-08-13 overwriting the
//     canonical Sona/person and score-hybrid/code_component rows.
//
// Both halves reduce to the same missing primitive: nothing in the codebase
// answered "which row does this name mean?" in one place. This file is that
// answer. Every door — annotation, upsert, by-name lookup, relation
// resolution — resolves through `entityCandidates`, so a caller can no longer
// get a different row depending on which door they knocked on.
//
// Matching is case-insensitive on name. That is deliberate and matches the
// annotation path and RecallActions (`COLLATE NOCASE`); mem_entity_upsert was
// the sole case-SENSITIVE door, which is how `Evenflow`/tool and
// `evenflow`/tool came to coexist as separate rows.

/// A row that a bare name could refer to, with the signal used to rank it.
struct EntityCandidate {
    let id: String
    let name: String
    let type: String
    /// Relations touching this row in either direction. The tiebreaker when a
    /// name is forked: prefer the row the graph actually uses.
    let edgeCount: Int
    let createdAt: Int64
    /// True when this row matched through `attributes.aliases` rather than its
    /// own name — the caller used a nickname and landed on the canonical row.
    var viaAlias: Bool = false

    /// Human-readable form for error and warning text, e.g.
    /// `Sona/person (9071333c, 1035 edges)`.
    var label: String {
        "\(name)/\(type) (\(id.prefix(8)), \(edgeCount) edge\(edgeCount == 1 ? "" : "s"))"
    }
}

/// Every row whose name — or one of whose `attributes.aliases` — matches `name`
/// case-insensitively, most-connected first.
///
/// The ordering is TOTAL — edges DESC, then createdAt ASC, then id ASC — so two
/// callers resolving the same name always land on the same row. The previous
/// `LIMIT 1` with no ORDER BY let SQLite's row order decide, which is why the
/// same name could resolve to the fork one call and the hub the next.
///
/// ALIASES exist because a description cannot redirect a name-matcher. The
/// duplicate person row "Archer" carried "DO NOT ENRICH — canonical is Archer
/// Frohlich" in its description and still captured 6 inline annotations in two
/// days (2026-09-25..27), since every door matched the bare name exactly.
/// Putting `{"aliases": ["Archer"]}` on the canonical row makes the short name
/// resolve there through every door. Set it with mem_entity_patch.
func entityCandidates(_ db: Database, name: String) throws -> [EntityCandidate] {
    let wanted = name.lowercased()
    return try fetchRankedCandidates(
        db,
        where: """
            LOWER(e.name) = LOWER(?)
            OR (json_valid(e.attributes) AND EXISTS (
                SELECT 1 FROM json_each(e.attributes, '$.aliases') a
                WHERE LOWER(a.value) = LOWER(?)))
            """,
        arguments: [name, name]
    ).map { candidate in
        var c = candidate
        c.viaAlias = c.name.lowercased() != wanted
        return c
    }
}

/// Shared SELECT behind every candidate lookup, so all of them rank under the
/// same total ordering.
private func fetchRankedCandidates(
    _ db: Database,
    where predicate: String,
    arguments: StatementArguments
) throws -> [EntityCandidate] {
    let rows = try Row.fetchAll(
        db,
        sql: """
        SELECT e.id, e.name, e.type, e.createdAt,
               (SELECT COUNT(*) FROM relations r
                 WHERE r.sourceId = e.id OR r.targetId = e.id) AS edgeCount
        FROM entities e
        WHERE \(predicate)
        ORDER BY edgeCount DESC, e.createdAt ASC, e.id ASC
        """,
        arguments: arguments
    )
    return rows.compactMap { row in
        guard let id = row["id"] as? String,
              let rowName = row["name"] as? String,
              let type = row["type"] as? String
        else { return nil }
        return EntityCandidate(
            id: id,
            name: rowName,
            type: type,
            edgeCount: (row["edgeCount"] as? Int64).map(Int.init) ?? 0,
            createdAt: (row["createdAt"] as? Int64) ?? 0
        )
    }
}

/// The row a bare name means: the most-connected row carrying it.
///
/// Used where a caller supplies a name with no type at all (relation targets,
/// `mem_entity_by_name`). Where a name is forked this deliberately prefers the
/// hub over the stub, because an edge pointed at the stub is an edge lost.
func resolveEntityByName(_ db: Database, name: String) throws -> EntityCandidate? {
    try entityCandidates(db, name: name).first
}

/// How a name+type pair resolved against what is already stored.
enum EntityResolution {
    /// No row carries this name — safe to insert.
    case absent
    /// Exactly the row the caller named. `siblings` are same-name rows of other
    /// types that exist alongside it (empty in the common case).
    case matched(EntityCandidate, siblings: [EntityCandidate])
    /// The name exists, but under other type(s) only. Writing here would either
    /// fork the name (annotation path) or overwrite a row the caller did not
    /// name (upsert path). Never resolve this silently.
    case typeMismatch([EntityCandidate])
}

/// Resolve a (name, type) pair — the shared decision both write doors make.
func resolveEntity(_ db: Database, name: String, type: String) throws -> EntityResolution {
    let candidates = try entityCandidates(db, name: name)
    guard !candidates.isEmpty else { return .absent }
    let wanted = type.lowercased()
    if let exact = candidates.first(where: { $0.type.lowercased() == wanted }) {
        return .matched(exact, siblings: candidates.filter { $0.id != exact.id })
    }
    return .typeMismatch(candidates)
}

// MARK: - Name-variant forks
//
// The type guard above closes forks where the NAME matches and the type
// doesn't. The mirror case is the same type under a shorter or longer name:
// annotating person "Archer" (2026-09-25) found no row named exactly that, so it
// INSERTed an empty stub next to the canonical "Archer Frohlich", the memory's
// edge landed on the stub, and nothing said so. Unlike a type mismatch this one
// can't be resolved automatically — "Archer" may genuinely be a different
// person — so the insert still happens and the caller is told which rows the
// name may have meant.

/// Types where short-name aliasing is common enough to be worth a warning.
/// Concepts, tools and failure modes are named precisely, and a word-subset
/// there ("scheduler" vs "scheduler-registered-not-live") is usually a
/// different thing.
let nameVariantEntityTypes: Set<String> = ["person", "organization", "project"]

/// Lowercased whitespace-separated words of a name, e.g. "Archer  Frohlich" →
/// {"archer", "frohlich"}.
func nameTokens(_ name: String) -> Set<String> {
    Set(name.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
}

/// Same-type rows whose name is a word-subset or word-superset of `name`
/// ("Archer" ⊂ "Archer Frohlich"), most-connected first. Empty for types
/// outside `nameVariantEntityTypes`.
///
/// Call this only once `resolveEntity` has returned `.absent`. The exact-name
/// row, if there is one, is not excluded here.
func nameVariantCandidates(_ db: Database, name: String, type: String) throws -> [EntityCandidate] {
    guard nameVariantEntityTypes.contains(type.lowercased()) else { return [] }
    let wanted = nameTokens(name)
    guard !wanted.isEmpty else { return [] }
    // The per-type population is a few hundred rows at most, so filtering by
    // token set in Swift is cheaper to get right than tokenizing in SQL.
    return try fetchRankedCandidates(db, where: "LOWER(e.type) = LOWER(?)", arguments: [type])
        .filter { candidate in
            let tokens = nameTokens(candidate.name)
            return !tokens.isEmpty && (tokens.isSubset(of: wanted) || tokens.isSuperset(of: wanted))
        }
}
