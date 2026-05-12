// Room actions: create / join / invite / list. Per plan §5.1-5.4.

import { schnorr } from "@noble/curves/secp256k1.js";
import { bytesToHex, hexToBytes, randomBytes } from "@noble/hashes/utils.js";
import { bech32 } from "@scure/base";

import { GatewayError, type GatewayClient, type NostrEventLike } from "../a4-client";
import { MemoryClientError } from "../memory-client";
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
  STUDIO_KIND_TRACK,
  validatePayload,
  type StudioRoomCtx,
} from "./util";
import { track as trackActions } from "./track";

/**
 * Minimal SSEManager surface the action layer reaches into. Kept narrow so
 * tests can inject a noop without depending on the full SSEManager type.
 */
export interface SSEOpener {
  open(roomSlug: string): Promise<void>;
  close?(roomSlug: string): Promise<void>;
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
  /**
   * Optional profile preview embedded in the kind:30522 claim event's
   * `content` so the founder can recognize the joiner in the admit
   * dialog. Privacy: anyone with the invite URL can read this — joiner
   * is opting into exposing nickname + bio to invite-URL holders. This
   * is acceptable since they're choosing to join.
   */
  profile?: {
    nickname?: unknown;
    bio?: unknown;
  };
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
  const defaultTracks: Array<{ name: string; title: string }> = Array.isArray(
    body.default_tracks,
  )
    ? (body.default_tracks as unknown[]).map((v, i) => {
        if (typeof v === "string") {
          const n = ensureSlug(v, `default_tracks[${i}]`);
          return { name: n, title: n };
        }
        if (v && typeof v === "object") {
          const obj = v as { name?: unknown; title?: unknown };
          const n = ensureSlug(obj.name, `default_tracks[${i}].name`);
          const t =
            obj.title !== undefined
              ? ensureString(obj.title, `default_tracks[${i}].title`)
              : n;
          return { name: n, title: t };
        }
        throw new HttpError(
          400,
          "bad_request",
          `default_tracks[${i}] must be a slug string or {name, title} object`,
        );
      })
    : [];

  // Reject duplicate slugs cleanly. Without this, a second call with the
  // same slug would mint a fresh audience keypair and overwrite the entity
  // + epoch_keys secret — silently orphaning the original room on the
  // gateway and breaking any peer who had already joined.
  const existing = await entity.byNameOrNull(`studio:room:${slug}`);
  if (existing) {
    throw new HttpError(409, "room_exists", `studio_room "${slug}" already exists locally`);
  }

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
      default_tracks: defaultTracks.map((t) => t.name),
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
  if (defaultTracks.length > 0) roomPayload["defaultTracks"] = defaultTracks.map((t) => t.name);
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
  for (const t of defaultTracks) {
    try {
      await trackActions.create(
        { room: slug, name: t.name, title: t.title, layout: "column" },
        ctx,
      );
      createdTracks.push(t.name);
    } catch (err) {
      // Surface but keep the room — operator can re-run track create later.
      const msg = err instanceof Error ? err.message : String(err);
      // eslint-disable-next-line no-console
      console.error(`[room.create] default track "${t.name}" failed: ${msg}`);
    }
  }

