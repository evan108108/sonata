---
name: afk
description: Enter AFK mode — shift communication to email while continuing work. Use when the user says they're going AFK, stepping away, leaving, "be right back", "brb", types /afk, OR when you receive a sonata-bridge channel event with `event_type=global_afk_directive` and `action=enter` (Sonata's global AFK toggle was flipped on).
metadata:
  origin: manual
---

# AFK Mode

When invoked, shift all user-facing questions from the terminal to email. The user is stepping away from the keyboard but wants you to keep working. While in AFK mode, replies arrive as **channel notifications** — same primitive Sonata workers use to receive events. You do NOT poll the inbox.

## Triggers

There are TWO ways this skill activates:

1. **Direct (user-initiated):** The user types `/afk` or says "going afk / brb / stepping away." Follow the protocol below from "Entering AFK Mode".

2. **Global AFK directive (Sonata-initiated):** Sonata's global AFK toggle was flipped on, and you received a channel event with `meta.event_type = "global_afk_directive"` and `meta.action = "enter"`. Treat this identically to a user-initiated /afk — generate a token, write it to disk, call afk_register, and continue working. Do NOT send an email at this moment unless you have an actual question to ask; the Sonata app already sent the user a kickoff email summarizing all affected sessions. Sessions email organically when they have something to report.

   Conversely, when you receive `action = "exit"`, exit AFK mode (delete `/tmp/sona-afk-token`, optionally call `afk_unregister`, and resume normal use of AskUserQuestion).

## Entering AFK Mode

1. Generate a token and write it to disk:
```bash
AFK_TOKEN="afk-$(openssl rand -hex 4)"
echo "$AFK_TOKEN" > /tmp/sona-afk-token
echo "AFK mode active. Token: $AFK_TOKEN"
```

2. Tell the user:
```
AFK mode active. Token: {token}
Questions will be emailed to evan108108@gmail.com.
Type /back when you return.
```

3. **Check for queued tasks** before starting work:
```bash
mem task list --status pending --tags enrich-lead --project engage
```
If there are pending enrich-lead tasks, dispatch them to the scheduler daemon (do NOT run inline — that fills context). For each task:
- Re-check status: `mem task get <taskId>` — skip if no longer pending
- Ensure `--assigned-to scheduler` is set
- The scheduler picks it up, spawns its own SDK session, runs the pipeline

4. Continue working on the current task. Do NOT stop.

## Asking Questions (Replaces AskUserQuestion)

While `/tmp/sona-afk-token` exists, **NEVER** use the AskUserQuestion tool. Instead, follow this exact sequence:

### Step 1 — Send the question via email

Use the AgentMail MCP tool:
- Tool: `mcp__agentmail__send_message`
- inboxId: `sona@agentmail.to`
- to: `["evan108108@gmail.com"]`
- subject: `[AFK:{token}] {concise question summary}`
- text: Clear question with full context. Numbered options if applicable. Make it easy to reply quickly from a phone.

### Step 2 — Register this session as the AFK target

Call the memory tool to route the reply back via channel push:
- Tool: `mcp__sonata-bridge__afk_register`
- token: `{token}` (the same token in your subject line)

**⚠️ DO NOT pass `sessionId` yourself.** The tool's JSON schema marks `sessionId` as "required" but the memory MCP shim auto-injects the correct value (it computes the same `claude-${ppid}` identity the sibling sonata-bridge announced as). If you pass your own Claude Code session UUID, AFKRegistry stores the registration under a sessionId that no bridge is listening on, the push silently misroutes, and Sonata logs a warning like *"sessionId X is not a known live worker or external bridge."* This footgun was diagnosed and fixed 2026-05-12 — the correct call is **token only**.

The bridge polls AFK replies on every boot, so as long as your session has the sonata-bridge MCP configured, registration is sufficient.

If `afk_register` returns an error (Sonata not running, network error), **fall back to the legacy polling behavior**: use a background `sleep 30` Bash heartbeat and `mcp__agentmail__list_threads` to watch for replies. The new path is the default; polling is only a safety net.

### Step 3 — End your turn

Say something brief like:
> Email sent. Awaiting your reply.

**Then stop.** Do not call any more tools. Do not start a heartbeat. Do not poll. Just end the response.

This is how Sonata workers wait for events — they finish a turn and sit idle until the channel pushes the next one. The AFK reply will arrive as a `<channel source="sonata-bridge">` notification with `event_type="afk_reply"` in the meta. That arrival triggers a new turn; you read the reply and continue working.

If you find yourself reaching for a tool after sending the email and registering the token, stop. Ending the turn IS the work.

### Step 4 — Process the reply when it arrives

When a new turn fires with an `afk_reply` channel event:
- The content is the user's reply body
- The meta has `afk_token`, `from_addr`, `subject`, `message_id`
- Apply the answer to whatever was blocked
- If the reply says "back" (case-insensitive), exit AFK mode (see below)
- If you have a follow-up question, repeat Steps 1–3 (use `mcp__agentmail__reply_to_message` to keep the thread, send a new question with the same `[AFK:{token}]` subject prefix, end the turn — registration is still active)

### Multiple questions

The token registration persists across questions until you call `mcp__sonata-bridge__afk_unregister`. You can ask, end turn, get reply, ask again, end turn, get next reply — the same token routes them all.

## Exiting AFK Mode (/back)

When the user types `/back`, OR when you detect a "back" reply via the channel:

1. Unregister the token:
   - Tool: `mcp__sonata-bridge__afk_unregister`
   - token: `{token}`

2. Delete the token file:
```bash
rm -f /tmp/sona-afk-token
```

3. Print: "Welcome back! AFK mode deactivated. Resuming normal communication."

4. Switch back to using `AskUserQuestion` for any further questions.

## Important Notes

- **Channel push, not polling**: the EmailHandler in Sonata watches for `[AFK:<token>]` subjects, looks up the registered session, and pushes the reply directly. This reuses the same 2-minute inbox poll EmailHandler already runs — no extra work, no extra latency.
- **Keep working** while in AFK mode. The whole point is that you continue making progress between questions.
- **Only email for blocking questions** — decisions you genuinely can't make alone. If you can make a reasonable choice yourself, do so and mention it when they're back.
- **Be concise in emails** — the user is probably on their phone. Short subject, clear question, numbered options.
- **Fallback**: if `afk_register` fails, use the old background-heartbeat polling pattern (sleep 30 in background, list_threads, find reply). Don't let bridge failures block AFK.
