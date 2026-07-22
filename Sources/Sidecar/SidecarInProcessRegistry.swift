import Foundation

/// Where an in-process sidecar's handler closure lives between registration
/// and event delivery.
///
/// Mirrors `SidecarRegistry`'s shape: lock-guarded `final class` + `static
/// let shared`, deliberately not an actor because both the register path
/// (boot, synchronous) and the lookup path (`MCPEventPusher` inside a
/// tight tick loop) benefit from a synchronous seam.
///
/// Only holds `.inProcess` sidecars. `.claudeCode` sidecars go through
/// `SidecarWindowController` for their process-side handle. Two shapes,
/// two homes — deliberately, so a bug in one can't corrupt the other.
final class SidecarInProcessRegistry: @unchecked Sendable {
    static let shared = SidecarInProcessRegistry()

    private var handlers: [String: SidecarInProcessHandler] = [:]
    private let lock = NSLock()

    private init() {}

    /// Publish `handler` under `name`. Overwrites any previous handler for
    /// the same name — a re-spawn (e.g. tier flipped `.off` → `.standard`)
    /// registers a fresh handler.
    func register(name: String, handler: @escaping SidecarInProcessHandler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[name] = handler
    }

    /// Withdraw `name`'s handler. Called on `.stop` (tier flipped to
    /// `.off`) or on process shutdown. After unregister, `handler(forName:)`
    /// returns nil until a matching `register` runs.
    ///
    /// `MCPEventPusher` treating a missing handler as "leave event assigned,
    /// try again next tick" is the intended graceful mode — a mid-flight
    /// unregister would only cost one tick, not lose an event.
    func unregister(name: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: name)
    }

    /// Look up the handler for `name`, or nil.
    ///
    /// Called from `MCPEventPusher.pushPendingWorkerEvents` on every tick
    /// that finds an event assigned to an in-process sidecar. Kept fast: a
    /// single lock hop, no allocation.
    func handler(forName name: String) -> SidecarInProcessHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[name]
    }

    /// Names of every currently-registered in-process sidecar. Used by the
    /// detail view when it needs to distinguish "sidecar exists but has no
    /// worker row" (in-process, healthy) from "sidecar failed to spawn"
    /// (Claude Code, broken).
    func registeredNames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(handlers.keys)
    }

    /// Drop all state. Tests only.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeAll()
    }
}

/// The synthetic session key an in-process sidecar publishes to
/// `SidecarRegistry`. `MCPEventPusher.pushPendingWorkerEvents` recognises
/// the `inproc-` prefix and dispatches to the in-process registry instead
/// of trying to push over SSE. WorkerActions' fail-closed check treats
/// this the same as any other sessionKey — a non-nil string.
///
/// One helper so the prefix and the format live in exactly one place.
enum SidecarInProcessKey {
    static let prefix = "inproc-"

    static func sessionKey(forName name: String) -> String {
        "\(prefix)\(name)"
    }

    static func isInProcess(_ sessionKey: String) -> Bool {
        sessionKey.hasPrefix(prefix)
    }

    static func name(fromSessionKey sessionKey: String) -> String? {
        guard sessionKey.hasPrefix(prefix) else { return nil }
        return String(sessionKey.dropFirst(prefix.count))
    }
}
