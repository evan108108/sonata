import Foundation
import GRDB
import Logging

/// The in-process handler for the memory sidecar.
///
/// Replaces the tier-1 architecture (Claude Code dispatcher + Haiku sub-agent
/// per event, 20-60s per hint pass, 20-46K tokens) with a Swift closure that
/// runs `mem_recall` server-side, filters against `already_injected`, formats
/// the top hits, and inserts a row into `sidecarHints`. Total wall time is
/// dominated by `mem_recall` itself — typically under 500ms for a scoped
/// query. Zero LLM tokens per event.
///
/// The design's core rules survive: precision over recall (limit to 3),
/// silence beats noise (skip write when nothing is judged worth surfacing).
/// The judgment step is `mem_recall`'s existing 7-layer ranking — the tier-1
/// sub-agent's LLM judgment was mostly cutting the bottom of that ranked list,
/// which `limit: 3` does for free.
///
/// The dispatcher and worker-prompt files (`SKILL.md`, `worker-prompt.md`)
/// are dead code as of this handler; they may or may not be removed from the
/// bundle in the same commit, but they can be — nothing here needs them.
enum MemorySidecarHandler {

    /// Sonata's local HTTP port — the same value the hooks use. Cached at
    /// process start; changing `$SONATA_PORT` mid-flight is not a supported
    /// mode. Loopback HTTP for `mem_recall` is a pragmatic choice: extracting
    /// the recall closure out of `recallActions` would be a lot more surgery
    /// than one localhost call is worth, and localhost round-trip on a warm
    /// process is measured in single-digit milliseconds.
    private static let sonataPort: Int = SonataInstance.port

    /// Build a handler closure for `SidecarInProcessRegistry.register`.
    ///
    /// Captures a logger so log lines land in the same file the LLM-driven
    /// sidecar's did. Everything else it needs is a singleton or the payload.
    static func handler(logger: Logger) -> SidecarInProcessHandler {
        return { @Sendable payload in
            let handlerLogger = logger
            do {
                try await run(payload: payload, logger: handlerLogger)
            } catch {
                handlerLogger.warning("memory sidecar handler failed on event \(payload.eventId): \(error)")
                throw error
            }
        }
    }

    // MARK: - Payload decode

    /// Slice of the memory_request payload the handler actually reads. Every
    /// other field the hook sends (budget_tier, judge_model, dedup_window)
    /// is either ignored or handled elsewhere; `top_k` is honored but capped
    /// at 3 because higher fan-out on advisory hints just makes noise.
    private struct Request: Decodable {
        let source_session_id: String
        let recent_context: RecentContext
        let already_injected: [String]?
        let top_k: Int?

        struct RecentContext: Decodable {
            let last_user_prompt: String?
            let last_assistant_head: String?
        }
    }

    // MARK: - Core

    private static func run(payload: SidecarEventPayload, logger: Logger) async throws {
        guard let data = payload.payloadJSON.data(using: .utf8) else {
            logger.warning("memory sidecar: payload for \(payload.eventId) is not UTF-8")
            return
        }
        let request: Request
        do {
            request = try JSONDecoder().decode(Request.self, from: data)
        } catch {
            logger.warning("memory sidecar: payload for \(payload.eventId) failed decode: \(error)")
            return
        }

        let sessionId = request.source_session_id
        guard !sessionId.isEmpty else {
            logger.warning("memory sidecar: event \(payload.eventId) has empty source_session_id")
            return
        }

        let query = queryText(from: request)
        guard !query.isEmpty else {
            logger.info("memory sidecar: event \(payload.eventId) has no usable query text — skipping")
            return
        }

        let alreadyInjected = Set(request.already_injected ?? [])
        // Cap top_k at 3. The tier-1 design's default was 10 with a judge step
        // that trimmed hard; here there's no judge, so a wide fan-out would
        // inject noise. Three high-confidence hints beat ten mixed-quality ones.
        let requestedLimit = request.top_k.map { max(1, min(3, $0)) } ?? 3

        let candidates = try await recall(query: query, limit: max(requestedLimit + alreadyInjected.count, requestedLimit))
        guard !candidates.isEmpty else {
            logger.debug("memory sidecar: no candidates for event \(payload.eventId)")
            return
        }

        let filtered = candidates
            .filter { !alreadyInjected.contains($0.id) }
            .prefix(requestedLimit)
        guard !filtered.isEmpty else {
            logger.debug("memory sidecar: all candidates were already injected for event \(payload.eventId)")
            return
        }

        let hint = formatHint(candidates: Array(filtered))
        guard !hint.isEmpty else { return }
        try await writeHint(sessionId: sessionId, content: hint)
        logger.info("memory sidecar: wrote \(filtered.count) hint(s) for session \(sessionId) on event \(payload.eventId)")
    }

