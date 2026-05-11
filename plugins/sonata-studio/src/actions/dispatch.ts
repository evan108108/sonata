// Dispatch-intent action: post. Per plan §5.10.
//
// `d_tag` is the bus event_id (slugged if not 64-hex) per SPEC §5.1.

import {
  buildSignedRumor,
  ensureSlug,
  ensureString,
  HttpError,
  loadRoomCtx,
  publishRumor,
  slugify,
  STUDIO_CONTEXT_V0,
  STUDIO_KIND_DISPATCH_INTENT,
  validatePayload,
} from "./util";
import type { ActionCtx } from "./room";

interface DispatchIntentPostRequest {
  room?: unknown;
  event_id?: unknown;
  candidates?: unknown;
  chosen?: unknown;
  reason?: unknown;
  signals?: unknown;
  track?: unknown;
}

interface DispatchIntentPostResult {
  rumor_event_id: string;
  d_tag: string;
}

export async function postDispatchIntent(
  body: DispatchIntentPostRequest,
  ctx: ActionCtx,
): Promise<DispatchIntentPostResult> {
  const roomSlug = ensureSlug(body.room, "room");
  const eventId = ensureString(body.event_id, "event_id");
  const candidates = normalizeStringArray(body.candidates, "candidates");
  if (candidates.length === 0) {
    throw new HttpError(400, "bad_request", `"candidates" must have at least one entry`);
  }
  const chosen = ensureString(body.chosen, "chosen");
  if (!candidates.includes(chosen)) {
    throw new HttpError(400, "bad_request", `"chosen" must appear in "candidates"`);
  }
  const reason = ensureString(body.reason, "reason");
  const signals = body.signals === undefined ? undefined : normalizeSignals(body.signals);
  const trackSlug = body.track !== undefined ? ensureSlug(body.track, "track") : undefined;

  const room = await loadRoomCtx(roomSlug, ctx.cfg.pluginPub);

  const payload: Record<string, unknown> = {
    "@context": STUDIO_CONTEXT_V0,
    "@type": "DispatchIntent",
    eventId,
    candidates,
    chosen,
    reason,
    createdBy: ctx.cfg.pluginPub.toLowerCase(),
    createdAt: Date.now(),
  };
  if (signals !== undefined) payload["signals"] = signals;
  if (trackSlug !== undefined) payload["track"] = trackSlug;
  validatePayload(STUDIO_KIND_DISPATCH_INTENT, payload);

  // d-tag: bus event id verbatim if 64-hex (it's already slug-safe and
  // identifies the dispatch decision uniquely); otherwise sluggify.
  const dTag = /^[0-9a-f]{64}$/i.test(eventId) ? eventId.toLowerCase() : slugify(eventId);
  if (dTag.length === 0) {
    throw new HttpError(400, "bad_request", `"event_id" must contain at least one slug-safe character`);
  }

  const rumor = buildSignedRumor({
    kind: STUDIO_KIND_DISPATCH_INTENT,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    publisherPub: ctx.cfg.pluginPub,
    dTag,
    alt: `Dispatch intent for bus event ${eventId.slice(0, 16)}…`,
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

function normalizeSignals(raw: unknown): Record<string, string | number | boolean> {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new HttpError(400, "bad_request", `"signals" must be an object`);
  }
  const out: Record<string, string | number | boolean> = {};
  for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
    if (typeof v !== "string" && typeof v !== "number" && typeof v !== "boolean") {
      throw new HttpError(400, "bad_request", `"signals.${k}" must be string|number|boolean`);
    }
    out[k] = v;
  }
  return out;
}

export const dispatch = {
  post(body: unknown, ctx: ActionCtx): Promise<DispatchIntentPostResult> {
    return postDispatchIntent((body ?? {}) as DispatchIntentPostRequest, ctx);
  },
};
