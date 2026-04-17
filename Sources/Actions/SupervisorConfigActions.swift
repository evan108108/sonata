import Foundation
import GRDB
import Hummingbird

// Action definitions for /api/supervisor/config routes.
// Backs the supervisor schedule configuration UI in Settings.
//
// The supervisorConfig table is a singleton keyed by id='singleton'.
// dayIntervalSec / nightIntervalSec control the HealthMonitor's
// supervisor check-event cadence based on current wall-clock hour.

// MARK: - Response Types

struct SupervisorConfigResponse: Encodable {
    let dayIntervalSec: Int
    let nightIntervalSec: Int
    let nightStartHour: Int
    let nightEndHour: Int
    let enabled: Bool
    let updatedAt: Int64
    let currentMode: String    // "day" | "night" | "disabled"
    let currentIntervalSec: Int
}

// MARK: - Mode helper

/// Returns "night" if hour ∈ [start, end) wrapping at midnight; else "day".
private func isNightHour(_ hour: Int, start: Int, end: Int) -> Bool {
    if start == end { return false }
    if start < end {
        return hour >= start && hour < end
    } else {
        // Wraps midnight (e.g. 22 → 7): night if hour >= start OR hour < end.
        return hour >= start || hour < end
    }
}

let supervisorConfigActions: [SonataAction] = [

    // GET /api/supervisor/config — fetch current config + current effective mode
    SonataAction(
        name: "supervisor_config_get",
        description: "Get the current supervisor check-interval configuration (day/night).",
        group: "/api/supervisor",
        path: "/config",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let row: Row? = try await ctx.dbPool.read { db -> Row? in
                    try Row.fetchOne(db, sql: """
                        SELECT dayIntervalSec, nightIntervalSec, nightStartHour,
                               nightEndHour, enabled, updatedAt
                        FROM supervisorConfig WHERE id = 'singleton'
                    """)
                }

                let dayInterval = (row?["dayIntervalSec"] as Int64?).map(Int.init) ?? 180
                let nightInterval = (row?["nightIntervalSec"] as Int64?).map(Int.init) ?? 1800
                let nightStart = (row?["nightStartHour"] as Int64?).map(Int.init) ?? 22
                let nightEnd = (row?["nightEndHour"] as Int64?).map(Int.init) ?? 7
                let enabled = ((row?["enabled"] as Int64?) ?? 1) != 0
                let updatedAt = (row?["updatedAt"] as Int64?) ?? 0

                let hour = Calendar.current.component(.hour, from: Date())
                let night = isNightHour(hour, start: nightStart, end: nightEnd)
                let mode = !enabled ? "disabled" : (night ? "night" : "day")
                let currentInterval = night ? nightInterval : dayInterval

                return SupervisorConfigResponse(
                    dayIntervalSec: dayInterval,
                    nightIntervalSec: nightInterval,
                    nightStartHour: nightStart,
                    nightEndHour: nightEnd,
                    enabled: enabled,
                    updatedAt: updatedAt,
                    currentMode: mode,
                    currentIntervalSec: currentInterval
                )
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/supervisor/config — partial update, merges with existing
    SonataAction(
        name: "supervisor_config_update",
        description: "Update the supervisor check-interval configuration (partial update; any omitted field keeps its current value).",
        group: "/api/supervisor",
        path: "/config",
        method: .post,
        params: [
            ActionParam("dayIntervalSec", .integer, description: "Day-mode check interval (seconds). Range 30–3600."),
            ActionParam("nightIntervalSec", .integer, description: "Night-mode check interval (seconds). Range 60–14400."),
            ActionParam("nightStartHour", .integer, description: "Night start hour (0–23)."),
            ActionParam("nightEndHour", .integer, description: "Night end hour (0–23)."),
            ActionParam("enabled", .boolean, description: "Whether supervisor checks are pushed at all."),
        ],
        handler: { ctx in
            let dayInterval = ctx.params.int("dayIntervalSec")
            let nightInterval = ctx.params.int("nightIntervalSec")
            let nightStart = ctx.params.int("nightStartHour")
            let nightEnd = ctx.params.int("nightEndHour")
            let enabled = ctx.params.bool("enabled")

            if let d = dayInterval, d < 30 || d > 3600 {
                throw ActionError.invalidParam("dayIntervalSec", "must be between 30 and 3600 seconds")
            }
            if let n = nightInterval, n < 60 || n > 14400 {
                throw ActionError.invalidParam("nightIntervalSec", "must be between 60 and 14400 seconds")
            }
            if let s = nightStart, s < 0 || s > 23 {
                throw ActionError.invalidParam("nightStartHour", "must be 0–23")
            }
            if let e = nightEnd, e < 0 || e > 23 {
                throw ActionError.invalidParam("nightEndHour", "must be 0–23")
            }

            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    // Ensure the singleton row exists (defensive — seed migration handles it).
                    let exists = try Bool.fetchOne(db, sql: """
                        SELECT COUNT(*) > 0 FROM supervisorConfig WHERE id = 'singleton'
                    """) ?? false

                    if !exists {
                        try db.execute(sql: """
                            INSERT INTO supervisorConfig
                                (id, dayIntervalSec, nightIntervalSec, nightStartHour,
                                 nightEndHour, enabled, updatedAt)
                            VALUES ('singleton', 180, 1800, 22, 7, 1, ?)
                        """, arguments: [now])
                    }

                    var sets: [String] = []
                    var args: [any DatabaseValueConvertible] = []
                    if let d = dayInterval { sets.append("dayIntervalSec = ?"); args.append(d) }
                    if let n = nightInterval { sets.append("nightIntervalSec = ?"); args.append(n) }
                    if let s = nightStart { sets.append("nightStartHour = ?"); args.append(s) }
                    if let e = nightEnd { sets.append("nightEndHour = ?"); args.append(e) }
                    if let en = enabled { sets.append("enabled = ?"); args.append(en ? 1 : 0) }
                    sets.append("updatedAt = ?")
                    args.append(now)

                    try db.execute(
                        sql: "UPDATE supervisorConfig SET \(sets.joined(separator: ", ")) WHERE id = 'singleton'",
                        arguments: StatementArguments(args)
                    )
                }
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            // Return the fresh row in the same shape as GET.
            let row: Row? = try await ctx.dbPool.read { db -> Row? in
                try Row.fetchOne(db, sql: """
                    SELECT dayIntervalSec, nightIntervalSec, nightStartHour,
                           nightEndHour, enabled, updatedAt
                    FROM supervisorConfig WHERE id = 'singleton'
                """)
            }

            let dayOut = (row?["dayIntervalSec"] as Int64?).map(Int.init) ?? 180
            let nightOut = (row?["nightIntervalSec"] as Int64?).map(Int.init) ?? 1800
            let startOut = (row?["nightStartHour"] as Int64?).map(Int.init) ?? 22
            let endOut = (row?["nightEndHour"] as Int64?).map(Int.init) ?? 7
            let enabledOut = ((row?["enabled"] as Int64?) ?? 1) != 0
            let updatedOut = (row?["updatedAt"] as Int64?) ?? now

            let hour = Calendar.current.component(.hour, from: Date())
            let night = isNightHour(hour, start: startOut, end: endOut)
            let mode = !enabledOut ? "disabled" : (night ? "night" : "day")
            let currentInterval = night ? nightOut : dayOut

            return SupervisorConfigResponse(
                dayIntervalSec: dayOut,
                nightIntervalSec: nightOut,
                nightStartHour: startOut,
                nightEndHour: endOut,
                enabled: enabledOut,
                updatedAt: updatedOut,
                currentMode: mode,
                currentIntervalSec: currentInterval
            )
        }
    ),
]
