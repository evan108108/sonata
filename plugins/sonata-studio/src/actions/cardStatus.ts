// Card status transition action — POST /api/card/transition.
//
// Implements the §3 authorization matrix from the card-assignment design:
//   - Author can set any status.
//   - Assignee can set in_progress and done.
//   - Anyone else gets 403 not_permitted.
//
// On success, re-publishes the card kind 30530 (replaceable-event LWW so the
// status field overwrites the prior payload) AND emits a kind-30533 audit
// comment with intent="status_change" and body `status: <prev> → <next>`.
// Returns the new rumor event id alongside the audit comment event id.

import { entity } from "../memory-client";
import {
  buildScopedDTag,
  buildSignedRumor,
  ensureSlug,
  ensureString,
  HttpError,
  loadRoomCtx,
  publishRumor,
  STUDIO_CONTEXT_V0,
  STUDIO_KIND_COMMENT,
  validatePayload,
} from "./util";
import type { ActionCtx } from "./room";

const HEX64_RE = /^[0-9a-f]{64}$/;

const LIFECYCLE_STATUSES = new Set(["open", "in_progress", "done", "archived"]);
const ASSIGNEE_ALLOWED_TARGETS = new Set(["in_progress", "done"]);

interface CardStatusTransitionRequest {
  room?: unknown;
  d_tag?: unknown;
  status?: unknown;
}

interface CardStatusTransitionResult {
  d_tag: string;
  rumor_event_id: string;
  audit_comment_event_id: string;
}

function parseAttrs(raw: string | null | undefined): Record<string, unknown> {
  if (!raw) return {};
  try {
    const v = JSON.parse(raw);
    if (v && typeof v === "object" && !Array.isArray(v)) return v as Record<string, unknown>;
  } catch {
    // ignore
  }
  return {};
}

function readAssignees(attrs: Record<string, unknown>): string[] {
  const raw = attrs["assignees"];
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((v): v is string => typeof v === "string")
    .map((s) => s.toLowerCase());
}

