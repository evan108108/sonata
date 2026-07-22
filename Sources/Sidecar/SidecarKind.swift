import Foundation

/// How a sidecar handles the events routed to it.
///
/// Every sidecar's job is the same: receive events by type, produce a side
/// effect (e.g. hints in `sidecarHints`, an enrichment in some other table,
/// a DM to a peer). Two ways to actually run that job:
///
/// - **`.claudeCode`** — the full-fat implementation. Sonata spawns a hidden
///   Claude Code session, drives it from a SKILL.md, and delivers events
///   over its SSE stream. The session can dispatch sub-agents, reason across
///   turns, rotate when its context fills. Right shape when the event needs
///   LLM judgment (reviewer, enricher, cross-session synthesizer).
///
/// - **`.inProcess`** — a Swift closure runs in Sonata's own process. No
///   Claude Code session, no `workers` row, no context monitor, no
///   rotation, no SKILL.md, no spend. Right shape when the event's work
///   is already covered by Sonata's own machinery (memory hints are just
///   `mem_recall` + a table INSERT — no need for an LLM to sit on top).
///
/// The choice is made at registration time, per sidecar. The framework
/// (registry, config store, spend tracker, settings panel, detail page,
/// hooks, hint API) does not care which one — it's the two call sites in
/// `SidecarLifecycle.spawn` and `MCPEventPusher.pushPendingWorkerEvents`
/// that branch. Everything else is uniform.
enum SidecarKind: String, Sendable, Equatable, Codable {
    case claudeCode
    case inProcess
}

/// The Swift closure an in-process sidecar registers to handle events.
///
/// Invoked from `MCPEventPusher.pushPendingWorkerEvents` when an assigned
/// event with `assignedTo == "inproc-<name>"` reaches the tick. Runs on
/// the pusher's actor executor; a handler that needs to do slow work should
/// `Task.detached` it or the pusher tick will back up.
///
/// Return without throwing to complete the event; throw to fail it. Errors
/// are logged with the event id so a broken handler surfaces in the log
/// instead of silently swallowing events.
typealias SidecarInProcessHandler = @Sendable (SidecarEventPayload) async throws -> Void

/// The minimum shape a handler needs to process one event. Deliberately
/// small: everything else the handler wants to know (DB pool, logger,
/// registries) is available via singletons (`SonataApp.sharedDbPool`,
/// module-level `Logger`, `SidecarRegistry.shared`, etc.). Threading them
/// through the payload would just be a second place they can go stale.
struct SidecarEventPayload: Sendable {
    /// The `workerEvents.id` this handler is servicing. Include in log
    /// lines so an operator can trace a specific event through Sonata's log.
    let eventId: String

    /// The event's `type` (e.g. `"memory_request"`). Present so a single
    /// registered sidecar can handle multiple event types with one closure
    /// if it wants — otherwise the handler can ignore it.
    let type: String

    /// The event's payload, exactly as it landed in `workerEvents.payload`
    /// (a JSON blob). Handler decodes what it needs, ignores what it
    /// doesn't. No framework-side decode step — the payload shape is a
    /// contract between the event producer and this sidecar, not
    /// something the framework wants to be in the middle of.
    let payloadJSON: String
}
