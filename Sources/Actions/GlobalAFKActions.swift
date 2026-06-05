import Foundation
import GRDB

// MARK: - Response shapes

private struct GlobalAFKStatusResponse: Encodable {
    let enabled: Bool
    let enabledAt: Int64?
    let flippedBy: String?
}

private struct GlobalAFKSetResponse: Encodable {
    let enabled: Bool
    let changed: Bool
}

let globalAFKActions: [SonataAction] = [

    SonataAction(
        name: "global_afk_status",
        description: "Return the current Global AFK toggle state. Use this to check whether all interactive sessions are in AFK mode (which routes the user's questions to email) before deciding whether to ask via AskUserQuestion vs the AFK email path.",
        group: "/api/afk",
        path: "/global/status",
        method: .get,
        params: [],
        handler: { ctx in
            let snapshot = try await ctx.dbPool.read { db -> (Bool, Int64?, String?) in
                let row = try Row.fetchOne(db, sql: "SELECT enabled, enabledAt, flippedBy FROM globalAFK WHERE id = 1")
                let enabled = (row?["enabled"] as? Int64 ?? 0) != 0
                let at = row?["enabledAt"] as? Int64
                let by = row?["flippedBy"] as? String
                return (enabled, at, by)
            }
            return GlobalAFKStatusResponse(
                enabled: snapshot.0,
                enabledAt: snapshot.1,
                flippedBy: snapshot.2
            )
        }
    ),

    SonataAction(
        name: "global_afk_set",
        description: "Flip the Global AFK toggle on or off. When enabled, the app will broadcast an 'enter AFK' directive to every connected interactive + dispatching session at next turn boundary (workers excluded). When disabled, broadcasts 'exit AFK'. Persistent across app restart. Use this for programmatic control from external machines / iPhone shortcuts / scheduled jobs — equivalent to flipping the title-bar toggle in the Sonata UI.",
        group: "/api/afk",
        path: "/global/set",
        method: .post,
        params: [
            ActionParam("enabled", .boolean, required: true, description: "true to enter AFK across all sessions, false to exit"),
        ],
        handler: { ctx in
            guard let enabled = ctx.params.bool("enabled") else {
                throw ActionError.custom("enabled is required (boolean)", .unprocessableContent)
            }
            // Hop to MainActor to mutate the @MainActor-isolated controller.
            // The flip persists synchronously to the DB inside setEnabled.
            let result = await MainActor.run {
                GlobalAFKController.shared.setEnabled(enabled, source: .mcp)
            }
            return GlobalAFKSetResponse(
                enabled: result,
                changed: result == enabled
            )
        }
    ),
]
