// Shared helpers for action handlers.
//
// Centralizes:
//   - The rumor builder (kind:30530-30536) — encrypt → tag → sign.
//   - The publish pipeline — gift-wrap per current member → POST raw/publish-wraps.
//   - Studio room lookup — pulls aud_id_pub, members, current epoch keys, etc.
//     out of the studio_room entity + secrets.
//   - Local-projection trampoline so `*_post` handlers see their own writes
//     immediately (per §5.5 step 9).
//   - The HttpError helper class so handlers can throw a typed status+code.

import { schnorr } from "@noble/curves/secp256k1.js";
import { bytesToHex, hexToBytes, randomBytes } from "@noble/hashes/utils.js";

import type { GatewayClient, NostrEventLike } from "../a4-client";
import * as memoryClient from "../memory-client";
import { entity, secret } from "../memory-client";
import {
  __getEventHash,
  __signEvent,
  type NostrEvent,
  wrap,
} from "../crypto/nip17";
import { encryptString } from "../crypto/nip44";
import { blake3ContentTag } from "../crypto/blake3-tag";
import { projectToMemory } from "../projection";
import type {
  MemoryClient as ProjectionMemoryClient,
  StudioRumor,
} from "../projection/types";
import {
  STUDIO_CONTEXT_V0,
  validateStudioWireEvent,
  payloadValidatorFor,
  STUDIO_KIND_ROOM,
} from "../validators";

// ── Spec constants ──────────────────────────────────────────────────────────

export const FA_CONTEXT_V0 = "https://4a4.ai/ns/v0";
export { STUDIO_CONTEXT_V0 };

const HEX64 = /^[0-9a-f]{64}$/i;
const SLUG = /^[A-Za-z0-9-]+$/;

// ── Errors ──────────────────────────────────────────────────────────────────

/**
 * Action-handler error with attached HTTP status + machine code per §5.12.
 * Caller serializes via `errorPayload` below.
 */
export class HttpError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "HttpError";
  }
}

export function errorPayload(err: HttpError): {
  ok: false;
  error: string;
  message: string;
  status: number;
} {
  return { ok: false, error: err.code, message: err.message, status: err.status };
}

// ── Studio room lookup ──────────────────────────────────────────────────────

export interface EpochKeyRecord {
  epoch: number;
  priv_hex: string;
  pub_hex: string;
}

export interface StudioRoomCtx {
  /** Memory entity row id for the studio_room. */
  entityId: string;
  /** Slug from the entity name (= the audience slug). */
  slug: string;
  /** 4A audience address: 30520:<aud_id_pub>:<slug>. */
  audienceAddress: string;
  /** Current declaration epoch (matches `current_epoch` in the entity body). */
  currentEpoch: number;
  /** Member set (lowercase 32-byte hex). */
  members: string[];
  /** Founder's aud_id keypair if we hold it locally; null for joined-only rooms. */
  audIdPrivHex: string | null;
  audIdPubHex: string;
  /** Current epoch's pubkey — used as the NIP-44 recipient for the rumor's content. */
  currentEpochPubHex: string;
  /** Current epoch's privkey — used during decrypt; we hold it as a member. */
  currentEpochPrivHex: string;
  /** State per §5.4 ("active" | "pending-grant" | "left"). */
  state: string;
  /** Raw entity body so callers can read auxiliary fields (project, title, etc.). */
  attributes: Record<string, unknown>;
}

function parseAttrs(raw: string | null | undefined): Record<string, unknown> {
  if (!raw) return {};
  try {
    const v = JSON.parse(raw);
    if (v && typeof v === "object" && !Array.isArray(v)) return v as Record<string, unknown>;
  } catch {
    // fall through
  }
  return {};
}

/**
 * Load a studio_room context by slug — validates the plugin is a current
 * member, pulls aud_id from the entity body + secrets store, and resolves
 * the current epoch keypair.
 *
 * Throws HttpError(404 room_not_found) if the slug doesn't resolve.
 * Throws HttpError(403 not_a_member) if the plugin pubkey isn't in members.
 */
