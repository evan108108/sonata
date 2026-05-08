// Room actions: create / join / invite / list. Per plan §5.1-5.4.

import { schnorr } from "@noble/curves/secp256k1.js";
import { bytesToHex, hexToBytes, randomBytes } from "@noble/hashes/utils.js";
import { bech32 } from "@scure/base";

import { GatewayError, type GatewayClient, type NostrEventLike } from "../a4-client";
import {
  buildAudienceClaim,
  buildAudienceDeclaration,
  buildKeyGrant,
  audienceAddress,
} from "../audience-events";
import { encrypt as nip44Encrypt } from "../crypto/nip44";
import { __signEvent, type NostrEvent } from "../crypto/nip17";
import { entity, secret } from "../memory-client";
import type { PluginConfig } from "../config";

import {
  HttpError,
  buildSignedRumor,
  ensureSlug,
  ensureString,
  isHex64,
  loadRoomCtx,
  publishRumor,
  STUDIO_CONTEXT_V0,
  STUDIO_KIND_ROOM,
  validatePayload,
} from "./util";
import { track as trackActions } from "./track";

/**
 * Minimal SSEManager surface the action layer reaches into. Kept narrow so
 * tests can inject a noop without depending on the full SSEManager type.
 */
export interface SSEOpener {
  open(roomSlug: string): Promise<void>;
}

export interface ActionCtx {
  cfg: PluginConfig;
  gateway: GatewayClient;
  /**
   * Optional in tests — when present, `joinRoom` opens the SSE stream for
   * the new room before returning so the gateway's key-grant for this
   * recipient cannot land in the gap between `rawClaim` returning and the
   * stream being opened. Plan §7 Pass D1.
   */
  sseManager?: SSEOpener;
}

interface RoomCreateRequest {
  slug?: unknown;
  title?: unknown;
  description?: unknown;
  project?: unknown;
  default_tracks?: unknown;
}

interface RoomCreateResult {
  audience_address: string;
  room_event_id: string;
  declaration_event_id: string;
  founding_grant_event_id: string;
  members: string[];
  epoch: number;
  default_tracks: string[];
}

interface RoomJoinRequest {
  invite_url?: unknown;
}

interface RoomJoinResult {
  audience_address: string;
  room_slug: string;
  epoch: number;
  claim_event_id: string;
  state: "active" | "pending-grant";
}

interface RoomInviteRequest {
  room_slug?: unknown;
  ttl_seconds?: unknown;
}

interface RoomInviteResult {
  four_a_url: string;
  https_url: string;
  invite_pub: string;
  expires_at: number;
}

interface RoomListEntry {
  audience_address: string;
  slug: string;
  title: string;
  epoch: number;
  members: string[];
  pending_invites: number;
  last_card_at?: number | undefined;
  state: string;
}

interface RoomListResult {
  rooms: RoomListEntry[];
}

// ── create ──────────────────────────────────────────────────────────────────

