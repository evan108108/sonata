import Foundation
import GRDB

// MARK: - Hex helpers

enum Hex {
    /// Decode a lowercase or mixed-case hex string to bytes. Returns nil on
    /// odd length or non-hex characters. Used for pubkey_hex and epoch_key
    /// material decoded from JSON attributes.
    static func decode(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let byte = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }

    /// Encode bytes to lowercase hex.
    static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// First 8 hex chars of a 64-hex pubkey — author byline fallback when
    /// `studio_member.nickname` is null (plan §2 gap #6).
    static func npubShort(_ pubkeyHex: String) -> String {
        String(pubkeyHex.prefix(8))
    }
}

// MARK: - AnyCodableValue — preserve unknown JSON values

/// A type-erased Decodable wrapper used to preserve forward-compatible
/// unknown values inside `StudioBlock.unknown(raw:)`. Spec §3.3 mandates
/// round-tripping of unknown block types; this carries the original JSON
/// shape so a future renderer (or a v0.1 upgrade) can interpret it.
enum AnyCodableValue: Equatable, Decodable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([AnyCodableValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: AnyCodableValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "AnyCodableValue: unknown JSON type")
    }
}

// MARK: - StudioRoom

struct StudioRoom: Equatable, Identifiable {
    let id: String
    let slug: String
    let title: String
    let description: String?
    let project: String?
    let defaultTracks: [String]
    let createdByPubkey: String
    let createdAtSeconds: Int64
    let eventId: String

    let state: String
    let currentEpoch: Int
    let members: [String]
    let lastSeenAtMs: Int64?
    let dispatchTraceOn: Bool
    let epochKeys: [Int: Data]

    init(row: Row) throws {
        guard let id = row["id"] as String? else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "studio_room: missing id"))
        }
        self.id = id

        let attrsRaw = row["attributes"] as String? ?? "{}"
        let attrs = try Self.parseJSONObject(attrsRaw)

        self.slug = (attrs["slug"] as? String) ?? (row["name"] as? String ?? "").replacingOccurrences(of: "studio:room:", with: "")
        self.title = (attrs["title"] as? String) ?? self.slug
        self.description = attrs["description"] as? String
        self.project = attrs["project"] as? String
        self.defaultTracks = (attrs["default_tracks"] as? [String]) ?? []
        self.createdByPubkey = (attrs["created_by_pubkey"] as? String) ?? ""
        self.createdAtSeconds = Self.intLike(attrs["created_at_seconds"]) ?? 0
        self.eventId = (attrs["event_id"] as? String) ?? ""

        self.state = (attrs["state"] as? String) ?? "active"
        self.currentEpoch = Int(Self.intLike(attrs["current_epoch"]) ?? 0)
        self.members = (attrs["members"] as? [String]) ?? []
        self.lastSeenAtMs = Self.intLike(attrs["last_seen_at_ms"])
        self.dispatchTraceOn = (attrs["dispatch_trace_on"] as? Bool) ?? false

        var ek: [Int: Data] = [:]
        if let keys = attrs["epoch_keys"] as? [String: String] {
            for (k, v) in keys {
                if let n = Int(k), let bytes = Hex.decode(v), bytes.count == 32 {
                    ek[n] = bytes
                }
            }
        }
        self.epochKeys = ek
    }

    private static func intLike(_ v: Any?) -> Int64? {
        if let i = v as? Int64 { return i }
        if let i = v as? Int   { return Int64(i) }
        if let d = v as? Double { return Int64(d) }
        if let s = v as? String, let n = Int64(s) { return n }
        return nil
    }

    private static func parseJSONObject(_ s: String) throws -> [String: Any] {
        guard let data = s.data(using: .utf8) else { return [:] }
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        return (parsed as? [String: Any]) ?? [:]
    }
}

// MARK: - StudioTrack

struct StudioTrack: Equatable, Identifiable {
    let id: String
    let name: String
    let title: String
    let description: String?
    let layout: String
    let roomSlug: String
    let createdByPubkey: String
    let createdAtSeconds: Int64
    let eventId: String
    let autoCreated: Bool
    let closedAtSeconds: Int64?

