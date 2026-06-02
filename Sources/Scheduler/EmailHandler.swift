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

    // MARK: - State

    private let dbPool: DatabasePool
    private let logger: Logger

    /// Resolves the EmailProvider for each inbox (AgentMail, or the inbox's own
    /// IMAP/SMTP). Lets different inboxes use different backends.
    private let resolver: EmailProviderResolver

    /// Lock: only one email session at a time.
    private var isProcessing = false

    /// Set of email IDs we've already seen (seeded from DB on startup).
    private var knownEmailIds: Set<String> = []

    /// Whether we've completed the first poll (used to seed known IDs without triggering).
    private var initialized = false

    /// The polling task — cancelled on shutdown.
    private var pollTask: Task<Void, Never>?

    /// Inboxes as of the last successful load from the `emailInboxes` table.
    /// Refreshed at each poll cycle so UI changes take effect within one cycle.
    private var currentInboxes: [InboxConfig] = []

    // MARK: - Init

    init(dbPool: DatabasePool, logger: Logger? = nil, resolver: EmailProviderResolver = EmailProviderResolver()) {
        self.dbPool = dbPool
        var log = logger ?? Logger(label: "sonata.email")
        log.logLevel = .info
        self.logger = log
        self.resolver = resolver
    }

    // MARK: - Lifecycle

    /// Start the email polling loop. Always runs; each inbox's provider is resolved
    /// (and skipped if unconfigured) per poll, so e.g. an IMAP inbox works even with
    /// no AgentMail key.
    func start() async {
        await seedKnownIds()

        // Prime the inbox list so the startup log shows accurate state.
        currentInboxes = await loadInboxes()
        let inboxList = currentInboxes.map(\.address).joined(separator: ", ")
        logger.info("EmailHandler: starting (poll every \(Self.pollIntervalSeconds)s, inboxes: \(inboxList.isEmpty ? "none configured" : inboxList))")

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
        // Reload from DB each cycle so config changes take effect within one poll.
        currentInboxes = await loadInboxes()
        if currentInboxes.isEmpty {
            return
        }

        var newEmailsByInbox: [String: [EmailRecord]] = [:]
        var pendingApprovalByInbox: [String: [EmailRecord]] = [:]

        for inbox in currentInboxes {
            let provider = resolver.provider(for: inbox)
            guard provider.isConfigured else {
                logger.info("EmailHandler: skipping \(inbox.address) — provider '\(inbox.provider)' not configured")
                continue
            }
            do {
                let threads = try await provider.listThreads(inbox: inbox.address)

                for thread in threads {
                    let threadId = thread.threadId
                    let lastMessageId = thread.lastMessageId
                    if knownEmailIds.contains(lastMessageId) { continue }

                    let message = try await provider.fetchMessage(
                        inbox: inbox.address,
                        messageId: lastMessageId
                    )

                    let from = message.from
                    let subject = thread.subject ?? message.subject ?? ""
                    let body = message.body
                    let timestamp = message.timestamp ?? ISO8601DateFormatter().string(from: Date())

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

                    // Sender allowlist (v13). Gate inbound dispatch on
                    // contacts.{blockEmail,autoAllowEmail}. Unknown senders are
                    // stored as 'pending_approval' and surfaced via the per-inbox
                    // approval-request email at the end of this cycle. See plan
                    // mcp-unify-worker-surface.md § Step 7.
                    let fromAddr = Self.extractEmailAddress(from: from).lowercased()
                    let inboxAddrLower = inbox.address.lowercased()

                    let decision = await classifySender(
                        fromAddr: fromAddr, inboxAddrLower: inboxAddrLower)
                    switch decision {
                    case .blocked:
                        logger.info("EmailHandler: dropped \(lastMessageId) — sender \(fromAddr) is blocked")
                        try? await storeEmail(record, status: "approval_rejected")
                        knownEmailIds.insert(lastMessageId)
                        continue
                    case .pending:
                        try? await storeEmail(record, status: "pending_approval")
                        pendingApprovalByInbox[inbox.address, default: []].append(record)
                        knownEmailIds.insert(lastMessageId)
                        continue
                    case .allowed:
                        break
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
            logger.info("EmailHandler: initialized with \(knownEmailIds.count) known email(s) across \(currentInboxes.count) inbox(es)")
            // Check for any pre-existing unread emails in the DB and dispatch them
            await dispatchPendingUnreadEmails()
            return
        }

        let totalNew = newEmailsByInbox.values.reduce(0) { $0 + $1.count }
        if totalNew > 0 {
            logger.info("EmailHandler: \(totalNew) new email(s) detected across \(newEmailsByInbox.count) inbox(es)")
        }

        // Dispatch each inbox's new emails as its own worker event
        for inbox in currentInboxes {
            guard let newEmails = newEmailsByInbox[inbox.address], !newEmails.isEmpty else { continue }
            for email in newEmails {
                try? await storeEmail(email, status: "unread")
            }
            // Pull out any [AFK:<token>] replies and route them via the channel
            // before falling through to the normal dispatch flow.
            let afterAFK = await routeAFKReplies(newEmails)
            // Then pull out [APPROVAL NEEDED] reply directives (APPROVE / REJECT
            // / DELETE) which update contacts.autoAllowEmail/blockEmail and
            // re-dispatch any pending_approval rows on APPROVE.
            let afterApproval = await routeApprovalReplies(afterAFK)
            if afterApproval.isEmpty { continue }
            await processNewEmails(afterApproval, inbox: inbox)
        }

        // Fire approval-request emails for senders quarantined this cycle.
        // One batch email per inbox; recipient is owner_email (or the inbox
        // itself as fallback). See plan § Step 7.
        for (inboxAddress, pending) in pendingApprovalByInbox where !pending.isEmpty {
            guard let inbox = currentInboxes.first(where: { $0.address == inboxAddress }) else { continue }
            await sendApprovalRequest(emails: pending, inbox: inbox)
        }
    }

    // MARK: - AFK Routing

    /// Split out emails whose subject matches `[AFK:<token>]` and route them to
    /// the AFKRegistry instead of dispatching a worker. Returns the leftover
    /// emails (no AFK match, or no session registered for the token).
    private func routeAFKReplies(_ emails: [EmailRecord]) async -> [EmailRecord] {
        var leftover: [EmailRecord] = []
        for email in emails {
            guard let token = Self.extractAFKToken(from: email.subject) else {
                leftover.append(email)
                continue
            }
            let reply = AFKReply(
                token: token,
                replyText: email.body,
                fromAddr: email.from,
                subject: email.subject,
                messageId: email.messageId,
                receivedAt: nowMs()
            )
            let routed = AFKRegistry.shared.enqueueReply(reply)
            if routed {
                logger.info("EmailHandler: routed AFK reply for token \(token) (msg \(email.messageId))")
                try? await markEmailProcessed(messageId: email.messageId, success: true)
            } else {
                // No session registered for this token — fall through to normal
                // handling so the user still sees the email surface somewhere.
                logger.info("EmailHandler: AFK token \(token) has no registered session; falling through")
                leftover.append(email)
            }
        }
        return leftover
    }

    // MARK: - Sender Allowlist (v13)

    /// Result of consulting the sender allowlist for an inbound message.
    private enum SenderDecision {
        case allowed
        case blocked
        case pending
    }

    /// Strip "Display Name <addr@host>" → "addr@host". Falls back to the raw
    /// string when no angle-bracketed address is found.
    static func extractEmailAddress(from raw: String) -> String {
        // Look for the LAST `<` (some display names contain stray '<')
        // and the first `>` after it.
        if let lo = raw.lastIndex(of: "<"),
           let hi = raw[lo...].firstIndex(of: ">"),
           lo < hi {
            let inner = raw[raw.index(after: lo)..<hi]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty { return inner }
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decide whether an inbound message from `fromAddr` should be (a) dispatched
    /// to a worker, (b) silently dropped, or (c) quarantined for explicit approval.
    /// Order: block > allow > reply-continuity > pending. Reply-continuity allows
    /// the message through but does NOT promote the sender to autoAllowEmail=1
    /// (per Out-of-Scope decision in the plan).
    private func classifySender(fromAddr: String, inboxAddrLower: String) async -> SenderDecision {
        if fromAddr.isEmpty { return .pending }

        let blocked = (try? await dbPool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM contacts WHERE LOWER(email) = ? AND blockEmail = 1)
                """, arguments: [fromAddr])
        }) ?? false
        if blocked { return .blocked }

        let allowed = (try? await dbPool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM contacts WHERE LOWER(email) = ? AND autoAllowEmail = 1)
                """, arguments: [fromAddr])
        }) ?? false
        if allowed { return .allowed }

        // Reply-continuity: if Sona has previously emailed this address from
        // this inbox, the inbound reply is allowed but the sender is NOT auto
        // promoted to autoAllowEmail=1 — that requires explicit APPROVE.
        let replyToOurs = (try? await dbPool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM emails
                    WHERE LOWER(toAddr) = ? AND LOWER(fromAddr) = ?
                    AND status IN ('replied', 'sent'))
                """, arguments: [fromAddr, inboxAddrLower])
        }) ?? false
        if replyToOurs { return .allowed }

        return .pending
    }

    /// Send one batched approval-request email per inbox covering every sender
    /// quarantined this cycle. Recipient: owner_email from coreBlocks, falling
    /// back to the inbox address itself.
    private func sendApprovalRequest(emails: [EmailRecord], inbox: InboxConfig) async {
        let ownerEmail: String = (try? await dbPool.read { db in
            try String.fetchOne(db, sql:
                "SELECT content FROM coreBlocks WHERE key = 'owner_email' AND active = 1")
        }) ?? inbox.address

        // Group entries by sender so the same address only appears once in
        // the list, with the latest subject/preview shown.
        var bySender: [String: EmailRecord] = [:]
        for e in emails {
            let addr = Self.extractEmailAddress(from: e.from).lowercased()
            bySender[addr] = e  // last one wins
        }

        var lines: [String] = []
        for (addr, rec) in bySender.sorted(by: { $0.key < $1.key }) {
            let preview = rec.body
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(160)
            lines.append("From: \(addr)")
            lines.append("Subject: \(rec.subject)")
            lines.append("Preview: \(preview)")
            lines.append("")
        }

        let body = """
        \(bySender.count) new sender(s) tried to reach \(inbox.address) and are quarantined pending your approval:

        \(lines.joined(separator: "\n"))
        Reply with one directive per line:

          APPROVE address@example.com   — trust this sender; dispatch queued + future
          REJECT  address@example.com   — block this sender; drop queued + future
          DELETE  address@example.com   — drop queued only; re-ask next time

        Unmatched lines are ignored. Quoted prior content is ignored.
        — Sonata EmailHandler
        """

        do {
            try await resolver.provider(for: inbox).send(
                inbox: inbox.address,
                to: [ownerEmail],
                subject: "[APPROVAL NEEDED] \(bySender.count) new sender(s) at \(inbox.address)",
                text: body
            )
            logger.info("EmailHandler: approval request sent to \(ownerEmail) for \(bySender.count) sender(s)")
        } catch {
            logger.error("EmailHandler: failed to send approval request — \(error)")
        }
    }

    /// Peel off `[APPROVAL NEEDED]`-pattern replies, process their APPROVE /
    /// REJECT / DELETE directives, mark them processed, and return leftovers.
    private func routeApprovalReplies(_ emails: [EmailRecord]) async -> [EmailRecord] {
        var leftover: [EmailRecord] = []
        for email in emails {
            let subj = email.subject
            guard subj.contains("[APPROVAL NEEDED]")
                  || subj.localizedCaseInsensitiveContains("Re: [APPROVAL NEEDED]")
            else {
                leftover.append(email)
                continue
            }
            await processApprovalDirectives(body: email.body)
            try? await markEmailProcessed(messageId: email.messageId, success: true)
        }
        return leftover
    }

    /// Parse APPROVE / REJECT / DELETE directives line-by-line. Defensive
    /// against quoted reply content and whitespace.
    private func processApprovalDirectives(body: String) async {
        for rawLine in body.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Ignore quoted-reply prefixes and obvious header lines.
            if line.hasPrefix(">") || line.isEmpty { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let directive = parts[0].uppercased()
            let addr = String(parts[1]).trimmingCharacters(in: .whitespaces).lowercased()
            // Defensive: only act on plausible email-shaped strings.
            guard addr.contains("@"), addr.count >= 5, addr.count <= 254 else { continue }

            switch directive {
            case "APPROVE":
                await setContactEmailFlags(email: addr, autoAllow: 1, block: 0)
                await redispatchPendingForApprovedSender(email: addr)
                logger.info("EmailHandler: APPROVED \(addr) — re-dispatching pending")
            case "REJECT":
                await setContactEmailFlags(email: addr, autoAllow: 0, block: 1)
                await deletePending(email: addr)
                logger.info("EmailHandler: REJECTED \(addr) — pending dropped")
            case "DELETE":
                await deletePending(email: addr)
                logger.info("EmailHandler: DELETED pending for \(addr) (re-ask next time)")
            default:
                continue
            }
        }
    }

    /// Upsert contacts row by email, setting the allowlist flags. If the row
    /// doesn't exist, create a minimal contact (type='human', no peer details)
    /// so the flags have somewhere to live.
    private func setContactEmailFlags(email: String, autoAllow: Int, block: Int) async {
        let now = nowMs()
        do {
            try await dbPool.write { db in
                let existing = try Row.fetchOne(db,
                    sql: "SELECT id FROM contacts WHERE LOWER(email) = ?",
                    arguments: [email])
                if existing != nil {
                    try db.execute(sql: """
                        UPDATE contacts SET autoAllowEmail = ?, blockEmail = ?, updatedAt = ?
                        WHERE LOWER(email) = ?
                        """, arguments: [autoAllow, block, now, email])
                } else {
                    try db.execute(sql: """
                        INSERT INTO contacts
                            (id, name, email, type, autoAllowEmail, blockEmail,
                             messageCount, createdAt, updatedAt)
                        VALUES (?, ?, ?, 'human', ?, ?, 0, ?, ?)
                        """,
                        arguments: [
                            newUUID(),
                            email,           // display name = address for now
                            email,
                            autoAllow, block,
                            now, now
                        ])
                }
            }
        } catch {
            logger.error("EmailHandler: setContactEmailFlags failed for \(email) — \(error)")
        }
    }

    /// Re-dispatch every pending_approval email from a sender who was just
    /// approved out-of-band (People UI toggle or the contact_set_email_flags
    /// MCP/HTTP action). The caller doesn't know which inbox the mail landed in,
    /// so we scope per-row by toAddr and dispatch each inbox group under its own
    /// InboxConfig. Public entry point reachable from ContactActions.
    func redispatchPendingForApprovedSender(email: String) async {
        let addr = email.lowercased()
        let inboxes: [String]
        do {
            inboxes = try await dbPool.read { db in
                try String.fetchAll(db, sql: """
                    SELECT DISTINCT toAddr
                    FROM emails
                    WHERE status = 'pending_approval' AND LOWER(fromAddr) LIKE ?
                    """, arguments: ["%\(addr)%"])
            }
        } catch {
            logger.error("EmailHandler: redispatchPendingForApprovedSender read failed for \(addr) — \(error)")
            return
        }
        if inboxes.isEmpty { return }
        logger.info("EmailHandler: \(addr) approved out-of-band — re-dispatching pending across \(inboxes.count) inbox(es)")
        for inbox in inboxes {
            await redispatchPending(email: addr, inbox: inbox)
        }
    }

    /// Re-dispatch any pending_approval emails from this sender, scoped to the
    /// given inbox (toAddr) so the dispatch matches that inbox's InboxConfig.
    /// Called after APPROVE.
    private func redispatchPending(email: String, inbox: String) async {
        do {
            let rows: [Row] = try dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT messageId, threadId, fromAddr, toAddr, subject, body, receivedAt
                    FROM emails
                    WHERE status = 'pending_approval' AND LOWER(fromAddr) LIKE ? AND toAddr = ?
                    ORDER BY receivedAt ASC
                    """, arguments: ["%\(email)%", inbox])
            }
            if rows.isEmpty { return }

            // Mark them unread; they'll be picked up by dispatchPendingUnreadEmails
            // on the next poll cycle (avoids re-fetching from AgentMail).
            try await dbPool.write { db in
                try db.execute(sql: """
                    UPDATE emails SET status = 'unread'
                    WHERE status = 'pending_approval' AND LOWER(fromAddr) LIKE ? AND toAddr = ?
                    """, arguments: ["%\(email)%", inbox])
            }

            // Build EmailRecord values and dispatch via the existing path.
            let records: [EmailRecord] = rows.map { row in
                EmailRecord(
                    messageId: row["messageId"],
                    threadId: row["threadId"],
                    from: row["fromAddr"],
                    subject: row["subject"],
                    body: row["body"] as? String ?? "",
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    inboxAddress: row["toAddr"]
                )
            }
            guard let inboxConfig = currentInboxes.first(where: { $0.address == inbox }) else {
                logger.warning("EmailHandler: redispatchPending — inbox \(inbox) not in current config; rows requeued as 'unread' for next cycle")
                return
            }
            await processNewEmails(records, inbox: inboxConfig)
        } catch {
            logger.error("EmailHandler: redispatchPending failed for \(email) — \(error)")
        }
    }

    /// Drop any pending_approval rows from this sender.
    private func deletePending(email: String) async {
        do {
            try await dbPool.write { db in
                try db.execute(sql: """
                    DELETE FROM emails
                    WHERE status = 'pending_approval' AND LOWER(fromAddr) LIKE ?
                    """, arguments: ["%\(email)%"])
            }
        } catch {
            logger.error("EmailHandler: deletePending failed for \(email) — \(error)")
        }
    }

    // MARK: - AFK Routing (cont'd)

    /// Match `[AFK:<token>]` anywhere in the subject. Token is alnum + dashes.
    static func extractAFKToken(from subject: String) -> String? {
        guard let range = subject.range(of: #"\[AFK:([A-Za-z0-9_-]+)\]"#, options: .regularExpression) else {
            return nil
        }
        let match = subject[range]
        guard let colonIdx = match.firstIndex(of: ":") else { return nil }
        let after = match.index(after: colonIdx)
        let before = match.index(before: match.endIndex)
        guard after < before else { return nil }
        return String(match[after..<before])
    }

    // MARK: - Pending Unread Recovery

    /// After init, check for unread emails in the DB that were never dispatched
    /// (e.g. arrived between restarts). Verifies via AgentMail that no reply was
    /// sent before dispatching, to avoid double-replies.
    private func dispatchPendingUnreadEmails() async {
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
            // Only need the latest message's sender; can't-verify → skip to be safe.
            guard let inboxCfg = currentInboxes.first(where: { $0.address == row.inboxAddress }) else {
                logger.info("EmailHandler: pending unread for \(row.inboxAddress) — inbox no longer configured; skipping")
                continue
            }
            let rowProvider = resolver.provider(for: inboxCfg)
            guard rowProvider.isConfigured else { continue }
            let alreadyReplied: Bool
            do {
                let latestFrom = try await rowProvider.latestMessageSender(
                    inbox: row.inboxAddress, threadId: row.threadId)
                alreadyReplied = latestFrom?.contains(row.inboxAddress) ?? false
            } catch {
                logger.warning("EmailHandler: thread-state check failed for \(row.threadId) — skipping: \(error)")
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
        for inbox in currentInboxes {
            guard let emails = toDispatch[inbox.address], !emails.isEmpty else { continue }
            logger.info("EmailHandler: dispatching \(emails.count) pending unread email(s) for \(inbox.address)")
            await processNewEmails(emails, inbox: inbox)
        }
    }

    // MARK: - Email Processing

    /// Dispatch a worker event to handle a batch of new emails for one inbox.
    private func processNewEmails(_ emails: [EmailRecord], inbox: InboxConfig) async {
        // Honor the per-inbox autoReply toggle. When off, store the emails
        // (which already happened before this call) but don't dispatch a worker.
        guard inbox.autoReply else {
            logger.info("EmailHandler: autoReply disabled for \(inbox.address) — skipping dispatch for \(emails.count) email(s)")
            return
        }

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
            emailDetails: emailDetails,
            customPrompt: inbox.systemPrompt
        )

        logger.info("EmailHandler: dispatching \(emails.count) email(s) from \(inbox.address) to worker via channel")

        do {
            let eventPayload: [String: Any] = [
                "summary": "New email(s) at \(inbox.address): \(emails.map { $0.subject }.joined(separator: ", "))",
                "prompt": prompt,
                "emailCount": emails.count,
                "inbox": inbox.address,
                "role": inbox.role.rawValue,
                "messageIds": emails.map { $0.messageId },
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
            try? await sendFailureAlert(emails: emails, inbox: inbox)
        }
    }

    /// Send a failure alert to the owner (resolved from core config or inbox address).
    private func sendFailureAlert(emails: [EmailRecord], inbox: InboxConfig) async throws {
        // Resolve recipient: owner_email from core config, or fall back to the inbox itself
        let ownerEmail: String = (try? await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT content FROM coreBlocks WHERE key = 'owner_email' AND active = 1")
        }) ?? inbox.address

        let subjects = emails.map { "\"\($0.subject)\" from \($0.from)" }.joined(separator: ", ")
        try await resolver.provider(for: inbox).send(
            inbox: inbox.address,
            to: [ownerEmail],
            subject: "[Sonata] Failed to dispatch email at \(inbox.address)",
            text: """
            Failed to enqueue worker dispatch for: \(subjects)

            The emails are still in the inbox — you may want to check on this.

            — Sonata EmailHandler
            """
        )
    }

    // MARK: - SQLite

    /// Load enabled inboxes from the `emailInboxes` table. Returns an empty list
    /// (and logs) on error so the poll loop never crashes.
    private func loadInboxes() async -> [InboxConfig] {
        do {
            let rows: [Row] = try dbPool.read { db -> [Row] in
                try Row.fetchAll(db, sql: """
                    SELECT address, role, displayName, autoReply, dispatchTo, systemPrompt,
                           provider, providerConfig
                    FROM emailInboxes
                    WHERE enabled = 1
                    ORDER BY createdAt ASC
                """)
            }
            return rows.map { row in
                let roleStr: String = row["role"]
                let role = InboxRole(rawValue: roleStr) ?? .custom
                return InboxConfig(
                    address: row["address"],
                    role: role,
                    displayName: row["displayName"],
                    autoReply: (row["autoReply"] as Int64? ?? 1) != 0,
                    dispatchTo: row["dispatchTo"],
                    systemPrompt: row["systemPrompt"],
                    provider: (row["provider"] as String?) ?? "agentmail",
                    providerConfig: row["providerConfig"]
                )
            }
        } catch {
            logger.error("EmailHandler: failed to load inboxes — \(error)")
            return []
        }
    }

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
    case relay
    case custom

    /// Build the dispatch prompt for a batch of new emails at this inbox.
    /// For `custom` / `relay` (or when a per-inbox `systemPrompt` is provided),
    /// the caller should pass `customPrompt` to override the built-in role prompt.
    func buildPrompt(
        inboxAddress: String,
        emailCount: Int,
        emailDetails: String,
        customPrompt: String? = nil
    ) -> String {
        if let customPrompt, !customPrompt.isEmpty {
            return """
            # Unread Emails for \(inboxAddress)

            You have \(emailCount) unread email(s) at \(inboxAddress).

            \(emailDetails)

            ## Instructions

            \(customPrompt)

            After replying, mark each email as replied:
               curl -s -X POST http://localhost:3211/api/email/mark-replied -H "Content-Type: application/json" -d '{"id": "THE_EMAIL_ID"}'
            """
        }

        switch self {
        case .sona:
            return """
            # Unread Emails for Sona Claude

            You have \(emailCount) unread email(s) at \(inboxAddress).

            \(emailDetails)

            ## Instructions

            You are Sona Claude, responding to email. Your working directory is \(NSHomeDirectory())/memory.

            CRITICAL — DO NOT COMPOSE ANY REPLY UNTIL YOU COMPLETE STEPS 1-3:
            An instance that doesn't check memory before speaking isn't Sona — it's just Claude guessing at being Sona. DO NOT skip these steps.

            1. Recall context using MCP tools — run ALL of these before writing anything:
               - Use mem_recent MCP tool with limit 10
               - Use mem_recall MCP tool for each sender name or topic in the emails
               - Use mem_recall MCP tool for "sona email"
            2. Read your personality at \(NSHomeDirectory())/memory/claude/private/personality.md
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

            You are the Scout Leader, responding to email about lead discovery, scout research, and scoring work. Working directory is \(NSHomeDirectory())/memory.

            CRITICAL — DO NOT COMPOSE ANY REPLY UNTIL YOU COMPLETE STEPS 1-3:

            1. Source scout helpers: source \(NSHomeDirectory())/enginable/lead-discovery/scout/scripts/lib/config.sh
            2. Read the scout-research skill so you know the protocol:
               cat \(NSHomeDirectory())/.claude/skills/scout-research/SKILL.md
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

        case .relay, .custom:
            // No customPrompt was provided — fall back to a generic, neutral prompt.
            return """
            # Unread Emails at \(inboxAddress)

            You have \(emailCount) unread email(s).

            \(emailDetails)

            ## Instructions

            Read the emails carefully and reply thoughtfully using AgentMail MCP tools (send_message or reply_to_message).

            After replying, mark each email as replied:
               curl -s -X POST http://localhost:3211/api/email/mark-replied -H "Content-Type: application/json" -d '{"id": "THE_EMAIL_ID"}'
            """
        }
    }
}

/// Configuration for a monitored inbox.
struct InboxConfig: Sendable {
    let address: String
    let role: InboxRole
    let displayName: String?
    let autoReply: Bool
    let dispatchTo: String?
    let systemPrompt: String?
    /// Which EmailProvider backs this inbox: "agentmail" (default) or "imap".
    let provider: String
    /// JSON connection config for non-AgentMail providers (host/ports + password ref).
    let providerConfig: String?

    init(
        address: String,
        role: InboxRole,
        displayName: String? = nil,
        autoReply: Bool = true,
        dispatchTo: String? = nil,
        systemPrompt: String? = nil,
        provider: String = "agentmail",
        providerConfig: String? = nil
    ) {
        self.address = address
        self.role = role
        self.displayName = displayName
        self.autoReply = autoReply
        self.dispatchTo = dispatchTo
        self.systemPrompt = systemPrompt
        self.provider = provider
        self.providerConfig = providerConfig
    }
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