export async function createRoom(
  body: RoomCreateRequest,
  ctx: ActionCtx,
): Promise<RoomCreateResult> {
  const slug = ensureSlug(body.slug, "slug");
  const title = ensureString(body.title, "title");
  const description = body.description !== undefined ? ensureString(body.description, "description", { allowEmpty: true }) : undefined;
  const project = body.project !== undefined ? ensureSlug(body.project, "project") : undefined;
  const defaultTracks = Array.isArray(body.default_tracks)
    ? (body.default_tracks as unknown[]).map((v, i) => ensureSlug(v, `default_tracks[${i}]`))
    : [];

  // 1. Keypairs.
  const audIdPriv = randomBytes(32);
  const audIdPub = bytesToHex(schnorr.getPublicKey(audIdPriv));
  const epoch1Priv = randomBytes(32);
  const epoch1Pub = bytesToHex(schnorr.getPublicKey(epoch1Priv));

  // 2. Declaration.
  const declTemplate = buildAudienceDeclaration({
    audIdPub,
    slug,
    name: title,
    description,
    epoch: 1,
    epochPub: epoch1Pub,
    members: [ctx.cfg.pluginPub],
  });
  const declUnsigned = {
    pubkey: audIdPub,
    kind: declTemplate.kind,
    created_at: declTemplate.created_at,
    tags: declTemplate.tags,
    content: declTemplate.content,
  };
  const declSigned = __signEvent(declUnsigned, audIdPriv);

  // 3. Founding grant — NIP-44 of bare epoch_1 priv from aud_id_priv → plugin_pub.
  const grantCiphertext = nip44Encrypt(epoch1Priv, audIdPriv, ctx.cfg.pluginPub);
  const grantTemplate = buildKeyGrant({
    audIdPub,
    slug,
    epoch: 1,
    recipientPub: ctx.cfg.pluginPub,
    ciphertext: grantCiphertext,
  });
  const grantUnsigned = {
    pubkey: audIdPub,
    kind: grantTemplate.kind,
    created_at: grantTemplate.created_at,
    tags: grantTemplate.tags,
    content: grantTemplate.content,
  };
  const grantSigned = __signEvent(grantUnsigned, audIdPriv);

  // 4. POST raw/create.
  const createRes = await ctx.gateway.rawCreate({
    declaration: toEventLike(declSigned),
    founding_grant: toEventLike(grantSigned),
  });

  // 5/6. Persist secrets BEFORE publishing the room rumor — we want the
  // entity to be fully usable on the local-projection step.
  const audIdSecretName = `studio:room:${slug}:aud_id_priv`;
  const epochSecretName = `studio:room:${slug}:epoch_keys`;
  await secret.set({
    name: audIdSecretName,
    value: bytesToHex(audIdPriv),
    description: `aud_id priv for studio room "${slug}"`,
  });
  await secret.set({
    name: epochSecretName,
    value: JSON.stringify({
      epochs: {
        "1": {
          epoch: 1,
          priv_hex: bytesToHex(epoch1Priv),
          pub_hex: epoch1Pub,
        },
      },
    }),
    description: `epoch keys for studio room "${slug}"`,
  });

  // We need a partial studio_room entity in place BEFORE the rumor's local
  // projection runs (so loadRoomCtx-style reads succeed). Stamp local-only
  // fields directly; the rumor projection will fill in body fields next.
  await entity.upsert({
    name: `studio:room:${slug}`,
    type: "studio_room",
    description: `Studio room ${slug}`,
    attributes: {
      _studio_kind: STUDIO_KIND_ROOM,
      _studio_type: "Room",
      slug,
      title,
      description: description ?? null,
      project: project ?? null,
      default_tracks: defaultTracks,
      // local-only — preserved by future projections.
      aud_id_pub_hex: audIdPub,
      aud_id_priv_secret_name: audIdSecretName,
      epoch_keys_secret_name: epochSecretName,
      current_epoch: 1,
      members: [ctx.cfg.pluginPub.toLowerCase()],
      state: "active",
      last_seen_wrap_at_ms: null,
      tags: ["sonata-studio", `room:${slug}`],
    },
  });

  // 5/6 (cont). Build + publish the room rumor.
  const roomCtx = await loadRoomCtx(slug, ctx.cfg.pluginPub);
  const roomPayload: Record<string, unknown> = {
    "@context": STUDIO_CONTEXT_V0,
    "@type": "Room",
    slug,
    title,
    createdBy: ctx.cfg.pluginPub.toLowerCase(),
  };
  if (description !== undefined) roomPayload["description"] = description;
  if (project !== undefined) roomPayload["project"] = project;
  if (defaultTracks.length > 0) roomPayload["defaultTracks"] = defaultTracks;
  validatePayload(STUDIO_KIND_ROOM, roomPayload);

  const rumor = buildSignedRumor({
    kind: STUDIO_KIND_ROOM,
    payload: roomPayload,
    room: roomCtx,
    publisherPriv: ctx.cfg.pluginPriv,
    publisherPub: ctx.cfg.pluginPub,
    dTag: slug,
    alt: `Studio room: ${title}`,
  });
  const { rumorEventId } = await publishRumor({
    rumor,
    payload: roomPayload,
    room: roomCtx,
    publisherPriv: ctx.cfg.pluginPriv,
    gateway: ctx.gateway,
  });

  // 8. Default tracks — sequential so a 5xx on track #2 doesn't spawn a
  // partial room. trackActions.create is idempotent on the d-tag (replaceable).
  const createdTracks: string[] = [];
  for (const tName of defaultTracks) {
    try {
      await trackActions.create(
        { room: slug, name: tName, title: tName, layout: "column" },
        ctx,
      );
      createdTracks.push(tName);
    } catch (err) {
      // Surface but keep the room — operator can re-run track create later.
      const msg = err instanceof Error ? err.message : String(err);
      // eslint-disable-next-line no-console
      console.error(`[room.create] default track "${tName}" failed: ${msg}`);
    }
  }

  return {
    audience_address: audienceAddress(audIdPub, slug),
    room_event_id: rumorEventId,
    declaration_event_id: createRes.declaration_event_id,
    founding_grant_event_id: createRes.founding_grant_event_id,
    members: [ctx.cfg.pluginPub.toLowerCase()],
    epoch: 1,
    default_tracks: createdTracks,
  };
}

