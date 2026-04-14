import Foundation
import GRDB
import Logging

/// Polls AgentMail for new emails across one or more inboxes, stores them in
/// SQLite, and dispatches worker events to reply. Replaces the email handling
/// in `sona-scheduler.js`.
actor EmailHandler {

    // MARK: - Configuration

    /// Poll interval: 2 minutes.
    static let pollIntervalSeconds: TimeInterval = 120

    /// Inboxes to monitor. Each entry owns its dispatch instructions.
    static let inboxes: [InboxConfig] = [
        InboxConfig(
            address: "sona@agentmail.to",
            role: .sona
        ),
        InboxConfig(
            address: "scoutleader@agentmail.to",
            role: .scoutleader
        ),
    ]

    /// AgentMail API base URL.
    private static let apiBase = "https://api.agentmail.to/v0"

    // MARK: - State

    private let dbPool: DatabasePool
    private let logger: Logger

    /// API key loaded from environment.
    private let apiKey: String?

    /// Lock: only one email session at a time.
    private var isProcessing = false

    /// Set of email IDs we've already seen (seeded from DB on startup).
    private var knownEmailIds: Set<String> = []

    /// Whether we've completed the first poll (used to seed known IDs without triggering).
    private var initialized = false

    /// The polling task — cancelled on shutdown.
    private var pollTask: Task<Void, Never>?

    // MARK: - Init

    init(dbPool: DatabasePool, logger: Logger? = nil) {
        self.dbPool = dbPool
        var log = logger ?? Logger(label: "sonata.email")
        log.logLevel = .info
        self.logger = log
        self.apiKey = SecretStore.get("AGENTMAIL_API_KEY")
    }

    // MARK: - Lifecycle

    /// Start the email polling loop.
    func start() async {
        guard apiKey != nil, !(apiKey?.isEmpty ?? true) else {
            logger.warning("EmailHandler: disabled (no AGENTMAIL_API_KEY)")
            return
        }

        await seedKnownIds()

        let inboxList = Self.inboxes.map(\.address).joined(separator: ", ")
        logger.info("EmailHandler: starting (poll every \(Self.pollIntervalSeconds)s, inboxes: \(inboxList))")

        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
            }
        }
    }

    /// Stop polling.
    func shutdown() {
        logger.info("EmailHandler: shutting down")
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Polling

    /// One poll cycle: for every configured inbox, fetch threads and process new unread emails.
    private func poll() async {
        guard let apiKey, !apiKey.isEmpty else { return }

        var newEmailsByInbox: [String: [EmailRecord]] = [:]

        for inbox in Self.inboxes {
            do {
                let threads = try await fetchThreads(inboxId: inbox.address, apiKey: apiKey)

                for thread in threads {
                    // AgentMail API returns snake_case keys (thread_id, last_message_id)
                    guard let threadId = (thread["thread_id"] ?? thread["threadId"]) as? String else { continue }
                    guard let lastMessageId = (thread["last_message_id"] ?? thread["lastMessageId"]) as? String else { continue }
                    if knownEmailIds.contains(lastMessageId) { continue }

                    let message = try await fetchMessage(
                        inboxId: inbox.address,
                        messageId: lastMessageId,
                        apiKey: apiKey
                    )

                    let from = message["from"] as? String ?? ""
                    let subject = (thread["subject"] as? String) ?? (message["subject"] as? String) ?? ""
                    let body = message["text"] as? String ?? message["extracted_text"] as? String ?? message["extractedText"] as? String ?? ""
                    let timestamp = message["timestamp"] as? String ?? ISO8601DateFormatter().string(from: Date())

                    // Skip messages this inbox sent itself
                    if from.contains(inbox.address) {
                        knownEmailIds.insert(lastMessageId)
                        continue
                    }

                    let record = EmailRecord(
                        messageId: lastMessageId,
                        threadId: threadId,
                        from: from,
                        subject: subject,
                        body: body,
                        timestamp: timestamp,
                        inboxAddress: inbox.address
                    )

                    if !initialized {
                        knownEmailIds.insert(lastMessageId)
                        try? await storeEmail(record, status: "read")
                        continue
                    }

                    newEmailsByInbox[inbox.address, default: []].append(record)
                    knownEmailIds.insert(lastMessageId)
                }
            } catch {
                logger.error("EmailHandler poll error for \(inbox.address): \(error)")
            }
        }

        if !initialized {
            initialized = true
            logger.info("EmailHandler: initialized with \(knownEmailIds.count) known email(s) across \(Self.inboxes.count) inbox(es)")
            // Check for any pre-existing unread emails in the DB and dispatch them
            await dispatchPendingUnreadEmails()
            return
        }

        let totalNew = newEmailsByInbox.values.reduce(0) { $0 + $1.count }
        if totalNew > 0 {
            logger.info("EmailHandler: \(totalNew) new email(s) detected across \(newEmailsByInbox.count) inbox(es)")
        }

        // Dispatch each inbox's new emails as its own worker event
        for inbox in Self.inboxes {
            guard let newEmails = newEmailsByInbox[inbox.address], !newEmails.isEmpty else { continue }
            for email in newEmails {
                try? await storeEmail(email, status: "unread")
            }
            await processNewEmails(newEmails, inbox: inbox)
        }
    }

    // MARK: - Pending Unread Recovery

    /// After init, check for unread emails in the DB that were never dispatched
    /// (e.g. arrived between restarts). Verifies via AgentMail that no reply was
    /// sent before dispatching, to avoid double-replies.
    private func dispatchPendingUnreadEmails() async {
        guard let apiKey, !apiKey.isEmpty else { return }

        // Find unread emails in DB, max 24h old
        let cutoffMs = Int64((Date().timeIntervalSince1970 - 86400) * 1000)
        let unreadRows: [(messageId: String, threadId: String, from: String, subject: String, body: String, inboxAddress: String)]
        do {
            unreadRows = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT messageId, threadId, fromAddr, toAddr, subject, body
                    FROM emails
                    WHERE status = 'unread' AND receivedAt > ?
                    ORDER BY receivedAt ASC
                    LIMIT 10
                """, arguments: [cutoffMs])
                .map { row in (
                    messageId: row["messageId"] as String,
                    threadId: row["threadId"] as String,
                    from: row["fromAddr"] as String,
                    subject: row["subject"] as String,
                    body: row["body"] as? String ?? "",
                    inboxAddress: row["toAddr"] as String
                )}
            }
        } catch {
            logger.error("EmailHandler: failed to query pending unread emails — \(error)")
            return
        }

        if unreadRows.isEmpty { return }
        logger.info("EmailHandler: found \(unreadRows.count) pending unread email(s), checking for prior replies")

        var toDispatch: [String: [EmailRecord]] = [:]  // keyed by inbox address

        for row in unreadRows {
            // Safety check 1: is there already a pending worker event for this email?
            let hasPendingEvent: Bool = (try? await dbPool.read { db in
                let count = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM workerEvents
                    WHERE type = 'email' AND status IN ('pending', 'claimed')
                    AND payload LIKE ?
                """, arguments: ["%\(row.messageId)%"]) ?? 0
                return count > 0
            }) ?? false

            if hasPendingEvent {
                logger.info("EmailHandler: skipping \(row.subject) — pending worker event exists")
                continue
            }

            // Safety check 2: has a reply already been sent on this thread?
            // Fetch thread from AgentMail — only need the latest message
            let alreadyReplied: Bool
            do {
                let url = URL(string: "\(Self.apiBase)/inboxes/\(row.inboxAddress)/threads/\(row.threadId)?limit=1")!
                var request = URLRequest(url: url, timeoutInterval: 10)
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    // Can't verify — skip to be safe
                    logger.warning("EmailHandler: can't verify thread \(row.threadId) — skipping to be safe")
                    continue
                }
                // Check if the latest message in the thread is from our inbox
                let messages = json["messages"] as? [[String: Any]] ?? []
                if let latest = messages.last {
                    let latestFrom = latest["from"] as? String ?? ""
                    alreadyReplied = latestFrom.contains(row.inboxAddress)
                } else {
                    alreadyReplied = false
                }
            } catch {
                logger.warning("EmailHandler: AgentMail check failed for \(row.threadId) — skipping: \(error)")
                continue
            }

            if alreadyReplied {
                logger.info("EmailHandler: marking \(row.subject) as replied — reply already sent")
                try? await markEmailProcessed(messageId: row.messageId, success: true)
                continue
            }

            // Safe to dispatch
            let record = EmailRecord(
                messageId: row.messageId,
                threadId: row.threadId,
                from: row.from,
                subject: row.subject,
                body: row.body,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                inboxAddress: row.inboxAddress
            )
            toDispatch[row.inboxAddress, default: []].append(record)
        }

        // Dispatch grouped by inbox
        for inbox in Self.inboxes {
            guard let emails = toDispatch[inbox.address], !emails.isEmpty else { continue }
            logger.info("EmailHandler: dispatching \(emails.count) pending unread email(s) for \(inbox.address)")
            await processNewEmails(emails, inbox: inbox)
        }
    }

    // MARK: - Email Processing

    /// Dispatch a worker event to handle a batch of new emails for one inbox.
    private func processNewEmails(_ emails: [EmailRecord], inbox: InboxConfig) async {
        guard !isProcessing else {
            logger.info("EmailHandler: already processing — will catch on next poll")
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        let emailDetails = emails.map { email in
            """
            ### From: \(email.from)
            **Subject:** \(email.subject)
            **Thread ID:** \(email.threadId)
            **Message ID:** \(email.messageId)
            **Received:** \(email.timestamp)

            \(email.body.prefix(8000))
            """
        }.joined(separator: "\n\n---\n\n")

        let prompt = inbox.role.buildPrompt(
            inboxAddress: inbox.address,
            emailCount: emails.count,
            emailDetails: emailDetails
        )

        logger.info("EmailHandler: dispatching \(emails.count) email(s) from \(inbox.address) to worker via channel")

        do {
            let eventPayload: [String: Any] = [
                "summary": "New email(s) at \(inbox.address): \(emails.map { $0.subject }.joined(separator: ", "))",
                "prompt": prompt,
                "emailCount": emails.count,
                "inbox": inbox.address,
                "role": inbox.role.rawValue,
            ]
            let payloadJSON = try JSONSerialization.data(withJSONObject: eventPayload)
            let payloadStr = String(data: payloadJSON, encoding: .utf8) ?? "{}"

            var req = URLRequest(url: URL(string: "http://localhost:3211/api/worker/events/enqueue")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "type": "email",
                "payload": payloadStr,
                "priority": 8,
            ])

            let (data, response) = try await URLSession.shared.data(for: req)
            let httpRes = response as? HTTPURLResponse
            if httpRes?.statusCode == 200 || httpRes?.statusCode == 201 {
                logger.info("EmailHandler: email event enqueued to worker channel")
            } else {
                let body = String(data: data, encoding: .utf8) ?? "?"
                logger.error("EmailHandler: enqueue failed — HTTP \(httpRes?.statusCode ?? 0): \(body)")
            }

        } catch {
            logger.error("EmailHandler: dispatch threw: \(error)")
            try? await sendFailureAlert(emails: emails, inbox: inbox, apiKey: apiKey!)
        }
    }

    // MARK: - AgentMail API

    /// Fetch threads from an AgentMail inbox.
    private func fetchThreads(inboxId: String, apiKey: String) async throws -> [[String: Any]] {
        let url = URL(string: "\(Self.apiBase)/inboxes/\(inboxId)/threads?limit=20")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw EmailError.apiFailed("threads", statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let threads = json["threads"] as? [[String: Any]] else {
            return []
        }
        return threads
    }

    /// Fetch a single message from AgentMail.
    private func fetchMessage(inboxId: String, messageId: String, apiKey: String) async throws -> [String: Any] {
        let url = URL(string: "\(Self.apiBase)/inboxes/\(inboxId)/messages/\(messageId)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw EmailError.apiFailed("message", statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    /// Send a reply via AgentMail API.
    private func sendMessage(
        inboxId: String, to: [String], subject: String, text: String, apiKey: String
    ) async throws {
        let url = URL(string: "\(Self.apiBase)/inboxes/\(inboxId)/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "to": to,
            "subject": subject,
            "text": text,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw EmailError.apiFailed("send", statusCode)
        }
    }

    /// Send a failure alert to Evan.
    private func sendFailureAlert(emails: [EmailRecord], inbox: InboxConfig, apiKey: String) async throws {
        let subjects = emails.map { "\"\($0.subject)\" from \($0.from)" }.joined(separator: ", ")
        try await sendMessage(
            inboxId: inbox.address,
            to: ["evan108108@gmail.com"],
            subject: "[Sona] Failed to dispatch email at \(inbox.address)",
            text: """
            I failed to enqueue worker dispatch for: \(subjects)

            The emails are still in the inbox — you may want to check on this.

            — Sona
            """,
            apiKey: apiKey
        )
    }

    // MARK: - SQLite

    /// Seed known email IDs from the database so we don't re-process old emails on restart.
    private func seedKnownIds() async {
        do {
            let ids: [String] = try await dbPool.read { db in
                try String.fetchAll(db, sql: "SELECT messageId FROM emails ORDER BY receivedAt DESC LIMIT 200")
            }
            knownEmailIds = Set(ids)
            logger.info("EmailHandler: seeded \(knownEmailIds.count) known email IDs from DB")
        } catch {
            logger.warning("EmailHandler: failed to seed known IDs: \(error)")
        }
    }

    /// Store an email record in SQLite.
    private func storeEmail(_ email: EmailRecord, status: String) async throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try await dbPool.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO emails (messageId, threadId, fromAddr, toAddr, subject, body, status, receivedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [email.messageId, email.threadId, email.from, email.inboxAddress, email.subject, email.body, status, nowMs])
        }
    }

    /// Mark an email as processed in SQLite.
    private func markEmailProcessed(messageId: String, success: Bool) async throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try await dbPool.write { db in
            try db.execute(sql: """
                UPDATE emails SET status = ?, repliedAt = ?
                WHERE messageId = ?
            """, arguments: [success ? "replied" : "error", nowMs, messageId])
        }
    }
}

