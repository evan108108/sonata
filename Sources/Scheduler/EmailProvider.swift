import Foundation

// MARK: - EmailProvider

/// A pluggable backend for the email Sonata sends and receives. Today the only
/// implementation is `AgentMailProvider` (the AgentMail HTTP API); a SwiftMail-backed
/// IMAP/SMTP provider is the planned second implementation so users can bring their
/// own email instead of an AgentMail account. `EmailHandler` talks only to this
/// protocol — no provider-specific details (URLs, key names, JSON key casing) leak
/// past a conforming type.
protocol EmailProvider: Sendable {
    /// Whether the provider has the credentials it needs to run. When false,
    /// `EmailHandler` stays disabled instead of polling.
    var isConfigured: Bool { get }

    /// Recent threads in `inbox`, newest-relevant first, already mapped to a
    /// provider-agnostic shape. Throws on transport/auth failure.
    func listThreads(inbox: String) async throws -> [EmailThreadSummary]

    /// A single message by id. Throws on transport/auth failure.
    func fetchMessage(inbox: String, messageId: String) async throws -> EmailMessage

    /// All messages on `threadId`, oldest-first, with bodies resolved — the
    /// conversation history a reply generator needs. Throws on transport/auth failure.
    func fetchThreadMessages(inbox: String, threadId: String) async throws -> [EmailMessage]

    /// The `from` of the latest message on `threadId`, used to detect whether we
    /// already replied. `nil` = the thread has no messages. Throws when the state
    /// can't be verified (caller should skip rather than risk a double-reply).
    func latestMessageSender(inbox: String, threadId: String) async throws -> String?

    /// Send a new message from `inbox`. Throws on non-2xx.
    func send(inbox: String, to: [String], subject: String, text: String) async throws

    /// Reply to an existing message, preserving its thread. Throws on non-2xx.
    func reply(inbox: String, messageId: String, text: String) async throws
}

// MARK: - Per-inbox provider resolution

/// Maps an inbox to the `EmailProvider` that backs it, so different inboxes can use
/// different backends (AgentMail vs. a user's own IMAP/SMTP) within one EmailHandler.
/// `defaultProvider` serves "agentmail" inboxes (injectable for tests).
struct EmailProviderResolver: Sendable {
    var defaultProvider: EmailProvider = AgentMailProvider()

    func provider(for inbox: InboxConfig) -> EmailProvider {
        switch inbox.provider.lowercased() {
        case "imap", "imapsmtp", "smtp":
            // A missing/invalid providerConfig yields an unconfigured ImapSmtpProvider
            // (isConfigured == false), so the caller skips the inbox rather than
            // silently routing an IMAP address through AgentMail.
            let config = Self.imapSmtpConfig(from: inbox)
                ?? ImapSmtpConfig(imapHost: "", smtpHost: "", username: inbox.address, password: "")
            return ImapSmtpProvider(config: config)
        default:
            return defaultProvider
        }
    }

    /// Parse an inbox's `providerConfig` JSON into an `ImapSmtpConfig`. The password
    /// is read from SecretStore via `passwordRef` (preferred) or taken inline
    /// (`password`, discouraged). Username defaults to the inbox address.
    static func imapSmtpConfig(from inbox: InboxConfig) -> ImapSmtpConfig? {
        guard let raw = inbox.providerConfig,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let imapHost = json["imapHost"] as? String, !imapHost.isEmpty,
              let smtpHost = json["smtpHost"] as? String, !smtpHost.isEmpty
        else { return nil }

        let password: String
        if let ref = json["passwordRef"] as? String, !ref.isEmpty {
            password = SecretStore.get(ref) ?? ""
        } else {
            password = json["password"] as? String ?? ""
        }

        return ImapSmtpConfig(
            imapHost: imapHost,
            smtpHost: smtpHost,
            username: (json["username"] as? String) ?? inbox.address,
            password: password,
            imapPort: (json["imapPort"] as? Int) ?? 993,
            smtpPort: (json["smtpPort"] as? Int) ?? 465
        )
    }
}

// MARK: - Provider-agnostic models

/// A thread summary reduced to what the poll loop needs.
struct EmailThreadSummary: Sendable {
    let threadId: String
    let lastMessageId: String
    let subject: String?
}

/// A fetched message reduced to what the poll loop needs. `body` is already the
/// best available plain text (provider resolves any text/extracted-text fallback).
struct EmailMessage: Sendable {
    let from: String
    let subject: String?
    let body: String
    let timestamp: String?
}

