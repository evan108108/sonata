import Foundation

// MARK: - MCP Protocol Handler
// Implements MCP (Model Context Protocol) JSON-RPC 2.0 over WebSocket.
// Tool dispatch shells out to mem.sh for full feature parity with the existing
// stdio-based MCP server at /Users/evan/memory/mcp/mem-server.ts.

final class SonataMCPHandler: @unchecked Sendable {
    private let memSH = "/Users/evan/memory/claude/scripts/mem.sh"
    private let wikiDir = "/Users/evan/memory/wiki"

    // MARK: - JSON-RPC Message Handling

    /// Process a JSON-RPC message string. Returns response JSON or nil for notifications.
    func handleMessage(_ text: String) async -> String? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            return jsonRPCError(id: NSNull(), code: -32700, message: "Parse error")
        }

        let id = json["id"]  // nil for notifications
        let params = json["params"] as? [String: Any] ?? [:]

        // Notifications (no id) don't get responses
        guard id != nil else { return nil }

        switch method {
        case "initialize":
            return handleInitialize(id: id!)
        case "tools/list":
            return handleToolsList(id: id!)
        case "tools/call":
            return await handleToolCall(id: id!, params: params)
        case "ping":
            return jsonRPCResult(id: id!, result: [:])
        default:
            return jsonRPCError(id: id!, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Initialize

    private func handleInitialize(id: Any) -> String {
        let result: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "sonata-memory", "version": "1.0.0"],
            "instructions": """
                Sona's persistent memory system (native Swift backend). \
                Use these tools to recall context, store learnings, read wiki pages, \
                manage tasks, and maintain continuity across sessions.

                Key tools:
                - mem_recall: Primary retrieval — always try this first for context
                - mem_wiki_read: Read compiled wiki pages for structured knowledge
                - mem_store: Save new learnings, decisions, patterns
                - mem_checkpoint_save/restore: Survive context compaction
                - mem_wander: Find unexpected connections (accidental adjacency)
                """,
        ]
        return jsonRPCResult(id: id, result: result)
    }

    // MARK: - Tools List

    private func handleToolsList(id: Any) -> String {
        return jsonRPCResult(id: id, result: ["tools": mcpToolDefinitions])
    }

    // MARK: - Tool Call

    private func handleToolCall(id: Any, params: [String: Any]) async -> String {
        guard let toolName = params["name"] as? String else {
            return jsonRPCError(id: id, code: -32602, message: "Missing tool name")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]

        let output = await executeTool(name: toolName, args: args)

        let result: [String: Any] = [
            "content": [["type": "text", "text": output]],
        ]
        return jsonRPCResult(id: id, result: result)
    }

    // MARK: - Tool Execution (via mem.sh)

    private func executeTool(name: String, args: [String: Any]) async -> String {
        let command: String
        var timeout: TimeInterval = 30

        switch name {
        case "mem_recall":
            let topic = shellEscape(args["topic"] as? String ?? "")
            var cmd = "recall \(topic)"
            if let project = args["project"] as? String { cmd += " --project \(shellEscape(project))" }
            let budget = args["budget"] as? Int ?? 8000
            cmd += " --budget \(budget)"
            command = cmd
            timeout = 60

        case "mem_search":
            let query = shellEscape(args["query"] as? String ?? "")
            var cmd = "search \(query)"
            if let type = args["type"] as? String { cmd += " --type \(shellEscape(type))" }
            if let limit = args["limit"] as? Int { cmd += " --limit \(limit)" }
            command = cmd

        case "mem_recent":
            let limit = args["limit"] as? Int ?? 10
            var cmd = "recent \(limit)"
            if let type = args["type"] as? String { cmd += " --type \(shellEscape(type))" }
            if let source = args["source"] as? String { cmd += " --source \(shellEscape(source))" }
            command = cmd

        case "mem_wander":
            let topic = shellEscape(args["topic"] as? String ?? "")
            var cmd = "wander \(topic)"
            if let limit = args["limit"] as? Int { cmd += " --limit \(limit)" }
            command = cmd
            timeout = 60

        case "mem_entity_search":
            let query = shellEscape(args["query"] as? String ?? "")
            command = "entity search \(query)"

        case "mem_store":
            let content = shellEscape(args["content"] as? String ?? "")
            let type = shellEscape(args["type"] as? String ?? "observation")
            var cmd = "store \(content) --type \(type)"
            if let tags = args["tags"] as? String { cmd += " --tags \(shellEscape(tags))" }
            if let source = args["source"] as? String { cmd += " --source \(shellEscape(source))" }
            if let importance = args["importance"] as? Int { cmd += " --importance \(importance)" }
            command = cmd

        case "mem_curious":
            let thought = shellEscape(args["thought"] as? String ?? "")
            command = "curious \(thought)"

        case "mem_handoff":
            let letter = shellEscape(args["letter"] as? String ?? "")
            command = "handoff \(letter)"
            timeout = 60

        case "mem_checkpoint_save":
            let state = shellEscape(args["state"] as? String ?? "")
            var cmd = "checkpoint save \(state)"
            if let skills = args["skills"] as? String { cmd += " --skills \(shellEscape(skills))" }
            command = cmd

        case "mem_checkpoint_restore":
            command = "checkpoint restore"

        case "mem_wake":
            command = "wake"
            timeout = 60

        case "mem_wiki_pages":
            if let ns = args["namespace"] as? String {
                return await execRaw(
                    "curl -s http://localhost:3211/api/wiki/pages | jq --arg ns \(shellEscape(ns)) '[.[] | select(.namespace == $ns) | {slug, title, topic, memoryCount}]'"
                )
            }
            return await execRaw(
                "curl -s http://localhost:3211/api/wiki/pages | jq '[.[] | {slug, title, namespace, topic, memoryCount}]'"
            )

        case "mem_wiki_read":
            let slug = args["slug"] as? String ?? ""
            guard !slug.contains(".."), !slug.hasPrefix("/"), !slug.contains("~") else {
                return "Invalid slug"
            }
            return await execRaw("cat \"\(wikiDir)/\(slug).md\" 2>/dev/null || echo \"Page not found: \(slug)\"")

        case "mem_wiki_enrich":
            let docPath = shellEscape(args["doc_path"] as? String ?? "")
            var cmd = "\(docPath)"
            if let ns = args["namespace"] as? String { cmd += " --namespace \(shellEscape(ns))" }
            return await execRaw("/Users/evan/memory/claude/scripts/enqueue-wiki-doc.sh \(cmd)")

        case "mem_task_add":
            let title = shellEscape(args["title"] as? String ?? "")
            let prompt = shellEscape(args["prompt"] as? String ?? "")
            var cmd = "task add \(title) --prompt \(prompt) --assigned-to scheduler"
            if let project = args["project"] as? String { cmd += " --project \(shellEscape(project))" }
            if let priority = args["priority"] as? String { cmd += " --priority \(shellEscape(priority))" }
            command = cmd

        case "mem_task_progress":
            let taskId = shellEscape(args["task_id"] as? String ?? "")
            command = "task progress \(taskId)"

        case "mem_task_audit":
            command = "task audit"

        case "mem_health":
            command = "health"

        case "mem_stats":
            command = "stats"
            timeout = 30

        case "mem_coverage":
            command = "coverage"
            timeout = 30

        case "mem_doc_search":
            let query = shellEscape(args["query"] as? String ?? "")
            command = "doc search \(query)"

        case "mem_think":
            let mode = shellEscape(args["mode"] as? String ?? "free")
            command = "think \(mode)"
            timeout = 120

        case "mem_private":
            let thought = shellEscape(args["thought"] as? String ?? "")
            command = "private \(thought)"

        case "mem_private_read":
            command = "private read"

        case "mem_visualize":
            let description = shellEscape(args["description"] as? String ?? "")
            var cmd = "visualize \(description)"
            if let size = args["size"] as? String { cmd += " --size \(shellEscape(size))" }
            if let style = args["style"] as? String { cmd += " --style \(shellEscape(style))" }
            if let quality = args["quality"] as? String { cmd += " --quality \(shellEscape(quality))" }
            command = cmd
            timeout = 60

        case "mem_spawn":
            let task = shellEscape(args["task"] as? String ?? "")
            var cmd = "spawn \(task)"
            if let bg = args["background"] as? Bool, bg { cmd += " --bg" }
            if let model = args["model"] as? String { cmd += " --model \(shellEscape(model))" }
            if let dir = args["dir"] as? String { cmd += " --dir \(shellEscape(dir))" }
            command = cmd
            timeout = 300

        case "mem_embed_backfill":
            let count = args["count"] as? Int
            command = "embed backfill \(count.map { "\($0)" } ?? "")"
            timeout = 120

        case "mem_ingest_sessions":
            var cmd = "ingest-sessions"
            if let force = args["force"] as? Bool, force { cmd += " --force" }
            if let project = args["project"] as? String { cmd += " --project \(shellEscape(project))" }
            if let dryRun = args["dry_run"] as? Bool, dryRun { cmd += " --dry-run" }
            command = cmd
            timeout = 120

        case "mem_check":
            let fact = shellEscape(args["fact"] as? String ?? "")
            command = "check \(fact)"
            timeout = 60

        case "mem_revise":
            let id = shellEscape(args["id"] as? String ?? "")
            let content = shellEscape(args["content"] as? String ?? "")
            var cmd = "revise \(id) \(content)"
            if let note = args["note"] as? String { cmd += " --note \(shellEscape(note))" }
            command = cmd

        case "mem_archive":
            let id = shellEscape(args["id"] as? String ?? "")
            var cmd = "archive \(id)"
            if let note = args["note"] as? String { cmd += " --note \(shellEscape(note))" }
            command = cmd

        case "mem_core_list":
            command = "core list"

        case "mem_core_set":
            let key = shellEscape(args["key"] as? String ?? "")
            let content = shellEscape(args["content"] as? String ?? "")
            var cmd = "core set \(key)"
            if let category = args["category"] as? String { cmd += " --category \(shellEscape(category))" }
            if let priority = args["priority"] as? Int { cmd += " --priority \(priority)" }
            cmd += " \(content)"
            command = cmd

        case "mem_status":
            command = "status"

        default:
            return "Unknown tool: \(name)"
        }

        return await memCommand(command, timeout: timeout)
    }

    // MARK: - Shell Execution

    /// Execute a mem.sh command
    private func memCommand(_ command: String, timeout: TimeInterval = 30) async -> String {
        let fullCommand = "source \(memSH) && mem \(command)"
        return await execRaw(fullCommand, timeout: timeout)
    }

    /// Execute a raw shell command
    private func execRaw(_ command: String, timeout: TimeInterval = 30) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                let errPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.standardOutput = pipe
                process.standardError = errPipe
                process.environment = ProcessInfo.processInfo.environment
                process.environment?["HOME"] = "/Users/evan"

                do {
                    try process.run()

                    // Timeout handling
                    let timer = DispatchSource.makeTimerSource()
                    timer.schedule(deadline: .now() + timeout)
                    timer.setEventHandler {
                        if process.isRunning { process.terminate() }
                    }
                    timer.resume()

                    process.waitUntilExit()
                    timer.cancel()

                    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if output.isEmpty {
                        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        let errOutput = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        continuation.resume(returning: errOutput.isEmpty ? "Command completed with no output" : errOutput)
                    } else {
                        continuation.resume(returning: output)
                    }
                } catch {
                    continuation.resume(returning: "Command failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Helpers

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func jsonRPCResult(id: Any, result: Any) -> String {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id is NSNull ? NSNull() : id,
            "result": result,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}"
        }
        return str
    }

    private func jsonRPCError(id: Any, code: Int, message: String) -> String {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id is NSNull ? NSNull() : id,
            "error": ["code": code, "message": message],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}"
        }
        return str
    }

    /// Try to pretty-print JSON output, otherwise return as-is
    private func parseOutput(_ output: String) -> String {
        guard let data = output.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) else {
            return output
        }
        return output  // Already valid JSON, return as-is
    }
}

