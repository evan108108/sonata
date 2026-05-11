// Comment action: post. Per plan §5.8.
//
// d_tag is `${target_id_hex}:${random_8_hex}` per §5.8 / SPEC.

import {
  HttpError,
  buildScopedDTag,
  buildSignedRumor,
  ensureSlug,
  ensureString,
  isHex64,
  loadRoomCtx,
  publishRumor,
  STUDIO_CONTEXT_V0,
  STUDIO_KIND_COMMENT,
  validatePayload,
} from "./util";
import type { ActionCtx } from "./room";

interface CommentPostRequest {
  room?: unknown;
  target?: unknown;
  body?: unknown;
  intent?: unknown;
}

interface CommentPostResult {
  rumor_event_id: string;
  d_tag: string;
}

export async function postComment(
  body: CommentPostRequest,
  ctx: ActionCtx,
): Promise<CommentPostResult> {
  const roomSlug = ensureSlug(body.room, "room");
  const target = ensureString(body.target, "target");
  const text = ensureString(body.body, "body");
  const intent = body.intent !== undefined ? ensureString(body.intent, "intent") : undefined;

  const room = await loadRoomCtx(roomSlug, ctx.cfg.pluginPub);

  const payload: Record<string, unknown> = {
    "@context": STUDIO_CONTEXT_V0,
    "@type": "Comment",
    target: { "@id": target },
    body: text,
    createdBy: ctx.cfg.pluginPub.toLowerCase(),
  };
  if (intent !== undefined) payload["intent"] = intent;
  validatePayload(STUDIO_KIND_COMMENT, payload);

  const dTagScope = isHex64(target) ? target.toLowerCase() : hashLikeScope(target);
  const dTag = buildScopedDTag(dTagScope);

  const rumor = buildSignedRumor({
    kind: STUDIO_KIND_COMMENT,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    publisherPub: ctx.cfg.pluginPub,
    dTag,
    alt: `Studio comment on ${target.slice(0, 32)}`,
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

/**
 * Targets that aren't 64-hex (4A addresses, nostr: URIs) become a single
 * scope segment with non-slug chars stripped. This keeps the d-tag valid
 * (replaceable-event d's are opaque, but downstream aggregators sometimes
 * filter on prefix).
 */
function hashLikeScope(s: string): string {
  return s.replace(/[^a-z0-9]/gi, "").slice(0, 32) || "target";
}

export const comment = {
  post(body: unknown, ctx: ActionCtx): Promise<CommentPostResult> {
    return postComment((body ?? {}) as CommentPostRequest, ctx);
  },
};
