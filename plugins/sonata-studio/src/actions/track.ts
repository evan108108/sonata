// Track action: create. Per plan §5.7.

import {
  HttpError,
  buildSignedRumor,
  ensureSlug,
  ensureString,
  loadRoomCtx,
  publishRumor,
  STUDIO_CONTEXT_V0,
  STUDIO_KIND_TRACK,
  validatePayload,
} from "./util";
import type { ActionCtx } from "./room";

interface TrackCreateRequest {
  room?: unknown;
  name?: unknown;
  title?: unknown;
  layout?: unknown;
  description?: unknown;
}

interface TrackCreateResult {
  rumor_event_id: string;
  d_tag: string;
}

const ALLOWED_LAYOUTS = ["column", "timeline", "grouped"] as const;

export async function createTrack(
  body: TrackCreateRequest,
  ctx: ActionCtx,
): Promise<TrackCreateResult> {
  const slug = ensureSlug(body.room, "room");
  const name = ensureSlug(body.name, "name");
  const title = ensureString(body.title, "title");
  const layoutInput = body.layout === undefined ? "column" : ensureString(body.layout, "layout");
  if (!(ALLOWED_LAYOUTS as readonly string[]).includes(layoutInput)) {
    throw new HttpError(400, "bad_request", `layout must be one of ${ALLOWED_LAYOUTS.join(", ")}`);
  }
  const description =
    body.description !== undefined
      ? ensureString(body.description, "description", { allowEmpty: true })
      : undefined;

  const room = await loadRoomCtx(slug, ctx.cfg.pluginPub);

  const payload: Record<string, unknown> = {
    "@context": STUDIO_CONTEXT_V0,
    "@type": "Track",
    name,
    title,
    layout: layoutInput,
    closedAt: null,
    createdBy: ctx.cfg.pluginPub.toLowerCase(),
  };
  if (description !== undefined) payload["description"] = description;
  validatePayload(STUDIO_KIND_TRACK, payload);

  // d-tag for a track is the track slug — replaceable by name within the room.
  const rumor = buildSignedRumor({
    kind: STUDIO_KIND_TRACK,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    publisherPub: ctx.cfg.pluginPub,
    dTag: name,
    alt: `Studio track: ${title}`,
  });
  const { rumorEventId } = await publishRumor({
    rumor,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    gateway: ctx.gateway,
  });

  return { rumor_event_id: rumorEventId, d_tag: name };
}

export const track = {
  create(body: unknown, ctx: ActionCtx): Promise<TrackCreateResult> {
    return createTrack((body ?? {}) as TrackCreateRequest, ctx);
  },
};
