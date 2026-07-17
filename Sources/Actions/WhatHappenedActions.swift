import Foundation
import GRDB

// Universal domain-status router. Convention documented at
// ~/.sonata/wiki/sonata/patterns/whathappened.md. Sonata is the phone book,
// never the aggregator: this action routes to an internal WhatHappenedRegistry
// handler OR to a plugin-declared HTTP endpoint. It never combines domains.

private let pluginForwardTimeoutSeconds: TimeInterval = 5.0
private let whathappenedGroup = "/api"
private let whathappenedPath = "/whathappened"

private struct WhatHappenedDomainCatalogEntry: Encodable {
    let domain: String
    let source: String            // "internal" | "plugin"
    let description: String?
    let args: [WhatHappenedCatalogArg]
    let url: String?              // plugin only
    let method: String?           // plugin only
    let port: Int?                // plugin only
}

private struct WhatHappenedCatalogArg: Encodable {
    let name: String
    let type: String
    let required: Bool
    let description: String?
}

private struct WhatHappenedCatalogResponse: Encodable {
    let domains: [WhatHappenedDomainCatalogEntry]
    let generated_at: Int64
}

let whatHappenedActions: [SonataAction] = [
    SonataAction(
        name: "whathappened",
        description: """
        Universal domain-status router. Returns the shared { domain, artifact_id, \
        queried_at, actions[], in_flight, external_verification, staleness_notes, \
        error } shape for the requested domain — read \
        ~/.sonata/wiki/sonata/patterns/whathappened.md for the schema convention. \
        Pass `list=true` to enumerate every registered domain (internal + plugin) \
        instead. Pass `domain` plus the domain's declared args to route (per-domain \
        args are forwarded as-is; the tool schema declares additionalProperties: \
        true so callers can pass whatever the target domain expects).
        """,
        group: whathappenedGroup,
        path: whathappenedPath,
        method: .post,
        params: [
            ActionParam(
                "domain", .string, required: false,
                description: "Domain slug to query (e.g. 'task', 'dm', 'memory', 'prstar', 'lead'). Omit when list=true."
            ),
            ActionParam(
                "list", .boolean, required: false,
                description: "If true, return the domain catalog instead of routing. Ignores 'domain' + any per-domain args.",
                default: false
            ),
            // Free-form per-domain args flow through .all — they are not
            // declared here because Sonata cannot know every domain's arg
            // schema at registration time. Per-domain validation happens
            // after routing. `mcpAllowAdditionalArgs: true` below tells the
            // MCP schema emitter to open the door for these.
        ],
        mcpAllowAdditionalArgs: true,
        handler: { ctx in
            if ctx.params.bool("list") == true {
                return try await buildCatalog(dbPool: ctx.dbPool)
            }
            guard let domain = ctx.params.string("domain"), !domain.isEmpty else {
                throw ActionError.missingParam("domain")
            }
            return try await route(domain: domain, params: ctx.params, dbPool: ctx.dbPool)
        }
    )
]

// MARK: - Catalog

private func buildCatalog(dbPool: DatabasePool) async throws -> WhatHappenedCatalogResponse {
    let internalDomains = WhatHappenedRegistry.shared.allInternal
    var entries: [WhatHappenedDomainCatalogEntry] = internalDomains.map { d in
        WhatHappenedDomainCatalogEntry(
            domain: d.domain,
            source: "internal",
            description: d.description.isEmpty ? nil : d.description,
            args: d.argsSchema.map {
                WhatHappenedCatalogArg(
                    name: $0.name,
                    type: $0.type.rawValue,
                    required: $0.required,
                    description: $0.description.isEmpty ? nil : $0.description
                )
            },
            url: nil,
            method: nil,
            port: nil
        )
    }

    let pluginRows: [Row] = try dbPool.read { db in
        try Row.fetchAll(db, sql: """
            SELECT plugin_name, domain, url, method, args_json, port
            FROM plugin_whathappened
            ORDER BY domain
        """)
    }
    for row in pluginRows {
        let pluginName: String = row["plugin_name"]
        // `domain` was added in v32. Rows written before v32's backfill
        // ran might still be NULL for the split second between migration
        // and the next plugin_enable — fall back to plugin_name.
        let domain: String = (row["domain"] as? String) ?? pluginName
        let url: String = row["url"]
        let method: String = row["method"]
        let argsJSON: String = row["args_json"]
        let port: Int = row["port"]
        let args = decodeCatalogArgs(from: argsJSON)
        entries.append(WhatHappenedDomainCatalogEntry(
            domain: domain,
            source: "plugin",
            description: nil,
            args: args,
            url: url,
            method: method,
            port: port
        ))
    }

    return WhatHappenedCatalogResponse(domains: entries, generated_at: nowMs())
}

