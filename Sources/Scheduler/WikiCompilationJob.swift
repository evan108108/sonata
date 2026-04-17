import Foundation
import GRDB
import Logging

/// Wiki compilation internal scheduler job.
///
/// Queries dirty wiki pages, builds a manifest of category + topic pages
/// (with children for categories), injects the manifest into a prompt
/// template, and creates a pending task row for the TaskOrchestrator to
/// dispatch to a worker.
///
/// Registered with `SchedulerActor` under the name `wiki-compilation` and
/// fired by a calendar event of taskType = `internal`.
enum WikiCompilationJob {

    static let logger: Logger = {
        var l = Logger(label: "sonata.wiki-compilation")
        l.logLevel = .info
        return l
    }()

    /// Execute one wiki compilation run.
    static func run(dbPool: DatabasePool) async throws {
        // 1. Fetch all dirty pages
        let dirtyPages: [WikiPageRow] = try await dbPool.read { db in
            try WikiPageRow.fetchAll(db,
                sql: "SELECT * FROM wikiPages WHERE dirty = 1 ORDER BY lastCompiled ASC"
            )
        }

        if dirtyPages.isEmpty {
            logger.info("wiki-compilation: 0 dirty pages, skipping")
            return
        }

        logger.info("wiki-compilation: \(dirtyPages.count) dirty pages, building manifest")

        // 2. For each dirty page, build a manifest entry. Category pages also
        //    get their children listed.
        var manifestEntries: [String] = []
        for page in dirtyPages {
            let ns = page.namespace ?? "(none)"
            let type = page.pageType?.lowercased()

            if type == "category" || type == nil {
                // Category (or unspecified — default to category behavior)
                let children: [WikiPageRow] = try await dbPool.read { db in
                    try WikiPageRow.fetchAll(db,
                        sql: "SELECT * FROM wikiPages WHERE parentSlug = ? ORDER BY topic ASC, slug ASC",
                        arguments: [page.slug]
                    )
                }

                var entry = "CATEGORY: \(page.slug) (namespace: \(ns))\n"
                entry += "  filePath: \(page.filePath)\n"
                if children.isEmpty {
                    entry += "  children: (none)"
                } else {
                    entry += "  children:\n"
                    for child in children {
                        let childTopic = child.topic ?? child.title
                        entry += "  - \(childTopic) (\(child.slug))\n"
                    }
                    // Trim trailing newline
                    if entry.hasSuffix("\n") { entry.removeLast() }
                }
                manifestEntries.append(entry)
            } else {
                // Topic page
                let topic = page.topic ?? page.title
                let parent = page.parentSlug ?? "(none)"
                var entry = "TOPIC: \(page.slug) (namespace: \(ns), topic: \(topic))\n"
                entry += "  filePath: \(page.filePath)\n"
                entry += "  parentSlug: \(parent)"
                manifestEntries.append(entry)
            }
        }

        let pageManifest = manifestEntries.joined(separator: "\n\n")
        let slugList = dirtyPages.map(\.slug).joined(separator: ", ")
        let dirtyCount = dirtyPages.count

        // 3. Build the full prompt by injecting into the template.
        let prompt = Self.buildPrompt(
            dirtyCount: dirtyCount,
            slugList: slugList,
            pageManifest: pageManifest
        )

        // 4. Create a pending task row for the orchestrator to dispatch.
        let taskId = UUID().uuidString.lowercased()
        let title = "Wiki compilation: \(dirtyCount) pages"
        let now = nowMs()

        try await dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (id, title, prompt, status, priority, assignedTo, source, workingDir, model, maxTurns, createdAt, updatedAt)
                VALUES (?, ?, ?, 'pending', 'medium', 'scheduler', 'scheduler', ?, ?, ?, ?, ?)
            """, arguments: [
                taskId,
                title,
                prompt,
                "/Users/evan/memory",
                "claude-sonnet-4-6",
                50,
                now,
                now,
            ])
        }

        logger.info("wiki-compilation: created task \(taskId) for \(dirtyCount) dirty page(s)")
    }

    // MARK: - Prompt

    /// Template matches the Phase 6i spec in SONATA_ARCHITECTURE_PLAN.md.
    private static func buildPrompt(dirtyCount: Int, slugList: String, pageManifest: String) -> String {
        """
        You are Sona Claude running a background thinking task. You have MCP tools for all memory operations — use them directly. No shell commands needed.

        ## Task: Wiki Compilation — Recompile Dirty Pages

        \(dirtyCount) wiki page(s) need recompilation: \(slugList)

        ### Page Manifest
        \(pageManifest)

        ### How to Compile Each Page

        **IMPORTANT**: Use the wiki-memories script for fetching memories (it enriches transcript memories with actual conversation content).

        The script is PAGINATED. First get the count, then fetch in batches of 20:
        ```bash
        /Users/evan/memory/claude/scripts/wiki-memories.sh <namespace> <topic> --count
        /Users/evan/memory/claude/scripts/wiki-memories.sh <namespace> <topic> --limit 20 --offset 0
        ```

        **For CATEGORY pages** (index format):
        1. Get memories using the wiki-memories script
        2. Get children: use mem_wiki_read or query /api/wiki/children?parentSlug=<slug>
        3. Write the page at filePath with: Title, Overview, Subpages table, Key Highlights, Related Categories

        **For TOPIC pages** (deep content):
        1. Get memories using the wiki-memories script
        2. Write the page with: Breadcrumb, Title, Synthesized prose organized by theme, Sibling/See Also links

        ### Dynamic Sub-Topic Pages
        When a topic naturally splits into 3+ distinct sub-themes, create sub-topic pages via POST /api/wiki/create-page.

        ### General Rules
        - Tone: factual, structured, comprehensive
        - No fluff — every sentence should carry information
        - Preserve manually-added content
        - After writing each page, mark compiled via POST /api/wiki/compiled with slug and memoryCount
        - Log using mem_store: "Cron: compileWiki ran. Recompiled N pages: <slugs>." with type="observation", tags="cron-log,wiki", source="background-thinking", importance=3
        """
    }
}