// ── join ────────────────────────────────────────────────────────────────────

const FOUR_A_PREFIX = "4a://invite/";
const HTTPS_PREFIX_RE = /^https?:\/\/[^/]+\/invite\//;
const INVITE_HRP = "4ainv";
// SPEC-v0.5 §6.2 invite keys: HRP=4ainv, 32-byte payload, encodes to ~64 chars
// (well under bech32's documented 90-char cap, but lift it for safety).
const BECH32_LIMIT = 256;

interface ParsedInvite {
  slug: string;
  epoch: number;
  /**
   * Hex form of the invite pubkey. Derived from the priv when the gateway-
   * emitted URL omits it from the path; carried directly on the legacy form.
   */
  invitePub: string;
  invitePrivBech: string;
  /** Decoded 32-byte priv. */
  invitePrivBytes: Uint8Array;
}

/**
 * Parse an invite URL into its slug/epoch + invite keypair components.
 * Accepts three shapes:
 *   1. Gateway-emitted current form, where the invite pubkey is *not* in the
 *      path and must be derived from the priv:
 *        4a://invite/<slug>/<epoch>?k=<bech32_priv>
 *        https://<host>/invite/<slug>/<epoch>?k=<bech32_priv>
 *   2. Legacy form retained for back-compat with anything Phase 2 issued:
 *        4a://invite/<slug>/<epoch>/<invite_pub_hex>?priv=<bech32_priv>
 *        https://<host>/invite/<slug>/<epoch>/<invite_pub_hex>?priv=<bech32_priv>
 *
 * Either way the priv is decoded as bech32(`4ainv`) — the gateway hands the
 * caller a `4ainv1…` string from `encodeInviteKey` (gateway/lib/invite-key.ts).
 * Bare 64-hex priv is accepted in the legacy form too (early Phase-2 callers
 * sometimes passed hex), but the new form requires bech32 because that's
 * what the gateway's `audience-raw.ts` `runInvite` returns.
 */
export function parseInviteUrl(url: string): ParsedInvite {
  let stripped = url.trim();
  if (stripped.startsWith(FOUR_A_PREFIX)) {
    stripped = stripped.slice(FOUR_A_PREFIX.length);
  } else if (HTTPS_PREFIX_RE.test(stripped)) {
    stripped = stripped.replace(HTTPS_PREFIX_RE, "");
  } else {
    throw new HttpError(400, "bad_request", `invite_url must start with 4a:// or https://...`);
  }
  const [path, query] = stripped.split("?");
  const parts = (path ?? "").split("/").filter((p) => p.length > 0);
  if (parts.length < 2) {
    throw new HttpError(400, "bad_request", `invite_url path must be slug/epoch[/invite_pub]`);
  }
  const slugRaw = parts[0];
  const epochRaw = parts[1];
  const invitePubRaw = parts[2];
  if (!slugRaw || !/^[A-Za-z0-9-]+$/.test(slugRaw)) {
    throw new HttpError(400, "bad_request", `invite_url slug invalid`);
  }
  const epoch = Number(epochRaw);
  if (!Number.isInteger(epoch) || epoch < 1) {
    throw new HttpError(400, "bad_request", `invite_url epoch invalid`);
  }
  const params = new URLSearchParams(query ?? "");
  const kParam = params.get("k");
  const privParam = params.get("priv");
  const privRaw = kParam ?? privParam;
  if (!privRaw) {
    throw new HttpError(
      400,
      "bad_request",
      `invite_url missing ?k= (or legacy ?priv=) bech32 token`,
    );
  }
  const invitePrivBytes = decodeInvitePriv(privRaw);
  // Legacy form supplies invite_pub on the path; new form requires us to
  // derive it from the priv. Either way we keep both hex and bytes around.
  let invitePub: string;
  if (invitePubRaw !== undefined) {
    if (!isHex64(invitePubRaw)) {
      throw new HttpError(400, "bad_request", `invite_url invite_pub must be 64-hex`);
    }
    invitePub = invitePubRaw.toLowerCase();
    const derived = bytesToHex(schnorr.getPublicKey(invitePrivBytes));
    if (derived !== invitePub) {
      throw new HttpError(
        400,
        "bad_request",
        `invite_url invite_pub does not match the priv`,
      );
    }
  } else {
    invitePub = bytesToHex(schnorr.getPublicKey(invitePrivBytes));
  }
  return {
    slug: slugRaw,
    epoch,
    invitePub,
    invitePrivBech: privRaw,
    invitePrivBytes,
  };
}

