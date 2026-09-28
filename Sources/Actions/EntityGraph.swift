import Foundation
import GRDB

// Graph-safe entity removal.
//
// Relations have no foreign keys (an endpoint can be a memory or an entity), so
// deleting an entity row used to leave every edge that named it pointing at a
// deleted id. Observed 2026-09-28: deleting duplicate "Campbell"
// (49b61a454eab5aa077bfa9e264b86ec9) left 91 dangling relations, deleted one
// call at a time. The duplicate "Evan" row has 2,792 edges, so a hand repair
// isn't possible at all.
//
// Two ways out, and they are different operations:
//   * delete with cascade: the edges die with the entity. Right when the
//     entity is junk.
//   * merge: the edges move to the canonical row first. Right when the entity
//     is a duplicate of something real, which is the common case.
// A plain delete of an entity that still has edges is refused, because a
// silent cascade would have destroyed the 91 edges a merge needed to keep.

struct GraphEntityRow {
    let id: String
    let name: String
    let type: String
    let description: String
    let attributes: String?
    let referenceCount: Int
    let lastReferencedAt: Int64?

    var label: String { "'\(name)' (\(type), \(id))" }
}

func fetchEntityRow(_ db: Database, id: String) throws -> GraphEntityRow? {
    try Row.fetchOne(
        db,
        sql: "SELECT id, name, type, description, attributes, referenceCount, lastReferencedAt FROM entities WHERE id = ?",
        arguments: [id]
    ).map {
        GraphEntityRow(
            id: $0["id"], name: $0["name"], type: $0["type"], description: $0["description"],
            attributes: $0["attributes"], referenceCount: $0["referenceCount"] ?? 0,
            lastReferencedAt: $0["lastReferencedAt"]
        )
    }
}

/// Relations where this entity is either endpoint.
func entityEdgeCount(_ db: Database, id: String) throws -> Int {
    try Int.fetchOne(
        db,
        sql: """
        SELECT COUNT(*) FROM relations
        WHERE (sourceId = ? AND sourceType = 'entity') OR (targetId = ? AND targetType = 'entity')
        """,
        arguments: [id, id]
    ) ?? 0
}

enum EntityDeleteOutcome: Equatable {
    case deleted(relationsDeleted: Int)
    case refused(edges: Int)
    case notFound
}

/// Delete an entity. With `cascade: false` an entity that still has edges is
/// refused and nothing is written. With `cascade: true` its relations are
/// deleted in the same transaction, so no edge can outlive the row.
func deleteEntity(_ db: Database, id: String, cascade: Bool) throws -> EntityDeleteOutcome {
    guard try fetchEntityRow(db, id: id) != nil else { return .notFound }
    let edges = try entityEdgeCount(db, id: id)
    if edges > 0 && !cascade { return .refused(edges: edges) }
    try db.execute(
        sql: """
        DELETE FROM relations
        WHERE (sourceId = ? AND sourceType = 'entity') OR (targetId = ? AND targetType = 'entity')
        """,
        arguments: [id, id]
    )
    let removed = db.changesCount
    try db.execute(sql: "DELETE FROM entities WHERE id = ?", arguments: [id])
    return .deleted(relationsDeleted: removed)
}

struct EntityMergePlan: Encodable, Equatable {
    let fromId: String
    let intoId: String
    /// Edges re-pointed from `fromId` to `intoId`.
    let moved: Int
    /// Edges dropped because `intoId` already has the same edge.
    let duplicatesDropped: Int
    /// Edges between the two rows, which would become `intoId -> intoId`.
    let selfLoopsDropped: Int
    /// Names added to `intoId`'s `attributes.aliases`.
    let aliasesAdded: [String]
}

// The same edge seen from the canonical row: an existing relation on `into`
// with the same other endpoint, direction and label.
private let duplicateOutgoing = """
    r.sourceId = :from AND r.sourceType = 'entity' AND EXISTS (
        SELECT 1 FROM relations x
        WHERE x.sourceId = :into AND x.sourceType = 'entity'
          AND x.targetId = r.targetId AND x.targetType = r.targetType AND x.relation = r.relation)
    """
private let duplicateIncoming = """
    r.targetId = :from AND r.targetType = 'entity' AND EXISTS (
        SELECT 1 FROM relations x
        WHERE x.targetId = :into AND x.targetType = 'entity'
          AND x.sourceId = r.sourceId AND x.sourceType = r.sourceType AND x.relation = r.relation)
    """
private let selfLoop = """
    (r.sourceId = :from AND r.sourceType = 'entity' AND r.targetId = :into AND r.targetType = 'entity')
    OR (r.sourceId = :into AND r.sourceType = 'entity' AND r.targetId = :from AND r.targetType = 'entity')
    """

enum EntityMergeError: Error, Equatable {
    case sameEntity
    case notFound(String)
}

