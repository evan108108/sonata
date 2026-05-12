// Project a Studio Card (kind 30530) → studio_card entity.
// Per plan §7.2.1.

import {
  appendAudit,
  buildEntityTags,
  ensureMember,
  parseExistingAttributes,
  resolvePendingRelations,
  shouldReplaceBody,
  upsertWithMerge,
} from "./util";
import { ensureTrackStub } from "./track";
import type { ProjectionContext } from "./types";

export async function projectCard(ctx: ProjectionContext): Promise<void> {
  const { rumor, payload, client, roomSlug, createdByPubkey, dTag } = ctx;
  const entityName = `studio:card:${roomSlug}:${createdByPubkey}:${dTag}`;

  const existing = await client.entity.byNameOrNull(entityName);
  const existingAttrs = parseExistingAttributes(existing?.attributes);
  if (!shouldReplaceBody(rumor.created_at, existingAttrs)) return;

  const memberId = await ensureMember(client, createdByPubkey, roomSlug);

  const trackSlug = typeof payload["track"] === "string" ? (payload["track"] as string) : "";
  const relatedToRaw = payload["relatedTo"];
  const relatedTo = Array.isArray(relatedToRaw)
    ? relatedToRaw.filter((v): v is string => typeof v === "string")
    : [];

  const status =
    typeof payload["status"] === "string" ? (payload["status"] as string) : "active";

  // Body is the canonical long-form field as of 2026-05-12. The pre-cutover
  // wire shape used `summary`; fall back to it so cards posted under the old
  // shape still surface their text.
  const cardBody =
    typeof payload["body"] === "string"
      ? (payload["body"] as string)
      : typeof payload["summary"] === "string"
        ? (payload["summary"] as string)
        : "";

  const attributes: Record<string, unknown> = {
    _studio_kind: 30530,
    _studio_type: "Card",
    card_kind: typeof payload["kind"] === "string" ? payload["kind"] : null,
    track_slug: trackSlug,
    title: typeof payload["title"] === "string" ? payload["title"] : "",
    body: cardBody,
    // DEPRECATED alias — readers should prefer `body`. Kept in sync for one
    // cutover release so unmigrated renderers still find the text. Remove
    // after 2026-05-12 + one release.
    summary: cardBody,
    blocks: Array.isArray(payload["blocks"]) ? payload["blocks"] : [],
    related_to: relatedTo,
    status,
    created_by_pubkey: createdByPubkey,
    room_slug: roomSlug,
    created_at_seconds: rumor.created_at,
    d_tag: dTag,
    event_id: rumor.id,
    tags: buildEntityTags(ctx),
    _studio_event_audit: appendAudit(existingAttrs, ctx),
  };

  const { id: cardId } = await upsertWithMerge(client, {
    name: entityName,
    type: "studio_card",
    description:
      typeof payload["title"] === "string"
        ? `Studio card: ${payload["title"]}`
        : `Studio card ${dTag}`,
    attributes,
  });

  // --in_track--> studio:track:<room>:<track>. Auto-create stub if missing.
  if (trackSlug.length > 0) {
    const trackId = await ensureTrackStub(ctx, trackSlug);
    await client.relation.create({
      sourceId: cardId,
      sourceType: "entity",
      targetId: trackId,
      targetType: "entity",
      relation: "in_track",
    });
  }

  // --in_room--> studio:room:<slug>
  const room = await client.entity.byNameOrNull(`studio:room:${roomSlug}`);
  if (room) {
    await client.relation.create({
      sourceId: cardId,
      sourceType: "entity",
      targetId: room.id,
      targetType: "entity",
      relation: "in_room",
    });
  }

  // --created_by--> studio:member:<pubkey>
  await client.relation.create({
    sourceId: cardId,
    sourceType: "entity",
    targetId: memberId,
    targetType: "entity",
    relation: "created_by",
  });

  // --related_to--> any related entities we already have. We resolve by
  // event_id only — `related_to` strings that aren't 64-hex are kept on
  // the entity body for renderers but not promoted to relations.
  for (const ref of relatedTo) {
    const targetId = await findEntityByEventId(client, ref);
    if (targetId) {
      await client.relation.create({
        sourceId: cardId,
        sourceType: "entity",
        targetId,
        targetType: "entity",
        relation: "related_to",
      });
    }
  }

  // Resolve any pending --targets--> relations that were waiting on us.
  await resolvePendingRelations(client, rumor.id, cardId);

  // Reserved-kind side-effects. Any `cardKind` starting with `_` is treated as
  // hidden metadata: the card is still projected to studio_card (so the wire
  // round-trips), but the UI filters these out and the projector layers
  // extra entity writes on top. See §"Reserved card kinds" below.
  const cardKindStr = typeof payload["kind"] === "string" ? (payload["kind"] as string) : "";
  if (cardKindStr.startsWith("_profile")) {
    await upsertRoomMember(ctx, attributes["title"] as string);
  }
}

