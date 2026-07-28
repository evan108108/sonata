import SwiftUI
import AppKit
import Foundation

struct StudioArtifactItem: Identifiable, Hashable, Equatable {
    let id: String
    let sha256: String
    let dTag: String
    let pubkey: String      // publisher pubkey (lowercase hex) — "signed by" attribution
    let title: String?
    let contentType: String
    let frozenURL: String?      // nil when the key secret is missing (key_missing recovery)
    let latestURL: String?
    let eventId: String
    let publishedAt: Date
    let roomId: String?         // always nil in v1 — room-qualified artifacts are v2
    let revoked: Bool
    let revokedAt: Date?
    let revokedReason: String?
    let keyMissing: Bool

    var displayTitle: String { title?.isEmpty == false ? title! : dTag }

    static func == (lhs: StudioArtifactItem, rhs: StudioArtifactItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@MainActor
class StudioArtifactsViewModel: ObservableObject {
    @Published var artifacts: [StudioArtifactItem] = []
    @Published var error: String?
    @Published var isLoading = false

    private var baseURL: String { "http://127.0.0.1:\(sonataPort)" }

    // MARK: - Fetch

    func fetch() async {
        isLoading = true
        defer { isLoading = false }

        let call = await callAction("sonata-studio_studio_artifact_list", ["filter": "personal"])
        guard call.ok else {
            // "Unknown tool" until the sonata-studio plugin ships the artifact
            // actions — an expected state (empty panel), not an error to surface.
            // Same posture as WebhookRoutesViewModel.refreshPluginPubkey.
            if call.message?.localizedCaseInsensitiveContains("unknown tool") == true {
                error = nil
                artifacts = []
            } else {
                error = call.message
            }
            return
        }
        error = nil
        artifacts = Self.rowArray(call.value).compactMap { row in
            guard let id = row["id"] as? String,
                  let sha256 = row["sha256"] as? String,
                  let dTag = row["d_tag"] as? String else { return nil }
            return StudioArtifactItem(
                id: id,
                sha256: sha256,
                dTag: dTag,
                pubkey: row["pubkey"] as? String ?? "",
                title: row["title"] as? String,
                contentType: row["content_type"] as? String ?? "text/html",
                frozenURL: row["frozen_url"] as? String,
                latestURL: row["latest_url"] as? String,
                eventId: row["event_id"] as? String ?? "",
                publishedAt: Date(timeIntervalSince1970: Double(Self.msValue(row["published_at_ms"]) ?? 0) / 1000),
                roomId: row["room_id"] as? String,
                revoked: Self.boolValue(row["revoked"]),
                revokedAt: Self.msValue(row["revoked_at_ms"]).map {
                    Date(timeIntervalSince1970: Double($0) / 1000)
                },
                revokedReason: row["revoked_reason"] as? String,
                keyMissing: Self.boolValue(row["key_missing"])
            )
        }
    }

    // MARK: - Revoke

    /// Slug-level (a-tag) revocation: NIP-09 address semantics suppress every
    /// manifest at the slug with created_at ≤ the kind:5's, so one call takes
    /// down the frozen AND latest URLs for the artifact.
    func revoke(dTag: String) async -> Bool {
        let call = await callAction("sonata-studio_studio_artifact_revoke", ["d_tag": dTag])
        if call.ok {
            await fetch()
            return true
        }
        error = call.message
        return false
    }

    // MARK: - Copy / open

    func copyURL(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    func openInBrowser(_ url: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }

    // MARK: - Action call plumbing

    /// All artifact reads/writes go through POST /api/mcp/call by action NAME —
    /// Sonata core's ActionRegistry routes to the sonata-studio plugin; the
    /// Swift side never talks to the plugin port directly.
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

    /// Accept a bare array, an array nested under a conventional key, or the
    /// double-envelope shape that Sonata's `/api/mcp/call` uses for plugin-
    /// proxied actions: `{ok: true, result: {artifacts: […]}}`. Sonata-core
    /// actions (like webhook routes) return the single-envelope shape; plugin
    /// actions (like this one) return the double-envelope shape.
    private static func rowArray(_ value: Any?) -> [[String: Any]] {
        if let arr = value as? [[String: Any]] { return arr }
        if let dict = value as? [String: Any] {
            for key in ["artifacts", "rows", "items"] {
                if let arr = dict[key] as? [[String: Any]] { return arr }
            }
            // Plugin-proxy double envelope — unwrap once and try again.
            if let inner = dict["result"] as? [String: Any] {
                for key in ["artifacts", "rows", "items"] {
                    if let arr = inner[key] as? [[String: Any]] { return arr }
                }
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
