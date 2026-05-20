import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for /api/contacts and /api/contact routes.
// Handler logic duplicated from ContactRoutes.swift.

private let validContactTypesForAction: Set<String> = ["human", "ai", "service"]

private func contactRowToResponseForAction(_ row: ContactRow) -> ContactResponse {
    ContactResponse(
        _id: row.id,
        _creationTime: row.createdAt,
        name: row.name,
        email: row.email,
        type: row.type,
        role: row.role,
        provider: row.provider,
        model: row.model,
        systemPrompt: row.systemPrompt,
        notes: row.notes,
        lastContactAt: row.lastContactAt,
        messageCount: row.messageCount,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        autoAllowEmail: row.autoAllowEmail,
        blockEmail: row.blockEmail,
        peerKind: row.peerKind,
        peerEndpoint: row.peerEndpoint,
        peerPubkey: row.peerPubkey
    )
}

let contactActions: [SonataAction] = [

    // GET /api/contacts — list all (optional type filter)
    SonataAction(
        name: "contact_list",
        description: "List contacts (optionally filtered by type).",
        group: "/api",
        path: "/contacts",
        method: .get,
        params: [
            ActionParam("type", .string, description: "Filter by contact type"),
            ActionParam("limit", .integer, description: "Max results (default 100)"),
        ],
        handler: { ctx in
            let type = ctx.params.string("type")
            let limit = ctx.params.int("limit") ?? 100

            var sql = "SELECT * FROM contacts WHERE 1=1"
            var args: [any DatabaseValueConvertible] = []

            if let t = type {
                sql += " AND type = ?"
                args.append(t)
            }
            sql += " ORDER BY name ASC LIMIT ?"
            args.append(limit)

            do {
                let rows = try ctx.dbPool.read { db in
                    try ContactRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                }
                return rows.map(contactRowToResponseForAction)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/contact?email= — get by email
    SonataAction(
        name: "contact_get",
        description: "Get a contact by email.",
        group: "/api",
        path: "/contact",
        method: .get,
        params: [
            ActionParam("email", .string, required: true, description: "Contact email"),
        ],
        handler: { ctx in
            let email = try ctx.params.require("email")
            do {
                let row = try await ctx.dbPool.read { db in
                    try ContactRow.fetchOne(db, sql: "SELECT * FROM contacts WHERE email = ?", arguments: [email])
                }
                guard let row else {
                    throw ActionError.notFound("Contact not found")
                }
                return contactRowToResponseForAction(row)
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/contact — upsert by email
    SonataAction(
        name: "contact_create",
        description: "Upsert a contact by email.",
        group: "/api",
        path: "/contact",
        method: .post,
        params: [
            ActionParam("name", .string, required: true, description: "Contact name"),
            ActionParam("email", .string, required: true, description: "Contact email"),
            ActionParam("type", .string, required: true, description: "Contact type: human, ai, or service"),
            ActionParam("role", .string, description: "Role"),
            ActionParam("provider", .string, description: "Provider (for AI contacts, peerKind='invoked')"),
            ActionParam("model", .string, description: "Model (for AI contacts, peerKind='invoked')"),
            ActionParam("systemPrompt", .string, description: "System prompt (for AI contacts, peerKind='invoked')"),
            ActionParam("notes", .string, description: "Notes"),
            ActionParam("autoAllowEmail", .integer, description: "1 = sender is allow-listed for inbound email (default 0)"),
            ActionParam("blockEmail", .integer, description: "1 = sender's inbound email is silently dropped (default 0)"),
            ActionParam("peerKind", .string, description: "'invoked' (Sona calls the peer's model) or 'federated' (peer runs itself)"),
            ActionParam("peerEndpoint", .string, description: "Federated peer endpoint (e.g. '192.168.0.17:3211')"),
            ActionParam("peerPubkey", .string, description: "Federated peer pubkey (hex)"),
        ],
        handler: { ctx in
            let name = try ctx.params.require("name")
            let email = try ctx.params.require("email")
            let type = try ctx.params.require("type")
            guard validContactTypesForAction.contains(type) else {
                throw ActionError.invalidParam("type", "Invalid contact type '\(type)'")
            }

            let role = ctx.params.string("role")
            let provider = ctx.params.string("provider")
            let model = ctx.params.string("model")
            let systemPrompt = ctx.params.string("systemPrompt")
            let notes = ctx.params.string("notes")
            let autoAllow = ctx.params.int("autoAllowEmail") ?? 0
            let block = ctx.params.int("blockEmail") ?? 0
            let peerKind = ctx.params.string("peerKind")
            let peerEndpoint = ctx.params.string("peerEndpoint")
            let peerPubkey = ctx.params.string("peerPubkey")

            let now = nowMs()

            do {
                let id = try await ctx.dbPool.write { db -> String in
                    let existing = try ContactRow.fetchOne(
                        db, sql: "SELECT * FROM contacts WHERE email = ?", arguments: [email])

                    if let existing {
                        try db.execute(
                            sql: """
                            UPDATE contacts SET
                                name = ?, type = ?, role = ?, provider = ?,
                                model = ?, systemPrompt = ?, notes = ?,
                                autoAllowEmail = ?, blockEmail = ?,
                                peerKind = ?, peerEndpoint = ?, peerPubkey = ?,
                                updatedAt = ?
                            WHERE id = ?
                            """,
                            arguments: [
                                name, type, role, provider,
                                model, systemPrompt, notes,
                                autoAllow, block,
                                peerKind, peerEndpoint, peerPubkey,
                                now,
                                existing.id
                            ]
                        )
                        return existing.id
                    } else {
                        let id = newUUID()
                        try db.execute(
                            sql: """
                            INSERT INTO contacts
                                (id, name, email, type, role, provider, model,
                                 systemPrompt, notes, messageCount,
                                 autoAllowEmail, blockEmail,
                                 peerKind, peerEndpoint, peerPubkey,
                                 createdAt, updatedAt)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0,
                                    ?, ?,
                                    ?, ?, ?,
                                    ?, ?)
                            """,
                            arguments: [
                                id, name, email, type, role,
                                provider, model, systemPrompt, notes,
                                autoAllow, block,
                                peerKind, peerEndpoint, peerPubkey,
                                now, now
                            ]
                        )
                        return id
                    }
                }
                return StoreResponse(id: id)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/contact/touch?email= — increment messageCount
    SonataAction(
        name: "contact_touch",
        description: "Increment messageCount and set lastContactAt for a contact by email.",
        group: "/api",
        path: "/contact/touch",
        method: .post,
        params: [
            ActionParam("email", .string, required: true, description: "Contact email", source: .query),
        ],
        handler: { ctx in
            let email = try ctx.params.require("email")
            let now = nowMs()

            do {
                let changed = try await ctx.dbPool.write { db -> Int in
                    try db.execute(
                        sql: """
                        UPDATE contacts SET
                            messageCount = messageCount + 1,
                            lastContactAt = ?,
                            updatedAt = ?
                        WHERE email = ?
                        """,
                        arguments: [now, now, email]
                    )
                    return db.changesCount
                }
                guard changed > 0 else {
                    throw ActionError.notFound("Contact not found")
                }
                return SuccessResponse()
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/contact/email-flags — flip autoAllowEmail / blockEmail by email
    // Lightweight one-shot used by the People UI's approve toggle. Avoids
    // round-tripping the full contact record just to flip a flag.
    SonataAction(
        name: "contact_set_email_flags",
        description: "Set the autoAllowEmail and/or blockEmail flags on a contact by email.",
        group: "/api",
        path: "/contact/email-flags",
        method: .post,
        params: [
            ActionParam("email", .string, required: true, description: "Contact email"),
            ActionParam("autoAllowEmail", .integer, description: "1 to allow-list, 0 to remove from allow list (default unchanged)"),
            ActionParam("blockEmail", .integer, description: "1 to block, 0 to unblock (default unchanged)"),
        ],
        handler: { ctx in
            let email = try ctx.params.require("email")
            let autoAllow = ctx.params.int("autoAllowEmail")
            let block = ctx.params.int("blockEmail")
            if autoAllow == nil && block == nil {
                throw ActionError.invalidParam("autoAllowEmail|blockEmail", "at least one flag is required")
            }
            let now = nowMs()
            do {
                let changed = try await ctx.dbPool.write { db -> Int in
                    var sets: [String] = []
                    var args: [any DatabaseValueConvertible] = []
                    if let a = autoAllow {
                        sets.append("autoAllowEmail = ?")
                        args.append(a)
                    }
                    if let b = block {
                        sets.append("blockEmail = ?")
                        args.append(b)
                    }
                    sets.append("updatedAt = ?")
                    args.append(now)
                    args.append(email)
                    let sql = "UPDATE contacts SET \(sets.joined(separator: ", ")) WHERE LOWER(email) = LOWER(?)"
                    try db.execute(sql: sql, arguments: StatementArguments(args))
                    return db.changesCount
                }
                guard changed > 0 else {
                    throw ActionError.notFound("Contact not found for email \(email)")
                }
                return SuccessResponse()
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // DELETE /api/contact?id= — delete by ID
    SonataAction(
        name: "contact_delete",
        description: "Delete a contact by ID.",
        group: "/api",
        path: "/contact",
        method: .delete,
        params: [
            ActionParam("id", .string, required: true, description: "Contact ID"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: "DELETE FROM contacts WHERE id = ?", arguments: [id])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),
]