/**
 * Decode a `4ainv1…` bech32 invite key into its 32-byte payload. Mirrors
 * gateway/src/lib/invite-key.ts so a priv minted by `audience-raw.ts`'s
 * `runInvite` round-trips here without surprise.
 *
 * Bare 64-hex is accepted as a back-compat fallback for the very early
 * Phase-2 invite callers that handed hex through unchanged.
 */
function decodeInvitePriv(s: string): Uint8Array {
  if (isHex64(s)) return hexToBytes(s);
  let decoded: { prefix: string; words: number[] };
  try {
    decoded = bech32.decode(s as `${string}1${string}`, BECH32_LIMIT);
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    throw new HttpError(400, "bad_request", `invite_priv bech32 decode failed: ${reason}`);
  }
  if (decoded.prefix !== INVITE_HRP) {
    throw new HttpError(
      400,
      "bad_request",
      `invite_priv has wrong HRP "${decoded.prefix}", expected "${INVITE_HRP}"`,
    );
  }
  let bytes: Uint8Array;
  try {
    bytes = bech32.fromWords(decoded.words);
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    throw new HttpError(400, "bad_request", `invite_priv bech32 payload invalid: ${reason}`);
  }
  if (bytes.length !== 32) {
    throw new HttpError(
      400,
      "bad_request",
      `invite_priv must be 32 bytes, got ${bytes.length}`,
    );
  }
  return new Uint8Array(bytes);
}