export async function loadRoomCtx(
  slug: string,
  pluginPub: string,
): Promise<StudioRoomCtx> {
  if (!SLUG.test(slug)) {
    throw new HttpError(400, "bad_request", `room slug "${slug}" must match [A-Za-z0-9-]+`);
  }
  const ent = await entity.byName(`studio:room:${slug}`);
  if (!ent) {
    throw new HttpError(404, "room_not_found", `no local studio_room for slug "${slug}"`);
  }
  const attrs = parseAttrs(ent.attributes);
  const audIdPubHex = String(attrs["aud_id_pub_hex"] ?? "").toLowerCase();
  if (!HEX64.test(audIdPubHex)) {
    throw new HttpError(500, "internal_error", `studio_room ${slug} missing aud_id_pub_hex`);
  }
  const currentEpoch = Number(attrs["current_epoch"] ?? 0);
  if (!Number.isInteger(currentEpoch) || currentEpoch < 1) {
    throw new HttpError(500, "internal_error", `studio_room ${slug} has invalid current_epoch`);
  }
  const members = Array.isArray(attrs["members"])
    ? (attrs["members"] as unknown[]).filter((m): m is string => typeof m === "string").map((m) => m.toLowerCase())
    : [];
  const lowerPlug = pluginPub.toLowerCase();
  if (!members.includes(lowerPlug)) {
    throw new HttpError(403, "not_a_member", `plugin pubkey is not a member of room "${slug}"`);
  }

  // Founder's aud_id_priv may or may not be present locally.
  let audIdPrivHex: string | null = null;
  const audIdPrivSecretName =
    typeof attrs["aud_id_priv_secret_name"] === "string"
      ? (attrs["aud_id_priv_secret_name"] as string)
      : null;
  if (audIdPrivSecretName) {
    try {
      const got = await secret.get(audIdPrivSecretName);
      audIdPrivHex = got?.value?.toLowerCase() ?? null;
    } catch {
      audIdPrivHex = null;
    }
  }

  // Current epoch keypair — secret stores a JSON record keyed by epoch.
  const epochSecretName =
    typeof attrs["epoch_keys_secret_name"] === "string"
      ? (attrs["epoch_keys_secret_name"] as string)
      : null;
  if (!epochSecretName) {
    throw new HttpError(500, "internal_error", `studio_room ${slug} missing epoch_keys_secret_name`);
  }
  let epochRec: EpochKeyRecord | null = null;
  try {
    const got = await secret.get(epochSecretName);
    const parsed = JSON.parse(got.value) as
      | { epochs?: Record<string, EpochKeyRecord> }
      | Record<string, string | EpochKeyRecord>;
    // Accept BOTH shapes: the verbose `{epochs: {<n>: {priv_hex, pub_hex}}}`
    // form (written by admit.ts mergeEpochKeysSecret) AND the flat
    // `{<n>: <priv_hex>}` form (written by SSEClient.persistEpochKeys).
    // The flat form was added by Phase 3 T3 with an admit.ts comment
    // promising "either consumer finds what it needs" — but this reader
    // was never updated. A member admitted via SSE key-grant (rather than
    // local rotate) hits the flat form; only the founder hits the verbose
    // form. Card-post breaking on B with "epoch N key missing" was this gap.
    const epochKey = String(currentEpoch);
    const verboseFound = (parsed as { epochs?: Record<string, EpochKeyRecord> })
      ?.epochs?.[epochKey];
    if (
      verboseFound &&
      HEX64.test(verboseFound.priv_hex) &&
      HEX64.test(verboseFound.pub_hex)
    ) {
      epochRec = verboseFound;
    } else {
      const flatFound = (parsed as Record<string, string | EpochKeyRecord>)?.[
        epochKey
      ];
      if (typeof flatFound === "string" && HEX64.test(flatFound)) {
        // Flat form stores priv only. Derive pub from the declaration's
        // members list — current_epoch's pub is published on-chain. This
        // reader has `attrs` in scope; the room's `aud_id_pub_hex` is the
        // audience identity, not the epoch pub, so we can't recover the
        // epoch pub from `attrs` alone. Cleanest fix: persistEpochKeys
        // should mirror the verbose form. Until then, fail explicitly with
        // a hint rather than letting the card-post path silently succeed
        // with a missing pub.
        throw new HttpError(
          500,
          "internal_error",
          `studio_room ${slug} epoch ${currentEpoch} stored in flat form (priv only); persistEpochKeys must mirror the verbose {priv_hex,pub_hex} record so non-founders can post cards`,
        );
      }
    }
  } catch (err) {
    if (err instanceof HttpError) throw err;
    // fall through to "key missing"
  }
  if (!epochRec) {
    throw new HttpError(500, "internal_error", `studio_room ${slug} epoch ${currentEpoch} key missing`);
  }

  return {
    entityId: ent.id,
    slug,
    audienceAddress: `30520:${audIdPubHex}:${slug}`,
    currentEpoch,
    members,
    audIdPrivHex,
    audIdPubHex,
    currentEpochPubHex: epochRec.pub_hex.toLowerCase(),
    currentEpochPrivHex: epochRec.priv_hex.toLowerCase(),
    state: typeof attrs["state"] === "string" ? (attrs["state"] as string) : "active",
    attributes: attrs,
  };
}

