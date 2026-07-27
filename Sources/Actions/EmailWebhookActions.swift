import Foundation
import Hummingbird

// Action definitions for the AgentMail webhook ingest seam. One action:
// `email_process_agentmail_webhook` — the destination a webhook route points at
// so an AgentMail `message.received` event lands in the same downstream state
// as a poller-caught email, minutes sooner. See the webhook-relay plan
// (sparkling-splashing-garden.md) for the full delivery chain.

// MARK: - Response Types

struct EmailWebhookProcessResponse: Encodable {
    let ok: Bool
    /// "ingested" when the message went through the routing chain,
    /// "skipped" when the envelope wasn't a message.received event.
    let action: String
    let detail: String?
}

// MARK: - Envelope decoding

/// Resolve AgentMail's event envelope from the delivery params. The
/// `webhook_deliver` dispatcher passes the raw webhook body as a JSON string
/// in `body` (with `body_b64` as the base64 fallback for non-UTF-8 bytes);
/// direct callers (manual testing) may instead pass the envelope fields as
/// top-level params, which the final fallback returns verbatim.
private func webhookEnvelope(from params: ActionParams) throws -> [String: Any] {
    if let body = params.string("body"), !body.isEmpty {
        guard let data = body.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ActionError.invalidParam("body", "not a JSON object")
        }
        return json
    }
    if let b64 = params.string("body_b64"), !b64.isEmpty {
        guard let data = Data(base64Encoded: b64),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ActionError.invalidParam("body_b64", "not base64-encoded JSON")
        }
        return json
    }
    return params.all
}

let emailWebhookActions: [SonataAction] = [

    // POST /api/email/webhook/agentmail — process one AgentMail event envelope
    SonataAction(
        name: "email_process_agentmail_webhook",
        description: "Process an AgentMail webhook event envelope. For message.received: fetch the message from AgentMail, run it through the same routing chain as the email poller, and quiet the poller for that inbox.",
        group: "/api/email",
        path: "/webhook/agentmail",
        method: .post,
        params: [
            ActionParam("slug", .string, description: "Webhook route slug (passed by webhook_deliver)"),
            ActionParam("body", .string, description: "Raw webhook body as a UTF-8 JSON string — AgentMail's event envelope {event, message_id, inbox_id}"),
            ActionParam("body_b64", .string, description: "Base64-encoded raw body; used when 'body' is absent"),
            ActionParam("headers", .object, description: "Forwarded third-party headers (unused for AgentMail)"),
            ActionParam("receivedAtMs", .integer, description: "When the gateway received the delivery"),
            ActionParam("sourceIp", .string, description: "Original webhook source IP"),
            ActionParam("wrapEventId", .string, description: "Gift-wrap rumor id, for log correlation"),
            ActionParam("event", .string, description: "Envelope field (direct-param form): AgentMail event type"),
            ActionParam("message_id", .string, description: "Envelope field (direct-param form): AgentMail message id"),
            ActionParam("inbox_id", .string, description: "Envelope field (direct-param form): AgentMail inbox id (the inbox address)"),
        ],
        handler: { ctx in
            let envelope = try webhookEnvelope(from: ctx.params)
            // AgentMail (Svix) sends `event_type`, older/generic senders send `event`.
            let event = (envelope["event_type"] ?? envelope["event"]) as? String ?? ""
            guard !event.isEmpty else {
                throw ActionError.missingParam("event_type")
            }
            guard event == "message.received" else {
                return EmailWebhookProcessResponse(
                    ok: true, action: "skipped",
                    detail: "event '\(event)' is not message.received")
            }

            // AgentMail nests message fields under `message`; flat form kept as fallback.
            let messageObj = (envelope["message"] as? [String: Any]) ?? envelope
            guard let messageId = (messageObj["message_id"] ?? messageObj["messageId"]) as? String,
                  !messageId.isEmpty else {
                throw ActionError.missingParam("message_id")
            }
            guard let inboxIdRaw = (messageObj["inbox_id"] ?? messageObj["inboxId"]) as? String,
                  !inboxIdRaw.isEmpty else {
                throw ActionError.missingParam("inbox_id")
            }

            guard let emailHandler = ctx.emailHandler else {
                throw ActionError.custom("Email handler not available", .serviceUnavailable)
            }
            // AgentMail's `inbox_id` is an email address for scoped inboxes but can be
            // an opaque `inbox_...` identifier in payloads. Try direct match first.
            // If it misses, the email is for an inbox this Sonata instance is not
            // configured to monitor (AgentMail's workspace-scoped webhook fires for
            // every inbox in the workspace, including ones this instance doesn't own).
            // Soft-skip rather than error: the delivery row still lands as verified,
            // but there's no dispatch and no error status — clean audit signal.
            //
            // Alternative: on a dedicated Sonata deploy (Scout), use AgentMail's
            // inbox-scoped webhook API (`client.inboxes.webhooks.create(inbox_id=...)`)
            // to filter at source. See docs/webhook-routes.md.
            guard let inbox = await emailHandler.inboxConfig(for: inboxIdRaw) else {
                return EmailWebhookProcessResponse(
                    ok: true, action: "skipped",
                    detail: "inbox '\(inboxIdRaw)' is not monitored by this Sonata instance")
            }
            let inboxId = inbox.address

            // Fetch the full message from AgentMail. A failure here throws all
            // the way out WITHOUT noteWebhookSeen — the poller stays at full
            // cadence and catches the missed message on its next cycle.
            let raw = try await AgentMailProvider().getMessage(inboxId: inboxId, messageId: messageId)

            let record = EmailRecord(
                messageId: raw.messageId,
                threadId: raw.threadId,
                from: raw.from,
                subject: raw.subject ?? "",
                body: raw.body,
                timestamp: raw.timestamp ?? ISO8601DateFormatter().string(from: Date()),
                inboxAddress: inbox.address
            )

            await emailHandler.ingestWebhookEmail(record, inbox: inbox)
            // Success path only: the ingest completed, so the poller can go
            // quiet on this inbox for the webhook window.
            await emailHandler.noteWebhookSeen(inbox: inbox.address)
            return EmailWebhookProcessResponse(ok: true, action: "ingested", detail: raw.messageId)
        }
    ),
]
