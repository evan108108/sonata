import XCTest
@testable import Sonata

/// Unit tests for per-inbox EmailProvider resolution (Phase 2b). Pure config/routing
/// logic — no IMAP/SMTP/AgentMail network calls.
final class EmailProviderTests: XCTestCase {

    private func inbox(provider: String, providerConfig: String? = nil,
                       address: String = "me@example.com") -> InboxConfig {
        InboxConfig(address: address, role: .custom, provider: provider, providerConfig: providerConfig)
    }

    // MARK: routing

    func testAgentMailInboxResolvesToDefaultProvider() {
        let resolver = EmailProviderResolver()
        XCTAssertTrue(resolver.provider(for: inbox(provider: "agentmail")) is AgentMailProvider)
        // Unknown/blank provider also falls back to the default (AgentMail).
        XCTAssertTrue(resolver.provider(for: inbox(provider: "")) is AgentMailProvider)
        XCTAssertTrue(resolver.provider(for: inbox(provider: "nonsense")) is AgentMailProvider)
    }

    func testImapInboxResolvesToImapSmtpProvider() {
        let cfg = #"{"imapHost":"imap.gmail.com","smtpHost":"smtp.gmail.com","password":"app-pw"}"#
        let provider = EmailProviderResolver().provider(for: inbox(provider: "imap", providerConfig: cfg))
        XCTAssertTrue(provider is ImapSmtpProvider)
        XCTAssertTrue(provider.isConfigured)
    }

    func testImapInboxWithMissingConfigIsUnconfigured() {
        // provider=imap but no providerConfig → an ImapSmtpProvider that reports
        // isConfigured == false, so EmailHandler skips the inbox.
        let provider = EmailProviderResolver().provider(for: inbox(provider: "imap"))
        XCTAssertTrue(provider is ImapSmtpProvider)
        XCTAssertFalse(provider.isConfigured)
    }

    // MARK: config parsing

    func testImapSmtpConfigParsesHostsPortsAndPassword() throws {
        let cfg = #"""
        {"imapHost":"imap.fastmail.com","imapPort":993,
         "smtpHost":"smtp.fastmail.com","smtpPort":587,
         "username":"override@fastmail.com","password":"secret"}
        """#
        let parsed = try XCTUnwrap(
            EmailProviderResolver.imapSmtpConfig(from: inbox(provider: "imap", providerConfig: cfg)))
        XCTAssertEqual(parsed.imapHost, "imap.fastmail.com")
        XCTAssertEqual(parsed.imapPort, 993)
        XCTAssertEqual(parsed.smtpHost, "smtp.fastmail.com")
        XCTAssertEqual(parsed.smtpPort, 587)
        XCTAssertEqual(parsed.username, "override@fastmail.com")  // explicit override
        XCTAssertEqual(parsed.password, "secret")
    }

    func testImapSmtpConfigDefaultsPortsAndUsername() throws {
        let cfg = #"{"imapHost":"imap.x.com","smtpHost":"smtp.x.com","password":"pw"}"#
        let parsed = try XCTUnwrap(
            EmailProviderResolver.imapSmtpConfig(from: inbox(provider: "imap", providerConfig: cfg,
                                                             address: "default@x.com")))
        XCTAssertEqual(parsed.imapPort, 993)            // default
        XCTAssertEqual(parsed.smtpPort, 465)            // default
        XCTAssertEqual(parsed.username, "default@x.com") // defaults to inbox address
    }

    func testImapSmtpConfigNilWhenHostsMissing() {
        XCTAssertNil(EmailProviderResolver.imapSmtpConfig(
            from: inbox(provider: "imap", providerConfig: #"{"password":"pw"}"#)))
        XCTAssertNil(EmailProviderResolver.imapSmtpConfig(
            from: inbox(provider: "imap", providerConfig: nil)))
    }

    // MARK: attachments

    func testAttachmentParsingMatchesAgentMailShape() {
        // Verbatim shape from GET /inboxes/<id>/messages/<mid> on 2026-07-28
        // (the AFK screenshot reply that exposed the metadata drop).
        let raw: [[String: Any]] = [[
            "attachment_id": "95c719ad-4e09-4b01-ad0b-f94c22ab475c",
            "filename": "1000021535.jpg",
            "size": 150010,
            "content_type": "image/jpeg",
            "content_disposition": "inline",
            "content_id": "<ii_19fab29785b43249f1a1>",
        ]]
        let parsed = EmailAttachment.fromProviderList(raw)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].attachmentId, "95c719ad-4e09-4b01-ad0b-f94c22ab475c")
        XCTAssertEqual(parsed[0].filename, "1000021535.jpg")
        XCTAssertEqual(parsed[0].size, 150010)
        XCTAssertEqual(parsed[0].contentType, "image/jpeg")
        XCTAssertEqual(parsed[0].contentDisposition, "inline")
    }

    func testAttachmentParsingToleratesCamelCaseAndSkipsIdless() {
        let raw: [[String: Any]] = [
            ["attachmentId": "att-1", "contentType": "application/pdf"],
            ["filename": "no-id.png"],  // no id → skipped
        ]
        let parsed = EmailAttachment.fromProviderList(raw)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].attachmentId, "att-1")
        XCTAssertEqual(parsed[0].contentType, "application/pdf")
        XCTAssertNil(parsed[0].filename)
        // Non-array input → [] (message had no attachments field).
        XCTAssertTrue(EmailAttachment.fromProviderList(nil).isEmpty)
        XCTAssertTrue(EmailAttachment.fromProviderList("junk").isEmpty)
    }

    func testAttachmentListRoundTripsThroughJSON() {
        let list = [EmailAttachment(
            attachmentId: "att-1", filename: "shot.jpg", size: 42,
            contentType: "image/jpeg", contentDisposition: "inline")]
        let json = EmailAttachment.encodeList(list)
        XCTAssertNotNil(json)
        let decoded = EmailAttachment.decodeList(json)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].attachmentId, "att-1")
        XCTAssertEqual(decoded[0].filename, "shot.jpg")
        XCTAssertEqual(decoded[0].size, 42)
        // Empty list encodes to nil (no DB/meta cost), and nil/garbage decode to [].
        XCTAssertNil(EmailAttachment.encodeList([]))
        XCTAssertTrue(EmailAttachment.decodeList(nil).isEmpty)
        XCTAssertTrue(EmailAttachment.decodeList("not json").isEmpty)
    }
}
