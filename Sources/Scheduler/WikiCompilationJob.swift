import Foundation
import GRDB
import Logging

/// Wiki compilation internal scheduler job.
///
/// Queries dirty wiki pages, builds a manifest of category + topic pages
/// (with children for categories), injects the manifest into a prompt
/// template, and creates a pending task row for the TaskDispatcher to
/// dispatch to a worker.
///
/// Registered with `SchedulerActor` under the name `wiki-compilation` and
/// fired by a calendar event of taskType = `internal`.
enum WikiCompilationJob {

    /// Stable `tasks.sourceRef` for every run of this job.
    ///
    /// Unlike spawn-claude jobs (whose task carries the firing calendarEvent's id),
    /// this internal job creates its own task row and has no jobId in hand — so it
    /// tags runs with a fixed ref instead. That ref is what lets a new run coalesce
    /// away an older undispatched one.
    static let scheduledJobRef = "wiki-compilation"

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

        logger.info("wiki-compilation: \(dirtyPages.count) dirty pages, measuring before manifest")

        // 2. Measure every dirty page and drop the ones the generic recipe would
        //    destroy rather than compile. See WikiCompileGuard for why this is a
        //    pre-dispatch check and not a note in the prompt.
        let candidates = try await Self.measure(dirtyPages, dbPool: dbPool)
        let (compilable, preserved) = WikiCompileGuard.partition(candidates)

        // Preserved pages are still *handled* — they just get the dirty flag
        // cleared in place instead of being rewritten. Leaving them dirty would
        // re-dispatch them every run forever.
        if !preserved.isEmpty {
            let now = nowMs()
            try await dbPool.write { db in
                for (candidate, _) in preserved {
                    try db.execute(sql: """
                        UPDATE wikiPages
                        SET dirty = 0, lastCompiled = ?, updatedAt = ?
                        WHERE slug = ?
                    """, arguments: [now, now, candidate.slug])
                }
            }
            for (candidate, reason) in preserved {
                logger.info("wiki-compilation: preserved \(candidate.slug) — \(reason)")
            }
        }

        if compilable.isEmpty {
            logger.info("wiki-compilation: all \(dirtyPages.count) dirty page(s) preserved, no task dispatched")
            return
        }

        let compilableSlugs = Set(compilable.map(\.slug))
        let pagesToCompile = dirtyPages.filter { compilableSlugs.contains($0.slug) }
        let measurementBySlug = Dictionary(uniqueKeysWithValues: compilable.map { ($0.slug, $0) })

        logger.info("wiki-compilation: \(pagesToCompile.count) compilable, \(preserved.count) preserved, building manifest")

