import XCTest
@testable import Sonata

/// Covers the `content` / `contentPath` pair added 2026-07-13.
///
/// The bug being fixed lives one layer above the server: callers hand-serialize
/// multi-line prose into a JSON string field and the JSON comes out malformed.
/// The fix lets them Write the prose to a file and pass a path instead, so these
/// tests care most about (a) prose surviving the file round-trip byte-identical
/// and (b) every failure path throwing rather than yielding an empty body.
final class TextBodyParamTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        // Under /tmp, which is an allowed root — same shape as a real caller's
        // scratchpad file.
        tmpDir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("sonata-textbody-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeFile(_ name: String, _ contents: String) throws -> String {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// The headline case: a >3KB multi-line reflection with the exact characters
    /// that break hand-escaped JSON — double quotes, apostrophes, em-dashes,
    /// backslashes, braces and newlines — must arrive byte-identical.
    func testLongProseRoundTripsByteIdentical() throws {
        let paragraph = """
        The guard sits on the same axis as the failure it is meant to catch, so it \
        reports "clean" against a corpse — and that's the whole day in one file. \
        A regex like .replace(/[\\x00-\\x1f]/g, "") can collapse into literal NULs. \
        Evan's note said: "don't trust the exit code." {"tags": ["a","b"]}
        """
        var prose = "# Reflection — 2026-07-13\n\n"
        for i in 1...20 {
            prose += "\(i). \(paragraph)\n\n"
        }
        XCTAssertGreaterThan(prose.utf8.count, 3072, "fixture must exceed 3KB")

        let path = try writeFile("reflection.md", prose)
        let params = ActionParams(["contentPath": path])
        let resolved = try params.requireTextBody("content", pathKey: "contentPath")

        XCTAssertEqual(resolved, prose)
        XCTAssertEqual(Array(resolved.utf8), Array(prose.utf8), "bytes must match exactly")
    }

    func testInlineContentStillWorks() throws {
        let params = ActionParams(["content": "a short memory"])
        XCTAssertEqual(try params.requireTextBody("content", pathKey: "contentPath"), "a short memory")
    }

    func testBothParamsIsAnError() throws {
        let path = try writeFile("body.md", "from the file")
        let params = ActionParams(["content": "inline", "contentPath": path])
        XCTAssertThrowsError(try params.requireTextBody("content", pathKey: "contentPath"))
    }

    func testNeitherParamIsAnError() {
        let params = ActionParams([:])
        XCTAssertThrowsError(try params.requireTextBody("content", pathKey: "contentPath"))
    }

    /// Optional form: a task with no prompt at all is legal.
    func testTextBodyReturnsNilWhenNeitherGiven() throws {
        XCTAssertNil(try ActionParams([:]).textBody("prompt", pathKey: "promptPath"))
    }

    // MARK: Guardrails — every one of these must throw, never return "".

    func testMissingFileThrows() {
        let params = ActionParams(["contentPath": tmpDir.appendingPathComponent("nope.md").path])
        XCTAssertThrowsError(try params.requireTextBody("content", pathKey: "contentPath"))
    }

    func testEmptyFileThrowsRatherThanStoringEmptyMemory() throws {
        let path = try writeFile("empty.md", "   \n\n  ")
        let params = ActionParams(["contentPath": path])
        XCTAssertThrowsError(try params.requireTextBody("content", pathKey: "contentPath"))
    }

    func testPathOutsideAllowedRootsThrows() {
        let params = ActionParams(["contentPath": "/etc/passwd"])
        XCTAssertThrowsError(try params.requireTextBody("content", pathKey: "contentPath"))
    }

    func testRelativePathThrows() {
        let params = ActionParams(["contentPath": "notes/reflection.md"])
        XCTAssertThrowsError(try params.requireTextBody("content", pathKey: "contentPath"))
    }

    func testDirectoryPathThrows() {
        let params = ActionParams(["contentPath": tmpDir.path])
        XCTAssertThrowsError(try params.requireTextBody("content", pathKey: "contentPath"))
    }

    func testOversizeFileThrows() throws {
        let path = try writeFile("big.md", String(repeating: "x", count: maxTextBodyBytes + 1))
        let params = ActionParams(["contentPath": path])
        XCTAssertThrowsError(try params.requireTextBody("content", pathKey: "contentPath"))
    }

    /// A symlink pointing outside the allowed roots must not smuggle a read.
    func testSymlinkEscapeThrows() throws {
        let link = tmpDir.appendingPathComponent("escape.md")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
        )
        let params = ActionParams(["contentPath": link.path])
        XCTAssertThrowsError(try params.requireTextBody("content", pathKey: "contentPath"))
    }

    // MARK: Param-name aliasing (the mem_revise id / originalId silent no-op)

    func testRequireAnyAcceptsCanonicalAndAlias() throws {
        XCTAssertEqual(try ActionParams(["originalId": "abc"]).requireAny(["originalId", "id"]), "abc")
        XCTAssertEqual(try ActionParams(["id": "xyz"]).requireAny(["originalId", "id"]), "xyz")
    }

    func testRequireAnyPrefersCanonicalWhenBothPresent() throws {
        let params = ActionParams(["originalId": "canonical", "id": "alias"])
        XCTAssertEqual(try params.requireAny(["originalId", "id"]), "canonical")
    }

    func testRequireAnyThrowsWhenAbsent() {
        XCTAssertThrowsError(try ActionParams([:]).requireAny(["originalId", "id"]))
    }
}
