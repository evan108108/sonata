import CryptoKit
import Foundation
import GRDB
import Logging

// MARK: - Webhook Actions (routes CRUD + the plugin-facing deliver endpoint)
//
// Inbound third-party webhooks reach Sonata through the 4a relay: the public
// gateway wraps the raw request, the local 4a plugin decrypts it and POSTs
// {slug, body_b64, headers, receivedAtMs, sourceIp, wrapEventId} to
// /api/webhook/deliver with the shared bearer PluginManager injected at spawn.
// This bundle owns the route table (slug → destination), signature
// verification against the user-configured per-slug secret, the delivery
// audit log, and dispatch to the destination (action | worker | dm | log).
//
// Factory, not a bare `let`: destKind dispatch needs the live ActionRegistry
// (same precedent as makePluginActions).

private let webhookLogger = Logger(label: "sonata.webhook")

/// SecretStore key holding the plugin↔Sonata shared bearer. Must match the
/// key PluginManager reads when injecting SONATA_WEBHOOK_BEARER.
let webhookSharedSecretKey = "4a_webhook_shared_secret"

private let webhookDestKinds = ["action", "worker", "dm", "log"]
private let webhookAuthSchemes = ["none", "bearer", "hmacSha256", "svix"]

// MARK: Row + response shapes

private struct WebhookRouteRow: Encodable {
    let id: String
    let slug: String
    let name: String
    let destKind: String
    let destTarget: String
    let authScheme: String
    let authSecretRef: String?
    let authHeaderName: String?
    let enabled: Bool
    let createdAtMs: Int64
    /// Prompt template rendered against the webhook payload when destKind='worker'.
    /// Nil → fall back to raw workerEvents enqueue (backward compat).
    let promptTemplate: String?
    /// Optional worker pool hint (which pool the dispatched task should target).
    /// Nil → dispatcher default.
    let workerPool: String?
    /// Optional dispatch filter. Shape `<path>=<v1>|<v2>|...`. Evaluated against
    /// payload before dispatch — mismatch → audit as "skipped: filter miss",
    /// no dispatch. Nil → always dispatch.
    let dispatchFilter: String?

    init(row: Row) {
        id = row["id"]
        slug = row["slug"]
        name = row["name"]
        destKind = row["destKind"]
        destTarget = row["destTarget"]
        authScheme = row["authScheme"]
        authSecretRef = row["authSecretRef"]
        authHeaderName = row["authHeaderName"]
        enabled = (row["enabled"] as Int64? ?? 0) != 0
        createdAtMs = row["createdAtMs"]
        promptTemplate = row["promptTemplate"]
        workerPool = row["workerPool"]
        dispatchFilter = row["dispatchFilter"]
    }

    /// The SecretStore key holding this route's third-party secret.
    var secretKey: String {
        if let ref = authSecretRef, !ref.isEmpty { return ref }
        return "webhook_secret_\(slug)"
    }
}

private struct RouteListResponse: Encodable {
    let routes: [WebhookRouteRow]
}

private struct RouteStatsEntry: Encodable {
    let routeId: String
    let slug: String
    let total: Int
    let verified: Int
    let lastReceivedAtMs: Int64?
}

private struct RouteStatsResponse: Encodable {
    let stats: [RouteStatsEntry]
}

private struct DeliveryRow: Encodable {
    let id: String
    let routeId: String
    let wrapEventId: String?
    let receivedAtMs: Int64
    let sourceIp: String?
    let bodyHash: String?
    let verified: Bool
    let handlerResult: String?
    let error: String?

    init(row: Row) {
        id = row["id"]
        routeId = row["routeId"]
        wrapEventId = row["wrapEventId"]
        receivedAtMs = row["receivedAtMs"]
        sourceIp = row["sourceIp"]
        bodyHash = row["bodyHash"]
        verified = (row["verified"] as Int64? ?? 0) != 0
        handlerResult = row["handlerResult"]
        error = row["error"]
    }
}

