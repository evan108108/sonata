// Project a Studio Track (kind 30531) → studio_track entity.
// Per plan §7.2.2.

import {
  appendAudit,
  buildEntityTags,
  ensureMember,
  parseExistingAttributes,
  shouldReplaceBody,
  upsertWithMerge,
} from "./util";
import type { ProjectionContext } from "./types";

export async function projectTrack(ctx: ProjectionContext): Promise<void> {
  const { rumor, payload, client, roomSlug } = ctx;
  const trackName =
    typeof payload["name"] === "string" ? (payload["name"] as string) : ctx.dTag;
  const entityName = `studio:track:${roomSlug}:${trackName}`;

  const existing = await client.entity.byNameOrNull(entityName);
  const existingAttrs = parseExistingAttributes(existing?.attributes);
  if (!shouldReplaceBody(rumor.created_at, existingAttrs)) return;

  const memberId = await ensureMember(client, ctx.createdByPubkey, roomSlug);
  const attributes: Record<string, unknown> = {
    _studio_kind: 30531,
    _studio_type: "Track",
    name: trackName,
    title: typeof payload["title"] === "string" ? payload["title"] : trackName,
    description: payload["description"] ?? null,
    layout: typeof payload["layout"] === "string" ? payload["layout"] : "column",
    closed_at_seconds:
      typeof payload["closedAt"] === "number" ? payload["closedAt"] : null,
    room_slug: roomSlug,
    created_by_pubkey: ctx.createdByPubkey,
    created_at_seconds: rumor.created_at,
    d_tag: ctx.dTag,
    event_id: rumor.id,
    tags: buildEntityTags(ctx),
    _studio_event_audit: appendAudit(existingAttrs, ctx),
    // A real Track event always wins over a stub auto-created by a Card.
    auto_created: false,
  };

  const { id } = await upsertWithMerge(client, {
    name: entityName,
    type: "studio_track",
    description: `Studio track ${trackName} (${roomSlug})`,
    attributes,
  });

  // --in_room--> studio:room:<slug>
  const room = await client.entity.byNameOrNull(`studio:room:${roomSlug}`);
  if (room) {
    await client.relation.create({
      sourceId: id,
      sourceType: "entity",
      targetId: room.id,
      targetType: "entity",
      relation: "in_room",
    });
  }

  // --created_by--> studio:member:<pubkey>
  await client.relation.create({
    sourceId: id,
    sourceType: "entity",
    targetId: memberId,
    targetType: "entity",
    relation: "created_by",
  });
}

/**
 * Auto-create a Track stub when a Card references one we haven't seen.
 * The real Track event will overwrite this when it arrives (auto_created
 * gets cleared by projectTrack). Idempotent on repeat calls.
 */
export async function ensureTrackStub(
  ctx: ProjectionContext,
  trackName: string,
): Promise<string> {
  const entityName = `studio:track:${ctx.roomSlug}:${trackName}`;
  const existing = await ctx.client.entity.byNameOrNull(entityName);
  if (existing) return existing.id;
  const res = await ctx.client.entity.upsert({
    name: entityName,
    type: "studio_track",
    description: `Studio track ${trackName} (${ctx.roomSlug}) — auto-created`,
    attributes: {
      _studio_kind: 30531,
      _studio_type: "Track",
      name: trackName,
      room_slug: ctx.roomSlug,
      auto_created: true,
      tags: ["sonata-studio", `room:${ctx.roomSlug}`, "auto-created"],
    },
  });
  // Tie the stub to its room if the room entity is around yet.
  const room = await ctx.client.entity.byNameOrNull(`studio:room:${ctx.roomSlug}`);
  if (room) {
    await ctx.client.relation.create({
      sourceId: res.id,
      sourceType: "entity",
      targetId: room.id,
      targetType: "entity",
      relation: "in_room",
    });
  }
  return res.id;
}
