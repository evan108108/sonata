import Foundation
import GRDB
import Logging

/// Owns the Global AFK toggle state and the side-effects that fire when it
/// flips. Reads/writes the single-row `globalAFK` table (v24).
///
/// Pass 1 scope (this file as shipped): pure state — reads, writes, notifies
/// observers via a NotificationCenter post. The actual broadcast-to-sessions
/// + kickoff-email side-effects are wired in Pass 2 by subscribing to the
/// `.sonataGlobalAFKChanged` notification.
///
/// Single-row table means there's only ever one global flag — no "which AFK?"
/// ambiguity. Persistent across app restart by design: if Evan toggles AFK
/// Monday night and Sonata reboots overnight, he's still AFK Tuesday morning
/// until he flips it off (with a persistent banner to mitigate the "why
/// aren't you replying" surprise).
@MainActor
final class GlobalAFKController: ObservableObject {
    static let shared = GlobalAFKController()

    /// Surface that initiated the most recent flip — informs telemetry and
    /// the persistent banner copy ("Global AFK on from iPhone shortcut").
    enum FlipSource: String {
        case ui
        case mcp
        case api
        case boot   // restored from DB on app launch — not a real flip
    }

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var enabledAt: Date?

    private var dbPool: DatabasePool?
    private let logger: Logging.Logger

    private init() {
        var log = Logging.Logger(label: "sonata.globalafk")
        log.logLevel = .info
        self.logger = log
    }

    /// Wire the controller to the DB and hydrate the in-memory flag from the
    /// row. Called once during SonataApp init.
    func bootstrap(dbPool: DatabasePool) {
        self.dbPool = dbPool
        do {
            let snapshot = try dbPool.read { db -> (Bool, Date?) in
                let row = try Row.fetchOne(db, sql: "SELECT enabled, enabledAt FROM globalAFK WHERE id = 1")
                let enabled = (row?["enabled"] as? Int64 ?? 0) != 0
                let at = (row?["enabledAt"] as? Int64).map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
                return (enabled, at)
            }
            self.isEnabled = snapshot.0
            self.enabledAt = snapshot.1
            logger.info("global AFK restored from DB: enabled=\(snapshot.0)")
        } catch {
            logger.error("global AFK bootstrap read failed: \(error)")
        }
    }

    /// Flip the flag. No-op (returns the unchanged state) if the requested
    /// state already matches. Persists synchronously to the DB, updates the
    /// in-memory @Published values, and posts a notification so subscribers
    /// (broadcast logic, email sender, status indicators) can react.
    @discardableResult
    func setEnabled(_ enabled: Bool, source: FlipSource) -> Bool {
        guard enabled != isEnabled else { return isEnabled }
        guard let dbPool else {
            logger.error("global AFK setEnabled called before bootstrap")
            return isEnabled
        }
        let now = enabled ? Date() : nil
        let nowMs: Int64? = now.map { Int64($0.timeIntervalSince1970 * 1000.0) }
        do {
            try dbPool.write { db in
                try db.execute(sql: """
                    UPDATE globalAFK
                       SET enabled = ?, enabledAt = ?, flippedBy = ?
                     WHERE id = 1
                    """,
                    arguments: [enabled ? 1 : 0, nowMs, source.rawValue])
            }
        } catch {
            logger.error("global AFK setEnabled persist failed: \(error)")
            return isEnabled
        }
        self.isEnabled = enabled
        self.enabledAt = now
        logger.info("global AFK flipped: enabled=\(enabled) source=\(source.rawValue)")
        NotificationCenter.default.post(
            name: .sonataGlobalAFKChanged,
            object: nil,
            userInfo: ["enabled": enabled, "source": source.rawValue]
        )
        return enabled
    }
}

extension Notification.Name {
    /// Posted whenever Global AFK flips. userInfo carries `enabled: Bool` and
    /// `source: String`. Pass 2 subscribers: directive broadcaster, kickoff
    /// email sender, status indicator views.
    static let sonataGlobalAFKChanged = Notification.Name("sonataGlobalAFKChanged")

    // sonataMCPSessionAttached is referenced by string literal at the post
    // and subscribe sites in MCPSessionState + GlobalAFKOrchestrator. A
    // static-let extension cross-file fails to link (Swift's strict static
    // addressor resolution); the literal-string approach sidesteps it.
}
