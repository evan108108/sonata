import Foundation
import GRDB

// Registry for `whathappened` domain handlers. Internal Sonata subsystems
// register at boot (see SonataApp.swift). Plugin domains live in the
// plugin_whathappened SQL table and are dispatched via HTTP forward in
// WhatHappenedActions.swift — this registry only holds in-process handlers.
//
// The response schema is pinned at ~/.sonata/wiki/sonata/patterns/whathappened.md.
// Do not add top-level fields here without updating that page first.

struct WhatHappenedArgSpec: Sendable {
    let name: String
    let type: ParamType
    let required: Bool
    let description: String

    init(_ name: String, type: ParamType, required: Bool = false, description: String = "") {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
    }
}

/// Small enum for the free-form `meta` sub-object on each action. Handlers
/// build these directly; plugin responses bypass this type entirely (they
/// return a raw JSON body that Sonata forwards verbatim).
enum WhatHappenedMetaValue: Encodable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }
}

struct WhatHappenedAction: Encodable {
    let when: Int64
    let action_kind: String
    let actor: String?
    let verdict: String?
    let sha: String?
    let url: String?
    let meta: [String: WhatHappenedMetaValue]?
}

struct WhatHappenedInFlight: Encodable {
    let actor: String?
    let started_at: Int64?
    let action_kind: String
    let last_heartbeat: Int64?
}

struct WhatHappenedExternalVerification: Encodable {
    let source: String
    let url: String?
    let matches_local_record: Bool?
}

struct WhatHappenedResponse: Encodable {
    let domain: String
    let artifact_id: String
    let queried_at: Int64
    let actions: [WhatHappenedAction]
    let in_flight: WhatHappenedInFlight?
    let external_verification: WhatHappenedExternalVerification?
    let staleness_notes: [String]
    let error: String?

    // Custom encode so the convention-required null fields are emitted as
    // explicit `null` instead of being omitted (Swift's default Codable
    // synthesis drops nil optionals). Wiki says in_flight and error MUST be
    // present in every response; external_verification is optional (may be
    // omitted or null) but callers deserve determinism so we emit it too.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(domain, forKey: .domain)
        try c.encode(artifact_id, forKey: .artifact_id)
        try c.encode(queried_at, forKey: .queried_at)
        try c.encode(actions, forKey: .actions)
        if let in_flight { try c.encode(in_flight, forKey: .in_flight) }
        else { try c.encodeNil(forKey: .in_flight) }
        if let external_verification {
            try c.encode(external_verification, forKey: .external_verification)
        } else {
            try c.encodeNil(forKey: .external_verification)
        }
        try c.encode(staleness_notes, forKey: .staleness_notes)
        if let error { try c.encode(error, forKey: .error) }
        else { try c.encodeNil(forKey: .error) }
    }

    enum CodingKeys: String, CodingKey {
        case domain, artifact_id, queried_at, actions
        case in_flight, external_verification, staleness_notes, error
    }

    static func errorResponse(
        domain: String,
        artifact_id: String,
        message: String
    ) -> WhatHappenedResponse {
        WhatHappenedResponse(
            domain: domain,
            artifact_id: artifact_id,
            queried_at: nowMs(),
            actions: [],
            in_flight: nil,
            external_verification: nil,
            staleness_notes: [],
            error: message
        )
    }
}

typealias WhatHappenedHandler = @Sendable (
    _ args: ActionParams,
    _ dbPool: DatabasePool
) async throws -> WhatHappenedResponse

struct WhatHappenedDomain: Sendable {
    let domain: String
    let argsSchema: [WhatHappenedArgSpec]
    let description: String
    let handler: WhatHappenedHandler
}

final class WhatHappenedRegistry: @unchecked Sendable {
    static let shared = WhatHappenedRegistry()

    private var domains: [String: WhatHappenedDomain] = [:]
    private let lock = NSLock()

    private init() {}

    func register(
        domain: String,
        argsSchema: [WhatHappenedArgSpec],
        description: String = "",
        handler: @escaping WhatHappenedHandler
    ) {
        lock.lock()
        defer { lock.unlock() }
        domains[domain] = WhatHappenedDomain(
            domain: domain,
            argsSchema: argsSchema,
            description: description,
            handler: handler
        )
    }

    func lookup(_ domain: String) -> WhatHappenedDomain? {
        lock.lock()
        defer { lock.unlock() }
        return domains[domain]
    }

    /// Snapshot of every internal domain, for the `list=true` catalog.
    var allInternal: [WhatHappenedDomain] {
        lock.lock()
        defer { lock.unlock() }
        return Array(domains.values)
    }
}