        // 3. For each compilable page, build a manifest entry. Category pages
        //    also get their children listed.
        var manifestEntries: [String] = []
        for page in pagesToCompile {
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
                entry += "  backingMemories: \(measurementBySlug[page.slug]?.backingMemoryCount ?? 0) (already measured — this page passed the pre-dispatch guard)\n"
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
                entry += "  backingMemories: \(measurementBySlug[page.slug]?.backingMemoryCount ?? 0) (already measured — this page passed the pre-dispatch guard)\n"
                entry += "  parentSlug: \(parent)"
                manifestEntries.append(entry)
            }
        }

        let pageManifest = manifestEntries.joined(separator: "\n\n")
        let slugList = pagesToCompile.map(\.slug).joined(separator: ", ")
        let dirtyCount = pagesToCompile.count

        // 4. Build the full prompt by injecting into the template.
        let prompt = Self.buildPrompt(
            dirtyCount: dirtyCount,
            slugList: slugList,
            pageManifest: pageManifest
        )

        // 4. Create a pending task row for the dispatcher to dispatch.
        let taskId = UUID().uuidString.lowercased()
        let title = "Wiki compilation: \(dirtyCount) pages"
        let now = nowMs()

        try await dbPool.write { db in
            // Coalesce against any still-undispatched compilation. This job is the
            // sharpest case for it: the dirty-page manifest is snapshotted into the
            // PROMPT above, so a run that dispatches hours later rebuilds a page list
            // that has since moved — and can overwrite a peer's fresh compilation.
            // The manifest is only true at the moment it is built; if the previous
            // run never reached a worker, it is not a queued unit of work, it is a
            // stale photograph. Re-derive, don't replay.
            try db.execute(sql: """
                UPDATE tasks
                SET status = 'cancelled', lastError = ?, updatedAt = ?
                WHERE source = 'scheduler' AND sourceRef = ? AND status = 'pending'
            """, arguments: [
                "superseded: its dirty-page manifest was stale before it ever dispatched",
                now,
                Self.scheduledJobRef,
            ])

            try db.execute(sql: """
                INSERT INTO tasks (id, title, prompt, status, priority, assignedTo, source, sourceRef, workingDir, model, maxTurns, createdAt, updatedAt)
                VALUES (?, ?, ?, 'pending', 'medium', 'scheduler', 'scheduler', ?, ?, ?, ?, ?, ?)
            """, arguments: [
                taskId,
                title,
                prompt,
                Self.scheduledJobRef,
                "\(NSHomeDirectory())/memory",
                "claude-sonnet-4-6",
                50,
                now,
                now,
            ])
        }

        logger.info("wiki-compilation: created task \(taskId) for \(dirtyCount) dirty page(s)")
    }

    // MARK: - Measurement

    /// Measure each dirty page against the selector the recipe would actually
    /// use, so the guard rules run on numbers rather than on the manifest's own
    /// (demonstrably unreliable) topic and pageType fields.
    ///
    /// The selector mirrors `wiki_memories_all`: filter memories by the page's
    /// namespace, and additionally by topic when the page sets one.
    private static func measure(_ pages: [WikiPageRow], dbPool: DatabasePool) async throws -> [WikiCompileGuard.Candidate] {
        try await dbPool.read { db in
            try pages.map { page in
                var sql = "SELECT COUNT(*), MAX(createdAt) FROM memories WHERE project = ?"
                var args: [any DatabaseValueConvertible] = [page.namespace ?? ""]
                if let topic = page.topic, !topic.isEmpty {
                    sql += " AND topic = ?"
                    args.append(topic)
                }

                var count = 0
                var newest: Int64? = nil
                if let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(args)) {
                    count = row[0] ?? 0
                    newest = row[1]
                }

                return WikiCompileGuard.Candidate(
                    slug: page.slug,
                    namespace: page.namespace,
                    topic: page.topic,
                    filePath: page.filePath,
                    lastCompiled: page.lastCompiled,
                    backingMemoryCount: count,
                    newestBackingMemoryAt: newest,
                    // Filled in by partition(), which sees the whole run.
                    collidingSlugs: [],
                    hasPreserveMarker: WikiCompileGuard.hasPreserveMarker(atPath: page.filePath)
                )
            }
        }
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

        Use Sonata MCP tools directly — no shell scripts needed.

        **Fetch memories for a page** (namespace is the page's `namespace`, topic is the page's `topic` if set):
        - `wiki_memories_all` with `{namespace, topic?, limit?}` — returns every memory for the page
        - `mem_recall` with `{topic, filterTopic?, limit?, budget?}` — for richer synthesis with entities, relations, and related wiki pages

        **For CATEGORY pages** (index format):
        1. Fetch memories via `wiki_memories_all` (namespace only — no topic filter)
        2. Fetch children via `wiki_children` with `{parentSlug: <slug>}`
        3. Write the page at filePath with: Title, Overview, Subpages table, Key Highlights, Related Categories

        **For TOPIC pages** (deep content):
        1. Fetch memories via `wiki_memories_all` with `{namespace, topic}`
        2. Write the page with: Breadcrumb, Title, Synthesized prose organized by theme, Sibling/See Also links

        ### Dynamic Sub-Topic Pages
        When a topic naturally splits into 3+ distinct sub-themes, create sub-topic pages via `wiki_create` MCP tool with `{slug, title, filePath, namespace, pageType:"topic", parentSlug, topic}`.

        ### STOP RULE — do not shrink a page

        Every page in this manifest has already passed a pre-dispatch guard: it has
        backing memories, its memory selector is unambiguous, and at least one backing
        memory is newer than its last compile. You do NOT need to re-derive any of that
        — the counts above are measured, trust them.

        One check the guard cannot make for you, because it needs your draft: **compare
        the size of what you are about to write against the file already on disk.** If
        your replacement is dramatically smaller — under roughly half — you are about to
        destroy curated content that the memories never contained. When that happens:

        1. Do NOT write the file.
        2. Add `compile: preserve` to the page's YAML frontmatter (create the frontmatter
           block if the file has none) so no future run re-derives this.
        3. Mark it clean via `wiki_patch` with `{slug, dirty: false, lastCompiled: <now-ms>}`.
        4. Note it in your run summary.

        Appending to or extending an existing page is always safe. Replacing a large page
        with a small synthesis is the failure mode this rule exists to stop.

        ### General Rules
        - Tone: factual, structured, comprehensive
        - No fluff — every sentence should carry information
        - Preserve manually-added content
        - After writing each page, mark it compiled via `wiki_patch` MCP tool with `{slug, dirty: false, lastCompiled: <now-ms>, memoryCount: <count>}`
        - Log using `mem_store`: "Cron: compileWiki ran. Recompiled N pages: <slugs>." with type="observation", tags="cron-log,wiki", source="background-thinking", importance=3
        """
    }
}
