import XCTest
@testable import Sonata

/// Webhook dispatch filter grammar (2026-10-26, AE-151). The Evenflow
/// sona-assigned routes dispatched two workers onto a ticket its author was
/// still holding: PR #785's GitHub auto-move (actor `github:evan108108`) and
/// an in-place body edit (no actor) both passed `body.kind=...`. The routes
/// now drop Sona- and GitHub-caused transitions and in-place edits of tickets
/// already past Todo, while human transitions, assignments and comments still
/// dispatch.
final class WebhookDispatchFilterTests: XCTestCase {

    private let sona = "nostr:049b628c4e18d562627fd924dea8dd6fe98d4dd3094fd85a53d84c0f5219b3c2"
    private let evan = "google:114038898351513339547"

    /// The filter both evenflow-sona-assigned routes carry.
    private var evenflowFilter: String {
        "body.kind=issue.created|issue.transitioned|comment.created"
            + " && body.payload.actor_pubkey!=\(sona)|github:*"
            + " || body.kind=issue.updated && body.payload.issue.status=Todo"
    }

    /// Envelope shaped like webhook_deliver's payloadParams for an Evenflow event.
    private func evenflow(_ kind: String, actor: String?, status: String) -> [String: Any] {
        var payload: [String: Any] = ["issue": ["short_id": "AE-151", "status": status]]
        if let actor { payload["actor_pubkey"] = actor }
        return ["body": ["kind": kind, "payload": payload]]
    }

    // MARK: Replays of the two 10/26 deliveries

    func testGitHubAutoTransitionIsDropped() {
        // Delivery ca54ecb4: PR #785 opened → GitHub automation moved AE-151 to In Review.
        let p = evenflow("issue.transitioned", actor: "github:evan108108", status: "In Review")
        XCTAssertNotNil(evaluateDispatchFilter(evenflowFilter, payload: p))
    }

    func testInPlaceEditOfStartedTicketIsDropped() {
        // Delivery 68988d61: body edit adding the PR link; in-place edits carry no actor.
        let p = evenflow("issue.updated", actor: nil, status: "In Review")
        XCTAssertNotNil(evaluateDispatchFilter(evenflowFilter, payload: p))
    }

    func testSonaTransitionIsDropped() {
        let p = evenflow("issue.transitioned", actor: sona, status: "In Review")
        XCTAssertNotNil(evaluateDispatchFilter(evenflowFilter, payload: p))
    }

    // MARK: What must still dispatch

    func testHumanTransitionDispatches() {
        let p = evenflow("issue.transitioned", actor: evan, status: "In Progress")
        XCTAssertNil(evaluateDispatchFilter(evenflowFilter, payload: p))
    }

    func testAssignmentOfTodoTicketDispatches() {
        // Assigning an existing ticket is an in-place PATCH: issue.updated, no actor.
        let p = evenflow("issue.updated", actor: nil, status: "Todo")
        XCTAssertNil(evaluateDispatchFilter(evenflowFilter, payload: p))
    }

    func testHumanCreatedTicketDispatches() {
        let p = evenflow("issue.created", actor: nil, status: "Todo")
        XCTAssertNil(evaluateDispatchFilter(evenflowFilter, payload: p))
    }

    func testCommentOnStartedTicketDispatches() {
        let p = evenflow("comment.created", actor: nil, status: "In Review")
        XCTAssertNil(evaluateDispatchFilter(evenflowFilter, payload: p))
    }

    func testUnlistedKindIsDropped() {
        let p = evenflow("issue.deleted", actor: evan, status: "Todo")
        XCTAssertNotNil(evaluateDispatchFilter(evenflowFilter, payload: p))
    }

    // MARK: Grammar

    func testOriginalSingleClauseFormUnchanged() {
        let filter = "body.action=opened|synchronize|reopened"
        XCTAssertNil(evaluateDispatchFilter(filter, payload: ["body": ["action": "synchronize"]]))
        let reason = evaluateDispatchFilter(filter, payload: ["body": ["action": "closed"]])
        XCTAssertEqual(reason, "filter miss: path='body.action' value='closed' expected =[opened|synchronize|reopened]")
    }

    func testNegationPassesOnMissingPath() {
        XCTAssertNil(evaluateDispatchFilter("body.actor!=github:*", payload: ["body": [:] as [String: Any]]))
    }

    func testPrefixMatchesOnlyThePrefix() {
        let filter = "body.actor=github:*"
        XCTAssertNil(evaluateDispatchFilter(filter, payload: ["body": ["actor": "github:webhook"]]))
        XCTAssertNotNil(evaluateDispatchFilter(filter, payload: ["body": ["actor": "nostr:github:x"]]))
    }

    func testMalformedClauseCountsAsMatching() {
        XCTAssertNil(evaluateDispatchFilter("body.kind", payload: ["body": ["kind": "x"]]))
        XCTAssertNil(evaluateDispatchFilter("body.kind=a && =b", payload: ["body": ["kind": "a"]]))
    }

    func testMissReasonNamesEveryGroup() {
        let reason = evaluateDispatchFilter("body.a=1 || body.b=2", payload: ["body": ["a": "0", "b": "0"]])
        XCTAssertEqual(reason, "filter miss: path='body.a' value='0' expected =[1]; path='body.b' value='0' expected =[2]")
    }
}
