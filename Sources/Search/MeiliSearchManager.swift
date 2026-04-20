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

    private var baseURL: String { "http://127.0.0.1:\(port)" }

    private var dataDir: String {
        NSHomeDirectory() + "/.sonata/meili-data"
    }

    private var keyFile: String {
        NSHomeDirectory() + "/.sonata/meili-key"
    }

    init() {
        var log = Logger(label: "sonata.meilisearch")
        log.logLevel = .info
        self.logger = log
    }

    // MARK: - Lifecycle

    func start() async {
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

        // Find the binary
        let binaryPath = findBinary()
        guard let binaryPath = binaryPath else {
            logger.error("MeiliSearch binary not found — search will be unavailable")
            return
        }

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

        // Configure searchable attributes
        await updateSettings(index: "wiki", settings: [
            "searchableAttributes": ["content", "title", "originalSlug", "namespace"],
            "displayedAttributes": ["slug", "originalSlug", "title", "namespace", "filePath"]
        ])
        await updateSettings(index: "archive", settings: [
            "searchableAttributes": ["content", "type", "tags", "source", "project"],
            "displayedAttributes": ["id", "content", "type", "tags", "source", "importance", "project", "status", "created"]
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

    // MARK: - Search

    func searchWiki(query: String, limit: Int = 5) async -> [SearchResult] {
        return await searchIndex("wiki", query: query, limit: limit)
    }

    func searchArchive(query: String, limit: Int = 5) async -> [SearchResult] {
        return await searchIndex("archive", query: query, limit: limit)
    }

    func search(query: String, limit: Int = 5) async -> [SearchResult] {
        async let wiki = searchWiki(query: query, limit: limit)
        async let archive = searchArchive(query: query, limit: limit)
        return await wiki + archive
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
            let id = fields["originalSlug"] ?? fields["slug"] ?? fields["id"] ?? ""
            let title = fields["title"] ?? id
            let snippet = String((fields["content"] ?? "").prefix(300))
            return SearchResult(id: id, title: title, snippet: snippet, index: index, fields: fields)
        }
    }

    // MARK: - Backfill

    func backfillWiki(dbPool: DatabasePool) async {
        let wikiDir = NSHomeDirectory() + "/.sonata/wiki"
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

    // MARK: - Binary Discovery

    private func findBinary() -> String? {
        let fm = FileManager.default

        // 1. Check app bundle — resolve from executable path
        if let execPath = Bundle.main.executablePath {
            let contentsDir = (execPath as NSString).deletingLastPathComponent + "/.."
            let resolved = (contentsDir as NSString).standardizingPath
            let resourceBinary = resolved + "/Resources/bin/meilisearch"
            if fm.isExecutableFile(atPath: resourceBinary) {
                return resourceBinary
            }
        }

        // 2. Check common Homebrew paths
        for path in ["/opt/homebrew/bin/meilisearch", "/usr/local/bin/meilisearch"] {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
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
