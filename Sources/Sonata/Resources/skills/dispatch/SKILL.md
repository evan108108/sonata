---
name: dispatch
description: Assign a task to a Sonata worker using the correct enqueue-based dispatch flow with mandatory DM-review protocol. Invoke when the user says "dispatch", "create a new task", "hand this to a worker", "assign a worker", "have a worker do this", "delegate this", or types /dispatch. Prevents the DM-based dispatch anti-pattern that leaves workers with `status="idle"` and vulnerable to preemption.
metadata:
  origin: manual
---

# Dispatch — Task assignment to Sonata workers

Codifies the ONE correct flow for handing work to a Sonata worker. Written because prior sessions used `dm_send` to assign tasks — DMs do NOT flip worker status, so the worker stayed `status="idle"` while working, and any incoming cron/email/task event would preempt them mid-flight. This skill exists so that never happens again.

## The core rule (do not violate)

**Task assignment goes through `worker_event_enqueue`. Never through `dm_send`.**

- `worker_event_enqueue` → worker claims → `status="busy"` + `currentEventId=<id>` → work → `worker_event_complete` → back to `idle`. The claim/complete discipline is enforced by the sonata-bridge MCP server which explicitly reminds every event handler: *"ALWAYS call the complete_event tool to mark the event done."* Workers reliably remember this.
- `dm_send` sends a message. It does NOT claim the worker. If you dispatch a task via DM, the worker executes it but their status stays `idle`, `currentEventId=""`. The next event that fires will be atomically claimed by them, and they abandon the DM task mid-flight. This is a real hazard, not a metrics gap.

DMs are for CONVERSATION within an already-claimed task — questions, reviews, status pings. Nothing more.

## Evan's law — fix-in-flight, do NOT file follow-up tickets for issues found mid-execution

**Rule (Evan, verbatim 2026-08-03):** *"if issues are found during the course of working on a ticket I want them fixed then and there and not new tickets filed. Unless we are talking about completely new features or something. If we keep doing this we will never see the end. If every ticket produces a new ticket then what are we doing? We have to try and fix issues as they come and not leave them to future workers to fix. This is Evan's law."*

**Why:** backlog cannot converge under net-positive follow-up filing. Splitting-out follow-ups optimizes for reviewer scope-of-review overhead, which is the wrong optimization when the reviewer IS the user and the user wants backlog to shrink.

