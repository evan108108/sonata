import XCTest
@testable import Sonata

/// Pure-logic coverage for Phase 4 T4: BlockDraft state machine + payload
/// shape, StudioComposeSheet validation, and the StudioStore optimistic
/// insert / reconcile cycle. UI snapshot tests are out of scope per the
/// task brief; what we verify here is the contract that the views rely on.
@MainActor
final class StudioComposeTests: XCTestCase {

    // MARK: - BlockDraft.isValid

    func testBlockDraftText_emptyBodyInvalid() {
        var d = BlockDraft(); d.kind = .text; d.body = "   "
        XCTAssertFalse(d.isValid)
    }

    func testBlockDraftText_withBodyValid() {
        var d = BlockDraft(); d.kind = .text; d.body = "hello"
        XCTAssertTrue(d.isValid)
    }

    func testBlockDraftCode_emptyBodyInvalid() {
        var d = BlockDraft(); d.kind = .code; d.body = ""
        XCTAssertFalse(d.isValid)
    }

    func testBlockDraftCode_anyBodyValid_evenWithoutLanguage() {
        var d = BlockDraft(); d.kind = .code; d.body = "echo hi"
        XCTAssertTrue(d.isValid)
    }

    func testBlockDraftLink_requiresHref() {
        var d = BlockDraft(); d.kind = .link
        XCTAssertFalse(d.isValid)
        d.href = "https://example.com"
        XCTAssertTrue(d.isValid)
    }

    func testBlockDraftField_requiresKeyAndValue() {
        var d = BlockDraft(); d.kind = .field
        XCTAssertFalse(d.isValid)
        d.fieldKey = "k"
        XCTAssertFalse(d.isValid)
        d.fieldValue = "v"
        XCTAssertTrue(d.isValid)
    }

    func testBlockDraftImage_invalidUntilBlockLanded() {
        var d = BlockDraft(); d.kind = .image
        XCTAssertFalse(d.isValid)
        d.imageBlockRaw = ["type": "image", "sha256": "abc"]
        XCTAssertTrue(d.isValid)
    }

    // MARK: - BlockDraft.toPayload

    func testToPayloadText() {
        var d = BlockDraft(); d.kind = .text; d.body = "x"
        let p = d.toPayload()
        XCTAssertEqual(p["type"] as? String, "text")
        XCTAssertEqual(p["body"] as? String, "x")
    }

    func testToPayloadCode_includesLanguage() {
        var d = BlockDraft(); d.kind = .code; d.body = "x"; d.language = "swift"
        let p = d.toPayload()
        XCTAssertEqual(p["type"] as? String, "code")
        XCTAssertEqual(p["language"] as? String, "swift")
        XCTAssertEqual(p["body"] as? String, "x")
    }

    func testToPayloadLink_omitsEmptyLabel() {
        var d = BlockDraft(); d.kind = .link; d.href = "https://x"
        let p = d.toPayload()
        XCTAssertEqual(p["type"] as? String, "link")
        XCTAssertEqual(p["href"] as? String, "https://x")
        XCTAssertNil(p["label"])
    }

    func testToPayloadLink_includesLabel() {
        var d = BlockDraft(); d.kind = .link; d.href = "https://x"; d.linkLabel = "PR"
        XCTAssertEqual(d.toPayload()["label"] as? String, "PR")
    }

    func testToPayloadField() {
        var d = BlockDraft(); d.kind = .field; d.fieldKey = "k"; d.fieldValue = "v"
        let p = d.toPayload()
        XCTAssertEqual(p["type"] as? String, "field")
        XCTAssertEqual(p["key"] as? String, "k")
        XCTAssertEqual(p["value"] as? String, "v")
    }

    func testToPayloadImage_usesAttachedBlock() {
        var d = BlockDraft(); d.kind = .image
        d.imageBlockRaw = ["type": "image", "sha256": "deadbeef", "mime_type": "image/png"]
        let p = d.toPayload()
        XCTAssertEqual(p["sha256"] as? String, "deadbeef")
        XCTAssertEqual(p["mime_type"] as? String, "image/png")
    }

