import Foundation
import GRDB

/// Protocol defining Sonata's full-text search subsystem.
/// Implementations can use MeiliSearch, Tantivy, or any other engine.
protocol SearchService: Sendable {

    // MARK: - Lifecycle
    func start() async
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

    // MARK: - Unified
    func search(query: String, limit: Int) async -> [SearchResult]

    // MARK: - Backfill
    func backfillWiki(dbPool: DatabasePool) async
    func backfillArchive(dbPool: DatabasePool) async
}

/// A single search result from any index.
struct SearchResult: Sendable {
    let id: String        // slug for wiki, memory id for archive
    let title: String
    let snippet: String
    let index: String     // "wiki" or "archive"
    let fields: [String: String]
}