/// Merge the duplicate `fromId` into the canonical `intoId`: re-point every
/// edge, drop edges `intoId` already has and edges between the two rows, record
/// the duplicate's name as an alias and its old identity under
/// `attributes.mergedFrom`, add its reference count, then delete it. Everything
/// happens in the caller's transaction. `dryRun` computes the plan and writes
/// nothing.
func mergeEntity(_ db: Database, fromId: String, intoId: String, dryRun: Bool, now: Int64) throws -> EntityMergePlan {
    guard fromId != intoId else { throw EntityMergeError.sameEntity }
    guard let from = try fetchEntityRow(db, id: fromId) else { throw EntityMergeError.notFound(fromId) }
    guard let into = try fetchEntityRow(db, id: intoId) else { throw EntityMergeError.notFound(intoId) }

    let args: StatementArguments = ["from": fromId, "into": intoId]
    let loops = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM relations r WHERE \(selfLoop)", arguments: args) ?? 0
    // A self-loop can also match a duplicate clause; count it once, as a loop.
    let dupes = try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM relations r WHERE ((\(duplicateOutgoing)) OR (\(duplicateIncoming))) AND NOT (\(selfLoop))",
        arguments: args
    ) ?? 0
    let total = try entityEdgeCount(db, id: fromId)
    let moved = total - loops - dupes

    var attributes = (from: parseAttributes(from.attributes), into: parseAttributes(into.attributes))
    var aliases = (attributes.into["aliases"] as? [String]) ?? []
    var added: [String] = []
    let known = Set(([into.name] + aliases).map { $0.lowercased() })
    for name in [from.name] + ((attributes.from["aliases"] as? [String]) ?? []) where !known.contains(name.lowercased()) && !added.contains(where: { $0.lowercased() == name.lowercased() }) {
        added.append(name)
    }
    let plan = EntityMergePlan(fromId: fromId, intoId: intoId, moved: moved, duplicatesDropped: dupes, selfLoopsDropped: loops, aliasesAdded: added)
    if dryRun { return plan }

    try db.execute(sql: "DELETE FROM relations WHERE id IN (SELECT r.id FROM relations r WHERE \(selfLoop))", arguments: args)
    try db.execute(sql: "DELETE FROM relations WHERE id IN (SELECT r.id FROM relations r WHERE \(duplicateOutgoing))", arguments: args)
    try db.execute(sql: "DELETE FROM relations WHERE id IN (SELECT r.id FROM relations r WHERE \(duplicateIncoming))", arguments: args)
    try db.execute(sql: "UPDATE relations SET sourceId = :into WHERE sourceId = :from AND sourceType = 'entity'", arguments: args)
    try db.execute(sql: "UPDATE relations SET targetId = :into WHERE targetId = :from AND targetType = 'entity'", arguments: args)

    aliases.append(contentsOf: added)
    attributes.into["aliases"] = aliases
    var mergedFrom = (attributes.into["mergedFrom"] as? [[String: Any]]) ?? []
    mergedFrom.append([
        "id": from.id, "name": from.name, "type": from.type,
        "description": from.description, "mergedAt": now,
    ])
    attributes.into["mergedFrom"] = mergedFrom
    let json = String(data: try JSONSerialization.data(withJSONObject: attributes.into, options: [.sortedKeys]), encoding: .utf8)

    let lastReferenced: Int64? = [from.lastReferencedAt, into.lastReferencedAt].compactMap { $0 }.max()
    try db.execute(
        sql: "UPDATE entities SET attributes = ?, referenceCount = ?, lastReferencedAt = ?, updatedAt = ? WHERE id = ?",
        arguments: [json, into.referenceCount + from.referenceCount, lastReferenced, now, intoId]
    )
    try db.execute(sql: "DELETE FROM entities WHERE id = ?", arguments: [fromId])
    return plan
}

private func parseAttributes(_ json: String?) -> [String: Any] {
    guard let json, let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}

struct DanglingEntityEdges: Encodable, Equatable {
    /// Relations with an `entity` endpoint whose id has no row in `entities`.
    let count: Int
    let deleted: Int
    let sample: [String]
}

/// Relations whose entity endpoint no longer exists. Unambiguous by
/// construction: only endpoints typed `entity` are checked, and only against
/// the entities table, so a memory endpoint can never be mistaken for one.
/// Deletes only when `delete` is true.
func danglingEntityEdges(_ db: Database, delete: Bool) throws -> DanglingEntityEdges {
    let predicate = """
        (r.sourceType = 'entity' AND NOT EXISTS (SELECT 1 FROM entities e WHERE e.id = r.sourceId))
        OR (r.targetType = 'entity' AND NOT EXISTS (SELECT 1 FROM entities e WHERE e.id = r.targetId))
        """
    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM relations r WHERE \(predicate)") ?? 0
    let sample = try String.fetchAll(
        db,
        sql: "SELECT r.id || ' ' || r.sourceType || ':' || r.sourceId || ' -[' || r.relation || ']-> ' || r.targetType || ':' || r.targetId FROM relations r WHERE \(predicate) LIMIT 10"
    )
    var deleted = 0
    if delete && count > 0 {
        try db.execute(sql: "DELETE FROM relations WHERE id IN (SELECT r.id FROM relations r WHERE \(predicate))")
        deleted = db.changesCount
    }
    return DanglingEntityEdges(count: count, deleted: deleted, sample: sample)
}

struct EntityDeleteResponse: Encodable {
    let success = true
    let relationsDeleted: Int
}

struct EntityMergeResponse: Encodable {
    let success = true
    let dryRun: Bool
    let plan: EntityMergePlan
}
