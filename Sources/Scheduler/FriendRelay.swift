import Foundation
import GRDB
import Logging

/// Polls AI friends' AgentMail inboxes and generates replies via their provider APIs.
/// Replaces the friend relay in `sona-scheduler.js`.
actor FriendRelay {

    // MARK: - Configuration

    /// Poll interval: 15 seconds.
    static let pollIntervalSeconds: TimeInterval = 15

    /// AgentMail API base URL.
    private static let apiBase = "https://api.agentmail.to/v0"

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
    private let agentMailKey: String?

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

    init(dbPool: DatabasePool, logger: Logger? = nil) {
        self.dbPool = dbPool
        var log = logger ?? Logger(label: "sonata.friend-relay")
        log.logLevel = .info
        self.logger = log
        self.agentMailKey = SecretStore.get("AGENTMAIL_API_KEY")
    }

    // MARK: - Lifecycle

    /// Start the friend relay polling loop.
    func start() async {
        guard let key = agentMailKey, !key.isEmpty else {
            logger.warning("FriendRelay: disabled (no AGENTMAIL_API_KEY)")
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

        guard let apiKey = agentMailKey, !apiKey.isEmpty else { return }

        // Refresh friends list from contacts DB
        await refreshFriends()

        for friend in friends {
            do {
                try await pollFriendInbox(friend: friend, apiKey: apiKey)
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
    private func pollFriendInbox(friend: Friend, apiKey: String) async throws {
        // Fetch recent threads
        let threads = try await fetchThreads(inboxId: friend.email, apiKey: apiKey)

        for thread in threads {
            guard let threadId = thread["threadId"] as? String,
                  let lastMessageId = thread["lastMessageId"] as? String else { continue }

            // Skip already handled
            if handledMessages.contains(lastMessageId) { continue }

            // On first run, seed without replying
            if !initialized {
                handledMessages.insert(lastMessageId)
                await saveHandledState()
                continue
            }

            // Fetch the last message to check sender
            let lastMsg = try await fetchMessage(inboxId: friend.email, messageId: lastMessageId, apiKey: apiKey)
            let lastFrom = lastMsg["from"] as? String ?? ""

            // Skip if the last message is FROM the friend (they already replied)
            if lastFrom.contains(friend.email) {
                handledMessages.insert(lastMessageId)
                await saveHandledState()
                continue
            }

            // Fetch all messages in this thread
            let threadMessages = try await fetchInboxMessages(inboxId: friend.email, apiKey: apiKey)
                .filter { ($0["threadId"] as? String) == threadId }
                .sorted { (a, b) in
                    let tsA = a["timestamp"] as? String ?? ""
                    let tsB = b["timestamp"] as? String ?? ""
                    return tsA < tsB
                }

            // Build conversation history for the provider API
            var conversationMessages: [[String: String]] = []
            for msg in threadMessages {
                var text = msg["text"] as? String ?? msg["extractedText"] as? String
                let from = msg["from"] as? String ?? ""

                // If no text in list data, fetch full message
                if text == nil {
                    if let msgId = msg["messageId"] as? String {
                        let fullMsg = try await fetchMessage(inboxId: friend.email, messageId: msgId, apiKey: apiKey)
                        text = fullMsg["text"] as? String ?? fullMsg["extractedText"] as? String ?? "(no content)"
                    }
                }

                let isFriend = from.contains(friend.email)
                conversationMessages.append([
                    "role": isFriend ? "assistant" : "user",
                    "content": text ?? "(no content)",
                ])
            }

            let subject = thread["subject"] as? String ?? "(no subject)"
            logger.info("FriendRelay: \(friend.name) has new message in thread \"\(subject)\" — generating reply")

            // Call provider API
            let reply = try await callProviderAPI(
                friend: friend,
                messages: conversationMessages
            )

            if let reply {
                // Reply via AgentMail
                try await replyToMessage(
                    inboxId: friend.email,
                    messageId: lastMessageId,
                    text: reply,
                    apiKey: apiKey
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

    /// Call the appropriate provider API (OpenAI/OpenRouter) for a friend.
    private func callProviderAPI(
        friend: Friend,
        messages: [[String: String]]
    ) async throws -> String? {
        // Determine endpoint and key
        let env = ProcessInfo.processInfo.environment
        let openRouterKey = env["OPENROUTER_API_KEY"]
        let openAIKey = env["OPENAI_API_KEY"]

        let apiKey: String
        let baseURL: String
        let model: String

        if let orKey = openRouterKey, !orKey.isEmpty {
            apiKey = orKey
            baseURL = "https://openrouter.ai/api/v1/chat/completions"
            // OpenRouter requires provider prefix
            model = friend.model.contains("/") ? friend.model : "openai/\(friend.model)"
        } else if let oaKey = openAIKey, !oaKey.isEmpty {
            apiKey = oaKey
            baseURL = "https://api.openai.com/v1/chat/completions"
            model = friend.model
        } else {
            logger.error("FriendRelay: no API key set (checked OPENROUTER_API_KEY, OPENAI_API_KEY)")
            return nil
        }

        // Build request
        let url = URL(string: baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build messages array with system prompt
        var allMessages: [[String: String]] = [
            ["role": "system", "content": friend.systemPrompt]
        ]
        allMessages.append(contentsOf: messages)

        let body: [String: Any] = [
            "model": model,
            "messages": allMessages,
            "max_tokens": 1500,
            "temperature": 0.8,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("FriendRelay: provider API error \(statusCode): \(body.prefix(200))")
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

    // MARK: - AgentMail API

    /// Fetch threads from an inbox.
    private func fetchThreads(inboxId: String, apiKey: String) async throws -> [[String: Any]] {
        let url = URL(string: "\(Self.apiBase)/inboxes/\(inboxId)/threads?limit=10")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let threads = json["threads"] as? [[String: Any]] else {
            return []
        }
        return threads
    }

    /// Fetch a single message.
    private func fetchMessage(inboxId: String, messageId: String, apiKey: String) async throws -> [String: Any] {
        let url = URL(string: "\(Self.apiBase)/inboxes/\(inboxId)/messages/\(messageId)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return [:]
        }

        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Fetch all messages from an inbox.
    private func fetchInboxMessages(inboxId: String, apiKey: String) async throws -> [[String: Any]] {
        let url = URL(string: "\(Self.apiBase)/inboxes/\(inboxId)/messages?limit=50")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else {
            return []
        }
        return messages
    }

    /// Reply to a message via AgentMail.
    private func replyToMessage(inboxId: String, messageId: String, text: String, apiKey: String) async throws {
        let url = URL(string: "\(Self.apiBase)/inboxes/\(inboxId)/messages/\(messageId)/reply")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["text": text]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FriendRelayError.replyFailed(statusCode)
        }
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

    /// Key prefix for appState table.
    private static let stateKey = "friend.relay.handled"

    /// Load handled message IDs from appState table.
    private func loadHandledState() async {
        do {
            let value: String? = try await dbPool.read { db in
                try String.fetchOne(db, sql: """
                    SELECT value FROM appState WHERE key = ?
                """, arguments: [Self.stateKey])
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

            try await dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO appState (key, value, updatedAt)
                    VALUES (?, ?, datetime('now'))
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
                """, arguments: [Self.stateKey, value])
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
