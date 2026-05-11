import Combine
import Foundation
import GRDB

@MainActor
final class StudioStore: ObservableObject {
    // MARK: - Published state

    @Published private(set) var rooms: [StudioRoom] = []
    @Published private(set) var tracks: [String: [StudioTrack]] = [:]
    @Published private(set) var cardsByRoomTrack: [String: [StudioCard]] = [:]
    @Published private(set) var comments: [String: [StudioComment]] = [:]
    @Published private(set) var dispatchIntents: [String: [StudioDispatchIntent]] = [:]
    @Published private(set) var members: [String: StudioMember] = [:]
    @Published private(set) var optimisticCards: [String: StudioCard] = [:]
    @Published private(set) var optimisticComments: [String: StudioComment] = [:]

    // MARK: - Internals

    private var dbPool: DatabasePool?
    private var cancellables: [String: AnyDatabaseCancellable] = [:]

    init() {}

    func start(dbPool: DatabasePool) {
        if self.dbPool === dbPool, cancellables["rooms"] != nil { return }
        self.dbPool = dbPool
        if cancellables["rooms"] == nil {
            startRoomsObservation()
        }
        if cancellables["members"] == nil {
            startMembersObservation()
        }
    }

    func stop() {
        for (_, c) in cancellables { c.cancel() }
        cancellables.removeAll()
    }

    deinit {
        for (_, c) in cancellables { c.cancel() }
    }

    private func requirePool() -> DatabasePool {
        precondition(dbPool != nil, "StudioStore.start(dbPool:) must be called before use")
        return dbPool!
    }

    // MARK: - Rooms observation

    private func startRoomsObservation() {
        let observation = ValueObservation.tracking { db -> [StudioRoom] in
            let rows = try Row.fetchAll(db, sql: Self.SQL_ROOMS_ALL)
            return rows.compactMap { try? StudioRoom(row: $0) }
        }
        let cancellable = observation.start(
            in: requirePool(),
            scheduling: .async(onQueue: .main),
            onError: { error in
                NSLog("[StudioStore] rooms observation error: \(error)")
            },
            onChange: { [weak self] rooms in
                MainActor.assumeIsolated { self?.rooms = rooms }
            }
        )
        cancellables["rooms"] = cancellable
    }

    private func startMembersObservation() {
        let observation = ValueObservation.tracking { db -> [String: StudioMember] in
            let rows = try Row.fetchAll(db, sql: Self.SQL_MEMBERS_ALL)
            var out: [String: StudioMember] = [:]
            for row in rows {
                if let m = try? StudioMember(row: row) {
                    out[m.pubkeyHex] = m
                }
            }
            return out
        }
        cancellables["members"] = observation.start(
            in: requirePool(),
            scheduling: .async(onQueue: .main),
            onError: { error in NSLog("[StudioStore] members observation error: \(error)") },
            onChange: { [weak self] m in MainActor.assumeIsolated { self?.members = m } }
        )
    }

    // MARK: - Per-room observations (lifecycle)

    func openRoom(_ slug: String) {
        startTracksObservation(forRoom: slug)
        startCardsObservation(forRoom: slug)
        startCommentsObservation(forRoom: slug)
        if let room = rooms.first(where: { $0.slug == slug }), room.dispatchTraceOn {
            startDispatchIntentsObservation(forRoom: slug)
        }
    }

    func closeRoom(_ slug: String) {
        for key in ["tracks-\(slug)", "cards-\(slug)", "comments-\(slug)", "dispatch-\(slug)"] {
            cancellables[key]?.cancel()
            cancellables.removeValue(forKey: key)
        }
    }

    private func startTracksObservation(forRoom slug: String) {
        let observation = ValueObservation.tracking { db -> [StudioTrack] in
            try Row.fetchAll(db, sql: Self.SQL_TRACKS_IN_ROOM, arguments: [slug])
                .compactMap { try? StudioTrack(row: $0) }
        }
        cancellables["tracks-\(slug)"] = observation.start(
            in: requirePool(),
            scheduling: .async(onQueue: .main),
            onError: { error in NSLog("[StudioStore] tracks(\(slug)) error: \(error)") },
            onChange: { [weak self] ts in MainActor.assumeIsolated { self?.tracks[slug] = ts } }
        )
    }

