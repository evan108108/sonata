// Card actions: post / list. Per plan §5.5-5.6.

import { entity } from "../memory-client";
import {
  buildDTag,
  buildSignedRumor,
  ensureSlug,
  ensureString,
  HttpError,
  loadRoomCtx,
  publishRumor,
  STUDIO_CONTEXT_V0,
  STUDIO_KIND_CARD,
  validatePayload,
} from "./util";
import type { ActionCtx } from "./room";

interface CardBlock {
  type: string;
  [k: string]: unknown;
}

interface CardPostRequest {
  room?: unknown;
  track?: unknown;
  kind?: unknown;
  title?: unknown;
  summary?: unknown;
  blocks?: unknown;
  related_to?: unknown;
  tags?: unknown;
  d_tag?: unknown;
}

interface CardPostResult {
  rumor_event_id: string;
  audience_address: string;
  d_tag: string;
}

interface CardListRequest {
  room?: unknown;
  track?: unknown;
  since?: unknown;
  limit?: unknown;
}

interface CardListEntry {
  event_id: string;
  d_tag: string;
  track: string;
  kind: string;
  title: string;
  summary: string;
  created_by: string;
  created_at: number;
  blocks: unknown[];
  tags: string[];
  related_to: string[];
  status: string;
}

interface CardListResult {
  cards: CardListEntry[];
}

// ── post ────────────────────────────────────────────────────────────────────

export async function postCard(
  body: CardPostRequest,
  ctx: ActionCtx,
): Promise<CardPostResult> {
  const roomSlug = ensureSlug(body.room, "room");
  const trackSlug = ensureSlug(body.track, "track");
  const cardKind = ensureString(body.kind, "kind");
  const title = ensureString(body.title, "title");
  const summary = ensureString(body.summary, "summary");
  const blocks = normalizeBlocks(body.blocks);
  const relatedTo = normalizeStringArray(body.related_to, "related_to");
  const cardTags = normalizeStringArray(body.tags, "tags");
  const dTag =
    body.d_tag !== undefined ? ensureString(body.d_tag, "d_tag") : buildDTag(title);

  const room = await loadRoomCtx(roomSlug, ctx.cfg.pluginPub);

  const payload: Record<string, unknown> = {
    "@context": STUDIO_CONTEXT_V0,
    "@type": "Card",
    kind: cardKind,
    track: trackSlug,
    title,
    summary,
    blocks,
    createdBy: ctx.cfg.pluginPub.toLowerCase(),
  };
  if (relatedTo.length > 0) payload["relatedTo"] = relatedTo;
  if (cardTags.length > 0) payload["tags"] = cardTags;
  validatePayload(STUDIO_KIND_CARD, payload);

  const rumor = buildSignedRumor({
    kind: STUDIO_KIND_CARD,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    publisherPub: ctx.cfg.pluginPub,
    dTag,
    alt: `Studio card: ${title}`,
  });
  const { rumorEventId } = await publishRumor({
    rumor,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    gateway: ctx.gateway,
  });

  return {
    rumor_event_id: rumorEventId,
    audience_address: room.audienceAddress,
    d_tag: dTag,
  };
}

function normalizeBlocks(raw: unknown): CardBlock[] {
  if (raw === undefined) return [];
  if (!Array.isArray(raw)) {
    throw new HttpError(400, "bad_request", `"blocks" must be an array`);
  }
  const out: CardBlock[] = [];
  for (let i = 0; i < raw.length; i++) {
    const b = raw[i];
    if (!b || typeof b !== "object" || Array.isArray(b)) {
      throw new HttpError(400, "bad_request", `blocks[${i}] must be an object`);
    }
    const obj = b as Record<string, unknown>;
    if (typeof obj["type"] !== "string" || obj["type"].length === 0) {
      throw new HttpError(400, "bad_request", `blocks[${i}].type must be a non-empty string`);
    }
    out.push(obj as CardBlock);
  }
  return out;
}

function normalizeStringArray(raw: unknown, field: string): string[] {
  if (raw === undefined) return [];
  if (!Array.isArray(raw)) {
    throw new HttpError(400, "bad_request", `"${field}" must be an array of strings`);
  }
  const out: string[] = [];
  for (let i = 0; i < raw.length; i++) {
    const v = raw[i];
    if (typeof v !== "string" || v.length === 0) {
      throw new HttpError(400, "bad_request", `"${field}[${i}]" must be a non-empty string`);
    }
    out.push(v);
  }
  return out;
}

// ── list ────────────────────────────────────────────────────────────────────