private func decodeCatalogArgs(from json: String) -> [WhatHappenedCatalogArg] {
    guard let data = json.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return []
    }
    return arr.map { obj in
        WhatHappenedCatalogArg(
            name: (obj["name"] as? String) ?? "",
            type: (obj["type"] as? String) ?? "string",
            required: (obj["required"] as? Bool) ?? false,
            description: obj["description"] as? String
        )
    }
}

// MARK: - Route

private func route(
    domain: String,
    params: ActionParams,
    dbPool: DatabasePool
) async throws -> any Encodable {
    // 1. Internal handler wins.
    if let internalDomain = WhatHappenedRegistry.shared.lookup(domain) {
        try validateArgs(internalDomain.argsSchema, against: params)
        return try await internalDomain.handler(params, dbPool)
    }
    // 2. Plugin lookup.
    if let pluginRow = try await loadPluginRow(domain: domain, dbPool: dbPool) {
        return try await forwardToPlugin(row: pluginRow, params: params)
    }
    // 3. Not registered.
    return WhatHappenedResponse.errorResponse(
        domain: domain,
        artifact_id: "",
        message: "domain '\(domain)' not registered — call whathappened(list=true) to see available domains"
    )
}

private func validateArgs(
    _ schema: [WhatHappenedArgSpec],
    against params: ActionParams
) throws {
    for spec in schema where spec.required {
        let raw = params.all[spec.name]
        let isMissing: Bool = {
            if raw == nil { return true }
            if let s = raw as? String, s.isEmpty { return true }
            return false
        }()
        if isMissing {
            throw ActionError.missingParam(spec.name)
        }
    }
}

// MARK: - Plugin forwarding

private struct PluginWhatHappenedRow {
    let pluginName: String
    let url: String
    let method: String
    let argsJSON: String
    let port: Int
}

private func loadPluginRow(
    domain: String,
    dbPool: DatabasePool
) async throws -> PluginWhatHappenedRow? {
    try await dbPool.read { db in
        // Look up by domain (v32+). If no row matches by `domain`, fall
        // back to `plugin_name` for compatibility with rows written before
        // the migration ran their backfill (should be zero rows in practice,
        // but the cost is one no-op query per miss).
        if let row = try Row.fetchOne(db, sql: """
            SELECT plugin_name, url, method, args_json, port
            FROM plugin_whathappened
            WHERE domain = ?
        """, arguments: [domain]) {
            return PluginWhatHappenedRow(
                pluginName: row["plugin_name"],
                url: row["url"],
                method: row["method"],
                argsJSON: row["args_json"],
                port: row["port"]
            )
        }
        guard let row = try Row.fetchOne(db, sql: """
            SELECT plugin_name, url, method, args_json, port
            FROM plugin_whathappened
            WHERE plugin_name = ?
        """, arguments: [domain]) else { return nil }
        return PluginWhatHappenedRow(
            pluginName: row["plugin_name"],
            url: row["url"],
            method: row["method"],
            argsJSON: row["args_json"],
            port: row["port"]
        )
    }
}

