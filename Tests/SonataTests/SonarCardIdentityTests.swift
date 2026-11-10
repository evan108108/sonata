import XCTest
@testable import Sonata

/// The sonar card nests identity under `agent`. Before 2026-11-10 the self
/// instance-id reader looked at the top level only, so isSelf was always false.
final class SonarCardIdentityTests: XCTestCase {

    /// The shape the live card returns (keys copied from evan-mac's
    /// /.well-known/sonar/card.json on 2026-11-10).
    func testReadsInstanceIdNestedUnderAgent() {
        let card = """
        {"agent": {"description": "d", "instance_id": "15e5138ac2168c17e9d2f9933a398694",
                   "name": "MacBookPro", "version": "1"},
         "authentication": {}, "capabilities": [], "transport": {}, "version": "1"}
        """
        XCTAssertEqual(SonarCardIdentity.instanceId(fromCardJSON: Data(card.utf8)),
                       "15e5138ac2168c17e9d2f9933a398694")
    }

    func testFallsBackToTopLevelInstanceId() {
        let card = #"{"instance_id": "abc123", "name": "old"}"#
        XCTAssertEqual(SonarCardIdentity.instanceId(fromCardJSON: Data(card.utf8)), "abc123")
    }

    func testAgentTakesPrecedenceOverTopLevel() {
        let card = #"{"instance_id": "top", "agent": {"instance_id": "nested"}}"#
        XCTAssertEqual(SonarCardIdentity.instanceId(fromCardJSON: Data(card.utf8)), "nested")
    }

    func testMissingOrMalformedReturnsEmpty() {
        XCTAssertEqual(SonarCardIdentity.instanceId(fromCardJSON: Data(#"{"agent": {}}"#.utf8)), "")
        XCTAssertEqual(SonarCardIdentity.instanceId(fromCardJSON: Data("not json".utf8)), "")
    }
}