    private func startCardsObservation(forRoom slug: String) {
        let observation = ValueObservation.tracking { db -> [StudioCard] in
            try Row.fetchAll(db, sql: Self.SQL_CARDS_IN_ROOM, arguments: [slug])
                .compactMap { try? StudioCard(row: $0) }
        }
        cancellables["cards-\(slug)"] = observation.start(
            in: requirePool(),
            scheduling: .async(onQueue: .main),
            onError: { error in NSLog("[StudioStore] cards(\(slug)) error: \(error)") },
            onChange: { [weak self] cards in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    var grouped: [String: [StudioCard]] = [:]
                    for c in cards {
                        let track = c.trackSlug.isEmpty ? "inbox" : c.trackSlug
                        grouped["\(slug)|\(track)", default: []].append(c)
                    }
                    var next = self.cardsByRoomTrack
                    for (k, _) in next where k.hasPrefix("\(slug)|") {
                        next.removeValue(forKey: k)
                    }
                    for (k, v) in grouped { next[k] = v }
                    self.cardsByRoomTrack = next
                    self.reconcileOptimisticAgainstReal(realCards: cards)
                }
            }
        )
    }

    private func startCommentsObservation(forRoom slug: String) {
        let observation = ValueObservation.tracking { db -> [StudioComment] in
            try Row.fetchAll(db, sql: Self.SQL_COMMENTS_IN_ROOM, arguments: [slug])
                .compactMap { try? StudioComment(row: $0) }
        }
        cancellables["comments-\(slug)"] = observation.start(
            in: requirePool(),
            scheduling: .async(onQueue: .main),
            onError: { error in NSLog("[StudioStore] comments(\(slug)) error: \(error)") },
            onChange: { [weak self] cs in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    var grouped: [String: [StudioComment]] = [:]
                    for c in cs {
                        guard let target = c.targetEventId else { continue }
                        grouped[target, default: []].append(c)
                    }
                    for (k, v) in grouped {
                        grouped[k] = v.sorted { $0.createdAtSeconds < $1.createdAtSeconds }
                    }
                    self.comments = grouped
                }
            }
        )
    }

    private func startDispatchIntentsObservation(forRoom slug: String) {
        let observation = ValueObservation.tracking { db -> [StudioDispatchIntent] in
            try Row.fetchAll(db, sql: Self.SQL_DISPATCH_IN_ROOM, arguments: [slug])
                .compactMap { try? StudioDispatchIntent(row: $0) }
        }
        cancellables["dispatch-\(slug)"] = observation.start(
            in: requirePool(),
            scheduling: .async(onQueue: .main),
            onError: { error in NSLog("[StudioStore] dispatch(\(slug)) error: \(error)") },
            onChange: { [weak self] xs in MainActor.assumeIsolated { self?.dispatchIntents[slug] = xs } }
        )
    }

    // MARK: - Accessors

    func cards(in room: String, track: String) -> [StudioCard] {
        cardsByRoomTrack["\(room)|\(track)"] ?? []
    }

    func comments(forCard eventId: String) -> [StudioComment] {
        comments[eventId] ?? []
    }

    func displayName(for pubkeyHex: String) -> String {
        members[pubkeyHex]?.displayName ?? Hex.npubShort(pubkeyHex)
    }

    func epochKey(room slug: String, epoch n: Int) -> Data? {
        rooms.first(where: { $0.slug == slug })?.epochKeys[n]
    }

    func lastActivityAt(track: StudioTrack, in roomSlug: String) -> Int64? {
        let cards = self.cards(in: roomSlug, track: track.name)
        return cards.map(\.createdAtSeconds).max()
    }

    func unreadCount(forRoom slug: String) -> Int {
        guard let room = rooms.first(where: { $0.slug == slug }) else { return 0 }
        let cutoffSec = (room.lastSeenAtMs ?? 0) / 1000
        var n = 0
        for key in cardsByRoomTrack.keys where key.hasPrefix("\(slug)|") {
            for c in cardsByRoomTrack[key] ?? [] where c.createdAtSeconds > cutoffSec {
                n += 1
            }
        }
        return n
    }

    // MARK: - Local-only mutations (T1)

    /// Write last_seen_at_ms = now() onto the room's local-only attribute.
    func markRoomSeen(_ slug: String) {
        guard let room = rooms.first(where: { $0.slug == slug }) else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        Task {
            await EntityHTTP.patchAttributes(
                id: room.id,
                attributes: ["last_seen_at_ms": nowMs]
            )
        }
    }

    /// Toggle the per-room dispatch-trace pseudo-tab.
    func setDispatchTraceOn(_ slug: String, _ on: Bool) {
        guard let room = rooms.first(where: { $0.slug == slug }) else { return }
        if on {
            startDispatchIntentsObservation(forRoom: slug)
        } else {
            cancellables["dispatch-\(slug)"]?.cancel()
            cancellables.removeValue(forKey: "dispatch-\(slug)")
        }
        Task {
            await EntityHTTP.patchAttributes(
                id: room.id,
                attributes: ["dispatch_trace_on": on]
            )
        }
    }

    // MARK: - Optimistic helpers (§15)

    func optimisticallyInsertCard(_ card: StudioCard, clientId: String) {
        optimisticCards[clientId] = card
    }

    func rollbackOptimisticCard(clientId: String) {
        optimisticCards.removeValue(forKey: clientId)
    }

    func optimisticallyInsertComment(_ comment: StudioComment, clientId: String) {
        optimisticComments[clientId] = comment
    }

    func rollbackOptimisticComment(clientId: String) {
        optimisticComments.removeValue(forKey: clientId)
    }

    private func reconcileOptimisticAgainstReal(realCards: [StudioCard]) {
        let realIds = Set(realCards.map(\.eventId))
        for (clientId, opt) in optimisticCards where !opt.eventId.isEmpty {
            if realIds.contains(opt.eventId) {
                optimisticCards.removeValue(forKey: clientId)
            }
        }
    }

    // MARK: - Mutation surface (T1 implements createRoom; T2-T4 fill the rest)

    func postCard(room: String, track: String, kind: String, title: String,
                  summary: String, blocks: [StudioBlock], tags: [String] = [],
                  relatedTo: [String]? = nil, dTag: String? = nil) async throws -> StudioCard {
        fatalError("implementer fills in per §8 + §15")
    }

    func postComment(targetEventId: String, body: String) async throws -> StudioComment {
        fatalError("implementer fills in per §8 + §15")
    }

    func attachImage(filePath: String, roomSlug: String, mimeType: String? = nil) async throws -> StudioImageBlock {
        fatalError("implementer fills in per §8")
    }

    /// T1: POST `/api/plugins/sonata-studio/room/create` per §8.1. Default tracks
    /// are sent as bare name strings (W1 R3); titles that differ from names are
    /// patched via follow-up `studio_track_create` calls.
    @discardableResult
    func createRoom(slug: String, title: String, description: String? = nil,
                    defaultTracks: [(name: String, title: String)] = []) async throws -> StudioRoom {
        let names = defaultTracks.map { $0.name }
        let req = StudioRoomCreateRequest(
            slug: slug,
            title: title,
            description: description,
            project: nil,
            defaultTracks: names.isEmpty ? nil : names
        )
        let response: StudioRoomCreateResponse = try await EntityHTTP.postPluginAction(
            path: "sonata-studio/room/create",
            body: req
        )

        // Follow-up track title patches for any track whose title != name.
        for t in defaultTracks where t.title != t.name && !t.title.isEmpty {
            let trackReq = StudioTrackCreateRequest(
                roomSlug: slug,
                name: t.name,
                title: t.title,
                layout: nil
            )
            _ = try? await EntityHTTP.postPluginActionVoid(
                path: "sonata-studio/track/create",
                body: trackReq
            )
        }

        // Best-effort: return a synthetic StudioRoom snapshot from the response.
        // ValueObservation will deliver the real row shortly.
        return StudioRoom.placeholder(
            id: "studio:room:\(slug)",
            slug: slug,
            title: title,
            description: description,
            createdByPubkey: "",
            createdAtSeconds: Int64(Date().timeIntervalSince1970),
            eventId: response.roomEventId,
            members: response.members,
            currentEpoch: response.epoch
        )
    }

    func joinRoom(inviteURL: String) async throws -> StudioRoom {
        fatalError("implementer fills in per §8")
    }

    /// Local-only delete. Removes the room entity + aud_id/epoch secrets and
    /// closes the SSE subscription. Does NOT publish a federated revocation —
    /// other members keep their copies of the room.
    func deleteRoom(slug: String) async throws {
        struct Req: Encodable { let slug: String }
        struct Resp: Decodable { let ok: Bool; let slug: String }
        do {
            let _: Resp = try await EntityHTTP.postPluginAction(
                path: "sonata-studio/room/delete",
                body: Req(slug: slug)
            )
        } catch {
            NSLog("[StudioStore] deleteRoom slug=\(slug) failed: \(error)")
            throw error
        }
        // ValueObservation re-fires on the entity delete; sidebar updates automatically.
    }

    // MARK: - SQL strings (cited in §3)

    nonisolated static let SQL_ROOMS_ALL = """
        SELECT id, name, description, attributes, createdAt, updatedAt
        FROM entities
        WHERE type = 'studio_room'
        ORDER BY updatedAt DESC
        """

    nonisolated static let SQL_TRACKS_IN_ROOM = """
        SELECT id, name, description, attributes
        FROM entities
        WHERE type = 'studio_track'
          AND json_extract(attributes, '$.room_slug') = ?
        ORDER BY json_extract(attributes, '$.name') ASC
        """

    nonisolated static let SQL_CARDS_IN_ROOM = """
        SELECT id, name, description, attributes
        FROM entities
        WHERE type = 'studio_card'
          AND json_extract(attributes, '$.room_slug') = ?
        ORDER BY json_extract(attributes, '$.created_at_seconds') DESC
        """

    nonisolated static let SQL_COMMENTS_IN_ROOM = """
        SELECT DISTINCT e.id, e.name, e.description, e.attributes
        FROM entities e
        WHERE e.type = 'studio_comment'
          AND json_extract(e.attributes, '$.room_slug') = ?
        ORDER BY json_extract(e.attributes, '$.created_at_seconds') ASC
        """

    nonisolated static let SQL_DISPATCH_IN_ROOM = """
        SELECT id, name, description, attributes
        FROM entities
        WHERE type = 'studio_dispatch_intent'
          AND json_extract(attributes, '$.room_slug') = ?
        ORDER BY json_extract(attributes, '$.created_at_ms') DESC
        """

    nonisolated static let SQL_MEMBERS_ALL = """
        SELECT id, name, description, attributes
        FROM entities
        WHERE type = 'studio_member'
        """
}