    init(row: Row) throws {
        guard let id = row["id"] as String? else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "studio_track: missing id"))
        }
        self.id = id
        let attrsRaw = row["attributes"] as String? ?? "{}"
        let attrs = (try? JSONSerialization.jsonObject(with: attrsRaw.data(using: .utf8) ?? Data())) as? [String: Any] ?? [:]
        self.name = (attrs["name"] as? String) ?? ""
        self.title = (attrs["title"] as? String) ?? self.name
        self.description = attrs["description"] as? String
        self.layout = (attrs["layout"] as? String) ?? "column"
        self.roomSlug = (attrs["room_slug"] as? String) ?? ""
        self.createdByPubkey = (attrs["created_by_pubkey"] as? String) ?? ""
        self.createdAtSeconds = (attrs["created_at_seconds"] as? Int64)
            ?? Int64((attrs["created_at_seconds"] as? Int) ?? 0)
        self.eventId = (attrs["event_id"] as? String) ?? ""
        self.autoCreated = (attrs["auto_created"] as? Bool) ?? false
        if let c = attrs["closed_at_seconds"] as? Int64 { self.closedAtSeconds = c }
        else if let c = attrs["closed_at_seconds"] as? Int { self.closedAtSeconds = Int64(c) }
        else { self.closedAtSeconds = nil }
    }
}

// MARK: - StudioCard

struct StudioCard: Equatable, Identifiable {
    let id: String
    let eventId: String
    let cardKind: String?
    let trackSlug: String
    let roomSlug: String
    let title: String
    /// Long-form markdown body (`attributes.body`). Cards posted under the
    /// pre-2026-05-12 wire shape only had `attributes.summary` — the decoder
    /// falls back to it so old cards still surface. Remove the fallback once
    /// the cutover release has shipped.
    let body: String
    let blocks: [StudioBlock]
    let relatedTo: [String]
    let tagsList: [String]
    let createdByPubkey: String
    let createdAtSeconds: Int64
    let dTag: String
    let status: String?

    var isDeleted: Bool { status == "deleted" }

    init(row: Row) throws {
        guard let id = row["id"] as String? else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "studio_card: missing id"))
        }
        self.id = id
        let attrsRaw = row["attributes"] as String? ?? "{}"
        guard let data = attrsRaw.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "studio_card: utf8 fail"))
        }
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        self.eventId = (raw["event_id"] as? String) ?? ""
        self.cardKind = raw["card_kind"] as? String
        self.trackSlug = (raw["track_slug"] as? String) ?? ""
        self.roomSlug = (raw["room_slug"] as? String) ?? ""
        self.title = (raw["title"] as? String) ?? ""
        self.body = (raw["body"] as? String) ?? (raw["summary"] as? String) ?? ""
        self.relatedTo = (raw["related_to"] as? [String]) ?? []
        self.tagsList = (raw["tags"] as? [String]) ?? []
        self.createdByPubkey = (raw["created_by_pubkey"] as? String) ?? ""
        self.createdAtSeconds = (raw["created_at_seconds"] as? Int64)
            ?? Int64((raw["created_at_seconds"] as? Int) ?? 0)
        self.dTag = (raw["d_tag"] as? String) ?? ""
        self.status = raw["status"] as? String

        if let rawBlocks = raw["blocks"] as? [Any], !rawBlocks.isEmpty,
           let blockData = try? JSONSerialization.data(withJSONObject: rawBlocks) {
            self.blocks = (try? JSONDecoder().decode([StudioBlock].self, from: blockData)) ?? []
        } else {
            self.blocks = []
        }
    }

    public init(
        id: String,
        eventId: String,
        cardKind: String?,
        trackSlug: String,
        roomSlug: String,
        title: String,
        body: String,
        blocks: [StudioBlock],
        relatedTo: [String],
        tagsList: [String],
        createdByPubkey: String,
        createdAtSeconds: Int64,
        dTag: String,
        status: String? = nil
    ) {
        self.id = id
        self.eventId = eventId
        self.cardKind = cardKind
        self.trackSlug = trackSlug
        self.roomSlug = roomSlug
        self.title = title
        self.body = body
        self.blocks = blocks
        self.relatedTo = relatedTo
        self.tagsList = tagsList
        self.createdByPubkey = createdByPubkey
        self.createdAtSeconds = createdAtSeconds
        self.dTag = dTag
        self.status = status
    }
}