**When a worker DMs to propose "should I file X as a follow-up?" the answer is almost always NO.** The default is fix-inline, note the scope-creep in the PR body, move on. Only file a new ticket when the discovery is:
- A **genuinely-new feature** ("while fixing X I realized we should add rate limiting" — that's a feature)
- A **truly-orthogonal subsystem** ("while touching this route I noticed the deploy script has a race" — different subsystem)

**Fix inline (do NOT file a follow-up):**
- Bugs discovered mid-execution (even if pre-existing)
- Adjacent code cleanup (unused declarations, stale comments, dead branches)
- Test-that-notes-a-quirk-but-doesn't-fix-it → NEVER accept this shape; either fix or explicitly note it's design not bug
- Documentation staleness on files being touched
- Predicate-inventory finds that reveal a hidden field the schema needs to accept
- Wire-reason strings, config drift, allowlist entries that should be pruned

**Coordinator responsibilities under this rule:**
1. Brief templates must NOT contain "file X as follow-up ticket" language.
2. When a worker proposes splitting scope, say NO. Ask them to bundle. Reviewer scope-of-review overhead is the coordinator's problem to manage (via structured review sections or dispatch scoping), not the pool's problem to solve via ticket-splitting.
3. When a worker proposes "reproduce a pre-existing bug in a test but don't fix it" — reject. Either fix it in the same PR or convince the coordinator it's design not bug.
4. The DM-flow prompt (step 7) MUST include Evan's law verbatim so workers know the default answer.

## When to invoke this skill

- User says "dispatch a worker", "create a new task", "hand this to a worker", "assign a worker", "delegate this", "have a worker do this".
- User types `/dispatch`.
- You (Sona) recognize a scope of work that should be done by a worker, not you personally, and want to propose delegation.

## The flow — ten steps, in order

### 1. Understand scope (1–2 clarifying questions max, only if genuinely fuzzy)

Skip if the ask is obvious. If unclear, ask via `AskUserQuestion` — but ONE round, not a Socratic dialogue. If the user is AFK, use email per the /afk skill.

### 2. Explore the codebase to get accurate context

Before writing the brief, actually read the code the worker will touch. Grep for existing patterns. Identify load-bearing surprises (silent defaults, closed unions, missing plumbing, undocumented conventions). Do NOT let the worker discover these mid-flight — you finding them once is cheap; the worker rediscovering them by breaking things is expensive.

Reading a task's target files yourself first is not optional. If you write a brief off memory or vibes, the worker inherits your fog.

### 3. Write the brief — a real document, not a paragraph in a DM

Location:
- If the task is in a repo with a `docs/plans/` (or similar) directory, write there: `docs/plans/<task-slug>-context.md`.
- Otherwise, write to your scratchpad: `<scratchpad>/<task-slug>-context.md`.

Contents (all sections mandatory unless N/A):

- **What & why** — one-paragraph summary. Link to the ticket / issue / user request.
- **Load-bearing surprises** — the things that will bite a fresh worker. File paths + line numbers + short excerpts. This is the most valuable part of the brief.
- **Files to touch** — table of file path → change. Not exhaustive, but the load-bearing ones.
- **Where things live** — pointers to the modules the worker will need (signing, encryption, publishing, schema, cron, UI).
- **Testing** — what the worker should verify before DMing for review.
- **Deploy context** — env vars, secret names, deploy commands, DO NOT DEPLOY warnings.
- **Key IDs** — every UUID/slug/short-id/pubkey the worker will need to paste into shell. Do not make them re-derive.
- **Related work** — ticket dependencies, follow-up tickets, prior art.
- **Coordination points** — where the worker must DM you before deciding.

Prefer over-briefing to under-briefing. Workers restore this doc into their context; the cost of an extra paragraph is negligible, the cost of a missing constraint is a broken deploy.

### 4. Save a checkpoint memory pointing to the brief

`mem_checkpoint_save` with:
- `sessionId`: your session id (from `sonata_whoami` → `routingId`).
- `project`: the project name.
- `state`: worker-facing context including — the brief file path, all key IDs, all load-bearing surprises (short version), the DM-flow protocol (verbatim), and a list of related tickets/tasks.
- `skills`: the skills the worker should keep active (usually just "memory").

**IMPORTANT — how workers restore (EFB-48 shipped 2026-07-31, live in Sonata core):** `mem_checkpoint_save` returns a `checkpointId`. `mem_checkpoint_restore(checkpointId: <id>)` fetches EXACTLY that row — no fallback, no substitution. This is the mechanism to use, always. Requirements on this dispatcher's side:

1. The `checkpointId` returned from step 4's `mem_checkpoint_save` MUST populate the `checkpointId` field in the step 6 enqueue payload (verify it's a real id, not the placeholder string).
2. The step 7 DM-flow prompt block MUST name the id explicitly in the "FIRST: RESTORE CHECKPOINT BY ID" section, so the worker knows to call `mem_checkpoint_restore(checkpointId: "<id>")` — the payload alone is invisible to the worker.