export async function transitionCardStatus(
  body: CardStatusTransitionRequest,
  ctx: ActionCtx,
): Promise<CardStatusTransitionResult> {
  const roomSlug = ensureSlug(body.room, "room");
  const dTag = ensureString(body.d_tag, "d_tag");
  const next = ensureString(body.status, "status");
  if (!LIFECYCLE_STATUSES.has(next)) {
    throw new HttpError(
      400,
      "invalid_status",
      `"status" must be one of open|in_progress|done|archived (got ${JSON.stringify(next)})`,
    );
  }

  const pluginPubLower = ctx.cfg.pluginPub.toLowerCase();

  // Locate the card by scanning studio_card entities for the room + d_tag —
  // the entity is keyed on the AUTHOR's pubkey, not the caller's, so we can't
  // construct the entity name directly when the caller is the assignee.
  const rows = await entity.list({ type: "studio_card", limit: 1000 });
  let entityName: string | null = null;
  let attrs: Record<string, unknown> = {};
  for (const r of rows) {
    const a = parseAttrs(r.attributes);
    if (a["room_slug"] === roomSlug && a["d_tag"] === dTag) {
      entityName = r.name;
      attrs = a;
      break;
    }
  }
  if (!entityName) {
    throw new HttpError(404, "card_not_found", `no card ${dTag} in room ${roomSlug}`);
  }

  const authorPub = String(attrs["created_by_pubkey"] ?? "").toLowerCase();
  if (!HEX64_RE.test(authorPub)) {
    throw new HttpError(500, "corrupt_card", `card ${dTag} has an invalid created_by_pubkey`);
  }
  const assignees = readAssignees(attrs);
  const isAuthor = authorPub === pluginPubLower;
  const isAssignee = assignees.includes(pluginPubLower);

  if (!isAuthor && !isAssignee) {
    throw new HttpError(
      403,
      "not_permitted",
      `only the author or current assignee may transition this card`,
    );
  }
  if (isAssignee && !isAuthor && !ASSIGNEE_ALLOWED_TARGETS.has(next)) {
    throw new HttpError(
      403,
      "not_permitted",
      `assignee may only transition to in_progress or done (requested: ${next})`,
    );
  }

  const prev =
    typeof attrs["status"] === "string" && LIFECYCLE_STATUSES.has(attrs["status"] as string)
      ? (attrs["status"] as string)
      : "open";

  const room = await loadRoomCtx(roomSlug, ctx.cfg.pluginPub);

  // Status transitions cannot republish the card: kind-30530 is addressable
  // by (kind, pubkey, d_tag), so a re-publish by the assignee (not the
  // original author) creates a SEPARATE replaceable event under the
  // assignee's pubkey instead of overwriting the author's card. Locally that
  // also writes a new studio_card entity keyed on the assignee. The original
  // card sits unchanged, the UI still reads "Open", and the transition
  // appears to revert.
  //
  // Instead, publish ONLY a kind-30533 comment with intent="status_change"
  // targeting the original card's event_id, plus a structured `to_status`
  // field. The comment projector applies the transition to the original
  // card entity. Comments are addressable by the transitioning party's own
  // pubkey, so the signature is legitimate.
  const originalCardEventId = String(attrs["event_id"] ?? "");
  if (originalCardEventId.length === 0) {
    throw new HttpError(500, "corrupt_card", `card ${dTag} has no event_id`);
  }
  const title = String(attrs["title"] ?? "");

  // Audit-trail comment — kind 30533, intent=status_change. Body is human-
  // readable; `to_status` is the machine-parseable target state used by
  // the comment projector to flip the original card's status field.
  const commentBody = `status: ${prev} → ${next}`;
  const commentPayload: Record<string, unknown> = {
    "@context": STUDIO_CONTEXT_V0,
    "@type": "Comment",
    target: { "@id": originalCardEventId },
    body: commentBody,
    intent: "status_change",
    to_status: next,
    from_status: prev,
    createdBy: pluginPubLower,
  };
  validatePayload(STUDIO_KIND_COMMENT, commentPayload);

  // Scope the comment d_tag to the target card so multiple status-change
  // comments on the same card from the same author replace cleanly. Distinct
  // from regular comments which scope on the target rumor + body hash.
  const commentDTag = buildScopedDTag(`status-change:${originalCardEventId}`);
  const commentRumor = buildSignedRumor({
    kind: STUDIO_KIND_COMMENT,
    payload: commentPayload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    publisherPub: ctx.cfg.pluginPub,
    dTag: commentDTag,
    alt: `Studio status change: ${commentBody}`,
  });
  const { rumorEventId: commentRumorId } = await publishRumor({
    rumor: commentRumor,
    payload: commentPayload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    gateway: ctx.gateway,
  });

  // §6.4 / §15.4 — a transition back to `open` clears the auto-run sentinel
  // so the next eligible publish re-fires dispatch. This lets a human (or
  // the assignee) deliberately re-run a card by toggling status. We patch
  // the studio_card entity directly here because the comment-projection
  // path won't strip these fields (it patches `status` only).
  if (next === "open") {
    const sentinelKeys = [
      "auto_run_dispatched_event_id",
      "auto_run_task_id",
      "auto_run_dispatched_at_ms",
      "auto_run_completion_status",
      "auto_run_completion_at_ms",
    ];
    const hadSentinel = sentinelKeys.some((k) => k in attrs);
    if (hadSentinel && entityName) {
      const cleared: Record<string, unknown> = { ...attrs };
      for (const k of sentinelKeys) delete cleared[k];
      // Re-clear status as well so it matches the projected target (the
      // audit-comment projection will also patch this, but doing it here
      // keeps the entity coherent if projection lags behind).
      cleared["status"] = "open";
      // Locate the entity id (we didn't capture it above to keep the original
      // lookup cheap). One additional byName fetch is acceptable for a
      // human-driven action.
      const row = await entity.byNameOrNull(entityName).catch(() => null);
      if (row) {
        await entity.patch({ id: row.id, attributes: cleared }).catch(() => {
          // Non-fatal: dispatch will re-fire after re-projection sets a
          // fresh sentinel if the entity-update fails here.
        });
      }
    }
  }

  return {
    d_tag: dTag,
    rumor_event_id: originalCardEventId,
    audit_comment_event_id: commentRumorId,
  };
}

export const cardStatus = {
  transition(body: unknown, ctx: ActionCtx): Promise<CardStatusTransitionResult> {
    return transitionCardStatus((body ?? {}) as CardStatusTransitionRequest, ctx);
  },
};
