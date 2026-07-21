---
name: afk
description: Enter AFK mode — shift communication to email while continuing work. Use when the user says they're going AFK, stepping away, leaving, "be right back", "brb", types /afk, OR when you receive a sonata-bridge channel event with `event_type=global_afk_directive` and `action=enter` (Sonata's global AFK toggle was flipped on).
metadata:
  origin: manual
---

# AFK Mode

When invoked, shift all user-facing questions from the terminal to email. The user is stepping away from the keyboard but wants you to keep working. While in AFK mode, replies arrive as **channel notifications** — same primitive Sonata workers use to receive events. You do NOT poll the inbox.

## How it works

There is no registration step and no token. **Send your AFK email through Sonata's own `email_send` / `email_reply` tools and routing takes care of itself** — Sonata stamps the routing key into the subject and records your session as the thread's owner. Replies come back to you as a channel notification (`event_type=afk_reply`), the same shape Sonata workers receive events.

This matters more than it looks. If you send through the AgentMail MCP tools instead, Sonata never sees the message, can't record that you own the thread, and the user's reply gets dispatched to a pool worker — which will answer on your thread as a second voice, because the event it receives tells it to. That happened three times in one day before this was fixed. Use `email_send` / `email_reply` and it cannot happen.

Two ways this skill activates:

1. **Direct (user-initiated)** — user types `/afk`, says "going afk / brb / stepping away", etc.
2. **Global AFK directive** — channel event with `meta.event_type = "global_afk_directive"` and `meta.action = "enter"`. Sonata's app toggle already sent the user a kickoff email summarizing all affected sessions; you don't need to send your own at this moment.

The protocol below is the same in both cases.

## Entering AFK Mode

1. **Learn your routing id.** Call `mcp__sonata-bridge__sonata_whoami` (or the `mcp__memory__` variant). It returns `{ routingId, sessionKey, role, ... }`. Use `routingId` — it's the stable handle EmailHandler routes against.

2. **Mark yourself AFK locally** so you remember on later turns:
   ```bash
   echo "$ROUTING_ID" > /tmp/sona-afk-token
   ```

3. **Send a "going afk" email** so the user has a thread to reply on. Use `mcp__sonata-bridge__email_send`:
   - to: `evan108108@gmail.com`
   - subject: `AFK mode on` — plain English. Sonata prepends the routing tag itself; you never type it.
   - text: one short line ("AFK mode active for this session. Reply on this thread anytime."). For global-AFK enters, skip this step — Sonata's kickoff email already covers it.

4. **Continue working.** Do NOT stop.

## Asking questions while AFK (replaces AskUserQuestion)

While `/tmp/sona-afk-token` exists, **NEVER** use `AskUserQuestion`. Instead:

1. Send the question via `mcp__sonata-bridge__email_send`:
   - subject: `<one-line summary>` — no tag, Sonata adds it.
   - text: clear question with full context, numbered options if applicable. Make it phone-replyable.
2. End the turn. Do NOT poll, do NOT heartbeat — replies arrive as channel notifications.

When a `<channel source="sonata-bridge" event_type="afk_reply" ...>` event fires, treat the content as the user's reply and continue. The meta carries `from_addr`, `subject`, `message_id`. If the reply text equals "back" (case-insensitive) or `/back`, exit AFK mode (see below).

To keep multi-turn threads tidy, use `mcp__sonata-bridge__email_reply` (pass the `message_id` from the notification meta) for follow-ups. Replying this way also (re-)claims the thread for your session, which is what keeps later messages on it from being dispatched to a worker.

## Exiting AFK Mode

On `/back` or a "back" reply, or on a `global_afk_directive` channel event with `action=exit`:

```bash
rm -f /tmp/sona-afk-token
```

Tell the user "Welcome back! Resuming normal communication." Switch back to `AskUserQuestion` for any further questions.

## Notes

- **No tokens, no registry.** Ownership is recorded when you send through `email_send`/`email_reply`; the `[AFK-#<sessionId>]` subject tag is the belt-and-suspenders fallback for threads with no ownership row (the kickoff mailto links, or mail sent from outside Sonata). Both resolve against live MCP sessions — if your session is gone (Sonata restarted, tab closed), the email falls through to normal worker handling instead of pushing into the void.
- **You can still hand-type the tag.** `[AFK-#<routingId>]` in a subject sent any other way continues to route. It's a fallback, not the mechanism — don't rely on remembering it.
- **Only email for blocking questions.** If you can make a reasonable choice yourself, do so and mention it when the user returns.
- **Be concise.** Short subject, clear question, numbered options. The user is probably on their phone.
- **Stay productive.** The whole point is that you keep working between questions.