private func forwardToPlugin(
    row: PluginWhatHappenedRow,
    params: ActionParams
) async throws -> any Encodable {
    let schema = decodeArgSpecs(from: row.argsJSON)
    for spec in schema where spec.required {
        let value = params.all[spec.name]
        let isMissing: Bool = {
            if value == nil { return true }
            if let s = value as? String, s.isEmpty { return true }
            return false
        }()
        if isMissing {
            throw ActionError.missingParam(spec.name)
        }
    }

    // Strip Sonata-only keys before forwarding — 'domain' and 'list' are the
    // router's own controls, not the plugin's business.
    var forwardArgs: [String: Any] = [:]
    for (k, v) in params.all where k != "domain" && k != "list" {
        forwardArgs[k] = v
    }

    let method = row.method.lowercased()
    let baseURL = "http://127.0.0.1:\(row.port)\(row.url)"

    var request: URLRequest
    if method == "get" {
        var comps = URLComponents(string: baseURL)!
        var items: [URLQueryItem] = comps.queryItems ?? []
        for (k, v) in forwardArgs {
            items.append(URLQueryItem(name: k, value: stringifyForQuery(v)))
        }
        comps.queryItems = items
        guard let url = comps.url else {
            return WhatHappenedResponse.errorResponse(
                domain: row.pluginName,
                artifact_id: "",
                message: "plugin URL is malformed: \(baseURL)"
            )
        }
        request = URLRequest(url: url)
        request.httpMethod = "GET"
    } else {
        guard let url = URL(string: baseURL) else {
            return WhatHappenedResponse.errorResponse(
                domain: row.pluginName,
                artifact_id: "",
                message: "plugin URL is malformed: \(baseURL)"
            )
        }
        request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONSerialization.data(withJSONObject: forwardArgs)
        request.httpBody = body
    }
    request.timeoutInterval = pluginForwardTimeoutSeconds

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return WhatHappenedResponse.errorResponse(
                domain: row.pluginName,
                artifact_id: "",
                message: "plugin returned a non-HTTP response"
            )
        }
        if http.statusCode >= 400 {
            let bodyPreview = String(data: data.prefix(512), encoding: .utf8) ?? ""
            return WhatHappenedResponse.errorResponse(
                domain: row.pluginName,
                artifact_id: "",
                message: "plugin returned HTTP \(http.statusCode): \(bodyPreview)"
            )
        }
        // Pass-through: the plugin body is trusted to conform to the shared
        // schema. Sonata does not validate its shape beyond that JSON parses.
        guard let bodyJSON = try? JSONSerialization.jsonObject(with: data) else {
            return WhatHappenedResponse.errorResponse(
                domain: row.pluginName,
                artifact_id: "",
                message: "plugin returned non-JSON body"
            )
        }
        return AnyJSONEncodable(bodyJSON)
    } catch let error as URLError where error.code == .timedOut {
        return WhatHappenedResponse.errorResponse(
            domain: row.pluginName,
            artifact_id: "",
            message: "plugin '\(row.pluginName)' timed out after \(Int(pluginForwardTimeoutSeconds))s"
        )
    } catch {
        return WhatHappenedResponse.errorResponse(
            domain: row.pluginName,
            artifact_id: "",
            message: "plugin '\(row.pluginName)' unreachable: \(error.localizedDescription)"
        )
    }
}

private func decodeArgSpecs(from json: String) -> [WhatHappenedArgSpec] {
    guard let data = json.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return []
    }
    return arr.map { obj in
        let name = (obj["name"] as? String) ?? ""
        let type = ParamType(rawValue: (obj["type"] as? String) ?? "string") ?? .string
        let required = (obj["required"] as? Bool) ?? false
        let description = (obj["description"] as? String) ?? ""
        return WhatHappenedArgSpec(name, type: type, required: required, description: description)
    }
}

private func stringifyForQuery(_ value: Any) -> String {
    if let s = value as? String { return s }
    if let i = value as? Int { return String(i) }
    if let d = value as? Double {
        if d.rounded() == d && d.isFinite { return String(Int64(d)) }
        return String(d)
    }
    if let b = value as? Bool { return b ? "true" : "false" }
    return "\(value)"
}

/// Encodes an already-parsed JSON value (dict / array / scalar) as-is when the
/// action handler returns it. Walks the value tree via Codable directly — do
/// NOT round-trip through JSONSerialization.data at scalar levels: that call
/// requires the top-level to be a container and raises NSInvalidArgumentException
/// on a scalar, crashing the process (learned the hard way 2026-07-17 —
/// plugin-forward path crashed Sonata on any response with a string in an
/// array, e.g. staleness_notes[]).
struct AnyJSONEncodable: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }

    func encode(to encoder: Encoder) throws {
        // NSNumber can encode as Bool/Int/Double depending on the underlying
        // storage. Test the more specific types first — a JSONSerialization
        // Bool decodes as NSNumber which also satisfies `as? Int`.
        var container = encoder.singleValueContainer()
        if value is NSNull {
            try container.encodeNil()
        } else if let num = value as? NSNumber {
            // Distinguish Bool from numeric NSNumber via objCType.
            if String(cString: num.objCType) == "c" {
                try container.encode(num.boolValue)
            } else if CFNumberIsFloatType(num as CFNumber) {
                try container.encode(num.doubleValue)
            } else {
                try container.encode(num.int64Value)
            }
        } else if let b = value as? Bool {
            try container.encode(b)
        } else if let i = value as? Int64 {
            try container.encode(i)
        } else if let i = value as? Int {
            try container.encode(i)
        } else if let d = value as? Double {
            try container.encode(d)
        } else if let s = value as? String {
            try container.encode(s)
        } else if let arr = value as? [Any] {
            try container.encode(arr.map(AnyJSONEncodable.init))
        } else if let dict = value as? [String: Any] {
            try container.encode(dict.mapValues(AnyJSONEncodable.init))
        } else {
            try container.encode(String(describing: value))
        }
    }
}