// ── Rumor builder ───────────────────────────────────────────────────────────

export interface BuildRumorArgs {
  kind: number;
  /** JSON-LD plaintext payload. Caller must have already validated it. */
  payload: Record<string, unknown>;
  room: StudioRoomCtx;
  /** Sender's identity priv (the plugin's own key in v0). */
  publisherPriv: Uint8Array;
  /** Sender's pubkey (the plugin's pub). */
  publisherPub: string;
  /** Replaceable-event d-tag value. */
  dTag: string;
  /** Human-readable alt tag (NIP-31). */
  alt: string;
  /** Optional extra tags (e.g., ["t", "..."]). Kept after the standard tags. */
  extraTags?: string[][];
}

export function buildSignedRumor(args: BuildRumorArgs): NostrEvent {
  const plaintext = JSON.stringify(args.payload);
  const ciphertext = encryptString(
    plaintext,
    args.publisherPriv,
    args.room.currentEpochPubHex,
  );
  const blake3 = blake3ContentTag(ciphertext);

  const tags: string[][] = [
    ["d", args.dTag],
    ["a", args.room.audienceAddress],
    ["fa:context", FA_CONTEXT_V0],
    ["fa:epoch", String(args.room.currentEpoch)],
    ["alt", args.alt],
    ["blake3", blake3],
  ];
  for (const m of args.room.members) {
    tags.push(["p", m.toLowerCase()]);
  }
  if (args.extraTags) {
    for (const t of args.extraTags) tags.push(t);
  }

  const created_at = Math.floor(Date.now() / 1000);
  const unsigned = {
    pubkey: args.publisherPub.toLowerCase(),
    kind: args.kind,
    created_at,
    tags,
    content: ciphertext,
  };
  return __signEvent(unsigned, args.publisherPriv);
}

// ── Publish pipeline ────────────────────────────────────────────────────────

/**
 * Build gift-wraps (one per member), POST to /v0/audience/raw/publish-wraps,
 * project the rumor locally so the caller sees its own write immediately.
 *
 * `publishedWrapsCache` is the §Z3 retry-stable cache: if we already built
 * the wrap set on a previous invocation for the same rumor, reuse those
 * exact event ids on retry (relays dedupe by id).
 */
export async function publishRumor(args: {
  rumor: NostrEvent;
  payload: Record<string, unknown>;
  room: StudioRoomCtx;
  publisherPriv: Uint8Array;
  gateway: GatewayClient;
  publishedWrapsCache?: NostrEvent[] | null;
}): Promise<{ wraps: NostrEvent[]; rumorEventId: string }> {
  // Wire-level validate the rumor before sending — fail fast on malformed.
  const wireOk = validateStudioWireEvent(args.rumor);
  if (!wireOk.ok) {
    throw new HttpError(400, "validator_rejected", `wire validator: ${wireOk.error}`);
  }

  // Build wraps per member if not already cached.
  let wraps = args.publishedWrapsCache ?? null;
  if (!wraps || wraps.length !== args.room.members.length) {
    wraps = args.room.members.map((m) => wrap(args.rumor, args.publisherPriv, m));
  }

  const giftWraps: NostrEventLike[] = wraps.map((w) => ({
    id: w.id,
    pubkey: w.pubkey,
    created_at: w.created_at,
    kind: w.kind,
    tags: w.tags,
    content: w.content,
    sig: w.sig,
  }));
  await args.gateway.rawPublishWraps({
    audience_address: args.room.audienceAddress,
    gift_wraps: giftWraps,
  });

  // Local projection — caller sees their own writes immediately.
  await projectLocally(args.rumor, args.payload);

  return { wraps, rumorEventId: args.rumor.id };
}

/**
 * Validate a payload against its kind validator, then run projection. Used
 * by the post-publish path AND by handlers that want to "preview" the
 * projection without going through the wire (member nickname doesn't
 * publish, so it doesn't go here).
 */
export async function projectLocally(
  rumor: NostrEvent,
  payload: Record<string, unknown>,
): Promise<void> {
  const v = payloadValidatorFor(rumor.kind);
  if (v) {
    const r = v(payload);
    if (!r.ok) {
      // Validation should have run pre-publish; getting here means we built
      // a malformed payload locally.
      throw new HttpError(500, "internal_error", `payload validator: ${r.error}`);
    }
  }
  const projectionRumor: StudioRumor = {
    id: rumor.id,
    pubkey: rumor.pubkey,
    kind: rumor.kind,
    created_at: rumor.created_at,
    tags: rumor.tags,
    content: rumor.content,
  };
  const client: ProjectionMemoryClient = {
    entity: memoryClient.entity,
    relation: memoryClient.relation,
    secret: memoryClient.secret,
  };
  await projectToMemory(projectionRumor, payload, client);
}

