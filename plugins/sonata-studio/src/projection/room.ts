// Project a Studio Room (kind 30536) → studio_room entity.
// Per plan §7.2.7: additive — local-only fields like aud_id_priv_hex,
// epoch_keys, current_epoch, members, last_seen_wrap_at_ms, state are
// NEVER overwritten by an event projection. Sensitive material flows
// through mem_secret_set (caller-side, not here) per Pass A finding A4.

import {
  appendAudit,
  buildEntityTags,
  parseExistingAttributes,
  shouldReplaceBody,
  upsertWithMerge,
} from "./util";
import type { ProjectionContext } from "./types";

const LOCAL_ONLY_KEYS = [
  "aud_id_priv_secret_name",
  "aud_id_pub_hex",
  "epoch_keys_secret_name",
  "current_epoch",
  "members",
  "last_seen_wrap_at_ms",
  "state",
  "epoch_keys",
  "last_seen_at_ms",
  "dispatch_trace_on",
];

export async function projectRoom(ctx: ProjectionContext): Promise<void> {
  const { rumor, payload } = ctx;
  const slug =
    typeof payload["slug"] === "string" ? (payload["slug"] as string) : ctx.roomSlug;
  const name = `studio:room:${slug}`;

  // LWW skip — but only against the room-projected fields. Local-only
  // fields are preserved regardless.
  const existingEntity = await ctx.client.entity.byNameOrNull(name);
  const existingAttrs = parseExistingAttributes(existingEntity?.attributes);
  if (!shouldReplaceBody(rumor.created_at, existingAttrs)) return;

  const description =
    typeof payload["description"] === "string"
      ? (payload["description"] as string)
      : `Studio room ${slug}`;

  const attributes: Record<string, unknown> = {
    _studio_kind: 30536,
    _studio_type: "Room",
    slug,
    title: typeof payload["title"] === "string" ? payload["title"] : slug,
    description: payload["description"] ?? null,
    project: payload["project"] ?? null,
    default_tracks: Array.isArray(payload["defaultTracks"])
      ? payload["defaultTracks"]
      : [],
    created_by_pubkey: ctx.createdByPubkey,
    created_at_seconds: rumor.created_at,
    d_tag: ctx.dTag,
    event_id: rumor.id,
    tags: buildEntityTags(ctx),
    _studio_event_audit: appendAudit(existingAttrs, ctx),
  };

  await upsertWithMerge(ctx.client, {
    name,
    type: "studio_room",
    description,
    attributes,
    preserveKeys: LOCAL_ONLY_KEYS,
  });
}