  // Open the SSE stream for this newly-created room. Without this, the
  // founder never subscribes to the audience's gift-wrap firehose and
  // therefore never receives cards posted by other members. (T4b root
  // cause: B's cards published correctly + stored on the gateway, but A's
  // SSEManager only opened streams for rooms it had at boot — and the
  // join action at line ~500 calls sseManager.open while create did not.)
  // Idempotent; safe if SSEManager already had a client for this slug.
  try {
    await ctx.sseManager.open(slug);
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error(
      `[room.create] sseManager.open("${slug}") failed: ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
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

  // Sanitize the optional profile preview. Anyone with the invite URL can
  // read claim.content, so we cap lengths and reject non-strings — joiner
  // is opting in by attaching this, but we still protect against an
  // accidentally-huge bio.
  const claimProfile = sanitizeClaimProfileBody(body.profile);

  // Build claim signed by invite_priv with claim_pubkey = plugin_pub.
  const claimTemplate = buildAudienceClaim({
    audIdPub,
    slug: parsed.slug,
    epoch: parsed.epoch,
    invitePub: parsed.invitePub,
    inviterPub,
    claimPub: ctx.cfg.pluginPub,
    profile: claimProfile ?? undefined,
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

function sanitizeClaimProfileBody(
  raw: RoomJoinRequest["profile"],
): { nickname?: string; bio?: string } | null {
  if (!raw || typeof raw !== "object") return null;
  const out: { nickname?: string; bio?: string } = {};
  if (typeof raw.nickname === "string") {
    const t = raw.nickname.trim();
    if (t.length > 0) out.nickname = t.slice(0, 200);
  }
  if (typeof raw.bio === "string") {
    const t = raw.bio.trim();
    if (t.length > 0) out.bio = t.slice(0, 500);
  }
  return out.nickname || out.bio ? out : null;
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

// ── republish snapshot ──────────────────────────────────────────────────────

export interface RepublishSnapshotResult {
  room_published: boolean;
  tracks_published: number;
  tracks_failed: number;
}

/**
 * Re-emit the founder's view of a room's metadata + tracks at the current
 * epoch. Used after `admit` rotates: every admitted recipient now holds the
 * new epoch key, so a fresh wrap of the room+tracks lands as initial state
 * (history-replay gap §1 of studio-phase-4 federation smoke).
 *
 * Treats local entities as source of truth — does NOT mutate any entity;
 * `projectLocally` inside `publishRumor` performs an idempotent overwrite
 * (older `created_at` is LWW-ignored, local-only fields are preserved).
 *
 * Each publish is wrapped in try/catch so one failure does not abort the
 * rest. The room rumor is attempted first, then tracks in document order.
 * Members are intentionally not republished: `studio_member` is local-only
 * and has no federated kind in studio-v0 (nickname federation is open work
 * for v0.1+).
 */
export async function republishRoomSnapshot(
  slug: string,
  ctx: ActionCtx,
): Promise<RepublishSnapshotResult> {
  // Fresh load — admit just rotated, so epoch + members differ from the
  // pre-admit context the caller already had in hand.
  const room = await loadRoomCtx(slug, ctx.cfg.pluginPub);

  const result: RepublishSnapshotResult = {
    room_published: false,
    tracks_published: 0,
    tracks_failed: 0,
  };

  // 1. Room (kind 30536).
  try {
    await republishRoomRumor(slug, room, ctx);
    result.room_published = true;
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error(
      `[room.republishSnapshot] room rumor for "${slug}" failed: ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
  }

  // 2. Tracks (kind 30531) — serialized so gateway rate-limits + SSE ordering
  //    on the receiving member stay stable.
  const allTracks = await entity.list({ type: "studio_track", limit: 500 });
  for (const t of allTracks) {
    const attrs = parseAttrs(t.attributes);
    if (attrs["room_slug"] !== slug) continue;
    // Skip stubs auto-created by a Card referencing an unknown track —
    // re-emitting them would assert false metadata.
    if (attrs["auto_created"] === true) continue;
    const trackName = typeof attrs["name"] === "string" ? (attrs["name"] as string) : null;
    if (!trackName) continue;
    try {
      await republishTrackRumor(slug, room, attrs, trackName, ctx);
      result.tracks_published += 1;
    } catch (err) {
      result.tracks_failed += 1;
      // eslint-disable-next-line no-console
      console.error(
        `[room.republishSnapshot] track "${trackName}" rumor for "${slug}" failed: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
    }
  }

  return result;
}

async function republishRoomRumor(
  slug: string,
  room: StudioRoomCtx,
  ctx: ActionCtx,
): Promise<void> {
  const attrs = room.attributes;
  const title =
    typeof attrs["title"] === "string" && (attrs["title"] as string).length > 0
      ? (attrs["title"] as string)
      : slug;
  const payload: Record<string, unknown> = {
    "@context": STUDIO_CONTEXT_V0,
    "@type": "Room",
    slug,
    title,
    createdBy: ctx.cfg.pluginPub.toLowerCase(),
  };
  if (typeof attrs["description"] === "string" && (attrs["description"] as string).length > 0) {
    payload["description"] = attrs["description"];
  }
  if (typeof attrs["project"] === "string" && (attrs["project"] as string).length > 0) {
    payload["project"] = attrs["project"];
  }
  const dt = attrs["default_tracks"];
  if (Array.isArray(dt) && dt.length > 0) {
    const names = dt.filter((x): x is string => typeof x === "string" && x.length > 0);
    if (names.length > 0) payload["defaultTracks"] = names;
  }
  validatePayload(STUDIO_KIND_ROOM, payload);
  const rumor = buildSignedRumor({
    kind: STUDIO_KIND_ROOM,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    publisherPub: ctx.cfg.pluginPub,
    dTag: slug,
    alt: `Studio room: ${title}`,
  });
  await publishRumor({
    rumor,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    gateway: ctx.gateway,
  });
}

async function republishTrackRumor(
  _slug: string,
  room: StudioRoomCtx,
  attrs: Record<string, unknown>,
  trackName: string,
  ctx: ActionCtx,
): Promise<void> {
  const title =
    typeof attrs["title"] === "string" && (attrs["title"] as string).length > 0
      ? (attrs["title"] as string)
      : trackName;
  const layoutRaw = typeof attrs["layout"] === "string" ? (attrs["layout"] as string) : "column";
  const layout =
    layoutRaw === "column" || layoutRaw === "timeline" || layoutRaw === "grouped"
      ? layoutRaw
      : "column";
  const closedAt =
    typeof attrs["closed_at_seconds"] === "number" ? (attrs["closed_at_seconds"] as number) : null;
  const payload: Record<string, unknown> = {
    "@context": STUDIO_CONTEXT_V0,
    "@type": "Track",
    name: trackName,
    title,
    layout,
    closedAt,
    createdBy: ctx.cfg.pluginPub.toLowerCase(),
  };
  if (typeof attrs["description"] === "string" && (attrs["description"] as string).length > 0) {
    payload["description"] = attrs["description"];
  }
  validatePayload(STUDIO_KIND_TRACK, payload);
  const rumor = buildSignedRumor({
    kind: STUDIO_KIND_TRACK,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    publisherPub: ctx.cfg.pluginPub,
    dTag: trackName,
    alt: `Studio track: ${title}`,
  });
  await publishRumor({
    rumor,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    gateway: ctx.gateway,
  });
}

// ── delete (local-only) ─────────────────────────────────────────────────────

interface RoomDeleteRequest {
  slug?: unknown;
}

interface RoomDeleteResult {
  ok: true;
  slug: string;
  deleted: {
    entity_id: string;
    secrets: string[];
    sse_closed: boolean;
  };
}

/**
 * Local-only delete. Removes the studio_room entity + its aud_id_priv and
 * epoch_keys secrets, and closes the SSE subscription. Does NOT publish a
 * revocation event — other members of the audience keep their local copies
 * and the audience on the 4A gateway continues to exist until gateway-side
 * garbage collection. Federated revoke is v0.x+ work.
 */
export async function deleteRoom(
  body: RoomDeleteRequest,
  ctx: ActionCtx,
): Promise<RoomDeleteResult> {
  const slug = ensureSlug(body.slug, "slug");

  const row = await entity.byNameOrNull(`studio:room:${slug}`);
  if (!row) {
    throw new HttpError(404, "room_not_found", `studio_room "${slug}" not found`);
  }

  // TODO(v0.1): enforce founder check; for v0, local-delete is unconditional.

  const attrs = parseAttrs(row.attributes);
  const audIdSecretName =
    typeof attrs["aud_id_priv_secret_name"] === "string" && (attrs["aud_id_priv_secret_name"] as string).length > 0
      ? (attrs["aud_id_priv_secret_name"] as string)
      : `studio:room:${slug}:aud_id_priv`;
  const epochSecretName =
    typeof attrs["epoch_keys_secret_name"] === "string" && (attrs["epoch_keys_secret_name"] as string).length > 0
      ? (attrs["epoch_keys_secret_name"] as string)
      : `studio:room:${slug}:epoch_keys`;

  let sseClosed = false;
  if (ctx.sseManager && typeof ctx.sseManager.close === "function") {
    try {
      await ctx.sseManager.close(slug);
      sseClosed = true;
    } catch (err) {
      // eslint-disable-next-line no-console
      console.error(
        `[room.delete] sseManager.close("${slug}") failed: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
    }
  }

  const deletedSecrets: string[] = [];
  for (const name of [audIdSecretName, epochSecretName]) {
    try {
      await secret.delete(name);
      deletedSecrets.push(name);
    } catch (err) {
      if (err instanceof MemoryClientError && err.status === 404) {
        // already gone — treat as success-ish, don't push.
        continue;
      }
      // eslint-disable-next-line no-console
      console.error(
        `[room.delete] secret.delete("${name}") failed: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
    }
  }

  await entity.delete(row.id);

  return {
    ok: true,
    slug,
    deleted: {
      entity_id: row.id,
      secrets: deletedSecrets,
      sse_closed: sseClosed,
    },
  };
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
  delete(body: unknown, ctx: ActionCtx): Promise<RoomDeleteResult> {
    return deleteRoom((body ?? {}) as RoomDeleteRequest, ctx);
  },
};
