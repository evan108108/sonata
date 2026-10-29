import XCTest
import GRDB
@testable import Sonata

// Regression tests for ftsEscape / ftsEscapeOR (Sources/Search/FTSQuery.swift).
//
// Pins the bug fixed on 2026-05-21: mem_search (and its siblings mem_entity_search,
// mem_doc_search, mem_task_search, mem_check, mem_wander) forwarded raw user input
// straight into FTS5 `MATCH`, so any hyphenated term or bareword OR/AND/NOT/NEAR
// keyword threw `SQLite error 1: no such column: …` instead of searching.
// mem_recall was already safe because it sanitized first; these tests pin that the
// shared escaper neutralizes FTS5 operator syntax for every caller.
final class FTSQueryTests: XCTestCase {

    // MARK: - Pure escaping behavior

    func testHyphenTermsAreQuotedAndBarewordOrStaysAnOperator() {
        // The exact input from the 5/21 bug report. Each term is double-quoted
        // (literal phrase) with a trailing `*`; the bareword "OR" between them stays
        // the FTS5 union operator (since 10/29; it used to be a literal "OR"* term).
        XCTAssertEqual(
            ftsEscape("world-watch OR strategic-signal"),
            "\"world-watch\"* OR \"strategic-signal\"*"
        )
    }

    func testBarewordAndIsDroppedAndStrayOrsAreTrimmed() {
        XCTAssertEqual(ftsEscape("alpha AND beta"), "\"alpha\"* \"beta\"*")
        XCTAssertEqual(ftsEscape("OR alpha OR OR beta OR"), "\"alpha\"* OR \"beta\"*")
        XCTAssertEqual(ftsEscape("OR"), "")
        XCTAssertEqual(ftsEscape("AND OR"), "")
        // Lowercase "or" and NOT stay literal terms.
        XCTAssertEqual(ftsEscape("this or that"), "\"this\"* \"or\"* \"that\"*")
        XCTAssertEqual(ftsEscape("alpha NOT beta"), "\"alpha\"* \"NOT\"* \"beta\"*")
    }

    func testEscapeORDropsBarewordOperators() {
        XCTAssertEqual(ftsEscapeOR("alpha OR beta AND gamma"), "\"alpha\"* OR \"beta\"* OR \"gamma\"*")
    }

    func testMultiWordIsImplicitAndOfPrefixMatches() {
        XCTAssertEqual(ftsEscape("world watch"), "\"world\"* \"watch\"*")
    }

    func testCommaAndSemicolonAreTokenSeparators() {
        XCTAssertEqual(ftsEscape("alpha, beta; gamma"), "\"alpha\"* \"beta\"* \"gamma\"*")
    }

    func testEmbeddedDoubleQuoteIsEscaped() {
        // A stray `"` inside a token must be doubled so the wrapping quotes stay balanced.
        XCTAssertEqual(ftsEscape("foo\"bar"), "\"foo\"\"bar\"*")
    }

    func testBlankInputProducesEmptyString() {
        XCTAssertEqual(ftsEscape(""), "")
        XCTAssertEqual(ftsEscape("   \t\n  "), "")
        XCTAssertEqual(ftsEscape(" , ; "), "")
    }

    func testEscapeORJoinsWithOrOperator() {
        XCTAssertEqual(ftsEscapeOR("alpha beta"), "\"alpha\"* OR \"beta\"*")
    }

    // MARK: - End-to-end against a real FTS5 table

    private func makeFTSPool() throws -> DatabasePool {
        let tmp = NSTemporaryDirectory() + "sonata-fts-\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let pool = try DatabasePool(path: tmp)
        try pool.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE docs_fts USING fts5(body)")
            try db.execute(sql: "INSERT INTO docs_fts(body) VALUES ('the world-watch strategic-signal feed')")
            try db.execute(sql: "INSERT INTO docs_fts(body) VALUES ('unrelated content')")
        }
        return pool
    }

    func testRawHyphenatedQueryThrows_DemonstratingTheBug() throws {
        let pool = try makeFTSPool()
        // The pre-fix code path: raw input straight to MATCH. This is the crash we fixed.
        XCTAssertThrowsError(
            try pool.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM docs_fts WHERE docs_fts MATCH ?",
                                 arguments: ["world-watch OR strategic-signal"])
            },
            "raw hyphenated/OR input is expected to throw an FTS5 syntax error"
        )
    }

    func testEscapedQueryDoesNotThrowAndMatches() throws {
        let pool = try makeFTSPool()
        let escaped = ftsEscape("world-watch strategic-signal")
        let rows = try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT body FROM docs_fts WHERE docs_fts MATCH ?",
                             arguments: [escaped])
        }
        // Implicit-AND of both prefix terms hits exactly the one matching row.
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["body"], "the world-watch strategic-signal feed")
    }

    func testEscapedBarewordOrQueryDoesNotThrow() throws {
        let pool = try makeFTSPool()
        // The literal 5/21 bug input must not throw.
        let escaped = ftsEscape("world-watch OR strategic-signal")
        XCTAssertNoThrow(
            try pool.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM docs_fts WHERE docs_fts MATCH ?",
                                 arguments: [escaped])
            }
        )
    }

    func testBarewordOrIsAUnionWhenOneSideHasNoMatch() throws {
        // 10/28: "toolWatch OR impeccable" returned only rows holding BOTH words, so an
        // OR-joined dedup check read as "no duplicate". One side matching must be enough.
        let pool = try makeFTSPool()
        let rows = try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT body FROM docs_fts WHERE docs_fts MATCH ?",
                             arguments: [ftsEscape("unrelated OR zzqxnotaword")])
        }
        XCTAssertEqual(rows.map { $0["body"] as String }, ["unrelated content"])
    }
}