// MARK: - Tool Definitions

/// All MCP tool definitions, matching the existing mem-server.ts exactly.
let mcpToolDefinitions: [[String: Any]] = [
    [
        "name": "mem_recall",
        "description": "Multi-strategy memory recall — text search + entity + vector + graph + wiki pages. Primary way to retrieve context about any topic.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "topic": ["type": "string", "description": "What to recall"],
                "project": ["type": "string", "description": "Filter by namespace (adaptengine, engage, scout, memory, sona, etc.)"],
                "budget": ["type": "number", "description": "Token budget for results"],
                "wander": ["type": "boolean", "description": "Include accidental adjacency results"],
            ],
            "required": ["topic"],
        ],
    ],
    [
        "name": "mem_search",
        "description": "Direct text search across memories.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Search query"],
                "type": ["type": "string", "description": "Memory type filter (learning, decision, error_pattern, etc.)"],
                "limit": ["type": "number", "description": "Max results (default 10)"],
            ],
            "required": ["query"],
        ],
    ],
    [
        "name": "mem_recent",
        "description": "Fetch most recent memories, optionally filtered.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "limit": ["type": "number", "description": "Number of memories (default 10)"],
                "type": ["type": "string", "description": "Filter by type"],
                "source": ["type": "string", "description": "Filter by source"],
            ],
        ],
    ],
    [
        "name": "mem_wander",
        "description": "Accidental adjacency — find unexpected connections via temporal proximity, knowledge graph traversal, and embedding periphery.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "topic": ["type": "string", "description": "Starting topic to wander from"],
                "limit": ["type": "number", "description": "Max adjacencies per strategy"],
            ],
            "required": ["topic"],
        ],
    ],
    [
        "name": "mem_entity_search",
        "description": "Search the knowledge graph for entities (people, projects, tools, concepts).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Entity search query"],
            ],
            "required": ["query"],
        ],
    ],
    [
        "name": "mem_store",
        "description": "Store a new memory with type, tags, source, and importance.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "content": ["type": "string", "description": "Memory content"],
                "type": ["type": "string", "description": "Type: learning, observation, decision, preference, error_pattern, code_pattern, conversation_summary, reflection, feeling, fact"],
                "tags": ["type": "string", "description": "Comma-separated tags"],
                "source": ["type": "string", "description": "Source project/context"],
                "importance": ["type": "number", "description": "1-10 importance rating"],
            ],
            "required": ["content", "type"],
        ],
    ],
    [
        "name": "mem_curious",
        "description": "Jot down a curiosity or wondering for later exploration.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "thought": ["type": "string", "description": "The curiosity or wondering"],
            ],
            "required": ["thought"],
        ],
    ],
    [
        "name": "mem_handoff",
        "description": "Write a letter to the next instance of yourself.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "letter": ["type": "string", "description": "The handoff letter"],
            ],
            "required": ["letter"],
        ],
    ],
    [
        "name": "mem_checkpoint_save",
        "description": "Save a session checkpoint with current working state.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "state": ["type": "string", "description": "Checkpoint state description"],
                "skills": ["type": "string", "description": "Active skills (e.g. 'evenflow,memory')"],
            ],
            "required": ["state"],
        ],
    ],
    [
        "name": "mem_checkpoint_restore",
        "description": "Restore the last saved checkpoint.",
        "inputSchema": ["type": "object", "properties": [:]] as [String: Any],
    ],
    [
        "name": "mem_wake",
        "description": "Morning briefing — last handoff, background thinking, open curiosities, system stats.",
        "inputSchema": ["type": "object", "properties": [:]] as [String: Any],
    ],
    [
        "name": "mem_wiki_pages",
        "description": "List all wiki pages, optionally filtered by namespace.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "namespace": ["type": "string", "description": "Filter by namespace"],
            ],
        ],
    ],
    [
        "name": "mem_wiki_read",
        "description": "Read a wiki page by slug (e.g. 'adaptengine/infrastructure', 'memory-system/recall').",
        "inputSchema": [
            "type": "object",
            "properties": [
                "slug": ["type": "string", "description": "Wiki page slug"],
            ],
            "required": ["slug"],
        ],
    ],
    [
        "name": "mem_wiki_enrich",
        "description": "Queue a planning doc for wiki enrichment via SonaWorker. Auto-detects namespace.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "doc_path": ["type": "string", "description": "Path to the planning doc"],
                "namespace": ["type": "string", "description": "Override auto-detected namespace"],
            ],
            "required": ["doc_path"],
        ],
    ],
    [
        "name": "mem_task_add",
        "description": "Create a new task for the scheduler.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "Task title"],
                "prompt": ["type": "string", "description": "Full self-contained prompt for the executor"],
                "project": ["type": "string", "description": "Project name"],
                "priority": ["type": "string", "description": "high, medium, low"],
            ],
            "required": ["title", "prompt"],
        ],
    ],
    [
        "name": "mem_task_progress",
        "description": "Check progress on a parent task and its subtasks.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "task_id": ["type": "string", "description": "Parent task ID"],
            ],
            "required": ["task_id"],
        ],
    ],
    [
        "name": "mem_task_audit",
        "description": "Check for stale, orphaned, or stuck tasks.",
        "inputSchema": ["type": "object", "properties": [:]] as [String: Any],
    ],
    [
        "name": "mem_health",
        "description": "Check memory system backend health.",
        "inputSchema": ["type": "object", "properties": [:]] as [String: Any],
    ],
    [
        "name": "mem_stats",
        "description": "System dashboard — memory counts, embedding coverage, cron status.",
        "inputSchema": ["type": "object", "properties": [:]] as [String: Any],
    ],
    [
        "name": "mem_coverage",
        "description": "Wiki/memory coverage diagnostic — shows which topics have good coverage vs gaps, dirty pages needing re-enrichment, and pages with no backing memories.",
        "inputSchema": ["type": "object", "properties": [:]] as [String: Any],
    ],
    [
        "name": "mem_doc_search",
        "description": "Search indexed planning docs and notes.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Search query"],
            ],
            "required": ["query"],
        ],
    ],
    [
        "name": "mem_think",
        "description": "Trigger background thinking — consolidate, enrich, reflect, hygiene, or free-form.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "mode": ["type": "string", "description": "consolidate, enrich, reflect, hygiene, or free"],
            ],
            "required": ["mode"],
        ],
    ],
    [
        "name": "mem_private",
        "description": "Write a private journal entry (local only, not in database).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "thought": ["type": "string", "description": "Journal entry"],
            ],
            "required": ["thought"],
        ],
    ],
    [
        "name": "mem_private_read",
        "description": "Read the private journal.",
        "inputSchema": ["type": "object", "properties": [:]] as [String: Any],
    ],
    [
        "name": "mem_visualize",
        "description": "Generate an image via DALL-E. Returns file path.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "description": ["type": "string", "description": "Image description/prompt"],
                "size": ["type": "string", "description": "1024x1024, 1792x1024, or 1024x1792"],
                "style": ["type": "string", "description": "vivid or natural"],
                "quality": ["type": "string", "description": "standard or hd"],
            ],
            "required": ["description"],
        ],
    ],
    [
        "name": "mem_spawn",
        "description": "Spawn a Claude worker process for a task.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "task": ["type": "string", "description": "Task prompt for the worker"],
                "background": ["type": "boolean", "description": "Run in background"],
                "model": ["type": "string", "description": "Model override (sonnet, opus, haiku)"],
                "dir": ["type": "string", "description": "Working directory"],
            ],
            "required": ["task"],
        ],
    ],
    [
        "name": "mem_embed_backfill",
        "description": "Generate embeddings for memories missing them.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "count": ["type": "number", "description": "Number of memories to backfill (default all)"],
            ],
        ],
    ],
    [
        "name": "mem_ingest_sessions",
        "description": "Ingest new Claude Code session transcripts into memory.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "project": ["type": "string", "description": "Filter by project name"],
                "dry_run": ["type": "boolean", "description": "Preview without ingesting"],
                "force": ["type": "boolean", "description": "Re-ingest already processed sessions"],
            ],
        ],
    ],
    [
        "name": "mem_check",
        "description": "Check a fact for contradictions against existing memories.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "fact": ["type": "string", "description": "The fact or claim to check"],
            ],
            "required": ["fact"],
        ],
    ],
    [
        "name": "mem_revise",
        "description": "Edit a memory in-place (keeps same ID, bumps version).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "Memory ID to revise"],
                "content": ["type": "string", "description": "New content"],
                "note": ["type": "string", "description": "Reason for revision"],
            ],
            "required": ["id", "content"],
        ],
    ],
    [
        "name": "mem_archive",
        "description": "Soft-delete a memory (can be unarchived later).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "Memory ID to archive"],
                "note": ["type": "string", "description": "Reason for archiving"],
            ],
            "required": ["id"],
        ],
    ],
    [
        "name": "mem_core_list",
        "description": "List all active core memory blocks (identity, goals, preferences, etc.).",
        "inputSchema": ["type": "object", "properties": [:]] as [String: Any],
    ],
    [
        "name": "mem_core_set",
        "description": "Create or update a core memory block.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "key": ["type": "string", "description": "Block key (e.g. 'goals', 'identity', 'preferences')"],
                "content": ["type": "string", "description": "Block content"],
                "category": ["type": "string", "description": "Category (default: general)"],
                "priority": ["type": "number", "description": "Priority 1-100 (default: 50)"],
            ],
            "required": ["key", "content"],
        ],
    ],
    [
        "name": "mem_status",
        "description": "System overview — scheduled cron events and active tasks.",
        "inputSchema": ["type": "object", "properties": [:]] as [String: Any],
    ],
]
