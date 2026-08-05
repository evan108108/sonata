# Ownership-gap on new email threads — first-reply-to-unclaimed-thread bug

## What & why

When Sonata's `email_reply` action is called on a thread whose messageId isn't yet known to Sonata's own email store, the ownership row doesn't get written, and the response returns `ownershipRecorded: false`. Every subsequent reply on the same thread — once Sonata has ingested any message from it — records correctly (`true`).

The failure window is specifically **first reply to a thread with no prior Sonata-side messages**. That's also the moment when a pool worker is most likely to pick up the next inbound message on that thread (no owner recorded → EmailHandler falls back to normal dispatch → pool worker grabs it → two versions of Sona answering on the same thread with different context). This is the exact "two Sonas on one thread" incident class Evan flagged three times in one day back when the AFK protocol was being built.

**Concrete instance (2026-08-02):** worker-6870623999 replied to Scout thread `2e897108` and got `ownershipRecorded: false`. They correctly declined to reply again, to avoid ping-pong with any pool worker that might grab the next turn. Sona's replies to Evan's evenflow thread `dc766fb6-aa8d-477f-9721-051b0a75e648` all returned `true` because that thread had been established (Evan's inbound emails were ingested and had generated `afk_reply` events, so the messageId → threadId lookup resolved).

## Load-bearing surprises

**The current reply handler DOES try to record ownership on outbound.** `Sources/Actions/EmailOutboundActions.swift:347-354`:

```swift
let threadId = await EmailThreadOwnership.threadId(
    forMessageId: messageId, dbPool: ctx.dbPool)
var recorded = false
if isInteractive, !sessionKey.isEmpty, let threadId {
    await EmailThreadOwnership.record(
        threadId: threadId, sessionKey: sessionKey, dbPool: ctx.dbPool)
    recorded = true
}
```

**The failure is the messageId→threadId lookup returning nil**, not the recording itself. `EmailThreadOwnership.threadId(forMessageId:)` almost certainly reads from Sonata's own `emails` (or similar) table. If the message hasn't been ingested there yet, the lookup returns nil, the guard `let threadId` fails, `recorded` stays false. The `EmailOutboundGateway.reply(...)` itself succeeds (it goes straight to AgentMail with the messageId), so the reply *sends*, it just isn't OWNED.

**Fix design options** — worth DMing before implementing:

1. **Fetch threadId from AgentMail post-reply.** The provider response should carry the threadId of the message we replied to (or we can look it up via a separate `getMessage(inboxId:messageId:)` call — already added to EmailProvider per the 4a-webhook plan). Record ownership on the freshly-fetched threadId. Robust; costs one extra HTTP call on first-reply-of-thread.

2. **Auto-ingest the message before replying.** If our own store doesn't know the messageId, fetch and store it first (same `getMessage` call), THEN look up threadId locally. Same cost, but has the side effect of populating our email store — good for `email_recent` / `email_unread` visibility of the just-replied-to message.

3. **Extend `EmailOutboundGateway.reply` to return the threadId.** Push the responsibility onto the outbound gateway so the ownership logic doesn't need a separate lookup. Requires the AgentMail reply endpoint to return threadId (verify — it probably does).

Lean: (2) or (3). (2) fixes the ambient-visibility gap too (the just-replied-to message being invisible to `email_recent` until the next poll cycle), (3) is minimal change. DM which shape you want before writing code.

**Watch for the interactivity guard.** Line 350: `if isInteractive, !sessionKey.isEmpty, let threadId`. Workers replying (role != "interactive") do NOT record ownership by design — they're doing dispatched work, not holding conversations. Preserve that. The fix is only for interactive sessions.

**Don't change the `send` handler.** The email_send comment at :289-293 explicitly notes there's no threadId to record on send (provider assigns it and doesn't hand back), and the AFK subject tag covers this case — the first reply arrives tagged, EmailHandler routes it to the correct session, and ownership is recorded at THAT moment (via `routeAFKReplies`). This ticket is specifically the email_reply path, which names an existing message and therefore has a threadId to work with.

## Files to touch

| file | change |
|---|---|
| `Sources/Actions/EmailOutboundActions.swift` | reply handler (:305-363) — fix ownership recording on first reply |
| `Sources/Email/EmailThreadOwnership.swift` (or wherever it lives) | possibly extend `threadId(forMessageId:)` fallback, OR the caller does the fetch |
| `Sources/Scheduler/EmailProvider.swift` | may need `getMessage(inboxId:messageId:)` if not already present (EFB-webhook plan added this) |
| `Tests/SonataTests/EmailOutboundActionsTests.swift` (or equivalent) | test coverage for first-reply-records-ownership |

## Testing

Unit-level:
- Reply to a messageId Sonata has already ingested → `ownershipRecorded: true`, threadId matches expected
- Reply to a messageId Sonata has NOT ingested → `ownershipRecorded: true` (the fix), threadId resolved via provider
- Worker (role != interactive) replying → `ownershipRecorded: false` (design, not regression)
- Missing sessionKey → `ownershipRecorded: false` (design)

Integration:
- Send a fresh outbound email from an outside address to sona@agentmail.to (simulate Scout-style thread start)
- Immediately reply via `email_reply` BEFORE the AgentMail poll cycle catches up
- Assert `ownershipRecorded: true` on the response
- Assert a subsequent inbound message on that thread produces an `afk_reply` to the calling session (not a pool worker dispatch)

## Deploy

- Sonata Swift binary rebuild (`swift build`), redeploy per standard Sonata cycle (BUILD: `rm -rf .build` before deploy per session note in memory).
- No D1 migration.
- Deploy freely — this is Sonata proper, in the "deploy freely" exception per Evan's standing rule.

## Coordination — MANDATORY DM points

- Post-brief-read: your read of the three fix options above (fetch post-reply / auto-ingest / gateway-returns-threadId)
- Post-code: DM me the diff before Sonata restart (restart terminates all worker sessions including yours — DM me your intent so I can warn other in-flight workers, same discipline as EFB-48)
- Post-deploy: fresh integration probe as described in Testing → prove-can-fail

## Key IDs / paths

- Sonata Swift repo: `/Users/evan/memory/Sonata`
- Sona's session id (this coordinator): `session-f4e8ed22897d418a`
- Sona's inbox: `sona@agentmail.to`
- Evenflow session Sona routes via: same as above
- Standing rule: Sonata source at `/Users/evan/memory/` is yours to modify freely

## Related

- Memory `pending-tasks-dispatch-immediately-there-is-no-defer-primitive` (9fa4f789fd47455dbe92187585066111) — the ownership gap is cross-linked here as same shape (an invariant relied on unconsciously that isn't there)
- Memory `shared-checkout-measurement-hazard` (5def90bf1cc347edaa9ea22c73141cdf) — different topic, same meta-rule
- EFB-48 discipline: DM the coordinator before Sonata restart (restart kills other in-flight workers)