private struct DeliveryListResponse: Encodable {
    let deliveries: [DeliveryRow]
}

private struct DeliverResponse: Encodable {
    let ok = true
    let deliveryId: String?
    let duplicate: Bool
    let verified: Bool
    let dispatched: Bool
    let error: String?
}

// MARK: Helpers

private func fetchRoute(slug: String, dbPool: DatabasePool) async throws -> WebhookRouteRow? {
    try await dbPool.read { db in
        try Row.fetchOne(
            db, sql: "SELECT * FROM webhookRoutes WHERE slug = ?", arguments: [slug]
        ).map(WebhookRouteRow.init(row:))
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Evaluate a dispatch filter of the shape `<json.path>=<v1>|<v2>|...` against
/// the payload. Returns nil on a match (dispatch proceeds) or a human-readable
/// reason when the filter blocks dispatch (audited on the delivery row).
///
/// A malformed filter (no `=`, empty allowlist) is treated as no-filter to
/// keep the audit trail sane; the misconfiguration would be too easy to hit
/// silently otherwise.
private func evaluateDispatchFilter(_ filter: String, payload: [String: Any]) -> String? {
    guard let eqIdx = filter.firstIndex(of: "=") else { return nil }
    let path = String(filter[..<eqIdx]).trimmingCharacters(in: .whitespaces)
    let rhs = String(filter[filter.index(after: eqIdx)...])
    let allowed = rhs.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    guard !path.isEmpty, !allowed.isEmpty else { return nil }

    // Reuse the template renderer's resolution logic via a single-expression
    // template. Warnings are ignored — a missing path renders empty, which
    // just means the filter fails (which is the correct behavior).
    let render = renderTemplate("{{ \(path) }}", payload: payload)
    let actual = render.rendered.trimmingCharacters(in: .whitespaces)
    if allowed.contains(actual) { return nil }
    return "filter miss: path='\(path)' value='\(actual)' expected=[\(allowed.joined(separator: "|"))]"
}

/// Encode a handler's `any Encodable` result for the audit row, truncated so
/// a chatty destination can't bloat the deliveries table.
private func encodeHandlerResult(_ result: any Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = (try? encoder.encode(AnyEncodable(result)))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "\(result)"
    return String(json.prefix(2000))
}

private func recordDelivery(
    id: String, verified: Bool, handlerResult: String?, error: String?,
    dbPool: DatabasePool
) async {
    do {
        try await dbPool.write { db in
            try db.execute(sql: """
                UPDATE webhookDeliveries
                SET verified = ?, handlerResult = ?, error = ?
                WHERE id = ?
                """, arguments: [verified ? 1 : 0, handlerResult, error, id])
        }
    } catch {
        webhookLogger.warning("webhook_deliver: audit update failed for \(id): \(error)")
    }
}

// MARK: Actions

func makeWebhookActions(registry: ActionRegistry) -> [SonataAction] {
    [

    // GET /api/webhook/routes — all configured routes
    SonataAction(
        name: "webhook_route_list",
        description: "List configured inbound webhook routes.",
        group: "/api/webhook",
        path: "/routes",
        method: .get,
        params: [],
        handler: { ctx in
            let routes = try await ctx.dbPool.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM webhookRoutes ORDER BY createdAtMs")
                    .map(WebhookRouteRow.init(row:))
            }
            return RouteListResponse(routes: routes)
        }
    ),

    // POST /api/webhook/routes/upsert — create or update a route (by slug)
    SonataAction(
        name: "webhook_route_upsert",
        description: "Create or update an inbound webhook route. Slug is the identity: an existing route with the same slug is updated.",
        group: "/api/webhook",
        path: "/routes/upsert",
        method: .post,
        params: [
            ActionParam("slug", .string, required: true, description: "URL slug ([A-Za-z0-9_-]+), the tail of the public hook URL"),
            ActionParam("name", .string, required: true, description: "Human-readable route name"),
            ActionParam("destKind", .string, required: true, description: "Destination kind: action | worker | dm | log"),
            ActionParam("destTarget", .string, description: "Destination target: action name, worker event type suffix, or DM target. Ignored for 'log'."),
            ActionParam("authScheme", .string, required: true, description: "Signature scheme: none | bearer | hmacSha256"),
            ActionParam("authSecretRef", .string, description: "SecretStore key holding the third-party secret (default webhook_secret_<slug>)"),
            ActionParam("authHeaderName", .string, description: "Header carrying the signature/bearer (required for hmacSha256)"),
            ActionParam("promptTemplate", .string, description: "For destKind='worker': template rendered against payload; result becomes the worker's prompt. Supports {{ path.to.value }} substitutions, plus {{ payload }} for the whole envelope. Null → raw workerEvents enqueue (backward compat)."),
            ActionParam("workerPool", .string, description: "For destKind='worker': optional pool hint the dispatched task should target."),
            ActionParam("dispatchFilter", .string, description: "Optional filter: '<json.path>=<v1>|<v2>|...'. Dispatch only when the resolved payload value matches one of the allowed values. Example: 'body.action=opened|synchronize|reopened' for GitHub PRs."),
            ActionParam("enabled", .boolean, description: "Route enabled (default true)"),
        ],
        handler: { ctx in
            let slug = try ctx.params.require("slug")
            guard slug.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                throw ActionError.invalidParam("slug", "must match [A-Za-z0-9_-]+")
            }
            let name = try ctx.params.require("name")
            let destKind = try ctx.params.require("destKind")
            guard webhookDestKinds.contains(destKind) else {
                throw ActionError.invalidParam("destKind", "must be one of \(webhookDestKinds.joined(separator: " | "))")
            }
            let destTarget = ctx.params.string("destTarget") ?? ""
            if destKind != "log", destTarget.isEmpty {
                throw ActionError.missingParam("destTarget")
            }
            let authScheme = try ctx.params.require("authScheme")
            guard webhookAuthSchemes.contains(authScheme) else {
                throw ActionError.invalidParam("authScheme", "must be one of \(webhookAuthSchemes.joined(separator: " | "))")
            }
            let authHeaderName = ctx.params.string("authHeaderName")
            if authScheme == "hmacSha256", (authHeaderName ?? "").isEmpty {
                throw ActionError.invalidParam("authHeaderName", "required for hmacSha256 (e.g. X-Hub-Signature-256)")
            }
            let authSecretRef = ctx.params.string("authSecretRef")
            let promptTemplate = ctx.params.string("promptTemplate")
            let workerPool = ctx.params.string("workerPool")
            let dispatchFilter = ctx.params.string("dispatchFilter")
            let enabled = ctx.params.bool("enabled") ?? true
            let id = newUUID()
            let now = nowMs()

            try await ctx.dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO webhookRoutes
                        (id, slug, name, destKind, destTarget, authScheme, authSecretRef, authHeaderName, enabled, createdAtMs, promptTemplate, workerPool, dispatchFilter)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(slug) DO UPDATE SET
                        name = excluded.name,
                        destKind = excluded.destKind,
                        destTarget = excluded.destTarget,
                        authScheme = excluded.authScheme,
                        authSecretRef = excluded.authSecretRef,
                        authHeaderName = excluded.authHeaderName,
                        enabled = excluded.enabled,
                        promptTemplate = excluded.promptTemplate,
                        workerPool = excluded.workerPool,
                        dispatchFilter = excluded.dispatchFilter
                    """, arguments: [
                        id, slug, name, destKind, destTarget, authScheme,
                        authSecretRef, authHeaderName, enabled ? 1 : 0, now,
                        promptTemplate, workerPool, dispatchFilter,
                    ])
            }
            guard let saved = try await fetchRoute(slug: slug, dbPool: ctx.dbPool) else {
                throw ActionError.database("route upsert did not persist for slug \(slug)")
            }
            return saved
        }
    ),

    // DELETE /api/webhook/routes — remove a route by slug
    SonataAction(
        name: "webhook_route_delete",
        description: "Delete an inbound webhook route by slug. Delivery history is kept.",
        group: "/api/webhook",
        path: "/routes",
        method: .delete,
        params: [
            ActionParam("slug", .string, required: true, description: "Slug of the route to delete"),
        ],
        handler: { ctx in
            let slug = try ctx.params.require("slug")
            let deleted = try await ctx.dbPool.write { db -> Int in
                try db.execute(sql: "DELETE FROM webhookRoutes WHERE slug = ?", arguments: [slug])
                return db.changesCount
            }
            guard deleted > 0 else { throw ActionError.notFound("webhook route '\(slug)'") }
            return SuccessResponse()
        }
    ),

    // GET /api/webhook/stats — per-route delivery aggregates
    SonataAction(
        name: "webhook_route_stats",
        description: "Per-route webhook delivery stats: total, verified count, last delivery time.",
        group: "/api/webhook",
        path: "/stats",
        method: .get,
        params: [],
        handler: { ctx in
            let stats = try await ctx.dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT r.id AS routeId, r.slug AS slug,
                           COUNT(d.id) AS total,
                           COALESCE(SUM(d.verified), 0) AS verified,
                           MAX(d.receivedAtMs) AS lastReceivedAtMs
                    FROM webhookRoutes r
                    LEFT JOIN webhookDeliveries d ON d.routeId = r.id
                    GROUP BY r.id
                    ORDER BY r.createdAtMs
                    """).map { row in
                        RouteStatsEntry(
                            routeId: row["routeId"],
                            slug: row["slug"],
                            total: row["total"],
                            verified: row["verified"],
                            lastReceivedAtMs: row["lastReceivedAtMs"]
                        )
                    }
            }
            return RouteStatsResponse(stats: stats)
        }
    ),

    // GET /api/webhook/deliveries — recent deliveries for a route
    SonataAction(
        name: "webhook_delivery_list",
        description: "Recent webhook deliveries for a route (newest first).",
        group: "/api/webhook",
        path: "/deliveries",
        method: .get,
        params: [
            ActionParam("slug", .string, required: true, description: "Route slug"),
            ActionParam("limit", .integer, description: "Max rows (default 50)"),
        ],
        handler: { ctx in
            let slug = try ctx.params.require("slug")
            guard let route = try await fetchRoute(slug: slug, dbPool: ctx.dbPool) else {
                throw ActionError.notFound("webhook route '\(slug)'")
            }
            let limit = min(max(ctx.params.int("limit") ?? 50, 1), 500)
            let deliveries = try await ctx.dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT * FROM webhookDeliveries
                    WHERE routeId = ?
                    ORDER BY receivedAtMs DESC
                    LIMIT ?
                    """, arguments: [route.id, limit]).map(DeliveryRow.init(row:))
            }
            return DeliveryListResponse(deliveries: deliveries)
        }
    ),

    // POST /api/webhook/deliver — the 4a plugin's entry point. httpOnly:
    // never an MCP tool; callers authenticate with the shared bearer.
    SonataAction(
        name: "webhook_deliver",
        description: "Internal: accept a relayed webhook delivery from the 4a plugin, verify, audit, dispatch.",
        group: "/api/webhook",
        path: "/deliver",
        method: .post,
        params: [
            ActionParam("slug", .string, required: true, description: "Route slug from the hook URL"),
            ActionParam("body_b64", .string, required: true, description: "Base64 of the exact raw webhook body bytes"),
            ActionParam("headers", .object, description: "Forwarded third-party headers"),
            ActionParam("receivedAtMs", .integer, description: "Gateway receipt time (default now)"),
            ActionParam("sourceIp", .string, description: "Original source IP as seen by the gateway"),
            ActionParam("wrapEventId", .string, required: true, description: "Gift-wrap rumor id — dedup key for at-least-once delivery"),
        ],
        httpOnly: true,
        handler: { ctx in
            // (a) Shared bearer — proves the caller is the spawned plugin.
            // 401 (not 200-unverified) so a misconfigured caller is loud.
            guard let expected = SecretStore.get(webhookSharedSecretKey),
                  ctx.requestHeaders["authorization"] == "Bearer \(expected)" else {
                throw ActionError.custom("unauthorized", .unauthorized)
            }

            let slug = try ctx.params.require("slug")
            let bodyB64 = try ctx.params.require("body_b64")
            let wrapEventId = try ctx.params.require("wrapEventId")
            guard let rawBody = Data(base64Encoded: bodyB64) else {
                throw ActionError.invalidParam("body_b64", "not valid base64")
            }
            let receivedAtMs = ctx.params.int("receivedAtMs").map(Int64.init) ?? nowMs()
            let sourceIp = ctx.params.string("sourceIp")
            // Third-party headers, lowercased for case-insensitive lookup.
            let forwardedHeaders: [String: String] = Dictionary(
                (ctx.params.object("headers") ?? [:]).map { ($0.key.lowercased(), "\($0.value)") },
                uniquingKeysWith: { first, _ in first }
            )

            // (b) Route lookup — 404 before any row is written, per plan.
            guard let route = try await fetchRoute(slug: slug, dbPool: ctx.dbPool),
                  route.enabled else {
                throw ActionError.notFound("enabled webhook route '\(slug)'")
            }

            // (c) Dedup insert. wrapEventId is UNIQUE; a replayed wrap
            // (SSE reconnect, plugin retry) inserts 0 rows → skip, 200 so
            // the plugin advances its cursor.
            let deliveryId = newUUID()
            let inserted = try await ctx.dbPool.write { db -> Int in
                try db.execute(sql: """
                    INSERT OR IGNORE INTO webhookDeliveries
                        (id, routeId, wrapEventId, receivedAtMs, sourceIp, bodyHash, verified)
                    VALUES (?, ?, ?, ?, ?, ?, 0)
                    """, arguments: [
                        deliveryId, route.id, wrapEventId, receivedAtMs,
                        sourceIp, sha256Hex(rawBody),
                    ])
                return db.changesCount
            }
            guard inserted > 0 else {
                webhookLogger.info("webhook_deliver: duplicate wrapEventId \(wrapEventId) for slug \(slug), skipping")
                return DeliverResponse(deliveryId: nil, duplicate: true, verified: false, dispatched: false, error: nil)
            }

            // (d) Verify the third party's own signature per route scheme.
            var verified = false
            var verifyError: String?
            switch route.authScheme {
            case "none":
                verified = true
            case "bearer":
                let headerName = (route.authHeaderName ?? "authorization").lowercased()
                if let secret = SecretStore.get(route.secretKey) {
                    let value = forwardedHeaders[headerName] ?? ""
                    verified = value == secret || value == "Bearer \(secret)"
                    if !verified { verifyError = "bearer mismatch on header '\(headerName)'" }
                } else {
                    verifyError = "no secret in SecretStore under '\(route.secretKey)'"
                }
            case "hmacSha256":
                let headerName = (route.authHeaderName ?? "").lowercased()
                if let secret = SecretStore.get(route.secretKey) {
                    if let sig = forwardedHeaders[headerName] {
                        verified = verifyHMACSHA256(rawBody: rawBody, headerValue: sig, secret: secret)
                        if !verified { verifyError = "HMAC-SHA256 mismatch on header '\(headerName)'" }
                    } else {
                        verifyError = "missing signature header '\(headerName)'"
                    }
                } else {
                    verifyError = "no secret in SecretStore under '\(route.secretKey)'"
                }
            case "svix":
                // Svix uses three fixed headers (svix-id, svix-timestamp,
                // svix-signature) — authHeaderName is unused for this scheme.
                if let secret = SecretStore.get(route.secretKey) {
                    let sid = forwardedHeaders["svix-id"] ?? ""
                    let sts = forwardedHeaders["svix-timestamp"] ?? ""
                    let ssig = forwardedHeaders["svix-signature"] ?? ""
                    if sid.isEmpty || sts.isEmpty || ssig.isEmpty {
                        verifyError = "missing one of svix-id / svix-timestamp / svix-signature"
                    } else {
                        verified = verifySvixSignature(
                            rawBody: rawBody,
                            svixId: sid,
                            svixTimestamp: sts,
                            svixSignature: ssig,
                            secret: secret
                        )
                        if !verified { verifyError = "svix signature mismatch or timestamp outside tolerance" }
                    }
                } else {
                    verifyError = "no secret in SecretStore under '\(route.secretKey)'"
                }
            default:
                verifyError = "unknown authScheme '\(route.authScheme)'"
            }

            guard verified else {
                // Audited, not dispatched. 200: a retry would fail the same
                // way, so the plugin must advance past this wrap.
                webhookLogger.warning("webhook_deliver: verification failed for slug \(slug): \(verifyError ?? "?")")
                await recordDelivery(id: deliveryId, verified: false, handlerResult: nil, error: verifyError, dbPool: ctx.dbPool)
                return DeliverResponse(deliveryId: deliveryId, duplicate: false, verified: false, dispatched: false, error: verifyError)
            }

            // (e) Dispatch. Failures are recorded on the audit row, not
            // thrown — the delivery itself succeeded and must not replay.
            var handlerResult: String?
            var dispatchError: String?
            var payloadParams: [String: Any] = [
                "slug": slug,
                "body_b64": bodyB64,
                "headers": ctx.params.object("headers") ?? [:],
                "receivedAtMs": Int(receivedAtMs),
                "wrapEventId": wrapEventId,
            ]
            // Parse the body as JSON when it's a JSON-object body so template/
            // filter expressions can reach into it (e.g. body.pull_request.number).
            // Falls back to the raw utf8 string when the body isn't JSON.
            if let bodyData = rawBody as Data?,
               let bodyJson = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                payloadParams["body"] = bodyJson
            } else if let utf8 = String(data: rawBody, encoding: .utf8) {
                payloadParams["body"] = utf8
            }
            if let sourceIp { payloadParams["sourceIp"] = sourceIp }

            // (e.1) Dispatch filter. Applied AFTER signature verify but BEFORE
            // dispatch. Mismatch → audit as skipped, no dispatch, no error.
            if let filter = route.dispatchFilter, !filter.isEmpty,
               let reason = evaluateDispatchFilter(filter, payload: payloadParams) {
                webhookLogger.info("webhook_deliver: skipped by filter for slug \(slug): \(reason)")
                await recordDelivery(id: deliveryId, verified: true,
                    handlerResult: "skipped: \(reason)", error: nil, dbPool: ctx.dbPool)
                return DeliverResponse(
                    deliveryId: deliveryId, duplicate: false, verified: true,
                    dispatched: false, error: nil
                )
            }

            switch route.destKind {
            case "action":
                if let dest = registry.action(named: route.destTarget) {
                    do {
                        let destCtx = ActionContext(
                            params: ActionParams(payloadParams),
                            dbPool: ctx.dbPool,
                            scheduler: ctx.scheduler,
                            search: ctx.search,
                            emailHandler: ctx.emailHandler
                        )
                        handlerResult = encodeHandlerResult(try await dest.handler(destCtx))
                    } catch {
                        dispatchError = "action '\(route.destTarget)' threw: \(error.localizedDescription)"
                    }
                } else {
                    dispatchError = "no action named '\(route.destTarget)' in registry"
                }
            case "worker":
                if let template = route.promptTemplate, !template.isEmpty {
                    // Templated path: render prompt from payload, dispatch a
                    // task with the rendered text. Template warnings (unknown
                    // paths, unclosed braces) land in the delivery's error
                    // column so silent typos in production show up in audit.
                    let result = renderTemplate(template, payload: payloadParams)
                    if !result.warnings.isEmpty {
                        dispatchError = "template warnings: \(result.warnings.joined(separator: "; "))"
                    }
                    if let create = registry.action(named: "mem_task_create") {
                        do {
                            var taskParams: [String: Any] = [
                                "title": "webhook: \(slug)",
                                "prompt": result.rendered,
                                "source": "webhook:\(slug)",
                            ]
                            if let pool = route.workerPool, !pool.isEmpty {
                                taskParams["assignedTo"] = pool
                            }
                            let createCtx = ActionContext(
                                params: ActionParams(taskParams),
                                dbPool: ctx.dbPool,
                                scheduler: ctx.scheduler,
                                search: ctx.search,
                                emailHandler: ctx.emailHandler
                            )
                            handlerResult = encodeHandlerResult(try await create.handler(createCtx))
                        } catch {
                            let msg = "mem_task_create threw: \(error.localizedDescription)"
                            dispatchError = dispatchError.map { "\($0); \(msg)" } ?? msg
                        }
                    } else {
                        dispatchError = "mem_task_create not in registry"
                    }
                } else if let enqueue = registry.action(named: "worker_event_enqueue") {
                    // Backward compat: no template → raw workerEvents enqueue.
                    do {
                        let payloadJSON = String(
                            data: try JSONSerialization.data(withJSONObject: payloadParams, options: [.sortedKeys]),
                            encoding: .utf8) ?? "{}"
                        let enqueueCtx = ActionContext(
                            params: ActionParams([
                                "type": "webhook_\(slug)",
                                "payload": payloadJSON,
                            ]),
                            dbPool: ctx.dbPool,
                            scheduler: ctx.scheduler,
                            search: ctx.search,
                            emailHandler: ctx.emailHandler
                        )
                        handlerResult = encodeHandlerResult(try await enqueue.handler(enqueueCtx))
                    } catch {
                        dispatchError = "worker_event_enqueue threw: \(error.localizedDescription)"
                    }
                } else {
                    dispatchError = "worker_event_enqueue not in registry"
                }
            case "dm":
                if let resolved = await DMTargetResolver.resolve(route.destTarget, dbPool: ctx.dbPool) {
                    let bodyText = String(data: rawBody, encoding: .utf8) ?? "(binary body, sha256 \(sha256Hex(rawBody)))"
                    let dmBody = "Webhook '\(slug)' received:\n\(String(bodyText.prefix(4000)))"
                    let response = await sendResolved(
                        target: route.destTarget,
                        resolved: resolved,
                        body: dmBody,
                        context: "webhook:\(slug)",
                        senderKey: "webhook:\(slug)",
                        inReplyToMessageId: nil,
                        dbPool: ctx.dbPool
                    )
                    handlerResult = encodeHandlerResult(response)
                    if response.status != "sent" {
                        dispatchError = "dm to '\(route.destTarget)': \(response.status)\(response.reason.map { " (\($0))" } ?? "")"
                    }
                } else {
                    dispatchError = "dm target '\(route.destTarget)' did not resolve"
                }
            case "log":
                handlerResult = "logged"
            default:
                dispatchError = "unknown destKind '\(route.destKind)'"
            }

            // (f) Record the outcome on the audit row.
            await recordDelivery(
                id: deliveryId, verified: true,
                handlerResult: handlerResult, error: dispatchError,
                dbPool: ctx.dbPool
            )
            return DeliverResponse(
                deliveryId: deliveryId, duplicate: false, verified: true,
                dispatched: dispatchError == nil, error: dispatchError
            )
        }
    ),

    ]
}
