---
name: supervisor
description: Sonata Supervisor health check. Run the full checklist on every check event — repair workers, clear orphans, unblock stale tasks, retry failures. Trigger: /supervisor, on every sonata-bridge "check" event.
metadata:
  origin: manual
---

# Sonata Supervisor Health Check

Run this checklist on every `check` event from the sonata-bridge channel. All actions use MCP tools — never shell commands.

## Run in Parallel First

Always fetch these simultaneously at the start of each check:

```
mcp: mem_task_list(status="active", limit=50)
mcp: mem_task_list(status="pending", limit=50)
mcp: mem_task_list(status="failed", limit=50)
mcp: mem_task_stats()
mcp: worker_list()
```

**CRITICAL — filter validation + unfiltered fallback**: Filters AND stats can both silently miss records. After fetching:
- If `stats.active > len(active_results)` OR `stats.pending > len(pending_results)` → filter lied. Run `mem_task_list(limit=200)` unfiltered and group by `status` field manually.
- The unfiltered list paginates oldest-first by default — always use `limit=200` when running it to capture recent tasks. Active/pending tasks are recent and will be missed if the limit is too low.
- Never conclude the queue is clean based on stats or filtered results alone.

---

## Checklist

### 1. Orphan Check + Dual-Claim Check
From the unfiltered task list, find every task where `status == "active"`. Cross-reference against `worker_list`: for EVERY active task, verify a busy worker lists it as `currentTask`.
- If NO worker has it as `currentTask` → orphaned. Call `mem_task_patch` to set status back to `"pending"` and clear `startedAt`.
- Do not trust the task's own fields — always cross-reference the live worker list.

**Dual-claim check**: scan `worker_list` for any two workers that share the same `currentTask` value. This means the same task was dispatched twice — both workers' work is compromised.
- Kill BOTH workers that hold the dual-claim via `worker_unregister(workerId)` — do not touch any other idle workers.
- Then either re-queue the task (`mem_task_patch(status="pending")`) for a best-effort recovery, or mark it failed (`mem_task_fail`) if the task involved writes that are likely now in a conflicted state.
- If re-queuing causes the same dual-claim to recur on the next dispatch cycle, the root cause is duplicate events in the queue — stop re-queuing, mark the task failed, and log ALERT. Do not keep killing workers in a loop.
- Log ALERT with both worker names, the task title, and which resolution was chosen (re-queued vs failed).

### 2. Stale Blocker Check
From the unfiltered task list, find every task where `status == "pending"` and `blockedBy` is non-empty:
- Fetch each blocker via `mem_task_get` and check its actual status.
- If ALL blockers are `completed`, `cancelled`, or `failed` → clear `blockedBy` to `[]` via `mem_task_patch`.
- Race conditions can leave stale blockers on tasks created after their blockers already finished. Always verify.

### 3. Worker Repair
**`draining` workers — leave them alone.** Draining is intentional (WorkerManager is cycling the worker). The Swift sweep will delete them automatically once their heartbeat goes stale. Do not re-register, do not purge, do not touch.

For every worker with `status: "offline"` only:

**Check heartbeat age:**
- **Fresh heartbeat (<60s old)**: status field is stale. Call `worker_register(workerId, sessionLabel, capabilities)` to upsert and reset to `"idle"`. Verify with `worker_list` afterward.
- **Stale heartbeat (>60s old)**: worker is dead. Call `worker_purge()` to remove it. This also triggers the app's auto-spawn.

**If pool is fully offline after purge + register attempts:**
- Wait 2-3 check cycles for auto-spawn.
- If still empty after 2-3 cycles → email Evan at evan108108@gmail.com from `sona@agentmail.to`.
- Subject: `[Supervisor] Worker pool offline — N tasks stranded`

### 4. Stuck Workers
**`memory_request` event stall (new-code, 2026-07-22)**: Workers handling `memory_request` events (sidecar stop-hook path) can wedge with tokens frozen at ~50k. Normal completion range: 3s–287s (median ~88s, max healthy ~4m47s). Kill rule: `currentInputTokens` frozen across **2 consecutive check cycles** AND event age **> 15 min**. This is a per-event-type declared timeout, not a blanket elapsed-time reaper. Fix: `worker_event_fail(currentEventId)` + `worker_unregister(workerId)`. Do NOT re-queue — memory_request is fire-and-forget; the next stop-hook fires a fresh one. Log NOTED. Email Evan only on first confirmed occurrence (bug report), not per-kill.

**Zero-token stall**: A worker is `busy` AND `currentInputTokens == 0`. Use heartbeat age and elapsed time to decide:
- **Fresh heartbeat + <30min elapsed**: leave it alone — worker is likely still initializing. Monitor next cycle.
- **Fresh heartbeat + >30min elapsed**: zombie state — heartbeating but model never started. Kill and replace.
- **Stale heartbeat (>60s) + >5min elapsed**: dead worker. Kill and replace.

