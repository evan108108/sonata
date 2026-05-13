// Project a Studio Comment (kind 30533) → studio_comment entity.
// Per plan §7.2.4. Pending-relation handling is the interesting bit:
// if the target entity isn't loaded yet (out-of-order delivery), we stash
// the relation in `_pending_relations` for later resolution. The Card /
// Question / Answer projectors call resolvePendingRelations() to drain.

import {
  appendAudit,
  buildEntityTags,
  ensureMember,
  extractTargetEventId,
  parseExistingAttributes,
  shouldReplaceBody,
  upsertWithMerge,
} from "./util";
import type { PendingRelation, ProjectionContext } from "./types";

export async function projectComment(ctx: ProjectionContext): Promise<void> {
  const { rumor, payload, client, roomSlug, createdByPubkey, dTag } = ctx;
  const entityName = `studio:comment:${roomSlug}:${createdByPubkey}:${dTag}`;

  const existing = await client.entity.byNameOrNull(entityName);
  const existingAttrs = parseExistingAttributes(existing?.attributes);
  if (!shouldReplaceBody(rumor.created_at, existingAttrs)) return;

  const memberId = await ensureMember(client, createdByPubkey, roomSlug);
  const target = isObject(payload["target"])
    ? (payload["target"] as Record<string, unknown>)
    : null;
  const targetRef = target && typeof target["@id"] === "string" ? (target["@id"] as string) : "";

  const attributes: Record<string, unknown> = {
    _studio_kind: 30533,
    _studio_type: "Comment",
    target_ref: targetRef,
    body: typeof payload["body"] === "string" ? payload["body"] : "",
    intent: typeof payload["intent"] === "string" ? payload["intent"] : null,
    blocks: Array.isArray(payload["blocks"]) ? payload["blocks"] : [],
    created_by_pubkey: createdByPubkey,
    room_slug: roomSlug,
    created_at_seconds: rumor.created_at,
    d_tag: dTag,
    event_id: rumor.id,
    tags: buildEntityTags(ctx),
    _studio_event_audit: appendAudit(existingAttrs, ctx),
  };

  // First commit: write the entity (without pending — we may add it below).
  const { id: commentId } = await upsertWithMerge(client, {
    name: entityName,
    type: "studio_comment",
    description: `Studio comment by ${createdByPubkey.slice(0, 8)}…`,
    attributes,
  });

  // --created_by--> studio:member:<pubkey>
  await client.relation.create({
    sourceId: commentId,
    sourceType: "entity",
    targetId: memberId,
    targetType: "entity",
    relation: "created_by",
  });

  // Try to resolve --targets--> immediately; if the target isn't around,
  // stash the relation in _pending_relations on this entity.
  const targetEventId = extractTargetEventId(targetRef);
  if (targetEventId) {
    const targetEntity = await findTargetEntity(client, targetEventId);
    if (targetEntity) {
      await client.relation.create({
        sourceId: commentId,
        sourceType: "entity",
        targetId: targetEntity.id,
        targetType: "entity",
        relation: "targets",
      });
    } else {
      const pending: PendingRelation[] = [
        ...readPending(existingAttrs),
        { relation: "targets", target_event_id: targetEventId },
      ];
      await client.entity.patch({
        id: commentId,
        attributes: { ...attributes, _pending_relations: pending },
      });
    }
  }

  // intent="status_change" comments are the wire format for card lifecycle
  // transitions. The originating action (cardStatus.ts) cannot republish
  // the card itself (kind-30530 is addressable by author pubkey, so the
  // assignee re-publishing forks the addressable event). Instead, the
  // comment carries the new state in `to_status` and the comment projector
  // applies it to the target card here.
  if (payload["intent"] === "status_change" && targetEventId) {
    const toStatus = payload["to_status"];
    const LIFECYCLE = new Set(["open", "in_progress", "done", "archived"]);
    if (typeof toStatus === "string" && LIFECYCLE.has(toStatus)) {
      const targetCard = await findTargetEntity(client, targetEventId);
      if (targetCard) {
        const cardAttrs = parseExistingAttributes(targetCard.attributes);
        await client.entity.patch({
          id: targetCard.id,
          attributes: { ...cardAttrs, status: toStatus },
        });
      }
    }
  }
}

function isObject(x: unknown): x is Record<string, unknown> {
  return typeof x === "object" && x !== null && !Array.isArray(x);
}

function readPending(attrs: Record<string, unknown>): PendingRelation[] {
  const raw = attrs["_pending_relations"];
  if (!Array.isArray(raw)) return [];
  const out: PendingRelation[] = [];
  for (const e of raw) {
    if (!isObject(e)) continue;
    const rel = e["relation"];
    const tid = e["target_event_id"];
    if (typeof rel === "string" && typeof tid === "string") {
      out.push({ relation: rel, target_event_id: tid });
    }
  }
  return out;
}

async function findTargetEntity(
  client: ProjectionContext["client"],
  eventId: string,
): Promise<{ id: string; type: string } | null> {
  for (const type of ["studio_card", "studio_question", "studio_answer"]) {
    const list = await client.entity.list({ type });
    for (const e of list) {
      const attrs = parseExistingAttributes(e.attributes);
      if (
        typeof attrs["event_id"] === "string" &&
        attrs["event_id"].toLowerCase() === eventId
      ) {
        return { id: e.id, type: e.type };
      }
    }
  }
  return null;
}
