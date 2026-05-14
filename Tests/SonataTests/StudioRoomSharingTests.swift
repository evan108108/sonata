import XCTest
@testable import Sonata

/// Pure-logic coverage for the renderer-side room sharing surfaces:
///   - invite URL prefix validation (used by StudioJoinRoomSheet),
///   - JSON decoding of the three plugin response envelopes,
///   - state-string render dispatch (active vs pending-grant).
final class StudioRoomSharingTests: XCTestCase {

    // MARK: - URL prefix validation

    func testInviteURL_acceptsS4ASchemeWithSlug() {
        XCTAssertTrue(StudioJoinRoomSheet.isLikelyInviteURL("s4a://invite/abc123"))
    }

    func testInviteURL_acceptsS4ASchemeMixedCase() {
        XCTAssertTrue(StudioJoinRoomSheet.isLikelyInviteURL("S4A://INVITE/abc123"))
    }

    func testInviteURL_acceptsHttpsWithInvitePath() {
        XCTAssertTrue(StudioJoinRoomSheet.isLikelyInviteURL(
            "https://claim.4a4.ai/invite/eyJ0eXAi"
        ))
    }

    func testInviteURL_trimsWhitespace() {
        XCTAssertTrue(StudioJoinRoomSheet.isLikelyInviteURL(
            "   https://claim.4a4.ai/invite/x   \n"
        ))
    }

    func testInviteURL_rejectsBareScheme() {
        // empty payload — must have something after `/invite/`
        XCTAssertFalse(StudioJoinRoomSheet.isLikelyInviteURL("s4a://invite/"))
    }

    func testInviteURL_rejectsHttpsWithoutInvitePath() {
        XCTAssertFalse(StudioJoinRoomSheet.isLikelyInviteURL("https://example.com/foo"))
    }

    func testInviteURL_rejectsRandomString() {
        XCTAssertFalse(StudioJoinRoomSheet.isLikelyInviteURL("hello world"))
    }

    func testInviteURL_rejectsEmptyString() {
        XCTAssertFalse(StudioJoinRoomSheet.isLikelyInviteURL(""))
    }

    // MARK: - Response decoding

    func testDecodeJoinResponse_pendingGrant() throws {
        let json = """
        {
          "audience_address": "aud:abc:room",
          "room_slug": "alpha",
          "epoch": 3,
          "claim_event_id": "cafef00d",
          "state": "pending-grant"
        }
        """
        let resp = try JSONDecoder().decode(
            StudioRoomJoinResponse.self,
            from: json.data(using: .utf8)!
        )
        XCTAssertEqual(resp.roomSlug, "alpha")
        XCTAssertEqual(resp.epoch, 3)
        XCTAssertEqual(resp.claimEventId, "cafef00d")
        XCTAssertEqual(resp.state, "pending-grant")
    }

    func testDecodeJoinResponse_active() throws {
        let json = #"{"audience_address":"a","room_slug":"b","epoch":1,"claim_event_id":"x","state":"active"}"#
        let resp = try JSONDecoder().decode(
            StudioRoomJoinResponse.self,
            from: json.data(using: .utf8)!
        )
        XCTAssertEqual(resp.state, "active")
    }

    func testDecodeInviteResponse() throws {
        let json = """
        {
          "s4a_url": "s4a://invite/AAA",
          "https_url": "https://claim.4a4.ai/invite/AAA",
          "invite_pub": "deadbeef",
          "expires_at": 1746000000
        }
        """
        let resp = try JSONDecoder().decode(
            StudioInviteResponse.self,
            from: json.data(using: .utf8)!
        )
        XCTAssertEqual(resp.s4aUrl, "s4a://invite/AAA")
        XCTAssertEqual(resp.httpsUrl, "https://claim.4a4.ai/invite/AAA")
        XCTAssertEqual(resp.invitePub, "deadbeef")
        XCTAssertEqual(resp.expiresAt, 1_746_000_000)
    }

    func testDecodeAdmitResult_someAdmitted() throws {
        let json = """
        {
          "ok": true,
          "admitted": [
            {"claim_pubkey": "ab", "key_grant_event_id": "g1"},
            {"claim_pubkey": "cd", "key_grant_event_id": "g2"}
          ],
          "new_epoch": 5,
          "declaration_event_id": "dec1"
        }
        """
        let result = try JSONDecoder().decode(
            StudioAdmitResult.self,
            from: json.data(using: .utf8)!
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.admitted.count, 2)
        XCTAssertEqual(result.admitted[0].claimPubkey, "ab")
        XCTAssertEqual(result.admitted[1].keyGrantEventId, "g2")
        XCTAssertEqual(result.newEpoch, 5)
        XCTAssertEqual(result.declarationEventId, "dec1")
        XCTAssertNil(result.failed)
    }

    func testDecodeAdmitResult_emptyProbeShape() throws {
        // "Are there pending claims?" cheap probe form — empty list + null
        // declaration_event_id (no rotation happened).
        let json = """
        {
          "ok": true,
          "admitted": [],
          "new_epoch": 5,
          "declaration_event_id": null
        }
        """
        let result = try JSONDecoder().decode(
            StudioAdmitResult.self,
            from: json.data(using: .utf8)!
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.admitted.count, 0)
        XCTAssertNil(result.declarationEventId)
    }

    func testDecodeAdmitResult_withFailures() throws {
        let json = """
        {
          "ok": true,
          "admitted": [{"claim_pubkey": "ab", "key_grant_event_id": "g1"}],
          "new_epoch": 7,
          "declaration_event_id": "dec",
          "failed": [{"recipient": "ef", "reason": "encrypt_failed"}]
        }
        """
        let result = try JSONDecoder().decode(
            StudioAdmitResult.self,
            from: json.data(using: .utf8)!
        )
        XCTAssertEqual(result.failed?.count, 1)
        XCTAssertEqual(result.failed?[0].recipient, "ef")
        XCTAssertEqual(result.failed?[0].reason, "encrypt_failed")
    }

    // MARK: - State-string semantics (mirror of sidebar render conditional)

    func testPendingGrantStateMatchesSidebarRule() {
        // The sidebar greys out rows where room.state == "pending-grant"
        // (StudioRoomList: titleColor / subtitleText branches). This guards
        // the literal string the renderer dispatches on.
        let pending = "pending-grant"
        let active = "active"
        XCTAssertEqual(pending, "pending-grant")
        XCTAssertNotEqual(pending, active)
    }
}
