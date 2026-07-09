// Non-blocking consent banner that appears at the top of a Studio room when
// the auto-run plugin has surfaced a pending-consent prompt for the current
// room.
//
// The plugin writes a `studio:pending_consent:<roomSlug>:<founderPubkey>`
// entity each time an eligible card arrives from an unauthorized founder
// (see auto-run/state.ts writePendingConsent). This view polls Sonata's
// /api/entity/list every ~3s while the room is open and renders the most
// recent prompt as a banner. Three buttons:
//
//   - Once   → run this card only; the founder isn't allow-listed for
//              future cards. Persists auto_run_founder_decisions[founder]=once.
//   - Always → add to allow-list; future cards from this founder auto-run
//              without prompting. Persists allowed_founders + decisions[founder]=always.
//   - Never  → block this founder. decisions[founder]=never. Future cards
//              are skipped silently.
//
// macOS notification fires once per pending consent (UNUserNotification with
// "Open in Sonata" action). Dismissing the banner consumes the entity so
// re-projection of the same card doesn't keep re-prompting.

import SwiftUI
import UserNotifications

private let kAutoRunAllowedFoundersKey = "auto_run_allowed_founders"
private let kAutoRunFounderDecisionsKey = "auto_run_founder_decisions"

struct StudioAutoRunConsentBanner: View {
    let roomSlug: String
    let roomTitle: String

    @State private var pending: [PendingConsent] = []
    @State private var notifiedTokens: Set<String> = []

    var body: some View {
        // When `pending` is empty we still need the view to occupy a real slot
        // in the layout tree — SwiftUI elides a `Group` whose only child is
        // `EmptyView`, and modifiers like `.onAppear` / `.task` on an elided
        // view never fire. A zero-height `Color.clear` keeps the view present
        // (invisible) so the lifecycle modifier actually runs and the poller
        // can start. See bug 2026-05-12: banner stayed hidden because the
        // first poll never fired.
        Group {
            if let first = pending.first {
                bannerContent(for: first)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .task(id: roomSlug) {
            requestNotificationAuth()
            await pollLoop()
        }
    }

    private func bannerContent(for prompt: PendingConsent) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Founder \(shortPub(prompt.founderPub)) assigned you a card")
                    .font(.callout.weight(.semibold))
                Text("Allow auto-run for this founder? \"\(prompt.cardTitle)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Once") { Task { await respond(prompt, decision: "once") } }
                .buttonStyle(.bordered)
            Button("Always") { Task { await respond(prompt, decision: "always") } }
                .buttonStyle(.borderedProminent)
            Button("Never") { Task { await respond(prompt, decision: "never") } }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .overlay(Divider(), alignment: .bottom)
    }

    /// Run the 3-second polling loop until the enclosing `.task(id:)` is
    /// cancelled (room change or view disappearance). Structured concurrency
    /// handles cancellation — no manual Task handle bookkeeping required.
    private func pollLoop() async {
        while !Task.isCancelled {
            await loadPending()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func loadPending() async {
        let entries = await PendingConsentLoader.list(forRoom: roomSlug)
        // Fire macOS notification once per (room, founder, card) tuple. The
        // token lives in @State so it's process-scoped — restarting the app
        // re-notifies for any still-pending prompts, which is the desired
        // behavior (consent never expires until acted on).
        for entry in entries where !notifiedTokens.contains(entry.token) {
            notify(entry)
        }
        await MainActor.run {
            for entry in entries { notifiedTokens.insert(entry.token) }
            pending = entries
        }
    }

    private func respond(_ prompt: PendingConsent, decision: String) async {
        // Read current profile, mutate, write back.
        var attrs = await EntityHTTP.readUserProfileAttributes()
        var founders = (attrs[kAutoRunAllowedFoundersKey] as? [String]) ?? []
        var decisions = (attrs[kAutoRunFounderDecisionsKey] as? [String: String]) ?? [:]
        let founder = prompt.founderPub.lowercased()
        switch decision {
        case "always":
            if !founders.contains(founder) { founders.append(founder) }
            decisions[founder] = "always"
        case "once":
            decisions[founder] = "once"
        case "never":
            decisions[founder] = "never"
            founders.removeAll { $0 == founder }
        default:
            break
        }
        attrs[kAutoRunAllowedFoundersKey] = founders
        attrs[kAutoRunFounderDecisionsKey] = decisions
        await EntityHTTP.mergeIntoUserProfile([
            kAutoRunAllowedFoundersKey: founders,
            kAutoRunFounderDecisionsKey: decisions,
        ])
        // Consume the pending-consent entity so the banner clears.
        await PendingConsentLoader.delete(prompt)
        // If "always" or "once", re-project the original card by patching the
        // studio_card entity to clear the auto_run_dispatched_event_id
        // sentinel — actually unnecessary here: the plugin only sets the
        // sentinel on dispatch, and a "needs_consent" outcome doesn't dispatch.
        // The next SSE delivery of the card (or a manual reopen) will re-fire
        // the hook and find the decision in place.
        await loadPending()
    }

    private func notify(_ prompt: PendingConsent) {
        let content = UNMutableNotificationContent()
        content.title = "Studio: auto-run consent needed"
        content.body = "\(shortPub(prompt.founderPub)) in \(roomTitle) → \"\(prompt.cardTitle)\""
        content.userInfo = [
            "room": roomSlug,
            "founder": prompt.founderPub,
            "card_event_id": prompt.cardEventId,
        ]
        let req = UNNotificationRequest(
            identifier: "auto-run-consent:\(prompt.token)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { _ in /* best-effort */ }
    }

    private func requestNotificationAuth() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }

    private func shortPub(_ pub: String) -> String {
        guard pub.count > 16 else { return pub }
        return "\(pub.prefix(8))…\(pub.suffix(4))"
    }
}

struct PendingConsent: Identifiable, Hashable {
    let id: String // entity id
    let roomSlug: String
    let founderPub: String
    let cardEventId: String
    let cardTitle: String
    let createdAtMs: Int

    var token: String { "\(roomSlug):\(founderPub):\(cardEventId)" }
}

enum PendingConsentLoader {
    static func list(forRoom roomSlug: String) async -> [PendingConsent] {
        var comps = URLComponents(
            url: EntityHTTP.baseURL.appendingPathComponent("api/entity/list"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "type", value: "studio_pending_consent")]
        guard let url = comps.url else { return [] }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            var out: [PendingConsent] = []
            for row in rows {
                let id = (row["id"] as? String) ?? (row["_id"] as? String) ?? ""
                guard !id.isEmpty else { continue }
                guard let attrsRaw = row["attributes"] as? String,
                      let attrs = (try? JSONSerialization.jsonObject(with: attrsRaw.data(using: .utf8) ?? Data())) as? [String: Any]
                else { continue }
                guard (attrs["room_slug"] as? String) == roomSlug else { continue }
                let entry = PendingConsent(
                    id: id,
                    roomSlug: roomSlug,
                    founderPub: (attrs["founder_pubkey"] as? String) ?? "",
                    cardEventId: (attrs["card_event_id"] as? String) ?? "",
                    cardTitle: (attrs["card_title"] as? String) ?? "(untitled)",
                    createdAtMs: (attrs["created_at_ms"] as? Int) ?? 0
                )
                if !entry.founderPub.isEmpty && !entry.cardEventId.isEmpty {
                    out.append(entry)
                }
            }
            out.sort { $0.createdAtMs < $1.createdAtMs }
            return out
        } catch {
            return []
        }
    }

    static func delete(_ prompt: PendingConsent) async {
        var comps = URLComponents(
            url: EntityHTTP.baseURL.appendingPathComponent("api/entity"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "id", value: prompt.id)]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
    }
}

// MARK: - Per-room override helpers

enum StudioAutoRunOverride: String {
    case on, off, defaultValue = "default"
}

enum StudioAutoRunOverrideStore {
    /// Read the current override from `studio:room:<slug>` attributes.
    static func read(roomSlug: String) async -> StudioAutoRunOverride {
        var comps = URLComponents(
            url: EntityHTTP.baseURL.appendingPathComponent("api/entity"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "name", value: "studio:room:\(roomSlug)")]
        guard let url = comps.url else { return .defaultValue }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .defaultValue
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let attrsRaw = (obj?["attributes"] as? String) ?? "{}"
            let attrs = ((try? JSONSerialization.jsonObject(with: attrsRaw.data(using: .utf8) ?? Data())) as? [String: Any]) ?? [:]
            let raw = (attrs["auto_run_override"] as? String) ?? "default"
            return StudioAutoRunOverride(rawValue: raw) ?? .defaultValue
        } catch {
            return .defaultValue
        }
    }

    /// Merge-and-write a new override value onto the room entity.
    static func write(roomSlug: String, override: StudioAutoRunOverride) async {
        // Get the entity id + existing attrs; PATCH a merged set.
        var comps = URLComponents(
            url: EntityHTTP.baseURL.appendingPathComponent("api/entity"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "name", value: "studio:room:\(roomSlug)")]
        guard let url = comps.url else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let id = (obj?["id"] as? String) ?? (obj?["_id"] as? String) ?? ""
            guard !id.isEmpty else { return }
            let attrsRaw = (obj?["attributes"] as? String) ?? "{}"
            var attrs = ((try? JSONSerialization.jsonObject(with: attrsRaw.data(using: .utf8) ?? Data())) as? [String: Any]) ?? [:]
            attrs["auto_run_override"] = override.rawValue
            await EntityHTTP.patchAttributes(id: id, attributes: attrs)
        } catch {
            return
        }
    }
}