// ── Pre-publish payload validation ──────────────────────────────────────────

/**
 * Run the kind-specific payload validator. Throws HttpError(400 validator_rejected)
 * on failure. Use BEFORE encrypting — the gateway will validate too on receive,
 * but we want to fail fast and never put a malformed event on the wire.
 */
export function validatePayload(kind: number, payload: Record<string, unknown>): void {
  const v = payloadValidatorFor(kind);
  if (!v) {
    throw new HttpError(500, "internal_error", `no validator for kind ${kind}`);
  }
  const r = v(payload);
  if (!r.ok) {
    throw new HttpError(400, "validator_rejected", r.error);
  }
}

// ── Slug / d-tag helpers ────────────────────────────────────────────────────

function randomHex(byteLen: number): string {
  return bytesToHex(randomBytes(byteLen));
}

/**
 * Sluggify a string per SPEC §5.1 — lower, [a-z0-9-], collapsed dashes,
 * trimmed of leading/trailing dashes. Returns "" if no usable chars.
 */
export function slugify(input: string): string {
  return input
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
}

/** Build a card/comment/etc. d-tag: `<sluggified-prefix>-<8-hex>`. */
export function buildDTag(prefix: string): string {
  const s = slugify(prefix);
  const safe = s.length > 0 ? s.slice(0, 56) : "x";
  return `${safe}-${randomHex(4)}`;
}

/** Build a comment-style d-tag: `<target_id>:<random_8_hex>` per §5.8. */
export function buildScopedDTag(scope: string): string {
  return `${scope}:${randomHex(4)}`;
}

// ── Address / event id parsing ──────────────────────────────────────────────

/**
 * Pull the audience slug from a 4A address, or return null if not an address.
 * 4A address is `30520:<64-hex>:<slug>`.
 */
export function parseAddressSlug(addr: string): string | null {
  const m = /^30520:[0-9a-f]{64}:([A-Za-z0-9-]+)$/i.exec(addr);
  return m ? m[1]! : null;
}

export function isHex64(s: string): boolean {
  return HEX64.test(s);
}

export function pubkeyFromPriv(priv: Uint8Array): string {
  return bytesToHex(schnorr.getPublicKey(priv));
}

export function genKeypair(): { priv: Uint8Array; privHex: string; pubHex: string } {
  const priv = randomBytes(32);
  return {
    priv,
    privHex: bytesToHex(priv),
    pubHex: bytesToHex(schnorr.getPublicKey(priv)),
  };
}

export function privBytes(hex: string): Uint8Array {
  if (!HEX64.test(hex)) throw new Error("priv hex must be 64 chars");
  return hexToBytes(hex);
}

// ── Studio kind constants ───────────────────────────────────────────────────
// Re-exported from validators so handlers don't import both modules.

export {
  STUDIO_KIND_CARD,
  STUDIO_KIND_TRACK,
  STUDIO_KIND_DISPATCH_INTENT,
  STUDIO_KIND_COMMENT,
  STUDIO_KIND_QUESTION,
  STUDIO_KIND_ANSWER,
  STUDIO_KIND_ROOM,
} from "../validators";

// ── Misc ────────────────────────────────────────────────────────────────────

export function ensureString(v: unknown, field: string, opts?: { allowEmpty?: boolean }): string {
  if (typeof v !== "string") {
    throw new HttpError(400, "bad_request", `"${field}" must be a string`);
  }
  if (!opts?.allowEmpty && v.length === 0) {
    throw new HttpError(400, "bad_request", `"${field}" must be non-empty`);
  }
  return v;
}

export function ensureSlug(v: unknown, field: string): string {
  const s = ensureString(v, field);
  if (!SLUG.test(s)) {
    throw new HttpError(400, "bad_request", `"${field}" must match slug [A-Za-z0-9-]+`);
  }
  return s;
}

/** Fingerprint a rumor's signed event id so callers don't need to recompute. */
export function rumorEventId(rumor: NostrEvent): string {
  return rumor.id;
}

// Marker used by jsdoc/refs above.
export type { NostrEvent };

// Re-export for handlers that need to inspect/mutate the gateway path directly.
export { __getEventHash };