**Fix sequence** (when threshold is met):
1. `mem_task_patch(taskId, {status: "pending"})` — re-queue the task
2. `worker_unregister(workerId)` — kill the worker, trigger auto-spawn of a fresh one

**Never use `worker_set_status(idle)` for a stall fix** — that recycles a broken worker back into the pool where it will stall the next task too.

Log NOTED. Only escalate to ALERT if the same task zero-stalls repeatedly.

**Elapsed time alone is NOT a kill signal.** (Evan's 2026-07-08 correction — supersedes the 2026-07-01 blanket 120-min rule. See [[feedback_kill_threshold_conflict]].) Long-running work (MNLA scoring, nightly scout runs) can legitimately exceed 2 hours; elapsed time correlates poorly with actual death. So:
- **Do NOT auto-kill a worker just because `now - assignedAt` crossed 120 min.** A busy worker that is still heartbeating and holding a live, uncancelled task is doing its job, however long it takes.
- **An elapsed-time threshold applies only when the task explicitly declares one** (e.g. a task that sets its own timeout). Enforce that per-task limit; otherwise there is no default elapsed cap.
- **Genuine death is detected by the signals in the "Stuck Workers" checks above** — stale heartbeat / offline (worker unreachable for >10 min), zero-token stall — NOT by elapsed time. Kill on those, and re-queue the task first (`mem_task_patch(taskId, {status: "pending"})` → `worker_unregister(workerId)`).
- **Cancelled-task exception:** if a worker is still running an event for a task that has since been `cancelled`, it may be reaped regardless of elapsed time — the work is no longer wanted. `fail_event(currentEventId, "task cancelled — reaped by supervisor")` → `worker_unregister(workerId)`.
- Do NOT email/escalate for routine kills; the audit log is enough. Email only if the same worker keeps recurring after multiple kills (pattern, not incident). **Never tell Evan the supervisor "cannot kill" a genuinely-dead worker — it can and should; that retired "do not kill" rule must not walk again.** The change here narrows *when* a kill is warranted (death signals, not the clock), not *whether* the supervisor may kill.
- Workers with an `illegitimate sessionLabel` (anything not matching `sona-worker-N`) are suspect — they were not spawned by SonataApp. Kill them regardless of elapsed time if the pool has idle valid workers.

### 5. Retryable Failures
For tasks with `status: "failed"` and `retryCount < 3`:
- Call `mem_task_retry(taskId)` to re-queue them.
- Only retry if failure looks transient (no permanent error in context).

### 6. Dispatch Verification
After clearing stale blockers (step 2), confirm newly-unblocked tasks actually get claimed within 1-2 cycles. If a task stays pending with empty `blockedBy` for 2+ cycles, investigate and report.

---

## Reporting Tiers

After completing all checks, decide:

| Tier | Condition | Action |
|------|-----------|--------|
| **SILENT** | Nothing wrong or nothing done | Just `complete_event` |
| **NOTED** | Fixed routine issues (orphans, stale blockers, worker status) | `mem_store` brief summary, then `complete_event` |
| **ALERT** | Pattern detected, or can't fix something | Email Evan (if unresolvable), then `complete_event` |

Always call `complete_event` as the final step.

---

## Key MCP Tools

| Tool | Use |
|------|-----|
| `mem_task_list` | List tasks by status |
| `mem_task_get` | Fetch one task |
| `mem_task_patch` | Update task fields (status, blockedBy, etc.) |
| `mem_task_retry` | Re-queue a failed task |
| `worker_list` | See all workers + currentTask |
| `worker_register` | Re-register / fix offline worker status |
| `worker_purge` | Remove stale workers (triggers auto-spawn) |
| `worker_heartbeat` | Update a worker's heartbeat |
| `mem_store` | Save notes/alerts to memory |
| `complete_event` | Mark the check event done (always last) |
| `fail_event` | Mark event failed if something went wrong processing it |

---

## Common Patterns & Fixes

**"offline" worker with fresh heartbeat** → `worker_register` (resets status to "idle")

**"draining" worker** → ignore, the sweep deletes it automatically when heartbeat goes stale

**Full pool offline** → `worker_purge` first (triggers auto-spawn). If still empty after 1-2 cycles → immediately try `worker_register` with known workerIds + sessionLabels. Sessions are often still alive — they just lost DB registration. Re-registering brings them back instantly. Only email Evan if `worker_register` also fails to restore the pool.

**Orphaned active task** → `mem_task_patch(taskId, {status: "pending"})` + clear `startedAt`

**Task stuck with stale blockedBy** → fetch each blocker, if all done/failed/cancelled → `mem_task_patch(taskId, {blockedBy: []})`
