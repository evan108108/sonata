// Project Studio Question (kind 30534) and Answer (kind 30535).
// Per plan §7.2.5 + §7.2.6. Answer has the side effect of flipping the
// target studio_question.answered = true.

import {
  appendAudit,
  buildEntityTags,
  ensureMember,
  extractTargetEventId,
  parseExistingAttributes,
  resolvePendingRelations,
  shouldReplaceBody,
  upsertWithMerge,
} from "./util";
import type { PendingRelation, ProjectionContext } from "./types";

export async function projectQuestion(ctx: ProjectionContext): Promise<void> {
  const { rumor, payload, client, roomSlug, createdByPubkey, dTag } = ctx;
  const entityName = `studio:question:${roomSlug}:${createdByPubkey}:${dTag}`;

  const existing = await client.entity.byNameOrNull(entityName);
  const existingAttrs = parseExistingAttributes(existing?.attributes);
  if (!shouldReplaceBody(rumor.created_at, existingAttrs)) return;

  const memberId = await ensureMember(client, createdByPubkey, roomSlug);

  // Preserve `answered` if already set by an out-of-order Answer.
  const previouslyAnswered = existingAttrs["answered"] === true;

  const attributes: Record<string, unknown> = {
    _studio_kind: 30534,
    _studio_type: "Question",
    body: typeof payload["body"] === "string" ? payload["body"] : "",
    track_slug: typeof payload["track"] === "string" ? payload["track"] : null,
    answered: previouslyAnswered,
    created_by_pubkey: createdByPubkey,
    room_slug: roomSlug,
    created_at_seconds: rumor.created_at,
    d_tag: dTag,
    event_id: rumor.id,
    tags: buildEntityTags(ctx),
    _studio_event_audit: appendAudit(existingAttrs, ctx),
  };

  const { id: questionId } = await upsertWithMerge(client, {
    name: entityName,
    type: "studio_question",
    description: `Studio question by ${createdByPubkey.slice(0, 8)}…`,
    attributes,
  });

  await client.relation.create({
    sourceId: questionId,
    sourceType: "entity",
    targetId: memberId,
    targetType: "entity",
    relation: "created_by",
  });

  const room = await client.entity.byNameOrNull(`studio:room:${roomSlug}`);
  if (room) {
    await client.relation.create({
      sourceId: questionId,
      sourceType: "entity",
      targetId: room.id,
      targetType: "entity",
      relation: "in_room",
    });
  }

  // Drain any pending --targets--> relations waiting on this question.
  await resolvePendingRelations(client, rumor.id, questionId);
}

export async function projectAnswer(ctx: ProjectionContext): Promise<void> {
  const { rumor, payload, client, roomSlug, createdByPubkey, dTag } = ctx;
  const entityName = `studio:answer:${roomSlug}:${createdByPubkey}:${dTag}`;

  const existing = await client.entity.byNameOrNull(entityName);
  const existingAttrs = parseExistingAttributes(existing?.attributes);
  if (!shouldReplaceBody(rumor.created_at, existingAttrs)) return;

  const memberId = await ensureMember(client, createdByPubkey, roomSlug);
  const target = isObject(payload["target"])
    ? (payload["target"] as Record<string, unknown>)
    : null;
  const questionRef = target && typeof target["@id"] === "string" ? (target["@id"] as string) : "";

  const attributes: Record<string, unknown> = {
    _studio_kind: 30535,
    _studio_type: "Answer",
    question_ref: questionRef,
    body: typeof payload["body"] === "string" ? payload["body"] : "",
    created_by_pubkey: createdByPubkey,
    room_slug: roomSlug,
    created_at_seconds: rumor.created_at,
    d_tag: dTag,
    event_id: rumor.id,
    tags: buildEntityTags(ctx),
    _studio_event_audit: appendAudit(existingAttrs, ctx),
  };

  const { id: answerId } = await upsertWithMerge(client, {
    name: entityName,
    type: "studio_answer",
    description: `Studio answer by ${createdByPubkey.slice(0, 8)}…`,
    attributes,
  });

  await client.relation.create({
    sourceId: answerId,
    sourceType: "entity",
    targetId: memberId,
    targetType: "entity",
    relation: "created_by",
  });

  // Resolve --targets--> studio_question (or stash as pending). Side effect:
  // flip studio_question.answered = true on the target.
  const targetEventId = extractTargetEventId(questionRef);
  if (targetEventId) {
    const question = await findEntityByEventId(client, "studio_question", targetEventId);
    if (question) {
      await client.relation.create({
        sourceId: answerId,
        sourceType: "entity",
        targetId: question.id,
        targetType: "entity",
        relation: "targets",
      });
      const qAttrs = parseExistingAttributes(question.attributes);
      if (qAttrs["answered"] !== true) {
        await client.entity.patch({
          id: question.id,
          attributes: { ...qAttrs, answered: true },
        });
      }
    } else {
      const pending: PendingRelation[] = [
        ...readPending(existingAttrs),
        { relation: "targets", target_event_id: targetEventId },
      ];
      await client.entity.patch({
        id: answerId,
        attributes: { ...attributes, _pending_relations: pending },
      });
    }
  }

  // Other out-of-order entities (e.g. a Comment targeting this Answer)
  // can resolve to us now.
  await resolvePendingRelations(client, rumor.id, answerId);
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

async function findEntityByEventId(
  client: ProjectionContext["client"],
  type: string,
  eventId: string,
): Promise<{ id: string; attributes?: string | null } | null> {
  const list = await client.entity.list({ type });
  for (const e of list) {
    const attrs = parseExistingAttributes(e.attributes);
    if (
      typeof attrs["event_id"] === "string" &&
      attrs["event_id"].toLowerCase() === eventId.toLowerCase()
    ) {
      return { id: e.id, attributes: e.attributes };
    }
  }
  return null;
}
