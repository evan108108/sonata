// Project a Studio DispatchIntent (kind 30532) → studio_dispatch_intent.
// Per plan §7.2.3.

import {
  appendAudit,
  buildEntityTags,
  ensureMember,
  parseExistingAttributes,
  shouldReplaceBody,
  upsertWithMerge,
} from "./util";
import type { ProjectionContext } from "./types";

export async function projectDispatchIntent(ctx: ProjectionContext): Promise<void> {
  const { rumor, payload, client, roomSlug, createdByPubkey } = ctx;
  const busEventId =
    typeof payload["eventId"] === "string" ? (payload["eventId"] as string) : ctx.dTag;
  const entityName = `studio:dispatch:${roomSlug}:${busEventId}`;

  const existing = await client.entity.byNameOrNull(entityName);
  const existingAttrs = parseExistingAttributes(existing?.attributes);
  if (!shouldReplaceBody(rumor.created_at, existingAttrs)) return;

  const memberId = await ensureMember(client, createdByPubkey, roomSlug);

  const attributes: Record<string, unknown> = {
    _studio_kind: 30532,
    _studio_type: "DispatchIntent",
    bus_event_id: busEventId,
    candidates: Array.isArray(payload["candidates"]) ? payload["candidates"] : [],
    chosen: typeof payload["chosen"] === "string" ? payload["chosen"] : null,
    reason: typeof payload["reason"] === "string" ? payload["reason"] : null,
    signals: isObject(payload["signals"]) ? payload["signals"] : {},
    track_slug: typeof payload["track"] === "string" ? payload["track"] : null,
    created_at_ms:
      typeof payload["createdAt"] === "number" ? payload["createdAt"] : null,
    created_by_pubkey: createdByPubkey,
    room_slug: roomSlug,
    created_at_seconds: rumor.created_at,
    d_tag: ctx.dTag,
    event_id: rumor.id,
    tags: buildEntityTags(ctx),
    _studio_event_audit: appendAudit(existingAttrs, ctx),
  };

  const { id: dispatchId } = await upsertWithMerge(client, {
    name: entityName,
    type: "studio_dispatch_intent",
    description: `Studio dispatch for bus event ${busEventId}`,
    attributes,
  });

  await client.relation.create({
    sourceId: dispatchId,
    sourceType: "entity",
    targetId: memberId,
    targetType: "entity",
    relation: "created_by",
  });

  const room = await client.entity.byNameOrNull(`studio:room:${roomSlug}`);
  if (room) {
    await client.relation.create({
      sourceId: dispatchId,
      sourceType: "entity",
      targetId: room.id,
      targetType: "entity",
      relation: "in_room",
    });
  }
}

function isObject(x: unknown): x is Record<string, unknown> {
  return typeof x === "object" && x !== null && !Array.isArray(x);
}
