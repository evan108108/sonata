import XCTest
@testable import Sonata

/// Pure-helper tests for `StudioCardRow`. UI snapshot tests are out of scope
/// per the T3 task brief; these cover the kind-icon mapping (R1) and the
/// relativeTime formatter that the row + comment thread both rely on.
final class StudioCardRowTests: XCTestCase {

    func testSymbolForKind_knownKinds() {
        XCTAssertEqual(StudioCardRow.symbol(for: "note"),     "bubble.left.fill")
        XCTAssertEqual(StudioCardRow.symbol(for: "lead"),     "target")
        XCTAssertEqual(StudioCardRow.symbol(for: "review"),   "checkmark.seal.fill")
        XCTAssertEqual(StudioCardRow.symbol(for: "task"),     "checklist")
        XCTAssertEqual(StudioCardRow.symbol(for: "question"), "questionmark.bubble.fill")
        XCTAssertEqual(StudioCardRow.symbol(for: "answer"),   "checkmark.bubble.fill")
    }

    func testSymbolForKind_defaultFallback() {
        XCTAssertEqual(StudioCardRow.symbol(for: nil),               "doc.fill")
        XCTAssertEqual(StudioCardRow.symbol(for: ""),                "doc.fill")
        XCTAssertEqual(StudioCardRow.symbol(for: "unknown-kind-42"), "doc.fill")
    }

    func testRelativeTime_justNow() {
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertEqual(StudioCardRow.relativeTime(from: now), "just now")
        XCTAssertEqual(StudioCardRow.relativeTime(from: now - 30), "just now")
    }

    func testRelativeTime_minutes() {
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertEqual(StudioCardRow.relativeTime(from: now - 60), "1m ago")
        XCTAssertEqual(StudioCardRow.relativeTime(from: now - 1800), "30m ago")
    }

    func testRelativeTime_hours() {
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertEqual(StudioCardRow.relativeTime(from: now - 3600), "1h ago")
        XCTAssertEqual(StudioCardRow.relativeTime(from: now - 7200), "2h ago")
    }

    func testRelativeTime_yesterday() {
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertEqual(StudioCardRow.relativeTime(from: now - 86_500), "yesterday")
    }

    func testRelativeTime_oldDate() {
        // > 2 days → falls back to "MMM d"
        let now = Int64(Date().timeIntervalSince1970)
        let result = StudioCardRow.relativeTime(from: now - 86_400 * 10)
        XCTAssertFalse(result.contains("ago"))
        XCTAssertFalse(result.contains("yesterday"))
    }

    func testImageBlockViewToastText() {
        XCTAssertEqual(
            ImageBlockView.toastText(for: .allMirrorsFailed),
            "Image unavailable on any mirror."
        )
        XCTAssertEqual(
            ImageBlockView.toastText(for: .integrityMismatch(host: "blossom.band")),
            "Image integrity check failed on blossom.band."
        )
        XCTAssertEqual(
            ImageBlockView.toastText(for: .decryptFailed),
            "Image cannot be decrypted (wrong epoch)."
        )
        XCTAssertEqual(
            ImageBlockView.toastText(for: .missingEpochKey(epoch: 5)),
            "Image references epoch 5; key not yet received."
        )
        XCTAssertEqual(
            ImageBlockView.toastText(for: .decodeFailed),
            "Image data could not be decoded."
        )
    }

    func testLinkBlockViewValidURL() {
        XCTAssertNotNil(LinkBlockView.validURL("https://example.com"))
        XCTAssertNotNil(LinkBlockView.validURL("http://example.com"))
        XCTAssertNil(LinkBlockView.validURL("ftp://example.com"))
        XCTAssertNil(LinkBlockView.validURL("file:///etc/passwd"))
        XCTAssertNil(LinkBlockView.validURL("custom-scheme://x"))
        XCTAssertNil(LinkBlockView.validURL("not a url"))
    }
}
