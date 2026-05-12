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
  STUDIO_KIND_CARD,
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

  // Re-emit the full card payload with the new status. The author's payload
  // shape is the source of truth here — we read fields off the entity attrs
  // (the projector wrote them at last publish) and re-publish under the
  // original author's signing key. Subtle: the card was authored by some
  // other pubkey, but the transition action publishes a NEW rumor signed by
  // the caller. Replaceable-event LWW resolves the d_tag, but the d_tag is
  // namespaced by author pubkey in the entity name; on the wire it's just
  // the d_tag, so peers reading the rumor see the latest by created_at.
  // Authoring pubkey on the wire is the caller (so peers can authenticate
  // the transition came from someone with permission).
  const trackSlug = String(attrs["track_slug"] ?? "");
  const cardKind = String(attrs["card_kind"] ?? "note");
  const title = String(attrs["title"] ?? "");
  const cardBody = String(attrs["body"] ?? attrs["summary"] ?? "");
  const blocks = Array.isArray(attrs["blocks"]) ? (attrs["blocks"] as unknown[]) : [];
  const relatedTo = Array.isArray(attrs["related_to"])
    ? (attrs["related_to"] as string[])
    : [];
  // Strip projector-synthesized tags (`sonata-studio`, `room:<slug>`) so they
  // don't leak into the user-facing tags list on re-publish.
  const rawTags = Array.isArray(attrs["tags"]) ? (attrs["tags"] as string[]) : [];
  const roomMarker = `room:${roomSlug}`;
  const cardTags = rawTags.filter((t) => t !== "sonata-studio" && t !== roomMarker);

  const cardPayload: Record<string, unknown> = {
    "@context": STUDIO_CONTEXT_V0,
    "@type": "Card",
    kind: cardKind,
    track: trackSlug,
    title,
    body: cardBody,
    blocks,
    createdBy: authorPub,
    assignees,
    status: next,
  };
  if (relatedTo.length > 0) cardPayload["relatedTo"] = relatedTo;
  if (cardTags.length > 0) cardPayload["tags"] = cardTags;
  validatePayload(STUDIO_KIND_CARD, cardPayload);

  const cardRumor = buildSignedRumor({
    kind: STUDIO_KIND_CARD,
    payload: cardPayload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    publisherPub: ctx.cfg.pluginPub,
    dTag,
    alt: `Studio card: ${title}`,
  });
  const { rumorEventId: cardRumorId } = await publishRumor({
    rumor: cardRumor,
    payload: cardPayload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    gateway: ctx.gateway,
  });

  // Audit-trail comment — kind 30533, intent=status_change, body documents
  // the prev → next transition (§2.3 of the design doc).
  const commentBody = `status: ${prev} → ${next}`;
  const commentPayload: Record<string, unknown> = {
    "@context": STUDIO_CONTEXT_V0,
    "@type": "Comment",
    target: { "@id": cardRumorId },
    body: commentBody,
    intent: "status_change",
    createdBy: pluginPubLower,
  };
  validatePayload(STUDIO_KIND_COMMENT, commentPayload);

  const commentDTag = buildScopedDTag(cardRumorId);
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

  return {
    d_tag: dTag,
    rumor_event_id: cardRumorId,
    audit_comment_event_id: commentRumorId,
  };
}

export const cardStatus = {
  transition(body: unknown, ctx: ActionCtx): Promise<CardStatusTransitionResult> {
    return transitionCardStatus((body ?? {}) as CardStatusTransitionRequest, ctx);
  },
};