// ── Reserved card kinds ─────────────────────────────────────────────────────
//
// Any cardKind starting with `_` is reserved for "hidden metadata" — wire
// round-trips normally, but renderers MUST hide them from card lists and the
// projector MAY layer additional entity writes on top.
//
// Defined today:
//   `_profile` — author's nickname in this room. Title field carries the
//                nickname. d_tag MUST be `profile:<lowercase-pubkey>` so
//                re-publishes overwrite.
//
// New `_`-prefixed kinds should keep the contract: the original studio_card
// projection still happens, the side-effect is additive, and the UI filter
// is applied at every surface that lists cards.

async function upsertRoomMember(
  ctx: ProjectionContext,
  rawTitle: string | undefined,
): Promise<void> {
  const { client, roomSlug, createdByPubkey } = ctx;
  const nickname = typeof rawTitle === "string" ? rawTitle.trim() : "";
  if (nickname.length === 0) return;

  // Per-room member entity. Distinct from the cross-room `studio:member:<pub>`
  // used by `ensureMember()` for relation targets — those keep their existing
  // shape so the studio_card --created_by--> relations don't churn.
  const name = `studio:member:${roomSlug}:${createdByPubkey}`;
  const existing = await client.entity.byNameOrNull(name);
  const existingAttrs = parseExistingAttributes(existing?.attributes);
  await client.entity.upsert({
    name,
    type: "studio_member",
    description: `Studio member ${createdByPubkey.slice(0, 8)}… in ${roomSlug}`,
    attributes: {
      ...existingAttrs,
      pubkey_hex: createdByPubkey,
      room_slug: roomSlug,
      nickname,
      tags: ["sonata-studio", "studio-member", `room:${roomSlug}`],
    },
  });
}

async function findEntityByEventId(
  client: ProjectionContext["client"],
  ref: string,
): Promise<string | null> {
  const HEX64 = /^[0-9a-f]{64}$/i;
  const eventId = HEX64.test(ref)
    ? ref.toLowerCase()
    : ref.startsWith("nostr:") && HEX64.test(ref.slice("nostr:".length))
      ? ref.slice("nostr:".length).toLowerCase()
      : null;
  if (!eventId) return null;
  for (const type of ["studio_card", "studio_question", "studio_answer"]) {
    const list = await client.entity.list({ type });
    for (const e of list) {
      const attrs = e.attributes ? safeParse(e.attributes) : {};
      if (typeof attrs["event_id"] === "string" && attrs["event_id"].toLowerCase() === eventId) {
        return e.id;
      }
    }
  }
  return null;
}

function safeParse(raw: string): Record<string, unknown> {
  try {
    const v = JSON.parse(raw);
    if (v && typeof v === "object" && !Array.isArray(v)) return v as Record<string, unknown>;
  } catch {
    /* ignore */
  }
  return {};
}
