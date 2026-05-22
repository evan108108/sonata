import Foundation
import GRDB

/// Protocol defining Sonata's full-text search subsystem.
/// Implementations can use MeiliSearch, Tantivy, or any other engine.
protocol SearchService: Sendable {

    // MARK: - Lifecycle
    func start(dbPool: DatabasePool?) async
    func shutdown() async
    func isHealthy() async -> Bool
    func ensureIndexes() async

    // MARK: - Wiki
    func indexWikiPage(slug: String, title: String, content: String, namespace: String?, filePath: String) async
    func removeWikiPage(slug: String) async
    func searchWiki(query: String, limit: Int) async -> [SearchResult]

    // MARK: - Archive
    func indexArchivedMemory(_ row: MemoryRow) async
    func searchArchive(query: String, limit: Int) async -> [SearchResult]

    // MARK: - Docs (planning documents at ~/.sonata/documents/)
    func indexDocFile(filename: String, title: String, content: String, filePath: String) async
    func removeDocFile(filename: String) async
    func searchDocs(query: String, limit: Int) async -> [SearchResult]

    // MARK: - Private (~/.sonata/private/ — internal use only)
    func indexPrivateFile(filename: String, title: String, content: String, filePath: String) async
    func removePrivateFile(filename: String) async
    func searchPrivate(query: String, limit: Int) async -> [SearchResult]

    // MARK: - Unified
    func search(query: String, limit: Int) async -> [SearchResult]

    // MARK: - Backfill
    func backfillWiki(dbPool: DatabasePool) async
    func backfillArchive(dbPool: DatabasePool) async
    func backfillDocs() async
    func backfillPrivate() async
}

/// A single search result from any index.
struct SearchResult: Sendable {
    let id: String        // slug for wiki, memory id for archive, filename for docs/private
    let title: String
    let snippet: String
    let index: String     // "wiki", "archive", "docs", or "private"
    let fields: [String: String]
}
