import Foundation
import GRDB
import Logging

/// MeiliSearch implementation of SearchService.
/// Manages a MeiliSearch subprocess on localhost:7711 with data at ~/.sonata/meili-data/.
actor MeiliSearchManager: SearchService {

    private var process: Process?
    private let port: Int = 7711
    private let logger: Logger
    private var masterKey: String = ""
    private let session = URLSession.shared
    /// Stashed so the first-run download path can build + backfill indexes itself
    /// once the binary lands (SonataApp's inline calls ran while Meili was down).
    private var dbPool: DatabasePool?

    private var baseURL: String { "http://127.0.0.1:\(port)" }

    private var dataDir: String {
        SonataInstance.dataDirectory + "/meili-data"
    }

    private var keyFile: String {
        SonataInstance.dataDirectory + "/meili-key"
    }

    private var docsDir: String {
        SonataInstance.dataDirectory + "/documents"
    }

    private var privateDir: String {
        SonataInstance.dataDirectory + "/private"
    }

    init() {
        var log = Logger(label: "sonata.meilisearch")
        log.logLevel = .info
        self.logger = log
    }

    // MARK: - Lifecycle

    func start(dbPool: DatabasePool? = nil) async {
        self.dbPool = dbPool

        // Load or generate master key
        if let existing = try? String(contentsOfFile: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            masterKey = existing
        } else {
            masterKey = UUID().uuidString
            try? masterKey.write(toFile: keyFile, atomically: true, encoding: .utf8)
        }

        // Create data directory
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)

        // Fast path: binary already present (bundle / Homebrew / prior download).
        // Launch synchronously so the caller's ensureIndexes()/backfill run in order.
        if let path = await BinaryProvisioner.shared.cachedPath(of: .meilisearch) {
            await launch(binaryPath: path)
            return
        }

        // Slow path (first run only): the ~122 MB binary isn't installed. Download
        // it in the background so we DON'T stall the HTTP server / services boot,
        // then launch and build + backfill the indexes ourselves — the caller's
        // inline ensureIndexes()/backfill already ran while Meili was down (no-ops).
        logger.info("MeiliSearch binary not present — downloading on first run; search unavailable until ready")
        Task {
            guard let path = await BinaryProvisioner.shared.provision(.meilisearch) else {
                logger.error("MeiliSearch provisioning failed — search will be unavailable")
                return
            }
            await self.launch(binaryPath: path)
            await self.firstRunIndexAndBackfill()
        }
    }

    /// Kill any orphan, launch the subprocess, wait for health. Shared by the
    /// cached-path and post-download paths.
    private func launch(binaryPath: String) async {
        // Kill any orphaned MeiliSearch process from a previous run
        killExistingMeiliSearch()

        // Launch subprocess — set cwd to data dir (app bundle cwd is read-only)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.currentDirectoryURL = URL(fileURLWithPath: dataDir)
        proc.arguments = [
            "--http-addr", "127.0.0.1:\(port)",
            "--db-path", dataDir,
            "--master-key", masterKey,
            "--no-analytics",
            "--env", "development"
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            process = proc
        } catch {
            logger.error("Failed to launch MeiliSearch: \(error)")
            return
        }

        // Check if process exited immediately
        try? await Task.sleep(nanoseconds: 500_000_000)
        if !proc.isRunning {
            logger.error("MeiliSearch exited immediately (code \(proc.terminationStatus))")
            process = nil
            return
        }

        // Wait for health check
        let healthy = await waitForHealthy(timeoutSeconds: 10)
        if healthy {
            logger.info("MeiliSearch started (PID \(proc.processIdentifier), port \(port))")
        } else {
            logger.error("MeiliSearch failed health check after 10s")
        }
    }

    /// First-run-after-download: build indexes and backfill content once Meili is
    /// actually up. Only reached on the download path; the normal boot does this
    /// via the caller right after `start()` returns.
    private func firstRunIndexAndBackfill() async {
        guard process != nil else { return }
        await ensureIndexes()
        if let pool = dbPool {
            await backfillWiki(dbPool: pool)
            await backfillArchive(dbPool: pool)
        }
        await backfillDocs()
    }

    func shutdown() {
        guard let proc = process, proc.isRunning else { return }
        logger.info("Shutting down MeiliSearch (PID \(proc.processIdentifier))")
        proc.terminate()
        process = nil
    }

    // MARK: - Health

    func isHealthy() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func waitForHealthy(timeoutSeconds: Int) async -> Bool {
        for i in 0..<(timeoutSeconds * 4) {
            if await isHealthy() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
            if i > 0 && i % 4 == 0 {
                logger.info("Waiting for MeiliSearch... (\(i / 4)s)")
            }
        }
        return false
    }

    // MARK: - Index Management

    func ensureIndexes() async {
        await createIndex(uid: "wiki", primaryKey: "slug")
        await createIndex(uid: "archive", primaryKey: "id")
        await createIndex(uid: "docs", primaryKey: "id")
        await createIndex(uid: "private", primaryKey: "id")
        await createIndex(uid: "emails", primaryKey: "id")
        await createIndex(uid: "sessions", primaryKey: "id")

        // Configure searchable attributes
        await updateSettings(index: "wiki", settings: [
            "searchableAttributes": ["content", "title", "originalSlug", "namespace"],
            "displayedAttributes": ["slug", "originalSlug", "title", "namespace", "filePath"]
        ])
        await updateSettings(index: "archive", settings: [
            "searchableAttributes": ["content", "type", "tags", "source", "project"],
            "displayedAttributes": ["id", "content", "type", "tags", "source", "importance", "project", "status", "created"]
        ])
        await updateSettings(index: "docs", settings: [
            "searchableAttributes": ["content", "title", "filename"],
            "displayedAttributes": ["id", "filename", "title", "filePath", "content"]
        ])
        await updateSettings(index: "private", settings: [
            "searchableAttributes": ["content", "title", "filename"],
            "displayedAttributes": ["id", "filename", "title", "filePath", "content"]
        ])
        await updateSettings(index: "emails", settings: [
            "searchableAttributes": ["subject", "body", "fromAddr", "toAddr"],
            "displayedAttributes": ["id", "subject", "body", "fromAddr", "toAddr", "threadId", "receivedAt"]
        ])
        await updateSettings(index: "sessions", settings: [
            "searchableAttributes": ["text", "project", "sessionId"],
            "displayedAttributes": ["id", "sessionId", "project", "chunk", "text", "mtimeMs"]
        ])
    }

    private func createIndex(uid: String, primaryKey: String) async {
        let body: [String: String] = ["uid": uid, "primaryKey": primaryKey]
        let _ = await post(path: "/indexes", body: body)
    }

    private func updateSettings(index: String, settings: [String: [String]]) async {
        let _ = await patch(path: "/indexes/\(index)/settings", body: settings)
    }

    // MARK: - Document Operations

    /// Encode a wiki slug for use as a MeiliSearch document ID (no slashes allowed)
    private func encodeSlug(_ slug: String) -> String {
        slug.replacingOccurrences(of: "/", with: "--")
    }

    /// Encode a relative filename for use as a MeiliSearch document ID.
    /// MeiliSearch IDs allow ONLY [A-Za-z0-9_-] (≤511 bytes); a doc with an
    /// invalid id makes Meili reject the WHOLE batch it's in, so a single
    /// space-bearing filename silently drops 50 docs (the 2026-06-17 docs
    /// gap: one "Issue 11 - ….md" poisoned its batch). `/`→`--` and `.`→`__`
    /// keep normal paths stable and reversible; the final pass maps any
    /// remaining disallowed char to `-` so EVERY filename yields a valid id.
    /// Normal filenames have no such chars, so their ids are unchanged (no
    /// re-index churn); only previously-broken names change — and those were
    /// never indexed anyway.
    private func encodeFilename(_ name: String) -> String {
        let base = name
            .replacingOccurrences(of: "/", with: "--")
            .replacingOccurrences(of: ".", with: "__")
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        let sanitized = String(base.map { allowed.contains($0) ? $0 : "-" })
        return String(sanitized.prefix(511))
    }

    func indexWikiPage(slug: String, title: String, content: String, namespace: String?, filePath: String) async {
        var doc: [String: String] = [
            "slug": encodeSlug(slug),
            "originalSlug": slug,
            "title": title,
            "content": content,
            "filePath": filePath
        ]
        if let ns = namespace { doc["namespace"] = ns }
        let _ = await post(path: "/indexes/wiki/documents", body: [doc])
    }

    func removeWikiPage(slug: String) async {
        let _ = await delete(path: "/indexes/wiki/documents/\(encodeSlug(slug))")
    }

    func indexDocFile(filename: String, title: String, content: String, filePath: String) async {
        let doc: [String: String] = [
            "id": encodeFilename(filename),
            "filename": filename,
            "title": title,
            "content": content,
            "filePath": filePath
        ]
        let _ = await post(path: "/indexes/docs/documents", body: [doc])
    }

    func removeDocFile(filename: String) async {
        let _ = await delete(path: "/indexes/docs/documents/\(encodeFilename(filename))")
    }

    func indexPrivateFile(filename: String, title: String, content: String, filePath: String) async {
        let doc: [String: String] = [
            "id": encodeFilename(filename),
            "filename": filename,
            "title": title,
            "content": content,
            "filePath": filePath
        ]
        let _ = await post(path: "/indexes/private/documents", body: [doc])
    }

    func removePrivateFile(filename: String) async {
        let _ = await delete(path: "/indexes/private/documents/\(encodeFilename(filename))")
    }

    func indexArchivedMemory(_ row: MemoryRow) async {
        let date = Date(timeIntervalSince1970: Double(row.createdAt) / 1000.0)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        var doc: [String: String] = [
            "id": row.id,
            "content": row.content,
            "type": row.type,
            "tags": row.tagsJSON,
            "importance": "\(Int(row.importance))",
            "status": row.status ?? "archived",
            "created": fmt.string(from: date)
        ]
        if let source = row.source { doc["source"] = source }
        if let project = row.project { doc["project"] = project }
        let _ = await post(path: "/indexes/archive/documents", body: [doc])
    }

    // MARK: - Conversations

    func indexEmailDocs(_ docs: [[String: String]]) async {
        guard !docs.isEmpty else { return }
        let _ = await post(path: "/indexes/emails/documents", body: docs)
    }

    func searchEmails(query: String, limit: Int = 5) async -> [SearchResult] {
        return await searchIndex("emails", query: query, limit: limit)
    }

    func indexSessionChunks(_ docs: [[String: String]]) async {
        guard !docs.isEmpty else { return }
        let _ = await post(path: "/indexes/sessions/documents", body: docs)
    }

    func removeSessionChunks(ids: [String]) async {
        guard !ids.isEmpty else { return }
        let _ = await post(path: "/indexes/sessions/documents/delete-batch", body: ids)
    }

    func searchSessions(query: String, limit: Int = 5) async -> [SearchResult] {
        return await searchIndex("sessions", query: query, limit: limit)
    }

    /// numberOfDocuments from /indexes/{uid}/stats — used by the recall
    /// health block to detect index drift (e.g. emails table vs index).
    func documentCount(index: String) async -> Int {
        guard let data = await get(path: "/indexes/\(index)/stats"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = json["numberOfDocuments"] as? Int else { return -1 }
        return n
    }

    // MARK: - Search

    func searchWiki(query: String, limit: Int = 5) async -> [SearchResult] {
        return await searchIndex("wiki", query: query, limit: limit)
    }

    func searchArchive(query: String, limit: Int = 5) async -> [SearchResult] {
        return await searchIndex("archive", query: query, limit: limit)
    }

    func searchDocs(query: String, limit: Int = 5) async -> [SearchResult] {
        return await searchIndex("docs", query: query, limit: limit)
    }

    func searchPrivate(query: String, limit: Int = 5) async -> [SearchResult] {
        return await searchIndex("private", query: query, limit: limit)
    }

    func search(query: String, limit: Int = 5) async -> [SearchResult] {
        async let wiki = searchWiki(query: query, limit: limit)
        async let archive = searchArchive(query: query, limit: limit)
        async let docs = searchDocs(query: query, limit: limit)
        async let privateIdx = searchPrivate(query: query, limit: limit)
        return await wiki + archive + docs + privateIdx
    }

    private func searchIndex(_ index: String, query: String, limit: Int) async -> [SearchResult] {
        let body: [String: Any] = ["q": query, "limit": limit]
        guard let data = await post(path: "/indexes/\(index)/search", body: body) else { return [] }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = json["hits"] as? [[String: Any]] else { return [] }

        return hits.map { hit in
            var fields: [String: String] = [:]
            for (key, value) in hit {
                if let str = value as? String { fields[key] = str }
                else { fields[key] = "\(value)" }
            }
            let id = fields["originalSlug"] ?? fields["slug"] ?? fields["filename"] ?? fields["id"] ?? ""
            // Title/snippet sources vary by index: wiki/docs carry title+content,
            // emails carry subject+body, session chunks carry sessionId+text.
            let title = fields["title"] ?? fields["subject"] ?? fields["sessionId"] ?? id
            let snippetSource = fields["content"] ?? fields["body"] ?? fields["text"] ?? ""
            let snippet = String(snippetSource.prefix(300))
            return SearchResult(id: id, title: title, snippet: snippet, index: index, fields: fields)
        }
    }

    // MARK: - Backfill

    func backfillWiki(dbPool: DatabasePool) async {
        let wikiDir = SonataInstance.dataDirectory + "/wiki"
        do {
            let rows = try await dbPool.read { db in
                try WikiPageRow.fetchAll(db, sql: "SELECT * FROM wikiPages WHERE pageType IS NULL OR pageType != 'archived'")
            }
            // Batch in groups of 10 to avoid payload size issues
            let batchSize = 10
            var indexed = 0
            for start in stride(from: 0, to: rows.count, by: batchSize) {
                let end = min(start + batchSize, rows.count)
                var docs: [[String: String]] = []
                for row in rows[start..<end] {
                    // Try the real wiki dir path first, fall back to DB filePath
                    let realPath = wikiDir + "/" + row.slug + ".md"
                    let content = (try? String(contentsOfFile: realPath, encoding: .utf8))
                        ?? (try? String(contentsOfFile: row.filePath, encoding: .utf8))
                        ?? ""
                    guard !content.isEmpty else { continue }
                    var doc: [String: String] = [
                        "slug": encodeSlug(row.slug),
                        "originalSlug": row.slug,
                        "title": row.title,
                        "content": content,
                        "filePath": realPath
                    ]
                    if let ns = row.namespace { doc["namespace"] = ns }
                    docs.append(doc)
                }
                if !docs.isEmpty {
                    let _ = await post(path: "/indexes/wiki/documents", body: docs)
                    indexed += docs.count
                }
            }
            logger.info("Backfilled \(indexed) wiki pages")
        } catch {
            logger.error("Wiki backfill failed: \(error)")
        }
    }

    func backfillArchive(dbPool: DatabasePool) async {
        do {
            let rows = try await dbPool.read { db in
                try MemoryRow.fetchAll(db, sql: "SELECT * FROM memories WHERE status IN ('archived', 'superseded')")
            }
            // Index in batches of 100
            let batchSize = 100
            for start in stride(from: 0, to: rows.count, by: batchSize) {
                let end = min(start + batchSize, rows.count)
                let batch = rows[start..<end]
                var docs: [[String: String]] = []
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                for row in batch {
                    let date = Date(timeIntervalSince1970: Double(row.createdAt) / 1000.0)
                    var doc: [String: String] = [
                        "id": row.id,
                        "content": row.content,
                        "type": row.type,
                        "tags": row.tagsJSON,
                        "importance": "\(Int(row.importance))",
                        "status": row.status ?? "archived",
                        "created": fmt.string(from: date)
                    ]
                    if let source = row.source { doc["source"] = source }
                    if let project = row.project { doc["project"] = project }
                    docs.append(doc)
                }
                let _ = await post(path: "/indexes/archive/documents", body: docs)
            }
            if !rows.isEmpty {
                logger.info("Backfilled \(rows.count) archived memories into MeiliSearch")
            }
        } catch {
            logger.error("Archive backfill failed: \(error)")
        }
    }

    /// Remove archive-index docs whose memory is no longer archived/superseded
    /// (hard-deleted, un-archived, or revived). backfillArchive is add-only, so
    /// without this orphans accumulate forever as archived memories get deleted
    /// — the 2026-06-17 archive-over-count. Makes archive reconciliation
    /// converge to exactly the source set. Returns the number pruned.
    @discardableResult
    func pruneArchiveOrphans(dbPool: DatabasePool) async -> Int {
        // All ids currently in the archive index (paginate generously).
        guard let data = await get(path: "/indexes/archive/documents?limit=100000&fields=id"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return 0 }
        let indexIds = results.compactMap { $0["id"] as? String }
        guard !indexIds.isEmpty else { return 0 }
        // Of those, which still qualify as archived/superseded?
        let validIds: Set<String> = (try? await dbPool.read { db -> Set<String> in
            var keep = Set<String>()
            for chunk in stride(from: 0, to: indexIds.count, by: 500) {
                let slice = Array(indexIds[chunk..<min(chunk + 500, indexIds.count)])
                let ph = slice.map { _ in "?" }.joined(separator: ",")
                let rows = try String.fetchAll(db,
                    sql: "SELECT id FROM memories WHERE status IN ('archived','superseded') AND id IN (\(ph))",
                    arguments: StatementArguments(slice))
                keep.formUnion(rows)
            }
            return keep
        }) ?? Set(indexIds)  // on read failure, keep everything (never over-delete)
        let orphans = indexIds.filter { !validIds.contains($0) }
        guard !orphans.isEmpty else { return 0 }
        let _ = await post(path: "/indexes/archive/documents/delete-batch", body: orphans)
        logger.info("Pruned \(orphans.count) orphaned archive docs")
        return orphans.count
    }

    func backfillDocs() async {
        await backfillDirectory(
            root: docsDir,
            indexName: "docs",
            description: "docs"
        )
    }

    func backfillPrivate() async {
        await backfillDirectory(
            root: privateDir,
            indexName: "private",
            description: "private"
        )
    }

    /// Scan `root` recursively for .md/.txt files and bulk-index each one into MeiliSearch.
    /// Primary key is the encoded relative path; `filename` preserves the readable path.
    private func backfillDirectory(root: String, indexName: String, description: String) async {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            logger.info("\(description) directory missing, skipping backfill: \(root)")
            return
        }

        guard let enumerator = fm.enumerator(atPath: root) else {
            logger.error("\(description) backfill: failed to enumerate \(root)")
            return
        }

        var batch: [[String: String]] = []
        var indexed = 0
        let batchSize = 50

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".md") || relativePath.hasSuffix(".txt") else { continue }
            let fullPath = root + "/" + relativePath
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8),
                  !content.isEmpty else { continue }

            let title = firstHeadingOrFilename(content: content, filename: relativePath)
            batch.append([
                "id": encodeFilename(relativePath),
                "filename": relativePath,
                "title": title,
                "content": content,
                "filePath": fullPath
            ])

            if batch.count >= batchSize {
                let _ = await post(path: "/indexes/\(indexName)/documents", body: batch)
                indexed += batch.count
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            let _ = await post(path: "/indexes/\(indexName)/documents", body: batch)
            indexed += batch.count
        }

        logger.info("Backfilled \(indexed) \(description) files into MeiliSearch")
    }

    /// Extract the first markdown heading as a title, else use the filename stem.
    private func firstHeadingOrFilename(content: String, filename: String) -> String {
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if trimmed.hasPrefix("#") {
                return String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            }
            if !trimmed.isEmpty { break }
        }
        let base = (filename as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        return stem.isEmpty ? filename : stem
    }

    // MARK: - HTTP Helpers

    private func post(path: String, body: Any) async -> Data? {
        guard let url = URL(string: "\(baseURL)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(masterKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await session.data(for: request)
            return data
        } catch {
            return nil
        }
    }

    private func patch(path: String, body: Any) async -> Data? {
        guard let url = URL(string: "\(baseURL)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(masterKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await session.data(for: request)
            return data
        } catch {
            return nil
        }
    }

    private func delete(path: String) async -> Data? {
        guard let url = URL(string: "\(baseURL)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(masterKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, _) = try await session.data(for: request)
            return data
        } catch {
            return nil
        }
    }

    private func get(path: String) async -> Data? {
        guard let url = URL(string: "\(baseURL)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(masterKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, _) = try await session.data(for: request)
            return data
        } catch {
            return nil
        }
    }

    private func killExistingMeiliSearch() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-x", "meilisearch"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

}