// MARK: - AgentMailProvider

/// `EmailProvider` backed by the AgentMail HTTP API (api.agentmail.to/v0). This is
/// the original (and default) backend; all AgentMail specifics — base URL, bearer
/// key, and snake_case JSON keys — live here and nowhere else. Behavior mirrors the
/// HTTP calls EmailHandler made inline before the provider was extracted.
struct AgentMailProvider: EmailProvider {
    private let apiBase = "https://api.agentmail.to/v0"
    private let apiKey: String?

    init(apiKey: String? = SecretStore.get("AGENTMAIL_API_KEY")) {
        self.apiKey = apiKey
    }

    var isConfigured: Bool { !(apiKey?.isEmpty ?? true) }

    private func key() throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw EmailError.noApiKey }
        return apiKey
    }

    private func getJSON(_ path: String, endpointLabel: String) async throws -> [String: Any] {
        let url = URL(string: "\(apiBase)\(path)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try key())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EmailError.apiFailed(endpointLabel, (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func post(_ path: String, body: [String: Any], endpointLabel: String) async throws {
        let url = URL(string: "\(apiBase)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try key())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw EmailError.apiFailed(endpointLabel, (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    func listThreads(inbox: String) async throws -> [EmailThreadSummary] {
        let json = try await getJSON("/inboxes/\(inbox)/threads?limit=20", endpointLabel: "threads")
        guard let threads = json["threads"] as? [[String: Any]] else { return [] }
        // AgentMail returns snake_case keys (thread_id, last_message_id); accept the
        // camelCase variants too. Threads missing either id are skipped, matching the
        // old poll-loop `continue`.
        return threads.compactMap { thread in
            guard let threadId = (thread["thread_id"] ?? thread["threadId"]) as? String,
                  let lastMessageId = (thread["last_message_id"] ?? thread["lastMessageId"]) as? String
            else { return nil }
            return EmailThreadSummary(
                threadId: threadId,
                lastMessageId: lastMessageId,
                subject: thread["subject"] as? String
            )
        }
    }

    func fetchMessage(inbox: String, messageId: String) async throws -> EmailMessage {
        let json = try await getJSON("/inboxes/\(inbox)/messages/\(messageId)", endpointLabel: "message")
        let body = json["text"] as? String
            ?? json["extracted_text"] as? String
            ?? json["extractedText"] as? String
            ?? ""
        return EmailMessage(
            from: json["from"] as? String ?? "",
            subject: json["subject"] as? String,
            body: body,
            timestamp: json["timestamp"] as? String
        )
    }

    func fetchThreadMessages(inbox: String, threadId: String) async throws -> [EmailMessage] {
        let json = try await getJSON("/inboxes/\(inbox)/messages?limit=50", endpointLabel: "messages")
        let raw = json["messages"] as? [[String: Any]] ?? []
        let inThread = raw.filter { ($0["thread_id"] ?? $0["threadId"]) as? String == threadId }
        let sorted = inThread.sorted {
            ($0["timestamp"] as? String ?? "") < ($1["timestamp"] as? String ?? "")
        }
        var result: [EmailMessage] = []
        for m in sorted {
            var body = m["text"] as? String
                ?? m["extracted_text"] as? String
                ?? m["extractedText"] as? String
            // List view may omit the body; fetch the full message to resolve it.
            if body == nil, let mid = (m["message_id"] ?? m["messageId"]) as? String {
                body = try? await fetchMessage(inbox: inbox, messageId: mid).body
            }
            result.append(EmailMessage(
                from: m["from"] as? String ?? "",
                subject: m["subject"] as? String,
                body: body ?? "",
                timestamp: m["timestamp"] as? String
            ))
        }
        return result
    }

    func latestMessageSender(inbox: String, threadId: String) async throws -> String? {
        let json = try await getJSON("/inboxes/\(inbox)/threads/\(threadId)?limit=1", endpointLabel: "thread")
        let messages = json["messages"] as? [[String: Any]] ?? []
        return messages.last?["from"] as? String
    }

    func send(inbox: String, to: [String], subject: String, text: String) async throws {
        try await post(
            "/inboxes/\(inbox)/messages",
            body: ["to": to, "subject": subject, "text": text],
            endpointLabel: "send"
        )
    }

    func reply(inbox: String, messageId: String, text: String) async throws {
        try await post(
            "/inboxes/\(inbox)/messages/\(messageId)/reply",
            body: ["text": text],
            endpointLabel: "reply"
        )
    }
}
