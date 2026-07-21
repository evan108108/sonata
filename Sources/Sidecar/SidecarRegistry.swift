import Foundation

/// Registry of sidecars, keyed by name, with an event-type index for routing.
///
/// Shape mirrors `WhatHappenedRegistry` (lock-guarded `final class` +
/// `static let shared`) rather than an actor, deliberately: `assignee(forEventType:)`
/// is meant to be called from the synchronous event-enqueue path, and an actor
/// would force an `await` into that call site.
///
/// Two kinds of state live here:
///   - **Config** (`register`) — written once at boot, read everywhere after.
///   - **Live session key** (`setSessionKey`) — published by `SidecarLifecycle`
///     on spawn and cleared before a rotation tears the old session down, so
///     routing never points at a session that has already been terminated.
///
/// The session key is intentionally *not* on `Sidecar` itself: config is
/// immutable and outlives any individual session, while the key changes on
/// every rotation.
final class SidecarRegistry: @unchecked Sendable {
    static let shared = SidecarRegistry()

    enum RegistrationError: Error, CustomStringConvertible {
        case duplicateName(String)
        case eventTypeAlreadyOwned(eventType: String, owner: String, incoming: String)

        var description: String {
            switch self {
            case .duplicateName(let name):
                return "Sidecar '\(name)' is already registered. Sidecar names are unique registry keys."
            case .eventTypeAlreadyOwned(let eventType, let owner, let incoming):
                return """
                    Event type '\(eventType)' is already owned by sidecar '\(owner)'; \
                    '\(incoming)' cannot also claim it. One event type routes to exactly \
                    one sidecar.
                    """
            }
        }
    }

    private var sidecarsByName: [String: Sidecar] = [:]
    private var nameByEventType: [String: String] = [:]
    private var sessionKeyByName: [String: String] = [:]
    private let lock = NSLock()

    private init() {}

    /// Register a sidecar. Throws on a duplicate name, or when another sidecar
    /// already claims one of `sidecar.eventTypes`.
    ///
    /// The event-type collision check matters as much as the name check: a
    /// silent overwrite of the routing index would send events to the wrong
    /// sidecar, and would only show up as work quietly disappearing.
    /// Registration is all-or-nothing — a throw leaves the registry untouched.
    func register(_ sidecar: Sidecar) throws {
        lock.lock()
        defer { lock.unlock() }

        guard sidecarsByName[sidecar.name] == nil else {
            throw RegistrationError.duplicateName(sidecar.name)
        }
        for eventType in sidecar.eventTypes {
            if let owner = nameByEventType[eventType] {
                throw RegistrationError.eventTypeAlreadyOwned(
                    eventType: eventType, owner: owner, incoming: sidecar.name
                )
            }
        }

        sidecarsByName[sidecar.name] = sidecar
        for eventType in sidecar.eventTypes {
            nameByEventType[eventType] = sidecar.name
        }
    }

    /// The sidecar that owns `type`, or nil when the event belongs to normal
    /// worker routing.
    func lookup(byEventType type: String) -> Sidecar? {
        lock.lock()
        defer { lock.unlock() }
        guard let name = nameByEventType[type] else { return nil }
        return sidecarsByName[name]
    }

    func lookup(byName name: String) -> Sidecar? {
        lock.lock()
        defer { lock.unlock() }
        return sidecarsByName[name]
    }

    /// Every registered sidecar. Order is unspecified.
    func all() -> [Sidecar] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sidecarsByName.values)
    }

    /// Session key an event of `type` should be assigned to, or nil to fall
    /// through to existing routing.
    ///
    /// This is the seam the event-enqueue path calls. Nil covers three cases
    /// that all mean the same thing to a caller — no sidecar owns this type,
    /// the owning sidecar has never been spawned, or it is mid-rotation with
    /// its key withdrawn. In every case the event should route normally rather
    /// than be held for a session that cannot answer it.
    func assignee(forEventType type: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let name = nameByEventType[type] else { return nil }
        return sessionKeyByName[name]
    }

    /// Publish (or withdraw, with nil) the live session key for a sidecar.
    /// Called by `SidecarLifecycle` on spawn and rotation.
    func setSessionKey(_ sessionKey: String?, for name: String) {
        lock.lock()
        defer { lock.unlock() }
        if let sessionKey {
            sessionKeyByName[name] = sessionKey
        } else {
            sessionKeyByName.removeValue(forKey: name)
        }
    }

    func sessionKey(for name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessionKeyByName[name]
    }

    /// Drop all state. Tests only — there is no unregister in the running app,
    /// where registration happens once at boot.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        sidecarsByName.removeAll()
        nameByEventType.removeAll()
        sessionKeyByName.removeAll()
    }
}
