import Foundation
import GRDB

enum DMTargetKind: String, Codable, Sendable {
    case worker
    case session
    case supervisor
    case peer
    case selfPeer   // resolver sentinel — never a real routing target;
                    // dm_send maps this to {status:not_found, reason:"self_peer"}
}

struct DMResolvedTarget: Sendable {
    let sessionKey: String
    let kind: DMTargetKind
    let peerId: String?
    let sessionId: String?
}

enum DMTargetResolver {
    static func resolve(_ input: String, dbPool: DatabasePool) async -> DMResolvedTarget? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let ci = trimmed.lowercased()

        // 1 & 2: workers table.
        if let workerId: String = try? await dbPool.read({ db -> String? in
            try String.fetchOne(db, sql: """
                SELECT workerId FROM workers
                WHERE status != 'offline' AND
                      (workerId = ? OR LOWER(sessionLabel) = ?)
                ORDER BY CASE WHEN workerId = ? THEN 0 ELSE 1 END
                LIMIT 1
            """, arguments: [trimmed, ci, trimmed])
        }).flatMap({ $0 }) {
            return DMResolvedTarget(sessionKey: workerId, kind: .worker, peerId: nil, sessionId: nil)
        }

        // 3, 4, 5, 5b: interactiveSessions
        //   - sessionId exact
        //   - claudeSessionId alias (added by sonata_identify, Section H)
        //   - name (case-insensitive)
        //   - derived mcpSessionKey "session-<first16hex>"
        if let sid: String = try? await dbPool.read({ db -> String? in
            try String.fetchOne(db, sql: """
                SELECT sessionId FROM interactiveSessions
                WHERE status = 'live' AND (
                    sessionId = ?
                    OR claudeSessionId = ?
                    OR LOWER(name) = ?
                    OR ('session-' || SUBSTR(REPLACE(sessionId, '-', ''), 1, 16)) = ?
                )
                LIMIT 1
            """, arguments: [trimmed, trimmed, ci, trimmed])
        }).flatMap({ $0 }) {
            let key = "session-" + sid.replacingOccurrences(of: "-", with: "").prefix(16)
            return DMResolvedTarget(sessionKey: key, kind: .session, peerId: nil, sessionId: sid)
        }

        // 6: supervisor literal.
        if ci == "supervisor" {
            return DMResolvedTarget(sessionKey: "supervisor", kind: .supervisor, peerId: nil, sessionId: nil)
        }

        // 7: sonar peer name. Self-federation guard: match own instance_id.
        if let peer = await SonarPeerLookup.byName(ci) {
            if await SonarPeerLookup.isSelf(peer.instanceId) {
                return DMResolvedTarget(sessionKey: peer.id, kind: .selfPeer, peerId: peer.id, sessionId: nil)
            }
            // Reject peers in known-dead states. Sonar's status enum is
            // ["discovered", "paired", "offline", "revoked"] — the healthy
            // states are `discovered` and `paired`. The July 7 fix (01a962d)
            // originally whitelisted "online" here, which is NOT a value
            // sonar ever sets, so every sonar-peer DM silently returned
            // not_live/peer_offline (surfaced 2026-07-08 when Scout
            // couldn't be reached despite being fully alive). Blacklist
            // the bad states instead — future sonar status values default
            // to routable.
            if peer.connectionStatus == "offline" || peer.connectionStatus == "revoked" {
                return DMResolvedTarget(sessionKey: peer.id, kind: .peer, peerId: nil, sessionId: nil)
            }
            return DMResolvedTarget(sessionKey: peer.id, kind: .peer, peerId: peer.id, sessionId: nil)
        }

        return nil
    }
}

enum SonarPeerLookup {
    struct PeerInfo: Sendable {
        let id: String
        let name: String
        let instanceId: String
        let connectionStatus: String
    }

    static func byName(_ ciName: String) async -> PeerInfo? {
        guard let peers = await allPeers() else { return nil }
        return peers.first { $0.name.lowercased() == ciName }
    }

    /// Returns all peers, or nil if the sonar plugin loopback is unreachable.
    static func allPeers() async -> [PeerInfo]? {
        guard let url = URL(string: "http://127.0.0.1:4000/api/peers") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return nil
            }
            return arr.compactMap { row in
                guard let id = row["id"] as? String,
                      let name = row["name"] as? String else { return nil }
                let instanceId = row["instance_id"] as? String ?? ""
                let status = row["connection_status"] as? String ?? "unknown"
                return PeerInfo(id: id, name: name, instanceId: instanceId, connectionStatus: status)
            }
        } catch {
            return nil
        }
    }

    /// Fast probe: HEAD the peers endpoint to distinguish "no such peer"
    /// from "sonar offline". Used ONLY on the negative path in dm_send.
    static func pluginReachable() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:4000/api/peers") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    private static let selfCache = SelfInstanceIdCache()

    static func isSelf(_ instanceId: String) async -> Bool {
        guard !instanceId.isEmpty else { return false }
        let ourId = await selfCache.get()
        return !ourId.isEmpty && ourId == instanceId
    }
}

actor SelfInstanceIdCache {
    private var cached: String = ""

    func get() async -> String {
        if !cached.isEmpty { return cached }
        cached = await fetch()
        return cached
    }

    private func fetch() async -> String {
        guard let url = URL(string: "http://127.0.0.1:4000/.well-known/sonar/card.json") else {
            return ""
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return ""
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["instance_id"] as? String else { return "" }
            return id
        } catch {
            return ""
        }
    }
}