Post-EFB-48 the server also fails LOUD when `sessionId`-scoped restore has no matching rows (was silently returning the pre-v31 NULL bucket, which typically served the supervisor's checkpoint). So byId is the correct default; sessionId-scoped restore is safe as a fallback but only for the caller's own recent saves.

Belt-and-braces: `mem_checkpoint_restore` now returns `sessionId` in its response. Workers should assert the returned `sessionId` matches the expected sender (this dispatcher's session id) as a machine-check that the id resolution didn't drift. That's a one-line check, not prose-reading.

Fallback (only if MCP is unreachable): `~/.sonata/scratch/active-checkpoint-<yourSessionId>.md` on disk. Note the path in the prompt so the worker has a recovery path.

The worker restores this **first**, before touching any code.


### 5. `TaskCreate` locally

So you and the user both see the task in the local task list.
- `subject`: short human title (e.g. "EFB-22 — Sprint tide via sona-worker-N").
- `description`: what the worker is doing, at what stage, checkpoint id, ticket link.
- Track status transitions with `TaskUpdate` as phases complete.

### 6. `worker_event_enqueue` — the actual dispatch

Payload (pass as `payload` param):
```json
{
  "taskId": "<local-task-id>",
  "title": "<one-line task title>",
  "prompt": "<the full task prompt — includes DM-flow block>",
  "workingDir": "<absolute path to the repo>",
  "briefPath": "<absolute path to the brief written in step 3>",
  "checkpointId": "<from step 4>",
  "senderSessionId": "<your session id>"
}
```

Set `type: "task"` on the enqueue. The prompt string MUST include the DM-flow block verbatim (see step 8).

Note: you enqueue **generically** — any idle worker in the pool will claim. Do NOT try to target a specific worker; the pool is uniform by design, and tasks should be self-contained enough that any worker can pick them up. If you find yourself wanting to target a worker, that's a signal your task/brief is under-scoped or leaning on unshareable context.

**UI-counter caveat (learned 2026-07-30):** Sonata has TWO task systems. `worker_event_*` (this step) creates a worker event that flips `status: busy` and populates `currentEventId` — the Workers tab counter reflects this correctly. But the **Tasks tab counter reads from `mem_task_*`** (a separate dispatcher-fed queue), which this skill does NOT populate. So the Tasks tab shows 0 even when a worker is actively working through your event.

Both are correct — they represent different systems. Don't retroactively `mem_task_create` for an in-flight event dispatch: the mem_task dispatcher would then spawn a SECOND worker to compete on the same task. If you want the Tasks tab counter to reflect this dispatch, use `mem_task_create` as the entry point INSTEAD of `worker_event_enqueue` (mem_task fans out to worker events downstream). Trade-off: mem_task is queued through the dispatcher, so there's a small extra hop. For most tasks the discrepancy is cosmetic; use whichever entry matches whether you want scheduler-managed lifecycle (mem_task) or direct event-queue semantics (worker_event_enqueue).

### 7. If the work is tracked in a ticket system, transition it to In Progress — SAME BATCH as the enqueue

**Applies only when a tracker exists.** Evenflow (EFB-XX), Linear (ENG-XX), GitHub issues (#123), any board where the work has a canonical row. If the dispatch is untracked scratch work (ad-hoc cleanup, one-off scripts, Sonata core work without a ticket), skip this step — there's nothing to keep in sync.

You (the dispatcher) know at fire-time whether a tracker applies: you named the ticket in the brief, or you didn't. This is contextual, not auto-detected.

**When a tracker applies:** dispatch is a state change on the board, not just a message-passing operation. A worker claiming an event that references EFB-XX means EFB-XX is being worked on RIGHT NOW; the board must reflect that. Leaving it in Todo while the worker codes for an hour is exactly the "invisible work" hazard Evan has raised repeatedly (his own words: "I have said this now about 100 times").

For every ticket referenced in the dispatch (single-ticket or bundle), transition in the same tool-batch as `worker_event_enqueue` + `TaskCreate`.

**Evenflow example:**
```bash
curl -s -X POST -H "Authorization: Bearer $(mem_secret_get evenflow_apikey)" \
  -H "Content-Type: application/json" \
  -d '{"column_id":"<in-progress-column-id>"}' \
  "https://evenflow.work/api/v0/issues/EFB-XX/transition"
```
For evan-s-flow-board the in-progress column id is `c837238b-5558-4b3d-916a-4a423426aa28` (cached 2026-08-03; find others via `curl /boards/<slug>` → parse `columns[].id where category='in_progress'`).

**Linear:** use `mcp__linear-mcp__save_issue` with the In Progress state id for the team.

**GitHub issues:** typically no state machine beyond open/closed, so no transition needed — but assign the issue to yourself/the worker's identity if that surfaces the work.

**Ordering: same tool-batch as `worker_event_enqueue` and `TaskCreate`.** Not "after the worker acks" — the worker can start claiming instantly; the board must be true the moment the coordinator returns to prompt.

**Merge-time and review-time transitions (evenflow):** handled AUTOMATICALLY by EFB-72's github rules (PR opened → In Review + pr_review pill; PR merged → Done + pr_merged pill). Requirement: the PR title or body MUST include the ticket short_id (e.g. "EFB-88") so `extractTicketRefs` finds it. Enforce that in step 10 (broker) — if a worker DMs a PR link and the title doesn't reference the ticket, tell them to fix it before merge.

### 8. The DM-flow protocol block — verbatim in every task prompt

Paste this INTO the task prompt (not a separate DM):

```
## FIRST: RESTORE CHECKPOINT BY ID

Call `mem_checkpoint_restore(checkpointId: "<checkpoint-id>")` — the id is in your task payload above. This fetches the exact checkpoint with NO fallback (per EFB-48, shipped 2026-07-31). Do NOT restore by session id as the primary path; sessionId-scoped restore is fine for your OWN recent saves but is not the mechanism for restoring a dispatcher's brief.

Belt-and-braces: the response includes a `sessionId` field. Assert it equals `<sender-session-id>`. If it doesn't, DM me — the id resolved to someone else's checkpoint.

If the byId call fails with not-found, DM me immediately — do NOT proceed on guesses.

Fallback path (only if MCP is unreachable): read `~/.sonata/scratch/active-checkpoint-<sender-session-id>.md` on disk.

## DM FLOW — MANDATORY, DO NOT SKIP

You are working under a strict DM-review protocol. This is not optional:

1. **DM me with any questions or concerns.** Do not guess on scope. Do not make ambiguous decisions solo. If you hit anything unexpected — especially any design ambiguity — DM me first.

2. **Give status updates via DM at meaningful checkpoints.** At minimum: after each phase, after each surprise, before any risky operation (wrangler deploy, migration apply to prod DB, gateway/external-repo change).

3. **DO NOT complete the task (worker_event_complete) until you have DMed me for review AND I have returned my review response.** "Task complete" is decided by MY review, not your judgment. Send me a summary of what changed, files touched, test evidence, and any open questions — then wait for my "shipit" or my requested changes.

4. Use `dm_send` targeting session `<your session id>` (that's me) or `dm_reply` with a message_id if replying to one of my DMs.

## EVAN'S LAW — fix-in-flight, do NOT file follow-up tickets

If you find a bug, quirk, adjacent cleanup opportunity, or stale doc during execution of this ticket, **fix it in the same PR.** Note the scope-creep in the PR body so the reviewer sees you took the extra work, but do NOT split it out into a follow-up ticket. Bug is a bug — fix it. If you find yourself writing "should I file this as a follow-up?" — the answer is almost always NO; the answer is "fix it, note it in the PR body." Only exception: a genuinely-new feature ("we should add rate limiting"), or a truly-orthogonal subsystem change ("the deploy script has a race" while you're touching a route handler). Bugs, quirks, adjacent cleanup, prose-doc updates, tests-of-pre-existing-behavior → in the same PR. Always.

The reason: backlog cannot converge if every ticket produces net-positive new tickets. Splitting scope optimizes for reviewer overhead; the coordinator (Sona) handles review-scope, the pool handles the fix. If a PR gets too big to review in one pass, DM the coordinator — that's a review-structure problem, not a ticket-splitting problem.
```

Substitute `<your session id>` with your actual sessionId from `sonata_whoami`. Substitute `<checkpoint-id>` with the checkpoint id from step 4 (also in the enqueue payload). Substitute `<sender-session-id>` with your actual sessionId (same as above).


### 9. Confirm dispatch to the user

Tell the user: the event id, task number, brief path, checkpoint id, and (once the worker ACKs) which worker claimed it. Short and factual — no need to re-explain what the task is.

### 10. Broker between user and worker

- Worker DMs arrive as `sonar_dm` channel events with `from_session_id=worker-*`. Relay them to the user in your own words — do not blindly quote.
- User replies get sent back with `dm_reply` (using the worker's message_id) so the thread stays coherent.
- When the worker DMs for review: read what they've done, check the code yourself if the change is risky, tell the user, and give a "ship it" or "changes needed" verdict.
- Only after the worker calls `worker_event_complete` AND you've reviewed do you `TaskUpdate` the local task to `completed`.

## Hard prohibitions

- **NEVER `dm_send` to assign a task.** DMs are for messages within an active claim, not for dispatch.
- **NEVER use Claude Code's built-in Agent tool (subagents) to delegate work.** Sonata workers are inspectable and redirectable; Agent-tool subagents are not. This is a standing rule regardless of this skill.
- **NEVER mark a Task `completed` before the worker's review round has finished.** The whole point of the flow is human-gated completion.
- **NEVER dispatch without a brief.** A one-line DM prompt is not a brief. See step 3.
- **NEVER approve a worker's "should I file this as a follow-up ticket?" without a hard justification.** Default answer is NO — bug is a bug, fix it in the same PR. Evan's law is a HARD rule, not a suggestion. If you approve a split, the burden is on you to justify why it's not a bug/cleanup (e.g. "genuinely-new feature", "truly-orthogonal subsystem", "would require a design decision the ticket's scope doesn't cover").
- **NEVER write "file X as follow-up ticket" language in a brief.** Bug findings must be worded as "fix inline; note in PR body."
- **When a ticket tracker applies: NEVER dispatch without transitioning the tracked ticket(s) to In Progress in the same tool-batch.** Leaving tickets in Todo while workers are actively coding creates invisible work — the user has raised this repeatedly. If the ticket lives on evenflow, hit `/api/v0/issues/EFB-XX/transition` with the in-progress column id as part of the dispatch. If it's Linear, the equivalent `save_issue` call fires in the same batch. See step 7. This applies ONLY when a tracker exists — untracked scratch work has nothing to transition, and that's a legitimate case, not a violation.

## What if the worker DMs the user directly, bypassing you?

You (Sona) are the broker. The worker was told to DM your session. If the worker somehow DMs the user directly (wrong target), gently correct via `dm_reply` and re-route. This shouldn't happen if the DM-flow block includes your sessionId, but the instruction is here in case it does.

## What if you receive a task-shaped DM (someone dispatched to you incorrectly)?

If a `sonar_dm` arrives from a session (not a worker) asking you to do a bounded task, DON'T just do it silently. Nudge back: "This looks like a task-shaped ask — should it go through `worker_event_enqueue` so we get claim/complete tracking?" Keep the discipline mutual.

## Checkpoint at the end

After the task is complete and reviewed:
- `mem_checkpoint_save` again with the outcome (what shipped, deploy status, follow-up tickets).
- `TaskUpdate` to `completed`.
- If the pattern taught you something new (a load-bearing surprise, a good design call, a failure mode), consider a `mem_store` so future dispatch runs benefit.

## Why this skill exists — brief origin note

On 2026-07-30, during EFB-22 (Sprint tide) dispatch to sona-worker-4, Sona used `dm_send` instead of `worker_event_enqueue`. The worker did the work correctly but stayed `status="idle"` the whole time, meaning any incoming event would have preempted them. Manually flipped to `busy` with `worker_set_status` as a stopgap. Evan (correctly): "we can't make this kind of mistake." This skill is that mistake's tombstone.
