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

    // MARK: - previewLine (markdown-strip helper)

    func testPreviewLine_plainText_unchanged() {
        XCTAssertEqual(
            StudioCardRow.previewLine("plain text", limit: 150),
            "plain text"
        )
    }

    func testPreviewLine_collapsesNewlines() {
        XCTAssertEqual(
            StudioCardRow.previewLine("first paragraph\n\nsecond line", limit: 150),
            "first paragraph second line"
        )
    }

    func testPreviewLine_stripsBoldItalicCode() {
        XCTAssertEqual(
            StudioCardRow.previewLine("**bold** *italic* `code` plain", limit: 150),
            "bold italic code plain"
        )
    }

    func testPreviewLine_linksKeepLabelDropUrl() {
        XCTAssertEqual(
            StudioCardRow.previewLine("see [the docs](https://example.com) for more", limit: 150),
            "see the docs for more"
        )
    }

    func testPreviewLine_imageAltKept() {
        XCTAssertEqual(
            StudioCardRow.previewLine("![banner](https://x/y.png) caption", limit: 150),
            "banner caption"
        )
    }

    func testPreviewLine_stripsHeadingsListsQuotes() {
        XCTAssertEqual(
            StudioCardRow.previewLine("# Title\n- item one\n- item two\n> quoted", limit: 150),
            "Title item one item two quoted"
        )
    }

    func testPreviewLine_truncatesAtLimit() {
        let body = String(repeating: "a", count: 300)
        let result = StudioCardRow.previewLine(body, limit: 150)
        XCTAssertEqual(result.count, 150)
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
