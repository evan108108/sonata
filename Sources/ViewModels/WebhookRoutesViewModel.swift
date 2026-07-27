import SwiftUI
import Foundation

struct WebhookRouteItem: Identifiable, Hashable, Equatable {
    let id: String
    let name: String
    let slug: String
    let destKind: String        // "action", "worker", "dm", "log"
    let destTarget: String
    let authScheme: String      // "none", "bearer", "hmacSha256", "svix"
    let authSecretRef: String?
    let authHeaderName: String?
    let promptTemplate: String?     // for destKind='worker': rendered against payload for the dispatched task's prompt
    let workerPool: String?         // for destKind='worker': optional pool hint
    let dispatchFilter: String?     // optional gate "<path>=<v1>|<v2>|..."; mismatch → skipped audit, no dispatch
    let actionParams: String?       // for destKind='action': JSON template rendered against payload, parsed, and spread into target action's params
    let enabled: Bool
    let createdAt: Date

    static func == (lhs: WebhookRouteItem, rhs: WebhookRouteItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct WebhookRouteStats {
    let lastDeliveryAt: Date?
    let deliveryCount: Int
    let verifiedRate: Double    // 0...1
}

struct WebhookDeliveryItem: Identifiable {
    let id: String
    let receivedAt: Date
    let sourceIp: String?
    let verified: Bool
    let handlerResult: String?
    let error: String?
}

@MainActor
class WebhookRoutesViewModel: ObservableObject {
    @Published var routes: [WebhookRouteItem] = []
    @Published var stats: [String: WebhookRouteStats] = [:]   // keyed by slug
    @Published var deliveries: [WebhookDeliveryItem] = []
    @Published var actionNames: [String] = []
    /// The 4a plugin's operational pubkey, fetched via its `4a_pubkey_get`
    /// action. nil until the plugin is installed and booted — the copy-URL
    /// affordance stays disabled until then.
    @Published var pluginPubkey: String?
    @Published var error: String?
    @Published var isLoading = false

    private var baseURL: String { "http://127.0.0.1:\(sonataPort)" }

    // MARK: - Fetch

    func fetch() async {
        isLoading = true
        defer { isLoading = false }

        let call = await callAction("webhook_route_list")
        guard call.ok else {
            error = call.message
            return
        }
        error = nil
        routes = Self.rowArray(call.value).compactMap { row in
            guard let id = row["id"] as? String,
                  let slug = row["slug"] as? String else { return nil }
            return WebhookRouteItem(
                id: id,
                name: row["name"] as? String ?? slug,
                slug: slug,
                destKind: row["destKind"] as? String ?? "log",
                destTarget: row["destTarget"] as? String ?? "",
                authScheme: row["authScheme"] as? String ?? "none",
                authSecretRef: row["authSecretRef"] as? String,
                authHeaderName: row["authHeaderName"] as? String,
                promptTemplate: row["promptTemplate"] as? String,
                workerPool: row["workerPool"] as? String,
                dispatchFilter: row["dispatchFilter"] as? String,
                actionParams: row["actionParams"] as? String,
                enabled: Self.boolValue(row["enabled"]),
                createdAt: Date(timeIntervalSince1970: Double(Self.msValue(row["createdAtMs"]) ?? 0) / 1000)
            )
        }

        await fetchStats()
        await refreshPluginPubkey()
        await loadActionNames()
    }

    /// webhook_route_stats returns aggregates for ALL routes in one call:
    /// { stats: [{ routeId, slug, total, verified, lastReceivedAtMs? }] }.
    private func fetchStats() async {
        let call = await callAction("webhook_route_stats")
        guard call.ok else { return }
        var bySlug: [String: WebhookRouteStats] = [:]
        for entry in Self.rowArray(call.value) {
            guard let slug = entry["slug"] as? String else { continue }
            let total = Self.msValue(entry["total"]).map(Int.init) ?? 0
            let verified = Self.msValue(entry["verified"]).map(Int.init) ?? 0
            bySlug[slug] = WebhookRouteStats(
                lastDeliveryAt: Self.msValue(entry["lastReceivedAtMs"]).map {
                    Date(timeIntervalSince1970: Double($0) / 1000)
                },
                deliveryCount: total,
                verifiedRate: total > 0 ? Double(verified) / Double(total) : 0
            )
        }
        stats = bySlug
    }

    // MARK: - Deliveries

    func fetchDeliveries(slug: String) async {
        deliveries = []
        let call = await callAction("webhook_delivery_list", ["slug": slug])
        guard call.ok else {
            error = call.message
            return
        }
        deliveries = Self.rowArray(call.value).compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return WebhookDeliveryItem(
                id: id,
                receivedAt: Date(timeIntervalSince1970: Double(Self.msValue(row["receivedAtMs"]) ?? 0) / 1000),
                sourceIp: row["sourceIp"] as? String,
                verified: Self.boolValue(row["verified"]),
                handlerResult: row["handlerResult"] as? String,
                error: row["error"] as? String
            )
        }
    }

    // MARK: - Upsert

    /// Slug is the route identity — upserting an existing slug updates it.
    func upsert(
        name: String,
        slug: String,
        destKind: String,
        destTarget: String,
        authScheme: String,
        authSecretRef: String?,
        authHeaderName: String?,
        promptTemplate: String?,
        workerPool: String?,
        dispatchFilter: String?,
        actionParams: String?,
        enabled: Bool
    ) async -> Bool {
        var args: [String: Any] = [
            "name": name,
            "slug": slug,
            "destKind": destKind,
            "destTarget": destTarget,
            "authScheme": authScheme,
            "enabled": enabled,
        ]
        if let r = authSecretRef, !r.isEmpty { args["authSecretRef"] = r }
        if let h = authHeaderName, !h.isEmpty { args["authHeaderName"] = h }
        if let t = promptTemplate, !t.isEmpty { args["promptTemplate"] = t }
        if let p = workerPool, !p.isEmpty { args["workerPool"] = p }
        if let f = dispatchFilter, !f.isEmpty { args["dispatchFilter"] = f }
        if let a = actionParams, !a.isEmpty { args["actionParams"] = a }

        let call = await callAction("webhook_route_upsert", args)
        if call.ok {
            await fetch()
            return true
        }
        error = call.message
        return false
    }

    func setEnabled(route: WebhookRouteItem, enabled: Bool) async -> Bool {
        await upsert(
            name: route.name,
            slug: route.slug,
            destKind: route.destKind,
            destTarget: route.destTarget,
            authScheme: route.authScheme,
            authSecretRef: route.authSecretRef,
            authHeaderName: route.authHeaderName,
            promptTemplate: route.promptTemplate,
            workerPool: route.workerPool,
            dispatchFilter: route.dispatchFilter,
            actionParams: route.actionParams,
            enabled: enabled
        )
    }

    // MARK: - Delete

    func delete(slug: String) async -> Bool {
        let call = await callAction("webhook_route_delete", ["slug": slug])
        if call.ok {
            await fetch()
            return true
        }
        error = call.message
        return false
    }

    // MARK: - Secrets

    /// Store a route's shared secret in the SecretStore keychain under the
    /// conventional key; the route row only ever carries the key name.
    func saveSecret(slug: String, secret: String) async -> Bool {
        let call = await callAction("mem_secret_set", [
            "name": "webhook_secret_\(slug)",
            "value": secret,
            "description": "Webhook shared secret for route '\(slug)'",
        ])
        if !call.ok { error = call.message }
        return call.ok
    }

    // MARK: - Copy URL

    func refreshPluginPubkey() async {
        let call = await callAction("4a_pubkey_get")
        if call.ok, let dict = call.value as? [String: Any],
           let pubkey = dict["pubkey"] as? String, !pubkey.isEmpty {
            pluginPubkey = pubkey
        } else {
            // "Unknown tool" until the 4a plugin registers its actions —
            // an expected state, not an error to surface.
            pluginPubkey = nil
        }
    }

    func hookURL(slug: String) -> String? {
        pluginPubkey.map { "https://api.4a4.ai/v0/hook/\($0)/\(slug)" }
    }

    // MARK: - Action registry names (destination dropdown)

    private func loadActionNames() async {
        guard let url = URL(string: "\(baseURL)/api/mcp/actions") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            actionNames = list.compactMap { $0["name"] as? String }.sorted()
        } catch {
            // Non-fatal: the dropdown falls back to free-text entry.
        }
    }