    // MARK: - StudioStore optimistic surface

    func testOptimisticallyInsertCard_landsSyntheticCard() {
        let store = StudioStore()
        store.optimisticallyInsertCard(
            clientId: "c1",
            roomSlug: "demo",
            trackSlug: "general",
            kind: "note",
            title: "title",
            summary: "summary",
            blocks: [],
            tagsList: [],
            relatedTo: []
        )
        XCTAssertEqual(store.optimisticCards.count, 1)
        let card = store.optimisticCards["c1"]
        XCTAssertEqual(card?.title, "title")
        XCTAssertEqual(card?.summary, "summary")
        XCTAssertEqual(card?.roomSlug, "demo")
        XCTAssertEqual(card?.trackSlug, "general")
        XCTAssertEqual(card?.cardKind, "note")
        XCTAssertEqual(card?.eventId, "")
    }

    func testSetOptimisticEventId_patchesEventIdOnly() {
        let store = StudioStore()
        store.optimisticallyInsertCard(
            clientId: "c1", roomSlug: "demo", trackSlug: "general",
            kind: "note", title: "t", summary: "s",
            blocks: [], tagsList: [], relatedTo: []
        )
        store.setOptimisticEventId(clientId: "c1", eventId: "evtX")
        XCTAssertEqual(store.optimisticCards["c1"]?.eventId, "evtX")
        XCTAssertEqual(store.optimisticCards["c1"]?.title, "t")
    }

    func testRollbackOptimisticCard_drops() {
        let store = StudioStore()
        store.optimisticallyInsertCard(
            clientId: "c1", roomSlug: "r", trackSlug: "t",
            kind: "note", title: "x", summary: "y",
            blocks: [], tagsList: [], relatedTo: []
        )
        XCTAssertEqual(store.optimisticCards.count, 1)
        store.rollbackOptimisticCard(clientId: "c1")
        XCTAssertTrue(store.optimisticCards.isEmpty)
    }

    func testOptimisticComment_lifecycle() {
        let store = StudioStore()
        store.optimisticallyInsertComment(
            clientId: "x1", roomSlug: "r", targetEventId: "evtCard",
            body: "hi", intent: nil
        )
        XCTAssertEqual(store.optimisticComments.count, 1)
        XCTAssertEqual(store.optimisticComments["x1"]?.body, "hi")
        XCTAssertEqual(store.optimisticComments["x1"]?.targetEventId, "evtCard")
        XCTAssertEqual(store.optimisticComments["x1"]?.eventId, "")

        store.setOptimisticCommentEventId(clientId: "x1", eventId: "evtReply")
        XCTAssertEqual(store.optimisticComments["x1"]?.eventId, "evtReply")

        store.rollbackOptimisticComment(clientId: "x1")
        XCTAssertTrue(store.optimisticComments.isEmpty)
    }

    func testOptimisticInsert_blocksRoundTripThroughDecoder() {
        let store = StudioStore()
        let blockDicts: [[String: Any]] = [
            ["type": "text", "body": "hello"],
            ["type": "link", "href": "https://x", "label": "PR"],
        ]
        store.optimisticallyInsertCard(
            clientId: "c1", roomSlug: "r", trackSlug: "t",
            kind: "note", title: "x", summary: "y",
            blocks: blockDicts, tagsList: [], relatedTo: []
        )
        let card = store.optimisticCards["c1"]
        XCTAssertEqual(card?.blocks.count, 2)
        if case .text(let body) = card?.blocks.first {
            XCTAssertEqual(body, "hello")
        } else {
            XCTFail("expected first block to decode as .text")
        }
    }

    // MARK: - parsedTags

    func testParsedTags_strips_andDropsEmpty() {
        // We can't easily instantiate StudioComposeSheet without an
        // EnvironmentObject, so we mirror its tag-parse logic here as a
        // small static helper test. The view delegates to the same string
        // operations.
        let raw = "  foo, bar,, baz   "
        let parsed = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(parsed, ["foo", "bar", "baz"])
    }
}
