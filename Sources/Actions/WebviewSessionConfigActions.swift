import Foundation
import GRDB
import Hummingbird

// Action definitions for /api/webview/config routes. Backs the Web Sessions
// governance UI in Settings. The webviewSessionConfig table is a singleton
// keyed by id='singleton' (Schema v19). Mirrors SupervisorConfigActions.

struct WebviewSessionConfigResponse: Encodable {
    let idleSuspendSec: Int
    let hardCloseSec: Int
    let maxLiveSessions: Int
    let updatedAt: Int64
}

let webviewSessionConfigActions: [SonataAction] = [
    SonataAction(
        name: "webview_session_config_get",
        description: "Get the webview session governance config (idle-suspend, hard-close, max live).",
        group: "/api/webview", path: "/config", method: .get, params: [],
        handler: { ctx in
            let row: Row? = try ctx.dbPool.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT idleSuspendSec, hardCloseSec, maxLiveSessions, updatedAt
                    FROM webviewSessionConfig WHERE id = 'singleton'
                """)
            }
            return WebviewSessionConfigResponse(
                idleSuspendSec: Int((row?["idleSuspendSec"] as Int64?) ?? 300),
                hardCloseSec: Int((row?["hardCloseSec"] as Int64?) ?? 1800),
                maxLiveSessions: Int((row?["maxLiveSessions"] as Int64?) ?? 8),
                updatedAt: (row?["updatedAt"] as Int64?) ?? 0)
        }
    ),
    SonataAction(
        name: "webview_session_config_update",
        description: "Update webview session governance config (partial; omitted fields keep their value).",
        group: "/api/webview", path: "/config", method: .post,
        params: [
            ActionParam("idleSuspendSec", .integer, description: "Idle seconds before suspend. 30–7200."),
            ActionParam("hardCloseSec", .integer, description: "Idle seconds before hard-close. 60–86400."),
            ActionParam("maxLiveSessions", .integer, description: "Max concurrent live WKWebViews. 1–64."),
        ],
        handler: { ctx in
            let idle = ctx.params.int("idleSuspendSec")
            let hard = ctx.params.int("hardCloseSec")
            let maxLive = ctx.params.int("maxLiveSessions")
            if let v = idle, v < 30 || v > 7200 { throw ActionError.invalidParam("idleSuspendSec", "30–7200") }
            if let v = hard, v < 60 || v > 86400 { throw ActionError.invalidParam("hardCloseSec", "60–86400") }
            if let v = maxLive, v < 1 || v > 64 { throw ActionError.invalidParam("maxLiveSessions", "1–64") }
            let now = nowMs()
            try await ctx.dbPool.write { db in
                let exists = try Bool.fetchOne(db, sql: "SELECT COUNT(*) > 0 FROM webviewSessionConfig WHERE id = 'singleton'") ?? false
                if !exists {
                    try db.execute(sql: """
                        INSERT INTO webviewSessionConfig (id, idleSuspendSec, hardCloseSec, maxLiveSessions, updatedAt)
                        VALUES ('singleton', 300, 1800, 8, ?)
                    """, arguments: [now])
                }
                var sets: [String] = []; var args: [any DatabaseValueConvertible] = []
                if let v = idle { sets.append("idleSuspendSec = ?"); args.append(v) }
                if let v = hard { sets.append("hardCloseSec = ?"); args.append(v) }
                if let v = maxLive { sets.append("maxLiveSessions = ?"); args.append(v) }
                sets.append("updatedAt = ?"); args.append(now)
                try db.execute(sql: "UPDATE webviewSessionConfig SET \(sets.joined(separator: ", ")) WHERE id = 'singleton'",
                               arguments: StatementArguments(args))
            }
            let row: Row? = try ctx.dbPool.read { db in
                try Row.fetchOne(db, sql: "SELECT idleSuspendSec, hardCloseSec, maxLiveSessions, updatedAt FROM webviewSessionConfig WHERE id = 'singleton'")
            }
            return WebviewSessionConfigResponse(
                idleSuspendSec: Int((row?["idleSuspendSec"] as Int64?) ?? 300),
                hardCloseSec: Int((row?["hardCloseSec"] as Int64?) ?? 1800),
                maxLiveSessions: Int((row?["maxLiveSessions"] as Int64?) ?? 8),
                updatedAt: (row?["updatedAt"] as Int64?) ?? now)
        }
    ),
]
