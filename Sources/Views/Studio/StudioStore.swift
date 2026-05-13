import Combine
import CoreGraphics
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
    /// Cross-room members keyed by pubkey hex (auto-stubbed by `ensureMember`
    /// in the projector, optional local nickname set via studio_member_set_nickname).
    /// Fallback only — federated per-room nicknames live in `roomMembers`.
    @Published private(set) var members: [String: StudioMember] = [:]
    /// Per-room members keyed by `"<roomSlug>|<pubkey>"`. Populated by the
    /// projector when it sees a `_profile` card — see plugin
    /// `projection/card.ts` upsertRoomMember(). Used by `displayName(for:in:)`
    /// as the primary source for member nicknames.
    @Published private(set) var roomMembers: [String: StudioMember] = [:]
    /// Local-only default nickname (the machine's "who am I"). Federated to
    /// each room via auto-publish of a `_profile` card. Empty until the user
    /// sets one in Settings → Studio.
    @Published private(set) var defaultNickname: String = ""
    /// Local-only filesystem path to the user's default avatar source image.
    /// Stored as a path (not encrypted-to-self bytes) for simplicity; the path
    /// is re-uploaded via `imageAttach` against each room's epoch at publish
    /// time. Empty/nil until the user picks one in Settings → Studio.
    /// Lives under `~/Library/Application Support/Sonata/avatars/` so the
    /// compose sheet's `~/Library/Caches/com.sonata` defer-cleanup doesn't
    /// reap it.
    @Published private(set) var defaultAvatarLocalPath: String? = nil
    @Published private(set) var optimisticCards: [String: StudioCard] = [:]
    @Published private(set) var optimisticComments: [String: StudioComment] = [:]
    /// Card eventIds the local user just asked to delete. Drives an instant
    /// fade from the published `cards` list while we wait for SSE to deliver
    /// the new `status: "deleted"` rumor and the projector to overwrite the
    /// entity body. Cleared either by SSE reconcile (the projected card is
    /// already filtered out as `isDeleted`) or by `rollbackOptimisticDelete`
    /// on POST failure.
    @Published private(set) var optimisticDeletes: Set<String> = []
    /// Edit-mode optimistic patches, keyed by entity id (stable across the
    /// kind-30530 republish). The values are the user-visible card with the
    /// new fields applied; the `cards(in:track:)` accessor merges these on
    /// top of the projected baseline so the UI updates instantly. Reconcile
    /// drops entries once the SSE-delivered rumor (with a matching expected
    /// event id) overwrites the entity body — see
    /// `reconcileOptimisticUpdates(realCards:)`.
    @Published private(set) var optimisticCardUpdates: [String: StudioCard] = [:]
    /// Tracks the rumor `event_id` we expect the next SSE projection to
    /// carry for each in-flight optimistic update. Populated once the
    /// plugin POST returns. Cleared together with the optimistic entry.
    private var optimisticUpdateExpectedEventIds: [String: String] = [:]

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
        if cancellables["user_profile"] == nil {
            startUserProfileObservation()
        }
        // Learn our own pubkey eagerly so author-only UI (Delete/Edit) is
        // gated correctly on cards posted before this Sonata launch.
        if currentPubkeyHex.isEmpty {
            Task { @MainActor in await learnCurrentPubkeyFromPlugin() }
        }
    }

    private func learnCurrentPubkeyFromPlugin() async {
        struct IdentityResponse: Decodable { let pubkey: String }
        // Retry with backoff — plugin may not have finished registering the
        // identity endpoint at the moment Sonata launches.
        let delays: [UInt64] = [0, 1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000]
        for (attempt, delay) in delays.enumerated() {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            do {
                let result: IdentityResponse = try await EntityHTTP.getPluginAction(
                    path: "sonata-studio/identity"
                )
                let hex = result.pubkey.lowercased()
                if !hex.isEmpty, currentPubkeyHex.isEmpty {
                    currentPubkeyHex = hex
                }
                return
            } catch {
                NSLog("[StudioStore] learnCurrentPubkeyFromPlugin attempt \(attempt + 1) failed: \(error)")
            }
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
                MainActor.assumeIsolated {
                    self?.rooms = rooms
                    self?.processDeferredProfilesOnRoomChange()
                }
            }
        )
        cancellables["rooms"] = cancellable
    }

    private func startMembersObservation() {
        let observation = ValueObservation.tracking { db -> (cross: [String: StudioMember], perRoom: [String: StudioMember]) in
            let rows = try Row.fetchAll(db, sql: Self.SQL_MEMBERS_ALL)
            var cross: [String: StudioMember] = [:]
            var perRoom: [String: StudioMember] = [:]
            for row in rows {
                guard let m = try? StudioMember(row: row) else { continue }
                // Per-room entities are named `studio:member:<room>:<pubkey>`
                // and carry a non-empty `room_slug` attribute. Cross-room
                // entities are named `studio:member:<pubkey>` (no room_slug)
                // and are the legacy ensureMember() shape.
                if !m.roomSlug.isEmpty {
                    perRoom["\(m.roomSlug)|\(m.pubkeyHex)"] = m
                } else {
                    cross[m.pubkeyHex] = m
                }
            }
            return (cross, perRoom)
        }
        cancellables["members"] = observation.start(
            in: requirePool(),
            scheduling: .async(onQueue: .main),
            onError: { error in NSLog("[StudioStore] members observation error: \(error)") },
            onChange: { [weak self] grouped in
                MainActor.assumeIsolated {
                    self?.members = grouped.cross
                    self?.roomMembers = grouped.perRoom
                }
            }
        )
    }

    private func startUserProfileObservation() {
        let observation = ValueObservation.tracking { db -> (nickname: String, avatarPath: String?, roomAvatarPaths: [String: String]) in
            let rows = try Row.fetchAll(db, sql: Self.SQL_USER_PROFILE)
            for row in rows {
                let attrsRaw = (row["attributes"] as String?) ?? "{}"
                let raw = ((try? JSONSerialization.jsonObject(with: attrsRaw.data(using: .utf8) ?? Data())) as? [String: Any]) ?? [:]
                let nick = (raw["default_nickname"] as? String) ?? ""
                let path = raw["default_avatar_local_path"] as? String
                let normalized = (path?.isEmpty ?? true) ? nil : path
                let roomPaths = (raw["room_avatar_paths"] as? [String: String]) ?? [:]
                return (nick, normalized, roomPaths)
            }
            return ("", nil, [:])
        }
        cancellables["user_profile"] = observation.start(
            in: requirePool(),
            scheduling: .async(onQueue: .main),
            onError: { error in NSLog("[StudioStore] user_profile observation error: \(error)") },
            onChange: { [weak self] tuple in
                MainActor.assumeIsolated {
                    self?.defaultNickname = tuple.nickname
                    self?.defaultAvatarLocalPath = tuple.avatarPath
                    self?.roomAvatarLocalPaths = tuple.roomAvatarPaths
                }
            }
        )
    }

    /// Per-room custom avatar source paths, keyed by room slug. Populated
    /// when the user picks "New for this room" with a custom avatar; the
    /// picker reads this back on next open to pre-populate the preview.
    @Published private(set) var roomAvatarLocalPaths: [String: String] = [:]

    /// Convenience accessor for the per-room custom avatar local path. Returns
    /// nil if the user has not chosen a room-specific avatar (or chose then
    /// reverted to default).
    func roomAvatarLocalPath(for roomSlug: String) -> String? {
        let p = roomAvatarLocalPaths[roomSlug]
        return (p?.isEmpty ?? true) ? nil : p
    }

    /// Return the current per-room nickname for the local user, if any. Used
    /// by the per-room editor sheet to pre-populate; falls back to the
    /// default nickname (which may also be empty).
    func currentRoomNickname(for roomSlug: String) -> String {
        let me = currentPubkeyHex.lowercased()
        if !me.isEmpty,
           let m = roomMembers["\(roomSlug)|\(me)"],
           let n = m.nickname, !n.isEmpty {
            return n
        }
        return defaultNickname
    }

    /// Publish or replace this user's `_profile` card in `roomSlug`. The
    /// d_tag is the deterministic `profile:<lowercase-pubkey>` so re-posts
    /// overwrite the prior rumor everywhere it's been delivered. Throws
    /// `StudioPluginError` on plugin failure. The card itself is filtered
    /// out of the UI (see `isReservedCardKind`); its only effect is the
    /// projector's `studio_member` upsert.
    ///
    /// When `avatarLocalPath` is non-nil and the file exists, the image is
    /// uploaded via `attachImage` (encrypted against the room's epoch) and
    /// the returned block is included in the card's `blocks[]`. Republishing
    /// without an avatar clears it (projector treats missing block as nil).
    @discardableResult
    func publishProfileCard(
        roomSlug: String,
        nickname: String,
        avatarLocalPath: String? = nil
    ) async throws -> String {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StudioPluginError(
                status: 400,
                code: "empty_nickname",
                message: "Nickname must not be empty."
            )
        }
        let me = currentPubkeyHex.lowercased()
        guard !me.isEmpty else {
            throw StudioPluginError(
                status: 412,
                code: "identity_unknown",
                message: "Sonata hasn't learned its own pubkey from the plugin yet."
            )
        }

        var blocks: [[String: Any]] = []
        if let path = avatarLocalPath,
           !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            do {
                let block = try await attachImage(
                    filePath: path,
                    roomSlug: roomSlug,
                    mimeType: "image/jpeg"
                )
                blocks.append(block)
            } catch {
                // Avatar upload failure shouldn't drop the nickname republish —
                // log it and continue with a blocks-less card. The user can
                // retry the avatar from Settings or the room picker.
                NSLog("[StudioStore] publishProfileCard avatar upload failed room=\(roomSlug): \(error)")
            }
        }

        // The renderer's existing `postCard` already wraps the plugin call.
        // We pin the d_tag to `profile:<pub>` so this card is replaceable
        // per-author per-room.
        return try await postCard(
            room: roomSlug,
            track: "inbox",
            kind: "_profile",
            title: trimmed,
            body: "(profile card — nickname carrier; hidden from the card list)",
            blocks: blocks,
            relatedTo: [],
            tagsList: [],
            dTag: "profile:\(me)"
        )
    }

    /// Fire-and-forget auto-publish hook called from card-post / room-join
    /// paths. No-op if defaultNickname is empty OR if this user already has
    /// a `_profile` card in the room. Errors are logged, not surfaced — the
    /// user's primary action shouldn't fail because the side-channel hiccuped.
    /// If `defaultAvatarLocalPath` is set, the avatar is included too.
    func autoPublishProfileIfNeeded(roomSlug: String) {
        let nickname = defaultNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nickname.isEmpty else { return }
        let me = currentPubkeyHex.lowercased()
        guard !me.isEmpty else { return }
        // Already federated — don't republish on every post.
        if let existing = roomMembers["\(roomSlug)|\(me)"],
           let n = existing.nickname, !n.isEmpty {
            return
        }
        let avatarPath = defaultAvatarLocalPath
        Task { @MainActor in
            do {
                _ = try await publishProfileCard(
                    roomSlug: roomSlug,
                    nickname: nickname,
                    avatarLocalPath: avatarPath
                )
            } catch {
                NSLog("[StudioStore] autoPublishProfile(\(roomSlug)) failed: \(error)")
            }
        }
    }

    /// Persist the machine-local default nickname into the
    /// `studio:user_profile` singleton entity. Triggers the observation above,
    /// which republishes `defaultNickname`. The value is never federated by
    /// itself — `auto-publish on first post / on join` is what carries it
    /// onto the wire as a `_profile` card per room.
    func setDefaultNickname(_ nickname: String) async {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        var attrs: [String: Any] = [
            "default_nickname": trimmed,
            "room_avatar_paths": roomAvatarLocalPaths,
        ]
        if let path = defaultAvatarLocalPath, !path.isEmpty {
            attrs["default_avatar_local_path"] = path
        }
        await EntityHTTP.upsertEntity(
            name: "studio:user_profile",
            type: "studio_user_profile",
            description: "Local default profile (machine-only, not federated directly)",
            attributes: attrs
        )
    }

    /// Persist the machine-local default avatar source path. Pass nil/empty
    /// to clear. The path is stored verbatim; the observation re-publishes
    /// `defaultAvatarLocalPath` so the Settings preview and any open picker
    /// sheets update. The avatar is re-encrypted and uploaded per-room at
    /// publish time (see `publishProfileCard`).
    func setDefaultAvatarLocalPath(_ path: String?) async {
        let cleaned = (path?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) ? "" : path!
        // Carry forward the nickname + per-room map so we don't blow them
        // away when the user only changes the default avatar.
        let attrs: [String: Any] = [
            "default_nickname": defaultNickname,
            "default_avatar_local_path": cleaned,
            "room_avatar_paths": roomAvatarLocalPaths,
        ]
        await EntityHTTP.upsertEntity(
            name: "studio:user_profile",
            type: "studio_user_profile",
            description: "Local default profile (machine-only, not federated directly)",
            attributes: attrs
        )
    }

    /// Persist a per-room custom avatar source path. Pass nil to clear the
    /// entry for that room (reverts to "use default" semantics for the
    /// picker's preview; the federated card itself isn't touched here —
    /// callers republish via `publishProfileCard` if they want the room's
    /// avatar to actually change).
    func setRoomAvatarLocalPath(roomSlug: String, path: String?) async {
        var map = roomAvatarLocalPaths
        let trimmed = path?.trimmingCharacters(in: .whitespaces)
        if let p = trimmed, !p.isEmpty {
            map[roomSlug] = p
        } else {
            map.removeValue(forKey: roomSlug)
        }
        let attrs: [String: Any] = [
            "default_nickname": defaultNickname,
            "default_avatar_local_path": defaultAvatarLocalPath ?? "",
            "room_avatar_paths": map,
        ]
        await EntityHTTP.upsertEntity(
            name: "studio:user_profile",
            type: "studio_user_profile",
            description: "Local default profile (machine-only, not federated directly)",
            attributes: attrs
        )
    }

    /// Queue a profile publish to fire when `roomSlug` transitions out of
    /// `pending-grant` into `active`. Used by the profile-picker sheet when
    /// the user joins a room that requires founder admit — we can't publish
    /// a `_profile` card until we have the room epoch key, but we want to
    /// honor the user's choice once that key arrives.
    ///
    /// At most one deferred entry per room: a second call overwrites the
    /// first (last-write-wins, mirroring how `_profile` itself replaces).
    func deferProfilePublish(roomSlug: String, nickname: String, avatarLocalPath: String?) {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deferredProfilePublishes.removeValue(forKey: roomSlug)
            return
        }
        deferredProfilePublishes[roomSlug] = DeferredProfile(
            nickname: trimmed,
            avatarLocalPath: avatarLocalPath
        )
        // Best-effort opportunistic flush: if the room is already active by
        // the time we got here (race between picker open and SSE state flip)
        // we don't need to wait for the next ValueObservation cycle.
        flushDeferredProfileIfActive(slug: roomSlug)
    }

    private struct DeferredProfile {
        let nickname: String
        let avatarLocalPath: String?
    }
    private var deferredProfilePublishes: [String: DeferredProfile] = [:]

    private func flushDeferredProfileIfActive(slug: String) {
        guard let deferred = deferredProfilePublishes[slug] else { return }
        guard let room = rooms.first(where: { $0.slug == slug }), room.state == "active" else {
            return
        }
        deferredProfilePublishes.removeValue(forKey: slug)
        Task { @MainActor in
            do {
                _ = try await publishProfileCard(
                    roomSlug: slug,
                    nickname: deferred.nickname,
                    avatarLocalPath: deferred.avatarLocalPath
                )
            } catch {
                NSLog("[StudioStore] deferred publishProfileCard(\(slug)) failed: \(error)")
            }
        }
    }

    /// Hook called from the rooms ValueObservation onChange: scan deferred
    /// entries and flush any whose room is now active. Kept on the main
    /// actor since both the deferred map and `rooms` are main-isolated.
    private func processDeferredProfilesOnRoomChange() {
        for slug in Array(deferredProfilePublishes.keys) {
            flushDeferredProfileIfActive(slug: slug)
        }
    }

    /// Resolve the per-room avatar `image` block for `pubkeyHex` in
    /// `roomSlug`, fetch + decrypt via the shared `StudioImageFetcher`, and
    /// return the decoded CGImage. Returns nil for missing avatars, missing
    /// fetchers, or any decode/fetch failure (caller shows a placeholder).
    func avatarImage(for pubkeyHex: String, in roomSlug: String) async -> CGImage? {
        let lower = pubkeyHex.lowercased()
        guard let member = roomMembers["\(roomSlug)|\(lower)"],
              let block = member.avatarImageBlock,
              let fetcher = imageFetcher else {
            return nil
        }
        do {
            return try await fetcher.image(
                for: block,
                room: roomSlug,
                authorPubHex: lower
            )
        } catch {
            return nil
        }
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
                    for c in cards where !c.isDeleted && !Self.isReservedCardKind(c.cardKind) {
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
                    self.reconcileOptimisticDeletes(realCards: cards)
                    self.reconcileOptimisticUpdates(realCards: cards)
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
        let raw = cardsByRoomTrack["\(room)|\(track)"] ?? []
        var byId: [String: StudioCard] = [:]
        for c in raw { byId[c.id] = c }

        // Apply edit-mode optimistic patches. If the patched copy now lives
        // in a different track, it should disappear from this track (the
        // other-track call will pull it in via the same merge).
        if !optimisticCardUpdates.isEmpty {
            for (id, opt) in optimisticCardUpdates where opt.roomSlug == room {
                if opt.trackSlug == track {
                    byId[id] = opt
                } else if byId[id] != nil {
                    byId.removeValue(forKey: id)
                }
            }
            // A patched card may have moved INTO this track from elsewhere —
            // include it even if the projector hasn't seen it yet.
            for (id, opt) in optimisticCardUpdates
            where opt.roomSlug == room && opt.trackSlug == track && byId[id] == nil {
                byId[id] = opt
            }
        }

        var out = Array(byId.values)
        if !optimisticDeletes.isEmpty {
            out = out.filter { !optimisticDeletes.contains($0.eventId) }
        }
        out.sort { $0.createdAtSeconds > $1.createdAtSeconds }
        return out
    }

    func comments(forCard eventId: String) -> [StudioComment] {
        comments[eventId] ?? []
    }

    /// Reserved-kind detector. Any cardKind starting with `_` is hidden
    /// metadata; the projector still writes the row but the UI never lists
    /// it. Mirrors plugin `projection/card.ts` §"Reserved card kinds".
    nonisolated static func isReservedCardKind(_ kind: String?) -> Bool {
        guard let kind = kind, !kind.isEmpty else { return false }
        return kind.hasPrefix("_")
    }

    /// Resolve the display name for `pubkeyHex` in (optional) `roomSlug`.
    /// Order: per-room federated nickname → local cross-room nickname
    /// (studio_member_set_nickname) → defaultNickname (only if pubkey ==
    /// self, so I see my own name before my _profile card lands) → short hex.
    func displayName(for pubkeyHex: String, in roomSlug: String? = nil) -> String {
        let lower = pubkeyHex.lowercased()
        if let room = roomSlug, !room.isEmpty,
           let perRoom = roomMembers["\(room)|\(lower)"],
           let nick = perRoom.nickname, !nick.isEmpty {
            return nick
        }
        if let cross = members[lower], let nick = cross.nickname, !nick.isEmpty {
            return nick
        }
        if !defaultNickname.isEmpty, lower == currentPubkeyHex.lowercased() {
            return defaultNickname
        }
        return Hex.npubShort(lower)
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
                if optimisticDeletes.contains(c.eventId) { continue }
                n += 1
            }
        }
        return n
    }

    // MARK: - Soft-delete (author-only)

    /// Republish the card as `status: "deleted"` via the plugin. The local
    /// card optimistically vanishes from `cards(in:track:)`; SSE will deliver
    /// the new rumor a moment later and projection overwrites the entity body
    /// with `isDeleted == true`, at which point reconcile clears the
    /// optimistic flag (the real row is now filtered too).
    ///
    /// Throws `StudioPluginError` on 404 (card_not_found) or 403 (not_author).
    func deleteCard(roomSlug: String, dTag: String, eventId: String) async throws {
        if !eventId.isEmpty {
            optimisticDeletes.insert(eventId)
        }
        struct Req: Encodable {
            let room: String
            let dTag: String
            enum CodingKeys: String, CodingKey { case room; case dTag = "d_tag" }
        }
        struct Resp: Decodable {
            let rumorEventId: String
            let dTag: String
            enum CodingKeys: String, CodingKey {
                case rumorEventId = "rumor_event_id"
                case dTag = "d_tag"
            }
        }
        do {
            let _: Resp = try await EntityHTTP.postPluginAction(
                path: "sonata-studio/card/delete",
                body: Req(room: roomSlug, dTag: dTag)
            )
        } catch {
            if !eventId.isEmpty {
                optimisticDeletes.remove(eventId)
            }
            throw error
        }
    }

    // MARK: - Author-only edit

    /// Republish the card as kind-30530 with merged fields. Any `nil` argument
    /// means "preserve the existing value"; non-nil overrides. Mirrors the
    /// plugin's `card.update` body contract.
    ///
    /// Optimistic update: an immediate patch lands in `optimisticCardUpdates`
    /// so the UI reflects the edit before the SSE round trip. On success the
    /// expected new `event_id` is stamped; once the projector overwrites the
    /// entity with that id, reconcile drops the patch. On failure, the patch
    /// is rolled back and the original card resurfaces.
    ///
    /// Returns the new rumor `event_id`. Throws `StudioPluginError` on
    /// 404 (card_not_found), 403 (not_author), or other plugin errors.
    @discardableResult
    func updateCard(
        roomSlug: String,
        dTag: String,
        eventId: String,
        track: String? = nil,
        kind: String? = nil,
        title: String? = nil,
        body: String? = nil,
        blocks: [[String: Any]]? = nil,
        tagsList: [String]? = nil,
        relatedTo: [String]? = nil,
        assigneePubkey: String?? = nil
    ) async throws -> String {
        guard let original = findCard(roomSlug: roomSlug, dTag: dTag, eventId: eventId) else {
            throw StudioPluginError(
                status: 404,
                code: "card_not_found",
                message: "no local card \(dTag) in room \(roomSlug)"
            )
        }

        let patched = patchCard(
            original: original,
            track: track,
            kind: kind,
            title: title,
            body: body,
            blocksRaw: blocks,
            tagsList: tagsList,
            relatedTo: relatedTo
        )
        optimisticCardUpdates[original.id] = patched

        var requestBody: [String: Any] = ["room": roomSlug, "d_tag": dTag]
        if let t = track { requestBody["track"] = t }
        if let k = kind { requestBody["kind"] = k }
        if let t = title { requestBody["title"] = t }
        if let b = body {
            requestBody["body"] = b
            // Legacy wire alias — kept in the encoded JSON for one cutover
            // release so an unmigrated plugin still finds the prose. Remove
            // after 2026-05-12 + one release.
            requestBody["summary"] = b
        }
        if let b = blocks { requestBody["blocks"] = b }
        if let r = relatedTo { requestBody["related_to"] = r }
        if let t = tagsList { requestBody["tags"] = t }
        if let outer = assigneePubkey {
            // Double-optional convention: outer .some means "caller asked to
            // change the assignment"; the inner Optional carries the new
            // value (nil → unassign). Outer .none means "preserve existing."
            if let pk = outer, !pk.isEmpty {
                requestBody["assignees"] = [pk.lowercased()]
            } else {
                requestBody["assignees"] = [] as [String]
            }
        }

        do {
            struct Resp: Decodable {
                let rumorEventId: String
                let dTag: String
                enum CodingKeys: String, CodingKey {
                    case rumorEventId = "rumor_event_id"
                    case dTag = "d_tag"
                }
            }
            let result: Resp = try await EntityHTTP.postPluginActionRaw(
                path: "sonata-studio/card/update",
                body: requestBody
            )
            optimisticUpdateExpectedEventIds[original.id] = result.rumorEventId
            return result.rumorEventId
        } catch {
            optimisticCardUpdates.removeValue(forKey: original.id)
            optimisticUpdateExpectedEventIds.removeValue(forKey: original.id)
            throw error
        }
    }

    // MARK: - Lifecycle transitions + assignment

    /// Move a card through its lifecycle (open ↔ in_progress ↔ done ↔ archived).
    /// Author may set any status; assignee may set in_progress or done. The
    /// plugin enforces the matrix server-side and emits an audit comment;
    /// callers should expect a 403 (`not_permitted`) for disallowed cells.
    @discardableResult
    func transitionCardStatus(
        roomSlug: String,
        dTag: String,
        status: String
    ) async throws -> String {
        struct Req: Encodable {
            let room: String
            let dTag: String
            let status: String
            enum CodingKeys: String, CodingKey { case room; case dTag = "d_tag"; case status }
        }
        struct Resp: Decodable {
            let dTag: String
            let rumorEventId: String
            let auditCommentEventId: String
            enum CodingKeys: String, CodingKey {
                case dTag = "d_tag"
                case rumorEventId = "rumor_event_id"
                case auditCommentEventId = "audit_comment_event_id"
            }
        }
        let resp: Resp = try await EntityHTTP.postPluginAction(
            path: "sonata-studio/card/transition",
            body: Req(room: roomSlug, dTag: dTag, status: status)
        )
        return resp.rumorEventId
    }

    /// Reassign a card. Pass nil/empty to unassign. The plugin's
    /// `studio_card_update` handler accepts the new `assignees` array and
    /// republishes the card under the author's d_tag. Author-only —
    /// reassignment from non-author callers will return 403 `not_author`.
    @discardableResult
    func updateCardAssignee(
        roomSlug: String,
        dTag: String,
        eventId: String,
        assigneePubkey: String?
    ) async throws -> String {
        let assignees: [String]
        if let pk = assigneePubkey, !pk.isEmpty {
            assignees = [pk.lowercased()]
        } else {
            assignees = []
        }
        let requestBody: [String: Any] = [
            "room": roomSlug,
            "d_tag": dTag,
            "assignees": assignees,
        ]
        _ = eventId // reserved for future reconciliation parity with updateCard
        struct Resp: Decodable {
            let rumorEventId: String
            let dTag: String
            enum CodingKeys: String, CodingKey {
                case rumorEventId = "rumor_event_id"
                case dTag = "d_tag"
            }
        }
        let result: Resp = try await EntityHTTP.postPluginActionRaw(
            path: "sonata-studio/card/update",
            body: requestBody
        )
        return result.rumorEventId
    }

    /// All members for a room (per-room federated profiles unioned with
    /// cross-room fallbacks), sorted by display name. Powers the assignee
    /// picker in the compose sheet and the drawer's Reassign popover.
    /// Includes the room's declared `members[]` so members without a
    /// `_profile` card still appear (they render with a short-hex fallback).
    func roomMembersList(for roomSlug: String) -> [StudioMember] {
        guard let room = rooms.first(where: { $0.slug == roomSlug }) else { return [] }
        var seen = Set<String>()
        var out: [StudioMember] = []
        for pk in room.members {
            let lower = pk.lowercased()
            if !seen.insert(lower).inserted { continue }
            if let m = roomMembers["\(roomSlug)|\(lower)"] {
                out.append(m)
            } else if let m = members[lower] {
                out.append(m)
            } else {
                out.append(StudioMember(rawPubkey: lower, roomSlug: roomSlug))
            }
        }
        return out.sorted { lhs, rhs in
            displayName(for: lhs.pubkeyHex, in: roomSlug)
                .localizedCaseInsensitiveCompare(
                    displayName(for: rhs.pubkeyHex, in: roomSlug)
                ) == .orderedAscending
        }
    }

    /// Find the projected card for a given (room, d_tag, eventId). The
    /// eventId disambiguates if the same d_tag has been republished — but
    /// in practice the projected entity is unique on (room, author, d_tag),
    /// so any of the three keys suffice.
    private func findCard(roomSlug: String, dTag: String, eventId: String) -> StudioCard? {
        for key in cardsByRoomTrack.keys where key.hasPrefix("\(roomSlug)|") {
            for c in cardsByRoomTrack[key] ?? [] {
                if c.dTag == dTag && c.roomSlug == roomSlug {
                    if eventId.isEmpty || c.eventId == eventId { return c }
                }
            }
        }
        return nil
    }

    /// Build a patched `StudioCard` from `original` overlaying any non-nil
    /// edit fields. Blocks override is the raw `[[String: Any]]` shape that
    /// the plugin expects; we decode it into typed `StudioBlock`s via the
    /// existing JSON path so the in-memory model stays consistent.
    private func patchCard(
        original: StudioCard,
        track: String?,
        kind: String?,
        title: String?,
        body: String?,
        blocksRaw: [[String: Any]]?,
        tagsList: [String]?,
        relatedTo: [String]?
    ) -> StudioCard {
        let newBlocks: [StudioBlock] = {
            guard let raw = blocksRaw else { return original.blocks }
            guard !raw.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let decoded = try? JSONDecoder().decode([StudioBlock].self, from: data)
            else { return [] }
            return decoded
        }()
        return StudioCard(
            id: original.id,
            eventId: original.eventId,
            cardKind: kind ?? original.cardKind,
            trackSlug: track ?? original.trackSlug,
            roomSlug: original.roomSlug,
            title: title ?? original.title,
            body: body ?? original.body,
            blocks: newBlocks,
            relatedTo: relatedTo ?? original.relatedTo,
            tagsList: tagsList ?? original.tagsList,
            createdByPubkey: original.createdByPubkey,
            createdAtSeconds: original.createdAtSeconds,
            dTag: original.dTag,
            status: original.status,
            assigneePubkey: original.assigneePubkey
        )
    }

    /// Drop optimistic edit patches whose underlying entity has been
    /// projected with the expected new rumor `event_id` — or whose entity
    /// row is no longer present at all (e.g. concurrent delete). Called
    /// from the cards onChange after the SSE round trip lands.
    private func reconcileOptimisticUpdates(realCards: [StudioCard]) {
        guard !optimisticCardUpdates.isEmpty else { return }
        let realById = Dictionary(uniqueKeysWithValues: realCards.map { ($0.id, $0) })
        var nextPatches = optimisticCardUpdates
        for (id, _) in optimisticCardUpdates {
            if let expected = optimisticUpdateExpectedEventIds[id],
               let real = realById[id], real.eventId == expected {
                nextPatches.removeValue(forKey: id)
                optimisticUpdateExpectedEventIds.removeValue(forKey: id)
            } else if realById[id] == nil {
                nextPatches.removeValue(forKey: id)
                optimisticUpdateExpectedEventIds.removeValue(forKey: id)
            }
        }
        if nextPatches != optimisticCardUpdates {
            optimisticCardUpdates = nextPatches
        }
    }

    /// Clear optimistic delete flags whose underlying card has been projected
    /// with `isDeleted == true` (the SSE round trip completed) — or whose row
    /// is no longer present at all. Called from the cards onChange.
    private func reconcileOptimisticDeletes(realCards: [StudioCard]) {
        if optimisticDeletes.isEmpty { return }
        let realById = Dictionary(uniqueKeysWithValues: realCards.map { ($0.eventId, $0) })
        var next = optimisticDeletes
        for id in optimisticDeletes {
            if let real = realById[id], real.isDeleted {
                next.remove(id)
            } else if realById[id] == nil {
                next.remove(id)
            }
        }
        if next != optimisticDeletes {
            optimisticDeletes = next
        }
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
        body: String,
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
            body: body,
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
            body: old.body,
            blocks: old.blocks,
            relatedTo: old.relatedTo,
            tagsList: old.tagsList,
            createdByPubkey: old.createdByPubkey,
            createdAtSeconds: old.createdAtSeconds,
            dTag: old.dTag
        )
        // Race fix: SSE may have already delivered the real card BEFORE
        // postCard returned the rumor event id — in which case the cards
        // observation already ran reconcile while the optimistic eventId
        // was still empty (so the match check skipped). Now that we've
        // populated the eventId, run a one-shot reconcile against the
        // current materialized cards. Without this the optimistic + real
        // duplicate forever.
        let realCards = cardsByRoomTrack.values.flatMap { $0 }
        reconcileOptimisticAgainstReal(realCards: realCards)
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
        body: String,
        blocks: [[String: Any]],
        relatedTo: [String],
        tagsList: [String],
        dTag: String?,
        assigneePubkey: String? = nil
    ) async throws -> String {
        var requestBody: [String: Any] = [
            "room": room,
            "track": track,
            "kind": kind,
            "title": title,
            "body": body,
            // Legacy wire alias — kept in the encoded JSON for one cutover
            // release so an unmigrated plugin still finds the prose. Remove
            // after 2026-05-12 + one release.
            "summary": body,
        ]
        if !blocks.isEmpty { requestBody["blocks"] = blocks }
        if !relatedTo.isEmpty { requestBody["related_to"] = relatedTo }
        if !tagsList.isEmpty { requestBody["tags"] = tagsList }
        if let d = dTag, !d.isEmpty { requestBody["d_tag"] = d }
        if let pk = assigneePubkey, !pk.isEmpty {
            requestBody["assignees"] = [pk.lowercased()]
        }

        let result: CardPostResponse = try await EntityHTTP.postPluginActionRaw(
            path: "sonata-studio/card/post",
            body: requestBody
        )
        rememberCurrentPubkey(from: result)
        // Auto-federate the default nickname on the first regular card the
        // user posts in a room. Skipped for `_profile` itself so we don't
        // recurse, and a no-op if we've already federated for this room.
        if !kind.hasPrefix("_") {
            autoPublishProfileIfNeeded(roomSlug: room)
        }
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
        if let creds = StudioStorageCredentials.lookup(forRoom: roomSlug) {
            body["s3_credentials"] = creds.body
        }

        let raw: [String: Any] = try await EntityHTTP.postPluginActionRawDict(
            path: "sonata-studio/image/attach",
            body: body
        )
        var block = raw
        block["type"] = "image"
        return block
    }

    /// Phase 5 — Encrypt + upload an arbitrary file via the plugin's
    /// `studio_file_attach` action. Hybrid encryption (random per-file
    /// ChaCha20-Poly1305 key, NIP-44-wrapped to the audience epoch). Returns
    /// the full file-block dict ready to drop into a card's blocks[] payload.
    /// The plugin enforces the 256 MiB hard cap; callers may apply softer
    /// caps at pick time.
    func attachFile(
        filePath: String,
        roomSlug: String,
        mimeType: String?
    ) async throws -> [String: Any] {
        var body: [String: Any] = [
            "file_path": filePath,
            "room_slug": roomSlug,
        ]
        if let m = mimeType, !m.isEmpty { body["mime_type"] = m }
        if let creds = StudioStorageCredentials.lookup(forRoom: roomSlug) {
            body["s3_credentials"] = creds.body
        }

        let raw: [String: Any] = try await EntityHTTP.postPluginActionRawDict(
            path: "sonata-studio/file/attach",
            body: body
        )
        var block = raw
        // The plugin already sets type:"file" on the response, but mirror the
        // attachImage convention of ensuring it survives any future server
        // shape changes.
        block["type"] = "file"
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

    /// T1: POST `/api/plugins/sonata-studio/room/join`. Returns a placeholder
    /// `StudioRoom` synthesized from the response; the real row arrives via
    /// the SSE projector shortly. Response `state` is either `"active"` (we
    /// already had a grant — e.g. re-joining a room we were a member of) or
    /// `"pending-grant"` (waiting for the founder to admit our claim).
    ///
    /// The caller is expected to trim/sanity-check the URL prefix before
    /// passing it in; this method forwards whatever it gets to the plugin.
    @discardableResult
    func joinRoom(
        inviteURL: String,
        profileNickname: String? = nil,
        profileBio: String? = nil
    ) async throws -> StudioRoom {
        struct Profile: Encodable {
            let nickname: String?
            let bio: String?
        }
        struct Req: Encodable {
            let inviteUrl: String
            let profile: Profile?
            enum CodingKeys: String, CodingKey {
                case inviteUrl = "invite_url"
                case profile
            }
        }
        let nick = profileNickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bio = profileBio?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickValue = (nick?.isEmpty ?? true) ? nil : nick
        let bioValue = (bio?.isEmpty ?? true) ? nil : bio
        let profile: Profile? = (nickValue != nil || bioValue != nil)
            ? Profile(nickname: nickValue, bio: bioValue)
            : nil
        let response: StudioRoomJoinResponse = try await EntityHTTP.postPluginAction(
            path: "sonata-studio/room/join",
            body: Req(inviteUrl: inviteURL, profile: profile)
        )
        // Auto-federate the default nickname into the room we just joined.
        // Fire-and-forget; no-op if defaultNickname is empty. Other members
        // pick up the _profile card via SSE within ~2s. When the join lands in
        // `pending-grant`, the federate-on-join attempt no-ops harmlessly:
        // postCard fails until the founder admits us, and the picker sheet's
        // deferred publish (subscribed on state→active transition) carries
        // the chosen profile in instead.
        autoPublishProfileIfNeeded(roomSlug: response.roomSlug)
        return StudioRoom.placeholder(
            id: "studio:room:\(response.roomSlug)",
            slug: response.roomSlug,
            title: response.roomSlug,
            description: nil,
            createdByPubkey: "",
            createdAtSeconds: Int64(Date().timeIntervalSince1970),
            eventId: response.claimEventId,
            members: [],
            currentEpoch: response.epoch,
            state: response.state
        )
    }

    /// Founder-only: mint a fresh invite URL for `slug`. `ttlSeconds` defaults
    /// to the plugin's 7-day default when nil. Throws `StudioPluginError` with
    /// code `not_founder` (403) if the local pubkey isn't the audience creator.
    func inviteRoom(slug: String, ttlSeconds: Int? = nil) async throws -> StudioInviteResponse {
        struct Req: Encodable {
            let roomSlug: String
            let ttlSeconds: Int?
            enum CodingKeys: String, CodingKey {
                case roomSlug = "room_slug"
                case ttlSeconds = "ttl_seconds"
            }
        }
        return try await EntityHTTP.postPluginAction(
            path: "sonata-studio/room/invite",
            body: Req(roomSlug: slug, ttlSeconds: ttlSeconds)
        )
    }

    /// Founder-only: list pending kind:30522 claims for `slug` along with each
    /// joiner's volunteered profile preview (nickname + bio), without
    /// rotating. The admit dialog uses this to render per-row identity
    /// previews before the founder commits to the rotate.
    func listPendingClaims(slug: String) async throws -> StudioPendingClaimsResult {
        struct Req: Encodable {
            let roomSlug: String
            enum CodingKeys: String, CodingKey { case roomSlug = "room_slug" }
        }
        return try await EntityHTTP.postPluginAction(
            path: "sonata-studio/room/pending",
            body: Req(roomSlug: slug)
        )
    }

    /// Founder-only: rotate the epoch and mint key-grants for any pending
    /// claims on `slug`. `maxAdmit` caps the number processed (nil = no cap).
    /// Returns an empty `admitted` list if there are no pending claims —
    /// that's the cheap "are there pending claims?" probe shape.
    func admitRoom(slug: String, maxAdmit: Int? = nil) async throws -> StudioAdmitResult {
        struct Req: Encodable {
            let roomSlug: String
            let maxAdmit: Int?
            enum CodingKeys: String, CodingKey {
                case roomSlug = "room_slug"
                case maxAdmit = "max_admit"
            }
        }
        return try await EntityHTTP.postPluginAction(
            path: "sonata-studio/room/admit",
            body: Req(roomSlug: slug, maxAdmit: maxAdmit)
        )
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

    nonisolated static let SQL_USER_PROFILE = """
        SELECT id, name, description, attributes
        FROM entities
        WHERE type = 'studio_user_profile'
        LIMIT 1
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

/// Response from `POST /api/plugins/sonata-studio/room/join`. `state` is
/// either `"active"` (we re-joined a room we still had a valid grant for)
/// or `"pending-grant"` (waiting for the founder to admit the claim).
struct StudioRoomJoinResponse: Decodable {
    let audienceAddress: String
    let roomSlug: String
    let epoch: Int
    let claimEventId: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case audienceAddress = "audience_address"
        case roomSlug = "room_slug"
        case epoch
        case claimEventId = "claim_event_id"
        case state
    }
}

/// Response from `POST /api/plugins/sonata-studio/room/invite`. The
/// renderer shows `https_url` (more shareable across apps) and stamps
/// `expires_at` (Unix seconds) into the UI.
struct StudioInviteResponse: Decodable, Equatable {
    let fourAUrl: String
    let httpsUrl: String
    let invitePub: String
    let expiresAt: Int64

    enum CodingKeys: String, CodingKey {
        case fourAUrl = "four_a_url"
        case httpsUrl = "https_url"
        case invitePub = "invite_pub"
        case expiresAt = "expires_at"
    }
}

/// Response from `POST /api/plugins/sonata-studio/room/admit`. `admitted`
/// is the list of newly granted members; if empty, no pending claims were
/// available to process. `failed` carries any per-recipient errors
/// (decryption / publish problems); the action still succeeds overall.
struct StudioAdmitResult: Decodable, Equatable {
    let ok: Bool
    let admitted: [Admitted]
    let newEpoch: Int
    let declarationEventId: String?
    let failed: [Failure]?

    struct Admitted: Decodable, Equatable {
        let claimPubkey: String
        let keyGrantEventId: String
        /// Optional profile preview parsed by the plugin from the joiner's
        /// kind:30522 claim event content. Nil when the gateway doesn't
        /// surface raw claim content (older gateways) or when the joiner
        /// chose not to volunteer a profile preview.
        let profile: StudioClaimProfile?

        enum CodingKeys: String, CodingKey {
            case claimPubkey = "claim_pubkey"
            case keyGrantEventId = "key_grant_event_id"
            case profile
        }
    }

    struct Failure: Decodable, Equatable {
        let recipient: String
        let reason: String
    }

    enum CodingKeys: String, CodingKey {
        case ok, admitted, failed
        case newEpoch = "new_epoch"
        case declarationEventId = "declaration_event_id"
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

/// Optional volunteered profile preview from a kind:30522 claim. Avatar is
/// deliberately absent — joiners can't encrypt an image to a room they
/// haven't been admitted to yet, so claim-time identity is text-only.
struct StudioClaimProfile: Decodable, Equatable {
    let nickname: String?
    let bio: String?
}

/// Response from `POST /api/plugins/sonata-studio/room/pending`. Each entry
/// is a kind:30522 claim awaiting founder rotation. `profile` is nil when
/// the gateway omits raw claim content (older gateways) or when the joiner
/// didn't volunteer a profile preview. Renderer falls back to pubkey-prefix
/// for nil entries.
struct StudioPendingClaimsResult: Decodable, Equatable {
    let ok: Bool
    let pending: [Pending]

    struct Pending: Decodable, Equatable, Identifiable {
        let claimPubkey: String
        let claimEventId: String
        let profile: StudioClaimProfile?

        var id: String { claimEventId }

        enum CodingKeys: String, CodingKey {
            case claimPubkey = "claim_pubkey"
            case claimEventId = "claim_event_id"
            case profile
        }
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

    /// Idempotent name-keyed upsert. Used for the local `studio:user_profile`
    /// singleton; logs and swallows errors because Settings UI shouldn't
    /// surface transient memory-server hiccups (the next save retries).
    static func upsertEntity(
        name: String,
        type: String,
        description: String,
        attributes: [String: Any]
    ) async {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/entity"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "name": name,
            "type": type,
            "description": description,
            "attributes": attributes,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            _ = try await URLSession.shared.data(for: req)
        } catch {
            NSLog("[EntityHTTP] upsertEntity(\(name)) failed: \(error)")
        }
    }

    /// One-shot read of the `studio:user_profile` singleton's
    /// `default_nickname`. Returns nil if the entity doesn't exist yet OR if
    /// the read failed transiently — the Settings pane treats nil as empty
    /// and keeps the user's in-progress edits.
    static func readDefaultNickname() async -> String? {
        return await readUserProfileAttribute(name: "default_nickname")
    }

    /// Companion to `readDefaultNickname` — returns the saved avatar source
    /// path (empty string treated as nil). Same fault tolerance: any failure
    /// resolves to nil so the Settings pane keeps the user's pending edits.
    static func readDefaultAvatarLocalPath() async -> String? {
        let v = await readUserProfileAttribute(name: "default_avatar_local_path")
        guard let v = v, !v.isEmpty else { return nil }
        return v
    }

    private static func readUserProfileAttribute(name attribute: String) async -> String? {
        let attrs = await readUserProfileAttributes()
        return attrs[attribute] as? String
    }

    /// Full attribute dictionary for `studio:user_profile`. Returns an empty
    /// dictionary when the entity is absent OR when the read failed — Auto-run
    /// Settings treats absence as the default profile.
    static func readUserProfileAttributes() async -> [String: Any] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/entity"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "name", value: "studio:user_profile")]
        guard let url = comps.url else { return [:] }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return [:]
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let attrsRaw = (obj?["attributes"] as? String) ?? "{}"
            let attrs = ((try? JSONSerialization.jsonObject(with: attrsRaw.data(using: .utf8) ?? Data())) as? [String: Any]) ?? [:]
            return attrs
        } catch {
            return [:]
        }
    }

    /// Merge-and-write a partial set of attributes into `studio:user_profile`,
    /// preserving keys we don't touch. Last-write-wins via PATCH if the entity
    /// already exists, falling back to upsert on first write.
    static func mergeIntoUserProfile(_ updates: [String: Any]) async {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/entity"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "name", value: "studio:user_profile")]
        var existingId: String? = nil
        var existingAttrs: [String: Any] = [:]
        if let url = comps.url {
            if let (data, response) = try? await URLSession.shared.data(from: url),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if let raw = obj?["attributes"] as? String,
                   let parsed = (try? JSONSerialization.jsonObject(with: raw.data(using: .utf8) ?? Data())) as? [String: Any] {
                    existingAttrs = parsed
                }
                if let id = obj?["id"] as? String {
                    existingId = id
                } else if let id = obj?["_id"] as? String {
                    existingId = id
                }
            }
        }
        var merged = existingAttrs
        for (k, v) in updates { merged[k] = v }
        if let id = existingId {
            await patchAttributes(id: id, attributes: merged)
        } else {
            await upsertEntity(
                name: "studio:user_profile",
                type: "studio_user_profile",
                description: "Local default profile (machine-only, not federated directly)",
                attributes: merged
            )
        }
    }

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

    /// GET a plugin action and decode the response. Used for read-only
    /// endpoints (e.g. /api/plugins/sonata-studio/identity).
    static func getPluginAction<Res: Decodable>(path: String) async throws -> Res {
        let url = baseURL.appendingPathComponent("api/plugins/").appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
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
        currentEpoch: Int,
        state: String = "active"
    ) -> StudioRoom {
        let attrs: [String: Any] = [
            "slug": slug,
            "title": title,
            "description": description ?? NSNull(),
            "default_tracks": [],
            "created_by_pubkey": createdByPubkey,
            "created_at_seconds": createdAtSeconds,
            "event_id": eventId,
            "state": state,
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
