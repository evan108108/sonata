import Foundation
import GRDB

// Powers the New Session sheet's "Resume previous…" picker. Lists historical
// Sona/Claude sessions from ~/.claude/projects/**/*.jsonl — optionally filtered
// by a transcript-content search via the Meili `sessions` index — and resolves
// each to the metadata the picker needs: working dir (required to relaunch
// `claude --resume` so it finds the transcript), a last-prompt label, recency,
// and whether the session's process is still alive (resuming a live session
// would fork the conversation, so the UI greys those out).

private struct SessionHistoryRow: Encodable {
    let sessionId: String
    let cwd: String
    let project: String
    let lastPrompt: String
    let firstPrompt: String
    let lastSeenMs: Int64
    let isLive: Bool
}

let sessionHistoryActions: [SonataAction] = [
    SonataAction(
        name: "session_history",
        description: "List resumable historical sessions (optionally filtered by a transcript-content query) for the New Session resume picker.",
        group: "/api/sessions",
        path: "/history",
        method: .get,
        params: [
            ActionParam("query", .string, description: "Transcript-content search (Meili sessions index). Omit for most-recent-first."),
            ActionParam("limit", .integer, description: "Max sessions (default 25)"),
        ],
        mcpOnly: false,
        handler: { ctx in
            let limit = max(1, min(ctx.params.int("limit") ?? 25, 100))
            let query = ctx.params.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines)

            let liveIds = SessionHistoryScanner.liveSessionIds()

            // Candidate (sessionId, transcriptPath) pairs, ordered.
            var ordered: [(sessionId: String, path: String)]
            if let query, !query.isEmpty, let search = ctx.search {
                // Search mode: rank by transcript content, dedup chunks → sessionId.
                let hits = await search.searchSessions(query: query, limit: limit * 4)
                let pathIndex = SessionHistoryScanner.transcriptPathsBySessionId()
                var seen = Set<String>()
                ordered = []
                for hit in hits {
                    let sid = hit.fields["sessionId"] ?? hit.id
                    guard seen.insert(sid).inserted, let path = pathIndex[sid] else { continue }
                    ordered.append((sid, path))
                    if ordered.count >= limit { break }
                }
            } else {
                // Browse mode: most-recently-modified transcripts first.
                ordered = SessionHistoryScanner.recentTranscripts(limit: limit)
            }

            let rows: [SessionHistoryRow] = ordered.compactMap { item in
                guard let meta = SessionHistoryScanner.resolve(sessionId: item.sessionId, path: item.path)
                else { return nil }
                return SessionHistoryRow(
                    sessionId: item.sessionId,
                    cwd: meta.cwd,
                    project: meta.project,
                    lastPrompt: meta.lastPrompt,
                    firstPrompt: meta.firstPrompt,
                    lastSeenMs: meta.lastSeenMs,
                    isLive: liveIds.contains(item.sessionId)
                )
            }
            return rows
        }
    ),
]

// MARK: - Scanner

enum SessionHistoryScanner {
    private static var projectsRoot: String { NSHomeDirectory() + "/.claude/projects" }
    private static var sessionsDir: String { NSHomeDirectory() + "/.claude/sessions" }

    /// sessionIds whose backing claude process is currently alive, read from
    /// ~/.claude/sessions/<pid>.json (same source AllSessionsViewModel uses).
    static func liveSessionIds() -> Set<String> {
        var out = Set<String>()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return out }
        for entry in entries where entry.hasSuffix(".json") {
            guard let pid = Int(entry.dropLast(".json".count)), kill(pid_t(pid), 0) == 0 else { continue }
            let path = sessionsDir + "/" + entry
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = json["sessionId"] as? String else { continue }
            out.insert(sid)
        }
        return out
    }

    /// Most-recently-modified `.jsonl` transcripts, newest first, capped.
    static func recentTranscripts(limit: Int) -> [(sessionId: String, path: String)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: projectsRoot) else { return [] }
        var files: [(path: String, mtime: Date)] = []
        while let rel = enumerator.nextObject() as? String {
            guard rel.hasSuffix(".jsonl") else { continue }
            let full = projectsRoot + "/" + rel
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            files.append((full, mtime))
        }
        return files.sorted { $0.mtime > $1.mtime }
            .prefix(limit)
            .map { (sessionId: ($0.path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: ""),
                    path: $0.path) }
    }

    /// sessionId → transcript path, for resolving search hits back to files.
    static func transcriptPathsBySessionId() -> [String: String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: projectsRoot) else { return [:] }
        var map: [String: String] = [:]
        while let rel = enumerator.nextObject() as? String {
            guard rel.hasSuffix(".jsonl") else { continue }
            let sid = (rel as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
            map[sid] = projectsRoot + "/" + rel
        }
        return map
    }

    struct Meta { let cwd: String; let project: String; let firstPrompt: String; let lastPrompt: String; let lastSeenMs: Int64 }

    /// Resolve cwd (required for resume), first/last prompt labels, and recency
    /// from a transcript. Reads a 64KB head (cwd + first prompt appear early)
    /// and a 256KB tail (last prompt). Returns nil when the file has no cwd or
    /// no substantive user message (e.g. an empty/aborted session — not
    /// resumable in a useful way).
    static func resolve(sessionId: String, path: String) -> Meta? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int) ?? 0
        guard size > 0 else { return nil }
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)
            ?? Date(timeIntervalSince1970: 0)

        let headData = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        var cwd: String?
        var firstPrompt: String?
        for line in headData.split(separator: 0x0a) {
            let ld = Data(line)
            guard let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any] else { continue }
            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            if firstPrompt == nil, let p = userPromptText(obj) { firstPrompt = p }
            if cwd != nil && firstPrompt != nil { break }
        }
        guard let resolvedCwd = cwd else { return nil }

        // Tail for last prompt.
        var lastPrompt = firstPrompt ?? ""
        let tailBytes = min(256 * 1024, size)
        if let _ = try? handle.seek(toOffset: UInt64(size - tailBytes)) {
            let tailData = (try? handle.readToEnd()) ?? Data()
            for line in tailData.split(separator: 0x0a).reversed() {
                if let p = userPromptText((try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]) ?? nil) {
                    lastPrompt = p
                    break
                }
            }
        }
        guard !lastPrompt.isEmpty else { return nil }

        let project = (resolvedCwd as NSString).lastPathComponent
        return Meta(
            cwd: resolvedCwd,
            project: project,
            firstPrompt: String((firstPrompt ?? lastPrompt).prefix(200)),
            lastPrompt: String(lastPrompt.prefix(200)),
            lastSeenMs: Int64(mtime.timeIntervalSince1970 * 1000)
        )
    }

    /// Substantive user prompt text from a transcript line, or nil for
    /// non-user lines, tool results, and harness wrappers. Mirrors the filter
    /// in AllSessionsViewModel.extractUserPrompt.
    private static func userPromptText(_ obj: [String: Any]?) -> String? {
        guard let obj, (obj["type"] as? String) == "user",
              let msg = obj["message"] as? [String: Any] else { return nil }
        var text: String?
        if let s = msg["content"] as? String {
            text = s
        } else if let arr = msg["content"] as? [[String: Any]] {
            for block in arr where (block["type"] as? String) == "text" {
                if let t = block["text"] as? String, !t.isEmpty { text = t; break }
            }
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        let wrappers = ["<system-reminder>", "<local-command-caveat>", "<local-command-stdout>",
                        "<command-name>", "<command-message>", "<command-args>",
                        "<channel source=", "<task-notification>", "This session is being continued"]
        for w in wrappers where t.hasPrefix(w) { return nil }
        return t
    }
}