// MARK: - StudioBlock — discriminated union

enum StudioBlock: Equatable {
    case text(body: String)
    case code(language: String, body: String)
    case link(href: String, label: String?)
    case field(key: String, value: String)
    case image(StudioImageBlock)
    case unknown(type: String, raw: [String: AnyCodableValue])
}

extension StudioBlock: Decodable {
    private enum TypeKey: String, CodingKey { case type }
    private struct AnyKey: CodingKey {
        let stringValue: String; init?(stringValue s: String) { self.stringValue = s }
        var intValue: Int? { nil }; init?(intValue: Int) { return nil }
        init(_ s: String) { self.stringValue = s }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TypeKey.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let body = try decoder.container(keyedBy: AnyKey.self).decode(String.self, forKey: AnyKey("body"))
            self = .text(body: body)
        case "code":
            let kc = try decoder.container(keyedBy: AnyKey.self)
            let language = (try? kc.decode(String.self, forKey: AnyKey("language"))) ?? ""
            let body = (try? kc.decode(String.self, forKey: AnyKey("body"))) ?? ""
            self = .code(language: language, body: body)
        case "link":
            let kc = try decoder.container(keyedBy: AnyKey.self)
            let href = try kc.decode(String.self, forKey: AnyKey("href"))
            let label = try? kc.decode(String.self, forKey: AnyKey("label"))
            self = .link(href: href, label: label)
        case "field":
            let kc = try decoder.container(keyedBy: AnyKey.self)
            let key = try kc.decode(String.self, forKey: AnyKey("key"))
            let value = try kc.decode(String.self, forKey: AnyKey("value"))
            self = .field(key: key, value: value)
        case "image":
            self = .image(try StudioImageBlock(from: decoder))
        default:
            let raw = (try? decoder.singleValueContainer().decode([String: AnyCodableValue].self)) ?? [:]
            self = .unknown(type: type, raw: raw)
        }
    }
}

// MARK: - StudioImageBlock

struct StudioImageBlock: Equatable, Decodable {
    let sha256: String
    let mirrors: [String]
    let decryptHint: DecryptHint
    let mimeType: String
    let blake3: String

    struct DecryptHint: Equatable, Decodable {
        let kind: String
        let epochN: Int

        enum CodingKeys: String, CodingKey {
            case kind
            case epochN = "epoch_n"
        }
    }

    enum CodingKeys: String, CodingKey {
        case sha256, mirrors
        case decryptHint = "decrypt_hint"
        case mimeType = "mime_type"
        case blake3
    }
}

// MARK: - StudioComment

struct StudioComment: Equatable, Identifiable {
    let id: String
    let eventId: String
    let targetRef: String
    let targetEventId: String?
    let body: String
    let intent: String?
    let createdByPubkey: String
    let roomSlug: String
    let createdAtSeconds: Int64