// MARK: - Plugin envelopes (§8.1)

struct StudioRoomCreateRequest: Encodable {
    let slug: String
    let title: String
    let description: String?
    let project: String?
    let defaultTracks: [String]?

    enum CodingKeys: String, CodingKey {
        case slug, title, description, project
        case defaultTracks = "default_tracks"
    }
}

struct StudioRoomCreateResponse: Decodable {
    let audienceAddress: String
    let roomEventId: String
    let declarationEventId: String
    let foundingGrantEventId: String
    let members: [String]
    let epoch: Int
    let defaultTracks: [String]

    enum CodingKeys: String, CodingKey {
        case audienceAddress = "audience_address"
        case roomEventId = "room_event_id"
        case declarationEventId = "declaration_event_id"
        case foundingGrantEventId = "founding_grant_event_id"
        case members, epoch
        case defaultTracks = "default_tracks"
    }
}

struct StudioTrackCreateRequest: Encodable {
    let roomSlug: String
    let name: String
    let title: String?
    let layout: String?

    enum CodingKeys: String, CodingKey {
        case roomSlug = "room_slug"
        case name, title, layout
    }
}

struct PluginErrorEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let code: String
        let message: String
    }
    let error: ErrorBody
}

/// Sonata's plugin proxy wraps every plugin success response as
/// `{ "ok": true, "result": <plugin-payload> }`. The renderer's typed
/// response structs decode `<plugin-payload>`; this envelope unwraps it.
struct PluginSuccessEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let result: T
}