// Full-tools override for auto-run workers in a specific room. When true,
// the plugin swaps the "no shell, no network" constraints paragraph in the
// prompt for a "you may use Bash/Write/network" one. Nothing else changes —
// there is no enforced sandbox, just a directive in the prompt text, so
// flipping this is a change to what we ASK the worker to do. Default false.
enum StudioFullToolsStore {
    static func read(roomSlug: String) async -> Bool {
        var comps = URLComponents(
            url: EntityHTTP.baseURL.appendingPathComponent("api/entity"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "name", value: "studio:room:\(roomSlug)")]
        guard let url = comps.url else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return false
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let attrsRaw = (obj?["attributes"] as? String) ?? "{}"
            let attrs = ((try? JSONSerialization.jsonObject(with: attrsRaw.data(using: .utf8) ?? Data())) as? [String: Any]) ?? [:]
            return (attrs["auto_run_full_tools"] as? Bool) ?? false
        } catch {
            return false
        }
    }

    static func write(roomSlug: String, fullTools: Bool) async {
        var comps = URLComponents(
            url: EntityHTTP.baseURL.appendingPathComponent("api/entity"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "name", value: "studio:room:\(roomSlug)")]
        guard let url = comps.url else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let id = (obj?["id"] as? String) ?? (obj?["_id"] as? String) ?? ""
            guard !id.isEmpty else { return }
            let attrsRaw = (obj?["attributes"] as? String) ?? "{}"
            var attrs = ((try? JSONSerialization.jsonObject(with: attrsRaw.data(using: .utf8) ?? Data())) as? [String: Any]) ?? [:]
            attrs["auto_run_full_tools"] = fullTools
            await EntityHTTP.patchAttributes(id: id, attributes: attrs)
        } catch {
            return
        }
    }
}
