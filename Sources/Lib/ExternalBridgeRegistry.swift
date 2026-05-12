import Foundation

// In-memory tracker for external sonata-bridge.ts processes — interactive
// `claude` (and claude-patched) sessions that have sonata-bridge configured
// as an MCP server but aren't registered Sonata pool workers.
//
// Bridges in passive mode call /api/bridge/announce on startup and
// /api/bridge/heartbeat every ~15s. Entries with no heartbeat in the last
// staleAfterMs window are pruned automatically when the count is read.
//
// Workers and supervisors don't register here — they're already tracked via
// the workers / supervisor heartbeat tables. This registry exists solely to
// surface the "external claude sessions" count on the dashboard.
final class ExternalBridgeRegistry: @unchecked Sendable {
    static let shared = ExternalBridgeRegistry()

    struct Entry {
        var sessionLabel: String?
        var pid: Int?
        var announcedAt: Int64
        var lastHeartbeat: Int64
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    // 60s gives a 4× margin over the 15s bridge heartbeat — keeps the count
    // accurate without flickering to zero on a single dropped heartbeat.
    private static let staleAfterMs: Int64 = 60_000

    func announce(sessionId: String, sessionLabel: String?, pid: Int?) {
        lock.lock(); defer { lock.unlock() }
        let now = nowMs()
        if var existing = entries[sessionId] {
            existing.lastHeartbeat = now
            if let sessionLabel { existing.sessionLabel = sessionLabel }
            if let pid { existing.pid = pid }
            entries[sessionId] = existing
        } else {
            entries[sessionId] = Entry(
                sessionLabel: sessionLabel,
                pid: pid,
                announcedAt: now,
                lastHeartbeat: now
            )
        }
    }

    func heartbeat(sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        let now = nowMs()
        if var existing = entries[sessionId] {
            existing.lastHeartbeat = now
            entries[sessionId] = existing
        } else {
            // Heartbeat for a session we've never seen (e.g. server restarted
            // and lost in-memory state) — adopt it. Bridge identity is stable
            // for the life of the process, so picking it back up is safe.
            entries[sessionId] = Entry(
                sessionLabel: nil,
                pid: nil,
                announcedAt: now,
                lastHeartbeat: now
            )
        }
    }

    func unregister(sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: sessionId)
    }

    /// True iff the sessionId belongs to a live external bridge (heartbeat within the staleness window).
    func contains(sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        return entries[sessionId] != nil
    }

    func currentCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        return entries.count
    }

    func snapshot() -> [(sessionId: String, entry: Entry)] {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        return entries.map { ($0.key, $0.value) }
    }

    private func pruneLocked() {
        let cutoff = nowMs() - Self.staleAfterMs
        entries = entries.filter { $0.value.lastHeartbeat >= cutoff }
    }
}