    // MARK: - Action call plumbing

    /// All webhook CRUD goes through POST /api/mcp/call by action NAME —
    /// the names are the stable contract; the actions' HTTP groups/paths
    /// are an implementation detail of the backend bundle.
    private struct ActionCallResult {
        let ok: Bool
        let value: Any?
        let message: String?
    }

    private func callAction(_ name: String, _ args: [String: Any] = [:]) async -> ActionCallResult {
        guard let url = URL(string: "\(baseURL)/api/mcp/call") else {
            return ActionCallResult(ok: false, value: nil, message: "Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "arguments": args])
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let result = json?["result"]
            let isError = (json?["error"] as? Bool) ?? false
            if isError || status >= 300 {
                return ActionCallResult(
                    ok: false,
                    value: nil,
                    message: (result as? String) ?? "\(name) failed: HTTP \(status)"
                )
            }
            return ActionCallResult(ok: true, value: result, message: nil)
        } catch {
            return ActionCallResult(ok: false, value: nil, message: error.localizedDescription)
        }
    }

    // MARK: - Lenient JSON helpers

    /// Accept either a bare array or an array nested under a conventional key,
    /// so the ViewModel tolerates whichever envelope the backend bundle picks.
    private static func rowArray(_ value: Any?) -> [[String: Any]] {
        if let arr = value as? [[String: Any]] { return arr }
        if let dict = value as? [String: Any] {
            for key in ["routes", "rows", "items", "deliveries", "stats"] {
                if let arr = dict[key] as? [[String: Any]] { return arr }
            }
        }
        return []
    }

    private static func msValue(_ v: Any?) -> Int64? {
        if let n = v as? Int64 { return n }
        if let n = v as? Int { return Int64(n) }
        if let n = v as? Double { return Int64(n) }
        if let s = v as? String { return Int64(s) }
        return nil
    }

    private static func boolValue(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? Int { return n != 0 }
        if let n = v as? Double { return n != 0 }
        return false
    }
}