export async function listCards(
  query: CardListRequest,
  _ctx: ActionCtx,
): Promise<CardListResult> {
  const roomSlug = ensureSlug(query.room, "room");
  const trackFilter =
    query.track !== undefined ? ensureSlug(query.track, "track") : null;
  const sinceMs =
    query.since !== undefined ? Number(query.since) : null;
  if (sinceMs !== null && (!Number.isFinite(sinceMs) || sinceMs < 0)) {
    throw new HttpError(400, "bad_request", `"since" must be a non-negative number`);
  }
  const limitRaw = query.limit !== undefined ? Number(query.limit) : 50;
  const limit = Math.max(1, Math.min(200, Math.floor(Number.isFinite(limitRaw) ? limitRaw : 50)));

  const rows = await entity.list({ type: "studio_card", limit: 1000 });
  const out: CardListEntry[] = [];
  for (const r of rows) {
    const attrs = parseAttrs(r.attributes);
    if (attrs["room_slug"] !== roomSlug) continue;
    if (trackFilter !== null && attrs["track_slug"] !== trackFilter) continue;
    const createdSec = Number(attrs["created_at_seconds"] ?? 0);
    const createdMs = createdSec * 1000;
    if (sinceMs !== null && createdMs < sinceMs) continue;
    out.push({
      event_id: String(attrs["event_id"] ?? ""),
      d_tag: String(attrs["d_tag"] ?? ""),
      track: String(attrs["track_slug"] ?? ""),
      kind: String(attrs["card_kind"] ?? ""),
      title: String(attrs["title"] ?? ""),
      summary: String(attrs["summary"] ?? ""),
      created_by: String(attrs["created_by_pubkey"] ?? ""),
      created_at: createdMs,
      blocks: Array.isArray(attrs["blocks"]) ? (attrs["blocks"] as unknown[]) : [],
      tags: Array.isArray(attrs["tags"]) ? (attrs["tags"] as string[]) : [],
      related_to: Array.isArray(attrs["related_to"])
        ? (attrs["related_to"] as string[])
        : [],
      status: typeof attrs["status"] === "string" ? (attrs["status"] as string) : "active",
    });
  }
  out.sort((a, b) => b.created_at - a.created_at);
  return { cards: out.slice(0, limit) };
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

// ── delete ──────────────────────────────────────────────────────────────────

interface CardDeleteRequest {
  room?: unknown;
  d_tag?: unknown;
}

interface CardDeleteResult {
  rumor_event_id: string;
  d_tag: string;
}

export async function deleteCard(
  body: CardDeleteRequest,
  ctx: ActionCtx,
): Promise<CardDeleteResult> {
  const roomSlug = ensureSlug(body.room, "room");
  const dTag = ensureString(body.d_tag, "d_tag");

  const pluginPubLower = ctx.cfg.pluginPub.toLowerCase();
  const entityName = `studio:card:${roomSlug}:${pluginPubLower}:${dTag}`;
  const existing = await entity.byNameOrNull(entityName);
  if (!existing) {
    throw new HttpError(404, "card_not_found", `no card ${dTag} in room ${roomSlug} by this author`);
  }
  const attrs = parseAttrs(existing.attributes);
  const createdBy = String(attrs["created_by_pubkey"] ?? "").toLowerCase();
  if (createdBy !== pluginPubLower) {
    throw new HttpError(403, "not_author", `only the card author may delete this card`);
  }

  const room = await loadRoomCtx(roomSlug, ctx.cfg.pluginPub);

  const trackSlug = String(attrs["track_slug"] ?? "");
  const title = String(attrs["title"] ?? "");
  const summary = String(attrs["summary"] ?? "");
  const cardKind = String(attrs["card_kind"] ?? "note");
  const blocks = Array.isArray(attrs["blocks"]) ? (attrs["blocks"] as unknown[]) : [];
  const relatedTo = Array.isArray(attrs["related_to"]) ? (attrs["related_to"] as string[]) : [];
  const cardTags = Array.isArray(attrs["tags"]) ? (attrs["tags"] as string[]) : [];

  const payload: Record<string, unknown> = {
    "@context": STUDIO_CONTEXT_V0,
    "@type": "Card",
    kind: cardKind,
    track: trackSlug,
    title,
    summary,
    blocks,
    createdBy: pluginPubLower,
    status: "deleted",
  };
  if (relatedTo.length > 0) payload["relatedTo"] = relatedTo;
  if (cardTags.length > 0) payload["tags"] = cardTags;
  validatePayload(STUDIO_KIND_CARD, payload);

  const rumor = buildSignedRumor({
    kind: STUDIO_KIND_CARD,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    publisherPub: ctx.cfg.pluginPub,
    dTag,
    alt: "Studio card: deleted",
  });
  const { rumorEventId } = await publishRumor({
    rumor,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    gateway: ctx.gateway,
  });

  return { rumor_event_id: rumorEventId, d_tag: dTag };
}

// ── update ──────────────────────────────────────────────────────────────────

interface CardUpdateRequest {
  room?: unknown;
  d_tag?: unknown;
  track?: unknown;
  kind?: unknown;
  title?: unknown;
  summary?: unknown;
  blocks?: unknown;
  related_to?: unknown;
  tags?: unknown;
}

interface CardUpdateResult {
  rumor_event_id: string;
  d_tag: string;
}

export async function updateCard(
  body: CardUpdateRequest,
  ctx: ActionCtx,
): Promise<CardUpdateResult> {
  const roomSlug = ensureSlug(body.room, "room");
  const dTag = ensureString(body.d_tag, "d_tag");

  const pluginPubLower = ctx.cfg.pluginPub.toLowerCase();
  const entityName = `studio:card:${roomSlug}:${pluginPubLower}:${dTag}`;
  const existing = await entity.byNameOrNull(entityName);
  if (!existing) {
    throw new HttpError(404, "card_not_found", `no card ${dTag} in room ${roomSlug} by this author`);
  }
  const attrs = parseAttrs(existing.attributes);
  const createdBy = String(attrs["created_by_pubkey"] ?? "").toLowerCase();
  if (createdBy !== pluginPubLower) {
    throw new HttpError(403, "not_author", `only the card author may edit this card`);
  }

  // Merge: present fields override; absent fields preserve from the entity body.
  const trackSlug =
    body.track !== undefined
      ? ensureSlug(body.track, "track")
      : String(attrs["track_slug"] ?? "");
  const cardKind =
    body.kind !== undefined
      ? ensureString(body.kind, "kind")
      : String(attrs["card_kind"] ?? "note");
  const title =
    body.title !== undefined
      ? ensureString(body.title, "title")
      : String(attrs["title"] ?? "");
  const summary =
    body.summary !== undefined
      ? ensureString(body.summary, "summary")
      : String(attrs["summary"] ?? "");
  const blocks =
    body.blocks !== undefined
      ? normalizeBlocks(body.blocks)
      : (Array.isArray(attrs["blocks"]) ? (attrs["blocks"] as CardBlock[]) : []);
  const relatedTo =
    body.related_to !== undefined
      ? normalizeStringArray(body.related_to, "related_to")
      : (Array.isArray(attrs["related_to"]) ? (attrs["related_to"] as string[]) : []);
  // Preserved tags must strip the synthetic prefixes that the projector
  // adds (`sonata-studio`, `room:<slug>`); otherwise republishing would
  // leak those into the wire payload's user-facing tags list.
  const cardTags =
    body.tags !== undefined
      ? normalizeStringArray(body.tags, "tags")
      : stripSyntheticTags(
          Array.isArray(attrs["tags"]) ? (attrs["tags"] as string[]) : [],
          roomSlug,
        );

  const room = await loadRoomCtx(roomSlug, ctx.cfg.pluginPub);

  const payload: Record<string, unknown> = {
    "@context": STUDIO_CONTEXT_V0,
    "@type": "Card",
    kind: cardKind,
    track: trackSlug,
    title,
    summary,
    blocks,
    createdBy: pluginPubLower,
  };
  if (relatedTo.length > 0) payload["relatedTo"] = relatedTo;
  if (cardTags.length > 0) payload["tags"] = cardTags;
  validatePayload(STUDIO_KIND_CARD, payload);

  const rumor = buildSignedRumor({
    kind: STUDIO_KIND_CARD,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    publisherPub: ctx.cfg.pluginPub,
    dTag,
    alt: `Studio card: ${title}`,
  });
  const { rumorEventId } = await publishRumor({
    rumor,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    gateway: ctx.gateway,
  });

  return { rumor_event_id: rumorEventId, d_tag: dTag };
}

function stripSyntheticTags(tags: string[], roomSlug: string): string[] {
  const roomMarker = `room:${roomSlug}`;
  return tags.filter((t) => t !== "sonata-studio" && t !== roomMarker);
}

// ── exports ─────────────────────────────────────────────────────────────────

export const card = {
  post(body: unknown, ctx: ActionCtx): Promise<CardPostResult> {
    return postCard((body ?? {}) as CardPostRequest, ctx);
  },
  list(query: unknown, ctx: ActionCtx): Promise<CardListResult> {
    return listCards((query ?? {}) as CardListRequest, ctx);
  },
  delete(body: unknown, ctx: ActionCtx): Promise<CardDeleteResult> {
    return deleteCard((body ?? {}) as CardDeleteRequest, ctx);
  },
  update(body: unknown, ctx: ActionCtx): Promise<CardUpdateResult> {
    return updateCard((body ?? {}) as CardUpdateRequest, ctx);
  },
};
