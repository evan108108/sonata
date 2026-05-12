// The "do the work" half of the auto-run subsystem.
//
// `dispatchCard` is the one-shot side effect — it POSTs a task to Sonata's
// /api/task endpoint, marks the card's sentinel, publishes a kind-30532
// dispatch_intent ("chosen=dispatch"), and transitions the card to
// in_progress via the existing audit-comment path.
//
// `markDispatchedFailure` is the watcher-side counterpart for tasks that
// finish complete or fail. Both call the same status_transition action as
// the renderer, so the audit-comment shape stays compatible with Worker 1's
// projection.
//
// `postSkippedComment` posts an audit-comment-only no-publish for cases
// where eligibility fails (rate-limit, founder not allow-listed, etc) so
// the assigner sees why nothing happened.

import { cardStatus } from "../actions/cardStatus";
import { comment as commentAction } from "../actions/comment";
import { dispatch as dispatchAction } from "../actions/dispatch";
import { log } from "../logger";
import { getAutoRunContext } from "./context";

const SONATA_HOST = (process.env["SONATA_HOST"] ?? "http://127.0.0.1:3211").replace(/\/$/, "");

export interface DispatchArgs {
  roomSlug: string;
  cardDTag: string;
  cardEventId: string;
  cardTitle: string;
  prompt: string;
  trackSlug: string;
  assignerPubkey: string;
  audienceAddress: string | null;
  roomProject: string | null;
}

export interface DispatchResult {
  task_id: string;
  rumor_event_id: string | null;
}

const AUTO_RUN_PROJECT = "studio-auto-run";

interface TaskCreateResponse {
  ok?: boolean;
  result?: { id?: string };
}

/**
 * Build the §6.5 dispatch envelope and POST it to Sonata's /api/task.
 *
 * `assignedTo: null` (public scheduler pool, §15.1 decision — no dedicated
 * studio-worker pool). Tags carry the room + card refs so the watcher and
 * any operator dashboard can correlate them.
 */
async function createSonataTask(args: DispatchArgs): Promise<string> {
  const body = {
    title: `Studio auto-run: ${args.cardTitle}`,
    prompt: args.prompt,
    source: "sonata-studio",
    sourceRef: args.cardEventId,
    project: AUTO_RUN_PROJECT,
    tags: [
      "studio-auto-run",
      `room:${args.roomSlug}`,
      `track:${args.trackSlug || "none"}`,
      `card:${args.cardEventId}`,
    ],
    workingDir: `~/.sonata/auto-run/${args.roomSlug}/${args.cardDTag}`,
    metadata: JSON.stringify({
      studio_room_slug: args.roomSlug,
      studio_card_event_id: args.cardEventId,
      studio_card_d_tag: args.cardDTag,
      studio_assigner_pubkey: args.assignerPubkey,
      studio_room_audience_address: args.audienceAddress,
    }),
  };
  const res = await fetch(`${SONATA_HOST}/api/task/`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`mem_task_create → ${res.status}: ${text}`);
  }
  let parsed: TaskCreateResponse;
  try {
    parsed = JSON.parse(text) as TaskCreateResponse;
  } catch {
    throw new Error(`mem_task_create returned non-JSON: ${text.slice(0, 200)}`);
  }
  const id = parsed.result?.id;
  if (!id) {
    throw new Error(`mem_task_create response missing result.id: ${text.slice(0, 200)}`);
  }
  return id;
}

/** Publish a kind-30532 dispatch_intent record summarising the decision. */
async function publishDispatchIntent(
  roomSlug: string,
  taskId: string,
  cardEventId: string,
  chosen: "dispatch" | "completed" | "failed" | "skipped",
  reason: string,
  signals: Record<string, string | number | boolean>,
): Promise<void> {
  const ctx = getAutoRunContext();
  if (!ctx) return;
  try {
    await dispatchAction.post(
      {
        room: roomSlug,
        // dispatch_intent's d_tag is built from event_id; we use a stable
        // per-card key so successive `dispatch` → `completed`|`failed`
        // publishes overwrite via replaceable-event LWW. Tying to the card
        // event_id (rather than the task id) keeps the record findable
        // alongside the card it belongs to.
        event_id: `studio-auto-run:${cardEventId}`,
        candidates: ["dispatch", "completed", "failed", "skipped"],
        chosen,
        reason,
        signals: {
          ...signals,
          task_id: taskId,
        },
      },
      ctx,
    );
  } catch (err) {
    log.warn("[auto-run] dispatch_intent publish failed", {
      room: roomSlug,
      err: err instanceof Error ? err.message : String(err),
    });
  }
}

