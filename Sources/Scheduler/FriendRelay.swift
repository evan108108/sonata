import Foundation
import GRDB
import Logging

/// Polls AI friends' AgentMail inboxes and generates replies via their provider APIs.
/// Replaces the friend relay in `sona-scheduler.js`.
actor FriendRelay {

    // MARK: - Configuration

    /// Poll interval: 15 seconds.
    static let pollIntervalSeconds: TimeInterval = 15

    /// Convex HTTP API for loading contacts.
    private static let convexAPI = "http://localhost:3211"

    // MARK: - Types

    /// An AI friend loaded from the contacts table.
    struct Friend: Sendable {
        let name: String
        let email: String
        let provider: String     // "openai", "openrouter", etc.
        let model: String        // e.g. "gpt-4o"
        let systemPrompt: String
    }

    // MARK: - State

    private let dbPool: DatabasePool
    private let logger: Logger

    /// Pluggable email backend (AgentMail today) — shared with EmailHandler so the
    /// AgentMail wire format lives in exactly one place.
    private let provider: EmailProvider

    /// Set of message IDs we've already handled.
    private var handledMessages: Set<String> = []

    /// Whether we've completed the first poll (seed IDs without replying).
    private var initialized = false

    /// Cached friend list (refreshed each poll).
    private var friends: [Friend] = []

    /// Lock: prevent overlapping polls.
    private var isPolling = false

    /// The polling task.
    private var pollTask: Task<Void, Never>?

    // MARK: - Init

    init(dbPool: DatabasePool, logger: Logger? = nil, provider: EmailProvider = AgentMailProvider()) {
        self.dbPool = dbPool
        var log = logger ?? Logger(label: "sonata.friend-relay")
        log.logLevel = .info
        self.logger = log
        self.provider = provider
    }

    // MARK: - Lifecycle

    /// Start the friend relay polling loop.
    func start() async {
        guard provider.isConfigured else {
            logger.warning("FriendRelay: disabled (email provider not configured)")
            return
        }

        // Load persisted handled message IDs from appState
        await loadHandledState()

        logger.info("FriendRelay: starting (poll every \(Self.pollIntervalSeconds)s)")

        pollTask = Task { [weak self] in
            // Initial poll after 5 seconds
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
            }
        }
    }

    /// Stop polling.
    func shutdown() {
        logger.info("FriendRelay: shutting down")
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Polling

    /// One poll cycle: check each friend's inbox for unanswered messages.
    private func poll() async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        guard provider.isConfigured else { return }

        // Refresh friends list from contacts DB
        await refreshFriends()

        // Idle no-op: if zero hosted AI friends exist, skip the per-friend poll
        // entirely. Saves the network/disk burst every 15s on installs that
        // have no invoked AI peers configured.
        guard !friends.isEmpty else { return }

        for friend in friends {
            do {
                try await pollFriendInbox(friend: friend)
            } catch {
                logger.error("FriendRelay: error polling \(friend.name): \(error)")
            }
        }

        if !initialized {
            initialized = true
            logger.info("FriendRelay: initialized with \(handledMessages.count) known message(s)")
        }
    }

    /// Poll a single friend's inbox.
    private func pollFriendInbox(friend: Friend) async throws {
        // Fetch recent threads
        let threads = try await provider.listThreads(inbox: friend.email)

        for thread in threads {
            let threadId = thread.threadId
            let lastMessageId = thread.lastMessageId

            // Skip already handled
            if handledMessages.contains(lastMessageId) { continue }

            // On first run, seed without replying
            if !initialized {
                handledMessages.insert(lastMessageId)
                await saveHandledState()
                continue
            }

            // Fetch the last message to check sender
            let lastMsg = try await provider.fetchMessage(inbox: friend.email, messageId: lastMessageId)
            let lastFrom = lastMsg.from

            // Skip if the last message is FROM the friend (they already replied)
            if lastFrom.contains(friend.email) {
                handledMessages.insert(lastMessageId)
                await saveHandledState()
                continue
            }

            // Fetch the thread's conversation history (oldest-first, bodies resolved)
            let threadMessages = try await provider.fetchThreadMessages(
                inbox: friend.email, threadId: threadId)

            // Build conversation history for the provider API
            var conversationMessages: [[String: String]] = []
            for msg in threadMessages {
                let isFriend = msg.from.contains(friend.email)
                conversationMessages.append([
                    "role": isFriend ? "assistant" : "user",
                    "content": msg.body.isEmpty ? "(no content)" : msg.body,
                ])
            }

            let subject = thread.subject ?? "(no subject)"
            logger.info("FriendRelay: \(friend.name) has new message in thread \"\(subject)\" — generating reply")

            // Call provider API
            let reply = try await callProviderAPI(
                friend: friend,
                messages: conversationMessages
            )

            if let reply {
                // Reply via the email provider
                try await provider.reply(
                    inbox: friend.email,
                    messageId: lastMessageId,
                    text: reply
                )
                logger.info("FriendRelay: \(friend.name) replied to \"\(subject)\"")

                handledMessages.insert(lastMessageId)
                await saveHandledState()

                // Post a DistributedNotification for any active interactive session
                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name("sonata.friendReply"),
                    object: nil,
                    userInfo: [
                        "friend": friend.name,
                        "subject": subject,
                        "preview": String(reply.prefix(200)),
                    ],
                    deliverImmediately: true
                )
            } else {
                logger.warning("FriendRelay: \(friend.name) failed to generate reply — will retry next poll")
                // Don't mark as handled so we retry
            }
        }
    }

    // MARK: - Provider API

    /// Call the appropriate provider for a friend. Dispatches on
    /// `friend.provider` (per-friend config), not on env vars. Returns the
    /// assistant message content, or nil on any failure (logged).
    private func callProviderAPI(
        friend: Friend,
        messages: [[String: String]]
    ) async throws -> String? {
        var allMessages: [[String: String]] = [
            ["role": "system", "content": friend.systemPrompt]
        ]
        allMessages.append(contentsOf: messages)

        switch friend.provider.lowercased() {
        case "local":
            // Route through the local Llama 3.1 8B server (same one pith uses).
            // No API key required; no per-call cost.
            do {
                return try await ChatServerManager.shared.chatCompletionMessages(
                    messages: allMessages,
                    maxTokens: 1500,
                    temperature: 0.8,
                    jsonObject: false
                )
            } catch {
                logger.error("FriendRelay: local chat call failed for \(friend.name): \(error)")
                return nil
            }

        case "openrouter":
            return try await callHostedChatAPI(
                friend: friend,
                allMessages: allMessages,
                baseURL: "https://openrouter.ai/api/v1/chat/completions",
                apiKeyEnv: "OPENROUTER_API_KEY",
                // OpenRouter requires a provider/model prefix; if the friend's
                // model already has one, pass through, else default to openai/.
                modelOverride: friend.model.contains("/") ? friend.model : "openai/\(friend.model)"
            )

        case "openai":
            return try await callHostedChatAPI(
                friend: friend,
                allMessages: allMessages,
                baseURL: "https://api.openai.com/v1/chat/completions",
                apiKeyEnv: "OPENAI_API_KEY",
                modelOverride: friend.model
            )

        default:
            logger.error("FriendRelay: unknown provider '\(friend.provider)' for \(friend.name); skipping")
            return nil
        }
    }

    /// Generic helper for OpenAI-compatible hosted endpoints (OpenAI direct,
    /// OpenRouter, anything else that speaks /v1/chat/completions and Bearer
    /// auth). Returns nil + logs on missing key or HTTP error.
    private func callHostedChatAPI(
        friend: Friend,
        allMessages: [[String: String]],
        baseURL: String,
        apiKeyEnv: String,
        modelOverride: String
    ) async throws -> String? {
        // Read via SecretStore (Sonata's canonical key path — matches
        // EmbeddingRoutes / BackupManager / EmailProvider). Reading raw
        // ProcessInfo env only works when Sonata is launched from a shell
        // with the var exported; that's not how the app normally runs.
        guard let apiKey = SecretStore.get(apiKeyEnv), !apiKey.isEmpty else {
            logger.error("FriendRelay: \(apiKeyEnv) not in SecretStore; cannot reach \(friend.provider) for \(friend.name)")
            return nil
        }

        let url = URL(string: baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": modelOverride,
            "messages": allMessages,
            "max_tokens": 1500,
            "temperature": 0.8,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("FriendRelay: \(friend.provider) API error \(statusCode): \(body.prefix(200))")
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }

        return content
    }

    // MARK: - Friends Loading

    /// Refresh the friends list from the Convex contacts API.
    private func refreshFriends() async {
        do {
            let url = URL(string: "\(Self.convexAPI)/api/contacts?type=ai")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return
            }

            guard let contacts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return
            }

            var loaded: [Friend] = []
            for contact in contacts {
                // Skip self and contacts without a provider
                if contact["role"] as? String == "self" { continue }
                guard let provider = contact["provider"] as? String, !provider.isEmpty else { continue }
                guard let name = contact["name"] as? String,
                      let email = contact["email"] as? String else { continue }

                let model = contact["model"] as? String ?? "gpt-4o"
                let systemPrompt = contact["systemPrompt"] as? String ?? "You are \(name). Be honest and thoughtful."

                loaded.append(Friend(
                    name: name,
                    email: email,
                    provider: provider,
                    model: model,
                    systemPrompt: systemPrompt
                ))
            }

            if !loaded.isEmpty {
                friends = loaded
            }
        } catch {
            // Keep using cached friends on failure
            logger.debug("FriendRelay: failed to refresh contacts: \(error)")
        }
    }

    // MARK: - State Persistence

    /// `appState.app` namespace for FriendRelay's persisted state. The table
    /// has UNIQUE(app, key) so every caller must provide its own app name.
    private static let stateApp = "friend-relay"

    /// `appState.key` under our app namespace.
    private static let stateKey = "handled"

    /// Load handled message IDs from appState table.
    private func loadHandledState() async {
        do {
            let value: String? = try await dbPool.read { db in
                try String.fetchOne(db, sql: """
                    SELECT value FROM appState WHERE app = ? AND key = ?
                """, arguments: [Self.stateApp, Self.stateKey])
            }

            if let value,
               let data = value.data(using: .utf8),
               let ids = try? JSONSerialization.jsonObject(with: data) as? [String] {
                handledMessages = Set(ids)
                initialized = true // If we have persisted state, we're initialized
                logger.info("FriendRelay: loaded \(handledMessages.count) handled message IDs from DB")
            }
        } catch {
            logger.warning("FriendRelay: failed to load handled state: \(error)")
        }
    }

    /// Persist handled message IDs to appState table.
    private func saveHandledState() async {
        do {
            // Keep only the most recent 500 IDs to prevent unbounded growth
            let idsToSave = Array(handledMessages.suffix(500))
            let data = try JSONSerialization.data(withJSONObject: idsToSave)
            let value = String(data: data, encoding: .utf8) ?? "[]"
            let now = Int64(Date().timeIntervalSince1970 * 1000)

            try await dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO appState (app, key, value, updatedAt)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(app, key) DO UPDATE
                    SET value = excluded.value, updatedAt = excluded.updatedAt
                """, arguments: [Self.stateApp, Self.stateKey, value, now])
            }
        } catch {
            logger.warning("FriendRelay: failed to save handled state: \(error)")
        }
    }
}

// MARK: - Errors

enum FriendRelayError: Error, LocalizedError {
    case replyFailed(Int)
    case noProviderKey

    var errorDescription: String? {
        switch self {
        case .replyFailed(let code):
            return "AgentMail reply failed with status \(code)"
        case .noProviderKey:
            return "No provider API key available"
        }
    }
}
