import Foundation
import SwiftMail

/// Connection + credential config for one IMAP/SMTP mailbox (app-password / LOGIN auth).
struct ImapSmtpConfig: Sendable {
    let imapHost: String
    let imapPort: Int
    let smtpHost: String
    let smtpPort: Int
    let username: String
    let password: String

    /// Gmail/Fastmail/iCloud/etc. defaults: IMAPS 993 + SMTPS 465.
    init(imapHost: String, smtpHost: String, username: String, password: String,
         imapPort: Int = 993, smtpPort: Int = 465) {
        self.imapHost = imapHost
        self.smtpHost = smtpHost
        self.username = username
        self.password = password
        self.imapPort = imapPort
        self.smtpPort = smtpPort
    }
}

/// `EmailProvider` backed by SwiftMail's IMAP + SMTP clients — the "bring your own
/// email" backend (Gmail / Fastmail / iCloud / self-hosted) using app-password LOGIN
/// auth. Conforms to the same protocol as `AgentMailProvider`, so the callers
/// (EmailHandler / FriendRelay / HealthMonitor) are unchanged.
///
/// v1 simplifications (intentional; documented for follow-up):
///  - **Identity = IMAP UID** (stable within a mailbox's UIDVALIDITY), stored as the
///    `messageId`/`threadId` string. A UIDVALIDITY reset would re-surface mail once.
///  - **One message == one "thread"** — no References/THREAD-based conversation
///    reconstruction yet, so `fetchThreadMessages` / `latestMessageSender` operate on
///    the single message. Replies still thread correctly via In-Reply-To/References.
///  - **Connection per call** (no pooling). Fine at a 120s poll cadence; pool later.
struct ImapSmtpProvider: EmailProvider {
    let config: ImapSmtpConfig

    var isConfigured: Bool {
        !config.username.isEmpty && !config.password.isEmpty
            && !config.imapHost.isEmpty && !config.smtpHost.isEmpty
    }

    // MARK: - Session helpers

    /// Open an authenticated IMAP session, run `body`, and always disconnect.
    private func withIMAP<T>(_ body: (IMAPServer) async throws -> T) async throws -> T {
        let server = IMAPServer(host: config.imapHost, port: config.imapPort)
        try await server.connect()
        do {
            try await server.login(username: config.username, password: config.password)
            let result = try await body(server)
            try? await server.disconnect()
            return result
        } catch {
            try? await server.disconnect()
            throw error
        }
    }

    /// Open an authenticated SMTP session, run `body`, and always disconnect.
    private func withSMTP(_ body: (SMTPServer) async throws -> Void) async throws {
        let server = SMTPServer(host: config.smtpHost, port: config.smtpPort)
        try await server.connect()
        do {
            try await server.login(username: config.username, password: config.password)
            try await body(server)
            try? await server.disconnect()
        } catch {
            try? await server.disconnect()
            throw error
        }
    }

    /// Fetch a single message by its UID-string identity (returns nil if not found).
    private func fetchByUID(_ server: IMAPServer, _ messageId: String) async throws -> Message? {
        guard let uidValue = Int(messageId), uidValue > 0 else { return nil }
        let set = MessageIdentifierSet<UID>(uidValue)
        for try await message in server.fetchMessages(using: set) { return message }
        return nil
    }

    private func toEmailMessage(_ m: Message) -> EmailMessage {
        EmailMessage(
            from: m.from ?? "",
            subject: m.subject,
            body: m.textBody ?? m.htmlBody ?? "",
            timestamp: m.date.map { ISO8601DateFormatter().string(from: $0) }
        )
    }

    // MARK: - EmailProvider

    func listThreads(inbox: String) async throws -> [EmailThreadSummary] {
        try await withIMAP { server in
            let selection = try await server.selectMailbox("INBOX")
            guard let latest = selection.latest(20) else { return [] }
            var out: [EmailThreadSummary] = []
            for try await m in server.fetchMessages(using: latest) {
                guard let uid = m.uid?.value else { continue }
                let id = String(uid)  // one message == one thread (v1)
                out.append(EmailThreadSummary(threadId: id, lastMessageId: id, subject: m.subject))
            }
            return out
        }
    }

    func fetchMessage(inbox: String, messageId: String) async throws -> EmailMessage {
        try await withIMAP { server in
            _ = try await server.selectMailbox("INBOX")
            guard let m = try await fetchByUID(server, messageId) else {
                throw EmailError.apiFailed("imap-fetch", 404)
            }
            return toEmailMessage(m)
        }
    }

    func fetchThreadMessages(inbox: String, threadId: String) async throws -> [EmailMessage] {
        // v1: a "thread" is a single message.
        [try await fetchMessage(inbox: inbox, messageId: threadId)]
    }

    func latestMessageSender(inbox: String, threadId: String) async throws -> String? {
        try await withIMAP { server in
            _ = try await server.selectMailbox("INBOX")
            return try await fetchByUID(server, threadId)?.from
        }
    }

    func send(inbox: String, to: [String], subject: String, text: String) async throws {
        try await withSMTP { server in
            let email = Email(
                sender: EmailAddress(address: config.username),
                recipients: to.map { EmailAddress(address: $0) },
                subject: subject,
                textBody: text
            )
            try await server.sendEmail(email)
        }
    }

    func reply(inbox: String, messageId: String, text: String) async throws {
        // Pull the original message so the reply addresses the right sender and
        // threads via In-Reply-To / References.
        let original: Message? = try await withIMAP { server in
            _ = try await server.selectMailbox("INBOX")
            return try await fetchByUID(server, messageId)
        }
        let toAddr = EmailHandler.extractEmailAddress(from: original?.from ?? config.username)
        let originalSubject = original?.subject ?? ""
        let subject = originalSubject.lowercased().hasPrefix("re:")
            ? originalSubject : "Re: \(originalSubject)"

        try await withSMTP { server in
            var email = Email(
                sender: EmailAddress(address: config.username),
                recipients: [EmailAddress(address: toAddr)],
                subject: subject,
                textBody: text
            )
            if let mid = original?.header.messageId?.description {
                email.additionalHeaders = ["In-Reply-To": mid, "References": mid]
            }
            try await server.sendEmail(email)
        }
    }
}