async function transitionCard(
  roomSlug: string,
  cardDTag: string,
  status: "open" | "in_progress" | "done" | "archived",
): Promise<void> {
  const ctx = getAutoRunContext();
  if (!ctx) return;
  try {
    await cardStatus.transition({ room: roomSlug, d_tag: cardDTag, status }, ctx);
  } catch (err) {
    log.warn("[auto-run] status transition failed", {
      room: roomSlug,
      d_tag: cardDTag,
      target: status,
      err: err instanceof Error ? err.message : String(err),
    });
  }
}

async function postCommentSafe(
  roomSlug: string,
  targetEventId: string,
  body: string,
  intent: string,
): Promise<void> {
  const ctx = getAutoRunContext();
  if (!ctx) return;
  try {
    await commentAction.post({ room: roomSlug, target: targetEventId, body, intent }, ctx);
  } catch (err) {
    log.warn("[auto-run] comment post failed", {
      room: roomSlug,
      intent,
      err: err instanceof Error ? err.message : String(err),
    });
  }
}

/**
 * Run the dispatch sequence:
 *   1. POST /api/task → task_id
 *   2. publish kind-30532 dispatch_intent (chosen="dispatch")
 *   3. publish kind-30533 status_change → in_progress (via cardStatus action)
 *
 * Each step is wrapped in try/catch — partial dispatch leaves the sentinel
 * in place so we don't double-fire; a human can recover the half-state by
 * reopening the card or restarting the worker.
 */
export async function dispatchCard(args: DispatchArgs): Promise<DispatchResult> {
  const taskId = await createSonataTask(args);
  await publishDispatchIntent(
    args.roomSlug,
    taskId,
    args.cardEventId,
    "dispatch",
    `auto-run dispatched: ${args.cardTitle.slice(0, 120)}`,
    {
      assigner: args.assignerPubkey.slice(0, 16),
      track: args.trackSlug,
    },
  );
  await transitionCard(args.roomSlug, args.cardDTag, "in_progress");
  return { task_id: taskId, rumor_event_id: null };
}

export async function postSkippedComment(
  roomSlug: string,
  cardEventId: string,
  reason: string,
): Promise<void> {
  await postCommentSafe(roomSlug, cardEventId, `Auto-run skipped: ${reason}`, "auto_run_skipped");
}

export async function reportTaskComplete(
  roomSlug: string,
  cardDTag: string,
  cardEventId: string,
  resultBody: string,
  taskId: string,
): Promise<void> {
  await postCommentSafe(
    roomSlug,
    cardEventId,
    resultBody.length > 0 ? resultBody : "(no result body returned)",
    "result",
  );
  await publishDispatchIntent(
    roomSlug,
    taskId,
    cardEventId,
    "completed",
    `auto-run completed in task ${taskId.slice(0, 8)}`,
    { result_summary: resultBody.slice(0, 200) },
  );
  await transitionCard(roomSlug, cardDTag, "done");
}

export async function reportTaskFailed(
  roomSlug: string,
  cardDTag: string,
  cardEventId: string,
  errorBody: string,
  taskId: string,
): Promise<void> {
  const reason = errorBody.length > 0 ? errorBody : "(no error message returned)";
  await postCommentSafe(roomSlug, cardEventId, `Auto-run failed: ${reason}`, "error");
  await publishDispatchIntent(
    roomSlug,
    taskId,
    cardEventId,
    "failed",
    `auto-run failed in task ${taskId.slice(0, 8)}: ${reason.slice(0, 120)}`,
    { error_summary: reason.slice(0, 200) },
  );
  // Per §6.4 + §14.3 commit 4: on task failure, transition back to open so
  // a human can pick it up. The assignee can re-trigger auto-run by toggling
  // status, which clears the sentinel and re-fires the dispatch.
  await transitionCard(roomSlug, cardDTag, "open");
}
