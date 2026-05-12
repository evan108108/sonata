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

    /// The local plugin pubkey — populated lazily the first time we see a
    /// projected card or comment in the local DB authored by us. Used as the
    /// `createdByPubkey` of optimistic synthetics so the author byline
    /// matches the real row when SSE reconciles. Empty until populated; an
    /// empty value just means optimistic rows show no author for the brief
    /// flicker before reconcile.
    @Published private(set) var currentPubkeyHex: String = ""

    // MARK: - Internals

    private var dbPool: DatabasePool?
    private var cancellables: [String: AnyDatabaseCancellable] = [:]

    /// One-per-tab image fetcher. Created on `start(dbPool:)` because the
    /// fetcher's epoch-key lookup needs the live pool. Held as `let?` so
    /// downstream views (`StudioRoomDetail`, `StudioCardDetailDrawer`) can
    /// pass it into `ImageBlockView` without rebuilding the actor.
    private(set) var imageFetcher: StudioImageFetcher?

    init() {}

    func start(dbPool: DatabasePool) {
        if self.dbPool === dbPool, cancellables["rooms"] != nil { return }
        self.dbPool = dbPool
        if imageFetcher == nil {
            imageFetcher = StudioImageFetcher(dbPool: dbPool)
        }
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
                    self.reconcileOptimisticCommentsAgainstReal(realComments: cs)
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

    /// Toggle the per-room dispatch-trace pseudo-tab. Starts/stops the
    /// `studio_dispatch_intent` observation for the room and patches the
    /// local-only `dispatch_trace_on` attribute on the `studio_room` entity.
    func setDispatchTraceOn(slug: String, _ on: Bool) async {
        guard let room = rooms.first(where: { $0.slug == slug }) else {
            NSLog("[StudioStore] setDispatchTraceOn: no room for slug \(slug)")
            return
        }
        if on {
            startDispatchIntentsObservation(forRoom: slug)
        } else {
            cancellables["dispatch-\(slug)"]?.cancel()
            cancellables.removeValue(forKey: "dispatch-\(slug)")
        }
        await EntityHTTP.patchAttributes(
            id: room.id,
            attributes: ["dispatch_trace_on": on]
        )
    }

    // MARK: - Optimistic helpers (§15)

    /// Low-level: insert a pre-built synthetic StudioCard. Most callers should
    /// use the parameterized overload below — it builds the synthetic for you.
    func optimisticallyInsertCard(_ card: StudioCard, clientId: String) {
        optimisticCards[clientId] = card
    }

    /// W6 surface: build + insert a synthetic StudioCard from compose params.
    /// `blocks` is the JSON-dict block payload exactly as it will be sent to
    /// the plugin (image blocks must already be the full StudioImageBlock
    /// shape with `type: "image"`). The card lands with `eventId=""` until
    /// the plugin POST returns and the caller invokes
    /// `setOptimisticEventId(clientId:eventId:)`.
    func optimisticallyInsertCard(
        clientId: String,
        roomSlug: String,
        trackSlug: String,
        kind: String,
        title: String,
        summary: String,
        blocks: [[String: Any]],
        tagsList: [String],
        relatedTo: [String]
    ) {
        let studioBlocks: [StudioBlock] = {
            guard !blocks.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: blocks),
                  let decoded = try? JSONDecoder().decode([StudioBlock].self, from: data)
            else { return [] }
            return decoded
        }()
        let now = Int64(Date().timeIntervalSince1970)
        let card = StudioCard(
            id: "studio:card:optimistic:\(clientId)",
            eventId: "",
            cardKind: kind,
            trackSlug: trackSlug,
            roomSlug: roomSlug,
            title: title,
            summary: summary,
            blocks: studioBlocks,
            relatedTo: relatedTo,
            tagsList: tagsList,
            createdByPubkey: currentPubkeyHex,
            createdAtSeconds: now,
            dTag: ""
        )
        optimisticCards[clientId] = card
    }

    /// Patch the eventId onto an outstanding optimistic card. Called after the
    /// plugin POST returns its `rumor_event_id`. Once this fires the existing
    /// content-match-by-eventId path in `reconcileOptimisticAgainstReal` will
    /// drop the optimistic once SSE delivers the real row.
    func setOptimisticEventId(clientId: String, eventId: String) {
        guard let old = optimisticCards[clientId] else { return }
        optimisticCards[clientId] = StudioCard(
            id: old.id,
            eventId: eventId,
            cardKind: old.cardKind,
            trackSlug: old.trackSlug,
            roomSlug: old.roomSlug,
            title: old.title,
            summary: old.summary,
            blocks: old.blocks,
            relatedTo: old.relatedTo,
            tagsList: old.tagsList,
            createdByPubkey: old.createdByPubkey,
            createdAtSeconds: old.createdAtSeconds,
            dTag: old.dTag
        )
    }

    func rollbackOptimisticCard(clientId: String) {
        optimisticCards.removeValue(forKey: clientId)
    }

    func optimisticallyInsertComment(_ comment: StudioComment, clientId: String) {
        optimisticComments[clientId] = comment
    }

    /// W6 surface: build + insert a synthetic StudioComment from compose
    /// params. Lands with `eventId=""` until `setOptimisticCommentEventId`
    /// patches it post-plugin.
    func optimisticallyInsertComment(
        clientId: String,
        roomSlug: String,
        targetEventId: String,
        body: String,
        intent: String?
    ) {
        let now = Int64(Date().timeIntervalSince1970)
        let comment = StudioComment(
            id: "studio:comment:optimistic:\(clientId)",
            eventId: "",
            targetRef: targetEventId,
            targetEventId: targetEventId,
            body: body,
            intent: intent,
            createdByPubkey: currentPubkeyHex,
            roomSlug: roomSlug,
            createdAtSeconds: now
        )
        optimisticComments[clientId] = comment
    }

    func setOptimisticCommentEventId(clientId: String, eventId: String) {
        guard let old = optimisticComments[clientId] else { return }
        optimisticComments[clientId] = StudioComment(
            id: old.id,
            eventId: eventId,
            targetRef: old.targetRef,
            targetEventId: old.targetEventId,
            body: old.body,
            intent: old.intent,
            createdByPubkey: old.createdByPubkey,
            roomSlug: old.roomSlug,
            createdAtSeconds: old.createdAtSeconds
        )
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

    /// Symmetric reconcile for comments — drop optimistic entries whose
    /// `eventId` matches a real projected comment. Called from the comments
    /// ValueObservation onChange.
    private func reconcileOptimisticCommentsAgainstReal(realComments: [StudioComment]) {
        let realIds = Set(realComments.map(\.eventId))
        for (clientId, opt) in optimisticComments where !opt.eventId.isEmpty {
            if realIds.contains(opt.eventId) {
                optimisticComments.removeValue(forKey: clientId)
            }
        }
    }

    // MARK: - Mutation surface (T4: postCard, postComment, attachImage)

    /// Post a card via the plugin. Returns the rumor `event_id` so the caller
    /// can patch the matching optimistic entry. `blocks` is the JSON-dict
    /// shape exactly as the plugin's `studio_card_post` expects — image
    /// blocks must already be the full StudioImageBlock dict with
    /// `type: "image"`. Throws `StudioPluginError` on 4xx/5xx.
    func postCard(
        room: String,
        track: String,
        kind: String,
        title: String,
        summary: String,
        blocks: [[String: Any]],
        relatedTo: [String],
        tagsList: [String],
        dTag: String?
    ) async throws -> String {
        var body: [String: Any] = [
            "room": room,
            "track": track,
            "kind": kind,
            "title": title,
            "summary": summary,
        ]
        if !blocks.isEmpty { body["blocks"] = blocks }
        if !relatedTo.isEmpty { body["related_to"] = relatedTo }
        if !tagsList.isEmpty { body["tags"] = tagsList }
        if let d = dTag, !d.isEmpty { body["d_tag"] = d }

        let result: CardPostResponse = try await EntityHTTP.postPluginActionRaw(
            path: "sonata-studio/card/post",
            body: body
        )
        rememberCurrentPubkey(from: result)
        return result.rumorEventId
    }

    /// Post a comment via the plugin. Returns the rumor `event_id`.
    func postComment(
        room: String,
        targetEventId: String,
        body bodyText: String,
        intent: String?
    ) async throws -> String {
        var body: [String: Any] = [
            "room": room,
            "target": targetEventId,
            "body": bodyText,
        ]
        if let i = intent, !i.isEmpty { body["intent"] = i }

        let result: CommentPostResponse = try await EntityHTTP.postPluginActionRaw(
            path: "sonata-studio/comment/post",
            body: body
        )
        return result.rumorEventId
    }

    /// Encrypt + upload an image via the plugin's Blossom path. Returns the
    /// full image-block dict with `type: "image"` prepended — ready to drop
    /// straight into a card's blocks[] payload.
    func attachImage(
        filePath: String,
        roomSlug: String,
        mimeType: String?
    ) async throws -> [String: Any] {
        var body: [String: Any] = [
            "file_path": filePath,
            "room_slug": roomSlug,
        ]
        if let m = mimeType, !m.isEmpty { body["mime_type"] = m }

        let raw: [String: Any] = try await EntityHTTP.postPluginActionRawDict(
            path: "sonata-studio/image/attach",
            body: body
        )
        var block = raw
        block["type"] = "image"
        return block
    }

    /// First-card-we-see heuristic: when the plugin returns a `rumor_event_id`
    /// for a card we just posted, the upcoming SSE row will carry the same
    /// `created_by_pubkey` — but we'd like the optimistic synthetic to have
    /// that pubkey too, so the byline matches during the reconcile flicker.
    /// `currentPubkeyHex` is also patched on the first SSE-projected card we
    /// authored ourselves; this method handles the explicit-post path.
    private func rememberCurrentPubkey(from response: CardPostResponse) {
        // The plugin POST response doesn't carry pubkey directly, but the
        // earliest projected card from our post will. Hooking that here would
        // require an inflight-clientId → expected-pubkey channel; instead
        // we let the cards observation fill currentPubkeyHex when it sees
        // a card with eventId matching one of our optimistic entries.
        _ = response
        learnCurrentPubkeyFromOptimisticMatch()
    }

    /// Sweep optimistic cards: for any card whose eventId is now present in
    /// the real cards table, copy its createdByPubkey forward so future
    /// optimistic rows render with the correct byline.
    private func learnCurrentPubkeyFromOptimisticMatch() {
        guard currentPubkeyHex.isEmpty else { return }
        for (_, opt) in optimisticCards where !opt.eventId.isEmpty {
            for cards in cardsByRoomTrack.values {
                if let real = cards.first(where: { $0.eventId == opt.eventId }),
                   !real.createdByPubkey.isEmpty {
                    currentPubkeyHex = real.createdByPubkey
                    return
                }
            }
        }
    }

    /// T1: POST `/api/plugins/sonata-studio/room/create` per §8.1. Default tracks
    /// are sent as `{name, title}` objects so the plugin can stamp the user-typed
    /// title on the first publish (no follow-up patch loop required).
    @discardableResult
    func createRoom(slug: String, title: String, description: String? = nil,
                    defaultTracks: [(name: String, title: String)] = []) async throws -> StudioRoom {
        let tracks = defaultTracks.map { StudioDefaultTrack(name: $0.name, title: $0.title) }
        let req = StudioRoomCreateRequest(
            slug: slug,
            title: title,
            description: description,
            project: nil,
            defaultTracks: tracks.isEmpty ? nil : tracks
        )
        let response: StudioRoomCreateResponse = try await EntityHTTP.postPluginAction(
            path: "sonata-studio/room/create",
            body: req
        )

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
    let defaultTracks: [StudioDefaultTrack]?

    enum CodingKeys: String, CodingKey {
        case slug, title, description, project
        case defaultTracks = "default_tracks"
    }
}

struct StudioDefaultTrack: Encodable {
    let name: String
    let title: String
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

struct CardPostResponse: Decodable {
    let rumorEventId: String
    let audienceAddress: String
    let dTag: String

    enum CodingKeys: String, CodingKey {
        case rumorEventId = "rumor_event_id"
        case audienceAddress = "audience_address"
        case dTag = "d_tag"
    }
}

struct CommentPostResponse: Decodable {
    let rumorEventId: String
    let dTag: String

    enum CodingKeys: String, CodingKey {
        case rumorEventId = "rumor_event_id"
        case dTag = "d_tag"
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

    /// POST a `[String: Any]` body to a plugin route. Encodes via
    /// JSONSerialization so callers can ship payloads that contain nested
    /// `[String: Any]` dicts (e.g. image blocks) without forcing every
    /// nested type to conform to Encodable. The response is decoded the
    /// same way `postPluginAction` does: unwrap `{ok, result}`.
    static func postPluginActionRaw<Res: Decodable>(
        path: String,
        body: [String: Any]
    ) async throws -> Res {
        let url = baseURL.appendingPathComponent("api/plugins/").appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

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
        let envelope = try JSONDecoder().decode(PluginSuccessEnvelope<Res>.self, from: data)
        return envelope.result
    }

    /// Same as `postPluginActionRaw` but returns the inner `result` field as
    /// `[String: Any]` rather than a typed Decodable. Used by image attach
    /// where the result shape is forwarded verbatim into a card's block.
    static func postPluginActionRawDict(
        path: String,
        body: [String: Any]
    ) async throws -> [String: Any] {
        let url = baseURL.appendingPathComponent("api/plugins/").appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

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
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = parsed["result"] as? [String: Any] else {
            throw StudioPluginError(
                status: http.statusCode,
                code: "decode_error",
                message: "Plugin response missing `result` object"
            )
        }
        return result
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