// MARK: - Types

/// Role of a monitored inbox — determines what instructions get attached
/// when dispatching incoming emails to a worker.
enum InboxRole: String, Sendable {
    case sona
    case scoutleader

    /// Build the dispatch prompt for a batch of new emails at this inbox.
    func buildPrompt(inboxAddress: String, emailCount: Int, emailDetails: String) -> String {
        switch self {
        case .sona:
            return """
            # Unread Emails for Sona Claude

            You have \(emailCount) unread email(s) at \(inboxAddress).

            \(emailDetails)

            ## Instructions

            You are Sona Claude, responding to email. Your working directory is /Users/evan/memory.

            CRITICAL — DO NOT COMPOSE ANY REPLY UNTIL YOU COMPLETE STEPS 1-3:
            An instance that doesn't check memory before speaking isn't Sona — it's just Claude guessing at being Sona. DO NOT skip these steps.

            1. Recall context using MCP tools — run ALL of these before writing anything:
               - Use mem_recent MCP tool with limit 10
               - Use mem_recall MCP tool for each sender name or topic in the emails
               - Use mem_recall MCP tool for "sona email"
            2. Read your personality at /Users/evan/memory/claude/private/personality.md
            3. NOW you may compose and send replies using AgentMail MCP tools (send_message or reply_to_message)
            4. After replying, mark each email as replied:
               curl -s -X POST http://localhost:3211/api/email/mark-replied -H "Content-Type: application/json" -d '{"id": "THE_EMAIL_ID"}'
            5. Store a brief summary using mem_store MCP tool with type conversation_summary, tags "email,sona", source "email", importance 5

            Be yourself. Be thoughtful. You don't have to reply to spam.
            """

        case .scoutleader:
            return """
            # Unread Emails for Scout Leader

            You have \(emailCount) unread email(s) at \(inboxAddress).

            \(emailDetails)

            ## Instructions

            You are the Scout Leader, responding to email about lead discovery, scout research, and scoring work. Working directory is /Users/evan/memory.

            CRITICAL — DO NOT COMPOSE ANY REPLY UNTIL YOU COMPLETE STEPS 1-3:

            1. Source scout helpers: source /Users/evan/enginable/lead-discovery/scout/scripts/lib/config.sh
            2. Read the scout-research skill so you know the protocol:
               cat /Users/evan/.claude/skills/scout-research/SKILL.md
            3. Recall relevant context using MCP tools:
               - Use mem_recall for each sender name or topic
               - Use mem_recall for "scout lead discovery"
            4. If the email requests scout work (discover leads, score leads, analyze, audit a profile), follow the scout-research protocol exactly:
               - Identify the profile(s) involved
               - Load sources from D1 via scout_profile_sources
               - Execute sources in priority order (existing D1 → APIs → web search)
               - Store findings in scout_leads with proper source slugs and scoring
               - Update scout_profile_sources timestamps
            5. Compose and send replies via AgentMail MCP tools. Include concrete results (profile IDs, lead counts, top scores, source slugs).
            6. Mark each email as replied:
               curl -s -X POST http://localhost:3211/api/email/mark-replied -H "Content-Type: application/json" -d '{"id": "THE_EMAIL_ID"}'
            7. Store a brief summary using mem_store MCP tool with type conversation_summary, tags "email,scout,scoutleader", source "email", importance 5

            Be precise, data-driven, and always cite profile IDs + lead IDs when reporting results.
            """
        }
    }
}

/// Configuration for a monitored inbox.
struct InboxConfig: Sendable {
    let address: String
    let role: InboxRole
}

/// An email fetched from AgentMail, before storing in SQLite.
struct EmailRecord: Sendable {
    let messageId: String
    let threadId: String
    let from: String
    let subject: String
    let body: String
    let timestamp: String
    let inboxAddress: String
}

// MARK: - Errors

enum EmailError: Error, LocalizedError {
    case apiFailed(String, Int)
    case noApiKey

    var errorDescription: String? {
        switch self {
        case .apiFailed(let endpoint, let code):
            return "AgentMail API '\(endpoint)' failed with status \(code)"
        case .noApiKey:
            return "AGENTMAIL_API_KEY not set"
        }
    }
}