    init(row: Row) throws {
        guard let id = row["id"] as String? else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "studio_comment: missing id"))
        }
        self.id = id
        let attrsRaw = row["attributes"] as String? ?? "{}"
        let raw = ((try? JSONSerialization.jsonObject(with: attrsRaw.data(using: .utf8) ?? Data())) as? [String: Any]) ?? [:]
        self.eventId = (raw["event_id"] as? String) ?? ""
        let tr = (raw["target_ref"] as? String) ?? ""
        self.targetRef = tr
        self.targetEventId = Self.extractEventId(tr)
        self.body = (raw["body"] as? String) ?? ""
        self.intent = raw["intent"] as? String
        self.createdByPubkey = (raw["created_by_pubkey"] as? String) ?? ""
        self.roomSlug = (raw["room_slug"] as? String) ?? ""
        self.createdAtSeconds = (raw["created_at_seconds"] as? Int64)
            ?? Int64((raw["created_at_seconds"] as? Int) ?? 0)
    }

    static func extractEventId(_ ref: String) -> String? {
        let trimmed = ref.trimmingCharacters(in: .whitespaces)
        let hex64 = #"^[0-9a-fA-F]{64}$"#
        if trimmed.range(of: hex64, options: .regularExpression) != nil {
            return trimmed.lowercased()
        }
        if trimmed.hasPrefix("nostr:") {
            let rest = String(trimmed.dropFirst("nostr:".count))
            if rest.range(of: hex64, options: .regularExpression) != nil {
                return rest.lowercased()
            }
        }
        return nil
    }

    public init(
        id: String,
        eventId: String,
        targetRef: String,
        targetEventId: String?,
        body: String,
        intent: String?,
        createdByPubkey: String,
        roomSlug: String,
        createdAtSeconds: Int64
    ) {
        self.id = id
        self.eventId = eventId
        self.targetRef = targetRef
        self.targetEventId = targetEventId
        self.body = body
        self.intent = intent
        self.createdByPubkey = createdByPubkey
        self.roomSlug = roomSlug
        self.createdAtSeconds = createdAtSeconds
    }
}

// MARK: - StudioMember

struct StudioMember: Equatable, Identifiable {
    let id: String
    let pubkeyHex: String
    let nickname: String?

    init(row: Row) throws {
        guard let id = row["id"] as String? else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "studio_member: missing id"))
        }
        self.id = id
        let attrsRaw = row["attributes"] as String? ?? "{}"
        let raw = ((try? JSONSerialization.jsonObject(with: attrsRaw.data(using: .utf8) ?? Data())) as? [String: Any]) ?? [:]
        self.pubkeyHex = (raw["pubkey_hex"] as? String) ?? ""
        self.nickname = raw["nickname"] as? String
    }

    var displayName: String { nickname ?? Hex.npubShort(pubkeyHex) }
}

// MARK: - StudioDispatchIntent

struct StudioDispatchIntent: Equatable, Identifiable {
    let id: String
    let busEventId: String
    let candidates: [String]
    let chosen: String?
    let reason: String?
    let signals: [String: AnyCodableValue]
    let trackSlug: String?
    let createdAtMs: Int64?
    let createdByPubkey: String
    let roomSlug: String
    let createdAtSeconds: Int64

    init(row: Row) throws {
        guard let id = row["id"] as String? else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "studio_dispatch_intent: missing id"))
        }
        self.id = id
        let attrsRaw = row["attributes"] as String? ?? "{}"
        let raw = ((try? JSONSerialization.jsonObject(with: attrsRaw.data(using: .utf8) ?? Data())) as? [String: Any]) ?? [:]
        self.busEventId = (raw["bus_event_id"] as? String) ?? ""
        self.candidates = (raw["candidates"] as? [String]) ?? []
        self.chosen = raw["chosen"] as? String
        self.reason = raw["reason"] as? String
        if let sigDict = raw["signals"] as? [String: Any],
           let sigData = try? JSONSerialization.data(withJSONObject: sigDict),
           let decoded = try? JSONDecoder().decode([String: AnyCodableValue].self, from: sigData) {
            self.signals = decoded
        } else {
            self.signals = [:]
        }
        self.trackSlug = raw["track_slug"] as? String
        self.createdAtMs = (raw["created_at_ms"] as? Int64)
            ?? (raw["created_at_ms"] as? Int).map(Int64.init)
        self.createdByPubkey = (raw["created_by_pubkey"] as? String) ?? ""
        self.roomSlug = (raw["room_slug"] as? String) ?? ""
        self.createdAtSeconds = (raw["created_at_seconds"] as? Int64)
            ?? Int64((raw["created_at_seconds"] as? Int) ?? 0)
    }
}