    // MARK: - Query

    /// The query text passed to `mem_recall`. Last user prompt is the primary
    /// signal; the assistant head is a fallback when the prompt itself is
    /// empty (e.g. a session that just resumed and stop-hooked with no user
    /// input yet). Trimmed to ~2000 chars — beyond that, mem_recall's own
    /// tokenizer starts truncating and the tail signal is lost anyway.
    private static func queryText(from request: Request) -> String {
        let prompt = request.recent_context.last_user_prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !prompt.isEmpty {
            return String(prompt.prefix(2000))
        }
        let head = request.recent_context.last_assistant_head?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(head.prefix(2000))
    }

    // MARK: - Recall

    /// One hit from `mem_recall`, extracted from the JSON response. Only the
    /// fields the hint formatter uses land here — everything else the endpoint
    /// returns (`_scoreComponents`, `_rankScore`, `updatedAt`, tags, …) is
    /// dropped on decode. Kept intentionally lean so a shape change on the
    /// server side only breaks fields we actually rely on.
    private struct Candidate: Decodable {
        let id: String
        let l0: String?
        let l1: String?

        enum CodingKeys: String, CodingKey {
            case id = "_id"
            case l0
            case l1
        }
    }

    private struct RecallResponse: Decodable {
        let memories: [Candidate]?
    }

    private static func recall(query: String, limit: Int) async throws -> [Candidate] {
        var components = URLComponents(string: "http://127.0.0.1:\(sonataPort)/api/recall")!
        components.queryItems = [
            URLQueryItem(name: "topic", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "tier", value: "l0"),
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw HandlerError.recallFailed("HTTP \(code)")
        }

        let decoded = try JSONDecoder().decode(RecallResponse.self, from: data)
        return decoded.memories ?? []
    }

    // MARK: - Format

    /// Produce the same markdown-block shape the tier-1 sub-agent used to
    /// write. The UserPromptSubmit hook's `extractMemoryIds` regex still
    /// matches `[memory: <id>]` here, so `already_injected` tracking works
    /// with no hook change.
    ///
    /// One takeaway line per candidate. Uses the memory's `l0` (compact
    /// abstract) as the takeaway if present; falls back to a trimmed `l1`
    /// (short summary) if only that landed. Never inlines the full body —
    /// that would explode the hint block past what a reader will actually
    /// read.
    private static func formatHint(candidates: [Candidate]) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        lines.append("<!-- Sidecar · \(now) · judge=none · \(candidates.count) hint\(candidates.count == 1 ? "" : "s") -->")
        lines.append("## Possibly relevant")
        lines.append("")
        for c in candidates {
            let takeaway = (c.l0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? c.l0 : c.l1)
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? c.id
            let oneLine = takeaway
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            lines.append("- **\(oneLine)** — [memory: \(c.id)]")
        }
        lines.append("")
        lines.append("<!-- /end -->")
        return lines.joined(separator: "\n")
    }

    // MARK: - Write

    /// Persist the hint via a direct DB insert. Avoids another loopback HTTP
    /// hop through `/api/sidecar/hint/write` (which the hooks use) — that
    /// endpoint's validation (empty-content rejection, whitespace checks)
    /// isn't relevant here because this code is the only writer and we've
    /// already decided the content is worth writing.
    private static func writeHint(sessionId: String, content: String) async throws {
        guard let dbPool = SonataApp.sharedDbPool else {
            throw HandlerError.noDBPool
        }
        let now = nowMs()
        try await dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO sidecarHints (sessionId, content, writtenAtMs)
                VALUES (?, ?, ?)
            """, arguments: [sessionId, content, now])
        }
    }

    // MARK: - Errors

    enum HandlerError: Error, CustomStringConvertible {
        case recallFailed(String)
        case noDBPool

        var description: String {
            switch self {
            case .recallFailed(let msg): return "mem_recall failed: \(msg)"
            case .noDBPool:              return "SonataApp.sharedDbPool is nil at hint write"
            }
        }
    }
}
