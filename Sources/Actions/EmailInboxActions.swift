import Foundation
import GRDB
import Hummingbird

// Action definitions for /api/email/inbox(es) routes.
// Backs the email inbox configuration UI in Settings.

// MARK: - Response Types

struct EmailInboxResponse: Encodable {
    let _id: String
    let address: String
    let role: String
    let displayName: String?
    let enabled: Bool
    let autoReply: Bool
    let dispatchTo: String?
    let systemPrompt: String?
    let provider: String
    let providerConfig: String?
    let createdAt: Int64
    let updatedAt: Int64
}

// MARK: - Row -> Response

private func rowToInboxResponse(_ row: Row) -> EmailInboxResponse {
    EmailInboxResponse(
        _id: row["id"],
        address: row["address"],
        role: row["role"],
        displayName: row["displayName"],
        enabled: (row["enabled"] as Int64? ?? 0) != 0,
        autoReply: (row["autoReply"] as Int64? ?? 0) != 0,
        dispatchTo: row["dispatchTo"],
        systemPrompt: row["systemPrompt"],
        provider: (row["provider"] as String?) ?? "agentmail",
        providerConfig: row["providerConfig"],
        createdAt: row["createdAt"],
        updatedAt: row["updatedAt"]
    )
}

let emailInboxActions: [SonataAction] = [

    // GET /api/email/inboxes — list all inboxes
    SonataAction(
        name: "email_inboxes_list",
        description: "List all configured email inboxes.",
        group: "/api/email",
        path: "/inboxes",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let rows: [Row] = try ctx.dbPool.read { db -> [Row] in
                    try Row.fetchAll(db, sql: """
                        SELECT id, address, role, displayName, enabled, autoReply,
                               dispatchTo, systemPrompt, provider, providerConfig,
                               createdAt, updatedAt
                        FROM emailInboxes
                        ORDER BY createdAt ASC
                    """)
                }
                return rows.map(rowToInboxResponse)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/email/inbox — upsert inbox by address
    SonataAction(
        name: "email_inbox_upsert",
        description: "Add or update an email inbox (upsert by address).",
        group: "/api/email",
        path: "/inbox",
        method: .post,
        params: [
            ActionParam("address", .string, required: true, description: "Inbox address (e.g. mybot@agentmail.to)"),
            ActionParam("role", .string, required: true, description: "Role: sona, scoutleader, relay, or custom"),
            ActionParam("displayName", .string, description: "Friendly name for UI"),
            ActionParam("enabled", .boolean, description: "Whether polling is active (default true)"),
            ActionParam("autoReply", .boolean, description: "Auto-reply to incoming email (default true)"),
            ActionParam("dispatchTo", .string, description: "Dispatch target: worker, supervisor, or manual"),
            ActionParam("systemPrompt", .string, description: "Custom reply personality prompt"),
            ActionParam("provider", .string, description: "Backend: 'agentmail' (default) or 'imap'"),
            ActionParam("imapHost", .string, description: "IMAP host (provider=imap)"),
            ActionParam("smtpHost", .string, description: "SMTP host (provider=imap)"),
            ActionParam("imapPort", .integer, description: "IMAP port (default 993)"),
            ActionParam("smtpPort", .integer, description: "SMTP port (default 465)"),
            ActionParam("imapPassword", .string, description: "App-password; stored in SecretStore, never the DB. Blank on edit = keep existing"),
        ],
        handler: { ctx in
            let address = try ctx.params.require("address")
            let role = try ctx.params.require("role")
            let displayName = ctx.params.string("displayName")
            let enabled = ctx.params.bool("enabled") ?? true
            let autoReply = ctx.params.bool("autoReply") ?? true
            let dispatchTo = ctx.params.string("dispatchTo")
            let systemPrompt = ctx.params.string("systemPrompt")
            let provider = ctx.params.string("provider") ?? "agentmail"

            // For IMAP inboxes, stash the app-password in SecretStore (keyed by
            // address) and store only a passwordRef in providerConfig — the DB
            // never holds the credential. Blank password on edit keeps the existing
            // secret. AgentMail inboxes carry no providerConfig.
            let providerConfig: String? = {
                guard provider.lowercased() == "imap" else { return nil }
                let passwordRef = "email.imap.\(address)"
                if let pw = ctx.params.string("imapPassword"), !pw.isEmpty {
                    SecretStore.set(name: passwordRef, value: pw,
                                    description: "IMAP app-password for \(address)")
                }
                let cfg: [String: Any] = [
                    "imapHost": ctx.params.string("imapHost") ?? "",
                    "smtpHost": ctx.params.string("smtpHost") ?? "",
                    "imapPort": ctx.params.int("imapPort") ?? 993,
                    "smtpPort": ctx.params.int("smtpPort") ?? 465,
                    "passwordRef": passwordRef,
                ]
                return (try? JSONSerialization.data(withJSONObject: cfg))
                    .flatMap { String(data: $0, encoding: .utf8) }
            }()

            let now = nowMs()
            do {
                let id = try await ctx.dbPool.write { db -> String in
                    let existingId = try String.fetchOne(
                        db,
                        sql: "SELECT id FROM emailInboxes WHERE address = ?",
                        arguments: [address]
                    )

                    if let existingId {
                        try db.execute(
                            sql: """
                            UPDATE emailInboxes SET
                                role = ?, displayName = ?, enabled = ?, autoReply = ?,
                                dispatchTo = ?, systemPrompt = ?, provider = ?,
                                providerConfig = ?, updatedAt = ?
                            WHERE id = ?
                            """,
                            arguments: [
                                role, displayName, enabled ? 1 : 0, autoReply ? 1 : 0,
                                dispatchTo, systemPrompt, provider, providerConfig,
                                now, existingId
                            ]
                        )
                        return existingId
                    } else {
                        let newId = newUUID()
                        try db.execute(
                            sql: """
                            INSERT INTO emailInboxes
                                (id, address, role, displayName, enabled, autoReply,
                                 dispatchTo, systemPrompt, provider, providerConfig,
                                 createdAt, updatedAt)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            arguments: [
                                newId, address, role, displayName,
                                enabled ? 1 : 0, autoReply ? 1 : 0,
                                dispatchTo, systemPrompt, provider, providerConfig,
                                now, now
                            ]
                        )
                        return newId
                    }
                }
                return StoreResponse(id: id)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // DELETE /api/email/inbox?id=
    SonataAction(
        name: "email_inbox_delete",
        description: "Delete an email inbox by ID.",
        group: "/api/email",
        path: "/inbox",
        method: .delete,
        params: [
            ActionParam("id", .string, required: true, description: "Inbox ID"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            do {
                let changed = try await ctx.dbPool.write { db -> Int in
                    try db.execute(sql: "DELETE FROM emailInboxes WHERE id = ?", arguments: [id])
                    return db.changesCount
                }
                guard changed > 0 else {
                    throw ActionError.notFound("Inbox not found")
                }
                return SuccessResponse()
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/email/inbox/enable
    SonataAction(
        name: "email_inbox_enable",
        description: "Enable an email inbox by ID.",
        group: "/api/email",
        path: "/inbox/enable",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Inbox ID"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            let now = nowMs()
            do {
                let changed = try await ctx.dbPool.write { db -> Int in
                    try db.execute(
                        sql: "UPDATE emailInboxes SET enabled = 1, updatedAt = ? WHERE id = ?",
                        arguments: [now, id]
                    )
                    return db.changesCount
                }
                guard changed > 0 else {
                    throw ActionError.notFound("Inbox not found")
                }
                return SuccessResponse()
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/email/inbox/disable
    SonataAction(
        name: "email_inbox_disable",
        description: "Disable an email inbox by ID (stops polling).",
        group: "/api/email",
        path: "/inbox/disable",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Inbox ID"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            let now = nowMs()
            do {
                let changed = try await ctx.dbPool.write { db -> Int in
                    try db.execute(
                        sql: "UPDATE emailInboxes SET enabled = 0, updatedAt = ? WHERE id = ?",
                        arguments: [now, id]
                    )
                    return db.changesCount
                }
                guard changed > 0 else {
                    throw ActionError.notFound("Inbox not found")
                }
                return SuccessResponse()
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),
]