struct StudioPluginError: LocalizedError {
    let status: Int
    let code: String
    let message: String
    var errorDescription: String? { message }
}

// MARK: - EntityHTTP

enum EntityHTTP {
    static let baseURL: URL = {
        let port = ProcessInfo.processInfo.environment["SONATA_PORT"] ?? "3211"
        return URL(string: "http://127.0.0.1:\(port)")!
    }()

    static func patchAttributes(id: String, attributes: [String: Any]) async {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/entity"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["id": id, "attributes": attributes]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            _ = try await URLSession.shared.data(for: req)
        } catch {
            NSLog("[EntityHTTP] patchAttributes(\(id)) failed: \(error)")
        }
    }

    /// POST a JSON body to `/api/plugins/<path>` and decode the response.
    static func postPluginAction<Req: Encodable, Res: Decodable>(
        path: String,
        body: Req
    ) async throws -> Res {
        let url = baseURL.appendingPathComponent("api/plugins/").appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        req.httpBody = try encoder.encode(body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw StudioPluginError(status: 0, code: "no_response", message: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(PluginErrorEnvelope.self, from: data) {
                throw StudioPluginError(
                    status: http.statusCode,
                    code: envelope.error.code,
                    message: envelope.error.message
                )
            }
            throw StudioPluginError(
                status: http.statusCode,
                code: "http_error",
                message: "Plugin returned HTTP \(http.statusCode)"
            )
        }
        // Sonata's plugin proxy wraps successful responses as
        // `{ "ok": true, "result": <plugin-payload> }`. Unwrap so callers
        // can declare typed structs that match the plugin's own response
        // shape (not the proxy envelope).
        let envelope = try JSONDecoder().decode(PluginSuccessEnvelope<Res>.self, from: data)
        return envelope.result
    }

    /// POST a JSON body where the response body is ignored (e.g. fire-and-forget patches).
    static func postPluginActionVoid<Req: Encodable>(
        path: String,
        body: Req
    ) async throws {
        let url = baseURL.appendingPathComponent("api/plugins/").appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        req.httpBody = try encoder.encode(body)
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StudioPluginError(status: 0, code: "http_error", message: "Plugin returned non-2xx")
        }
    }
}

// MARK: - StudioRoom synthesis helper

extension StudioRoom {
    /// Build a placeholder StudioRoom for return values where we don't yet
    /// have the full projected row (e.g. createRoom). ValueObservation will
    /// supersede this once the row lands.
    static func placeholder(
        id: String,
        slug: String,
        title: String,
        description: String?,
        createdByPubkey: String,
        createdAtSeconds: Int64,
        eventId: String,
        members: [String],
        currentEpoch: Int
    ) -> StudioRoom {
        let attrs: [String: Any] = [
            "slug": slug,
            "title": title,
            "description": description ?? NSNull(),
            "default_tracks": [],
            "created_by_pubkey": createdByPubkey,
            "created_at_seconds": createdAtSeconds,
            "event_id": eventId,
            "state": "active",
            "current_epoch": currentEpoch,
            "members": members,
        ]
        let attrJSON = (try? JSONSerialization.data(withJSONObject: attrs))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let row = Row(["id": id, "name": "studio:room:\(slug)", "attributes": attrJSON])
        return (try? StudioRoom(row: row))
            // Last-resort fallback — shouldn't be reachable since the JSON above is well-formed.
            ?? (try! StudioRoom(row: Row(["id": id, "attributes": "{}"])))
    }
}