export async function joinRoom(
  body: RoomJoinRequest,
  ctx: ActionCtx,
): Promise<RoomJoinResult> {
  const inviteUrl = ensureString(body.invite_url, "invite_url");
  const parsed = parseInviteUrl(inviteUrl);
  const invitePrivBytes = parsed.invitePrivBytes;

  // Look up declaration via the gateway's by-invite-pub read endpoint. The
  // gateway-emitted URL form omits `aud_id_pub`, so we resolve it (and the
  // cached declaration) from the invite_pub we just derived.
  const declRes = await fetchDeclarationByInvite(ctx, parsed);
  const declTags = declRes.declaration.tags;
  const audIdPub = declRes.declaration.pubkey.toLowerCase();
  const inviterPub = pickFirstP(declTags) ?? ctx.cfg.pluginPub;

  // Build claim signed by invite_priv with claim_pubkey = plugin_pub.
  const claimTemplate = buildAudienceClaim({
    audIdPub,
    slug: parsed.slug,
    epoch: parsed.epoch,
    invitePub: parsed.invitePub,
    inviterPub,
    claimPub: ctx.cfg.pluginPub,
  });
  const invitePub = bytesToHex(schnorr.getPublicKey(invitePrivBytes));
  const claimUnsigned = {
    pubkey: invitePub,
    kind: claimTemplate.kind,
    created_at: claimTemplate.created_at,
    tags: claimTemplate.tags,
    content: claimTemplate.content,
  };
  const claimSigned = __signEvent(claimUnsigned, invitePrivBytes);

  const audAddr = audienceAddress(audIdPub, parsed.slug);
  const claimRes = await ctx.gateway.rawClaim({
    audience_address: audAddr,
    claim: toEventLike(claimSigned),
  });

  // Stamp a `pending-grant` studio_room — SSE manager (T6) will flip it to
  // active once the founder rotates and the new key-grant arrives.
  const epochSecretName = `studio:room:${parsed.slug}:epoch_keys`;
  await entity.upsert({
    name: `studio:room:${parsed.slug}`,
    type: "studio_room",
    description: `Studio room ${parsed.slug} (joining)`,
    attributes: {
      _studio_kind: STUDIO_KIND_ROOM,
      _studio_type: "Room",
      slug: parsed.slug,
      title: parsed.slug,
      description: null,
      project: null,
      default_tracks: [],
      aud_id_pub_hex: audIdPub,
      aud_id_priv_secret_name: null,
      epoch_keys_secret_name: epochSecretName,
      current_epoch: parsed.epoch,
      members: declTagsToMembers(declTags),
      state: "pending-grant",
      last_seen_wrap_at_ms: null,
      joined_at_ms: Date.now(),
      tags: ["sonata-studio", `room:${parsed.slug}`],
    },
  });

  // Open the SSE stream BEFORE returning so the founder's rotate-and-grant
  // can't slip into a window where the room exists locally but no SSE
  // client is listening for the key-grant. Plan §7 Pass D1+D3.
  if (ctx.sseManager) {
    try {
      await ctx.sseManager.open(parsed.slug);
    } catch (err) {
      // Don't fail the join just because SSE failed to open — the run loop
      // self-recovers on reconnect. Log only.
      // eslint-disable-next-line no-console
      console.warn(
        `[room.join] sseManager.open("${parsed.slug}") failed: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
    }
  }

  return {
    audience_address: audAddr,
    room_slug: parsed.slug,
    epoch: parsed.epoch,
    claim_event_id: claimRes.claim_event_id,
    state: "pending-grant",
  };
}

function pickFirstP(tags: string[][]): string | null {
  for (const t of tags) if (t[0] === "p" && typeof t[1] === "string") return t[1].toLowerCase();
  return null;
}

function declTagsToMembers(tags: string[][]): string[] {
  const out: string[] = [];
  for (const t of tags) if (t[0] === "p" && typeof t[1] === "string") out.push(t[1].toLowerCase());
  return out;
}

async function fetchDeclarationByInvite(
  ctx: ActionCtx,
  parsed: ParsedInvite,
): Promise<{ declaration: NostrEvent }> {
  // The new gateway-emitted invite URL omits `aud_id_pub`, so we resolve the
  // declaration via `GET /v0/audience/by-invite-pub/<invite_pub>` which the
  // gateway backs with a reverse index over every cached fa:pending entry.
  // 404 (never seen) and 410 (claimed/rotated out) both surface to the user
  // as a single 410 `invite_not_found` per Phase 3 §3.
  try {
    const res = await ctx.gateway.getDeclarationByInvitePub({ invite_pub: parsed.invitePub });
    const decl = res.declaration as unknown as NostrEvent;
    if (!decl || typeof decl.pubkey !== "string") {
      throw new HttpError(502, "gateway_unavailable", `declaration response missing pubkey`);
    }
    return { declaration: decl };
  } catch (err) {
    if (err instanceof GatewayError) {
      if (err.status === 404 || err.status === 410) {
        throw new HttpError(410, "invite_not_found", "invite not found or expired");
      }
      throw new HttpError(502, "gateway_unavailable", `declaration read failed: ${err.message}`);
    }
    if (err instanceof HttpError) throw err;
    const msg = err instanceof Error ? err.message : String(err);
    throw new HttpError(502, "gateway_unavailable", `declaration read failed: ${msg}`);
  }
}

// ── invite ──────────────────────────────────────────────────────────────────

export async function inviteToRoom(
  body: RoomInviteRequest,
  ctx: ActionCtx,
): Promise<RoomInviteResult> {
  const slug = ensureSlug(body.room_slug, "room_slug");
  const ttlSeconds = body.ttl_seconds === undefined ? 7 * 24 * 60 * 60 : Number(body.ttl_seconds);
  if (!Number.isInteger(ttlSeconds) || ttlSeconds < 60) {
    throw new HttpError(400, "bad_request", `ttl_seconds must be an integer >= 60`);
  }

  const room = await loadRoomCtx(slug, ctx.cfg.pluginPub);
  if (!room.audIdPrivHex) {
    throw new HttpError(403, "not_founder", `only founder can mint invites for "${slug}"`);
  }

  // Generate an invite keypair and pass it to the gateway, which mints the
  // rotated declaration on our behalf and returns the URLs.
  const invitePriv = randomBytes(32);
  const invitePub = bytesToHex(schnorr.getPublicKey(invitePriv));

  // Build a rotated declaration adding the pending invite. Sign with aud_id_priv.
  const audIdPriv = hexToBytes(room.audIdPrivHex);
  const expiration = Math.floor(Date.now() / 1000) + ttlSeconds;
  const newPending = [
    ...currentPendingInvites(room.attributes),
    { invitePub, expirationUnix: expiration },
  ];
  const declTemplate = buildAudienceDeclaration({
    audIdPub: room.audIdPubHex,
    slug,
    name: pickTitle(room.attributes),
    description: pickDescription(room.attributes),
    epoch: room.currentEpoch,
    epochPub: room.currentEpochPubHex,
    members: room.members,
    pending: newPending,
  });
  const declUnsigned = {
    pubkey: room.audIdPubHex,
    kind: declTemplate.kind,
    created_at: declTemplate.created_at,
    tags: declTemplate.tags,
    content: declTemplate.content,
  };
  const declSigned = __signEvent(declUnsigned, audIdPriv);

  const res = await ctx.gateway.rawInvite({
    audience_address: room.audienceAddress,
    declaration: toEventLike(declSigned),
    invite_pub: invitePub,
    invite_priv_4ainv: bytesToHex(invitePriv),
  });

  return {
    four_a_url: res.four_a_url,
    https_url: res.https_url,
    invite_pub: invitePub,
    expires_at: res.expires_at,
  };
}

function currentPendingInvites(
  attrs: Record<string, unknown>,
): { invitePub: string; expirationUnix: number }[] {
  const raw = attrs["pending_invites"];
  if (!Array.isArray(raw)) return [];
  const out: { invitePub: string; expirationUnix: number }[] = [];
  for (const e of raw) {
    if (!e || typeof e !== "object") continue;
    const o = e as Record<string, unknown>;
    if (typeof o["invitePub"] === "string" && typeof o["expirationUnix"] === "number") {
      out.push({ invitePub: o["invitePub"], expirationUnix: o["expirationUnix"] });
    }
  }
  return out;
}

function pickTitle(attrs: Record<string, unknown>): string {
  const t = attrs["title"];
  return typeof t === "string" && t.length > 0 ? t : String(attrs["slug"] ?? "untitled");
}

function pickDescription(attrs: Record<string, unknown>): string | undefined {
  const d = attrs["description"];
  return typeof d === "string" && d.length > 0 ? d : undefined;
}

// ── list ────────────────────────────────────────────────────────────────────

export async function listRooms(_ctx: ActionCtx): Promise<RoomListResult> {
  const rows = await entity.list({ type: "studio_room", limit: 200 });
  const out: RoomListEntry[] = [];
  for (const r of rows) {
    const attrs = parseAttrs(r.attributes);
    const slug = String(attrs["slug"] ?? r.name.replace(/^studio:room:/, ""));
    const audIdPub = String(attrs["aud_id_pub_hex"] ?? "");
    if (!isHex64(audIdPub)) continue;
    out.push({
      audience_address: audienceAddress(audIdPub, slug),
      slug,
      title: typeof attrs["title"] === "string" ? (attrs["title"] as string) : slug,
      epoch: Number(attrs["current_epoch"] ?? 1),
      members: Array.isArray(attrs["members"]) ? (attrs["members"] as string[]) : [],
      pending_invites: Array.isArray(attrs["pending_invites"])
        ? (attrs["pending_invites"] as unknown[]).length
        : 0,
      last_card_at:
        typeof attrs["last_card_at_ms"] === "number"
          ? (attrs["last_card_at_ms"] as number)
          : undefined,
      state: typeof attrs["state"] === "string" ? (attrs["state"] as string) : "active",
    });
  }
  return { rooms: out };
}

// ── helpers ─────────────────────────────────────────────────────────────────

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

function toEventLike(e: NostrEvent): NostrEventLike {
  return {
    id: e.id,
    pubkey: e.pubkey,
    created_at: e.created_at,
    kind: e.kind,
    tags: e.tags,
    content: e.content,
    sig: e.sig,
  };
}

// ── exports ─────────────────────────────────────────────────────────────────

export const room = {
  create(body: unknown, ctx: ActionCtx): Promise<RoomCreateResult> {
    return createRoom((body ?? {}) as RoomCreateRequest, ctx);
  },
  join(body: unknown, ctx: ActionCtx): Promise<RoomJoinResult> {
    return joinRoom((body ?? {}) as RoomJoinRequest, ctx);
  },
  invite(body: unknown, ctx: ActionCtx): Promise<RoomInviteResult> {
    return inviteToRoom((body ?? {}) as RoomInviteRequest, ctx);
  },
  list(ctx: ActionCtx): Promise<RoomListResult> {
    return listRooms(ctx);
  },
};
