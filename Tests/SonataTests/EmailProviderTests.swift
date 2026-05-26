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
}
