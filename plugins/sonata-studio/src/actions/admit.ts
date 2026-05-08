// Founder admit — Phase 3 §1 Gap 2.
//
// `studio_room_admit` consumes any pending kind:30522 audience-claim events
// the gateway has stored for this room, rotates the audience epoch to
// `current_epoch + 1`, and mints a fresh kind:30521 key-grant for each
// member of the new epoch (existing members AND the new claimers). On
// success the local studio_room entity is patched with the new epoch +
// member set and the new epoch private key is appended to the room's
// epoch-keys secret.
//
// Founder-only: the action requires the local plugin to hold `aud_id_priv`
// for the room (same gate used by `inviteToRoom`).
//
// Idempotent: a re-run with no fresh claims returns `{admitted: []}`. Per
// Phase 3 plan §3, on partial fan-out (declaration accepted, grant fan-out
// partially failed) the action returns a 207-equivalent shape with the
// successful + failed recipient breakdown so an operator re-run can patch
// the gap.
//
// Concurrency (§7 Pass D4): admit calls for the same room are serialized
// through a per-process `Map<slug, Promise>` guard — two concurrent admits
// would each try to publish a kind:30520 with the same epoch number,
// racing on `created_at` at the relay and corrupting the local epoch-priv.

import { schnorr } from "@noble/curves/secp256k1.js";
import { bytesToHex, hexToBytes, randomBytes } from "@noble/hashes/utils.js";

import type { GatewayClient, NostrEventLike, RawRotateResponse } from "../a4-client";
import {
  audienceAddress,
  buildAudienceDeclaration,
  buildKeyGrant,
} from "../audience-events";
import { encrypt as nip44Encrypt } from "../crypto/nip44";
import { __signEvent, type NostrEvent } from "../crypto/nip17";
import { entity, secret } from "../memory-client";

import {
  HttpError,
  ensureSlug,
  isHex64,
  loadRoomCtx,
  type StudioRoomCtx,
} from "./util";
import type { ActionCtx } from "./room";

interface RoomAdmitRequest {
  room_slug?: unknown;
  max_admit?: unknown;
}

interface AdmittedEntry {
  claim_pubkey: string;
  key_grant_event_id: string;
}

interface FailedRecipient {
  recipient: string;
  reason: string;
}

interface RoomAdmitResult {
  ok: boolean;
  admitted: AdmittedEntry[];
  new_epoch: number;
  declaration_event_id: string | null;
  failed?: FailedRecipient[];
  error?: string;
}

/**
 * Per-room serialization. Two admit() calls for the same slug must not run
 * the rotate flow in parallel — the second would publish the same epoch
 * number and the relays' last-write-wins semantics could leave us with the
 * wrong epoch_priv locally. The lock is process-local; restart-after-crash
 * recovery is handled by re-running admit.
 */
const admitLocks = new Map<string, Promise<unknown>>();

async function withRoomLock<T>(slug: string, fn: () => Promise<T>): Promise<T> {
  const prev = admitLocks.get(slug);
  let release: () => void = () => undefined;
  const next = new Promise<void>((resolve) => {
    release = resolve;
  });
  admitLocks.set(slug, next);
  try {
    if (prev) {
      try {
        await prev;
      } catch {
        // prior holder's failure is its own concern.
      }
    }
    return await fn();
  } finally {
    release();
    if (admitLocks.get(slug) === next) admitLocks.delete(slug);
  }
}

export async function admitRoom(
  body: RoomAdmitRequest,
  ctx: ActionCtx,
): Promise<RoomAdmitResult> {
  const slug = ensureSlug(body.room_slug, "room_slug");
  const maxAdmit = parseMaxAdmit(body.max_admit);

  return withRoomLock(slug, () => admitRoomInner(slug, maxAdmit, ctx));
}

async function admitRoomInner(
  slug: string,
  maxAdmit: number | null,
  ctx: ActionCtx,
): Promise<RoomAdmitResult> {
  const room = await loadRoomCtx(slug, ctx.cfg.pluginPub);
  if (!room.audIdPrivHex) {
    throw new HttpError(
      403,
      "not_founder",
      `only the founder can admit claims for "${slug}"`,
    );
  }

  // 1. Pull pending claims from the gateway. Filter to claims whose pubkey
  //    isn't already a member (idempotent re-run protection per §7 B10).
  const claimsRes = await ctx.gateway.rawProcessClaims({
    audience_address: room.audienceAddress,
  });
  const memberSet = new Set(room.members.map((m) => m.toLowerCase()));
  const fresh: { invite_pub: string; claim_pubkey: string; claim_event_id: string }[] = [];
  for (const c of claimsRes.claimed ?? []) {
    if (typeof c.claim_pubkey !== "string") continue;
    const cp = c.claim_pubkey.toLowerCase();
    if (!isHex64(cp)) continue;
    if (memberSet.has(cp)) continue;
    fresh.push({
      invite_pub: c.invite_pub,
      claim_pubkey: cp,
      claim_event_id: c.claim_event_id,
    });
    if (maxAdmit !== null && fresh.length >= maxAdmit) break;
  }

  if (fresh.length === 0) {
    return {
      ok: true,
      admitted: [],
      new_epoch: room.currentEpoch,
      declaration_event_id: null,
    };
  }

  // 2. Build the rotated declaration. New epoch = current + 1, new epoch
  //    pub, fresh claimers added to `p` member tags, satisfied invite_pubs
  //    dropped from `pending_invites`.
  const audIdPriv = hexToBytes(room.audIdPrivHex);
  const newEpoch = room.currentEpoch + 1;
  const newEpochPriv = randomBytes(32);
  const newEpochPub = bytesToHex(schnorr.getPublicKey(newEpochPriv));

  const newMembers: string[] = [...room.members.map((m) => m.toLowerCase())];
  for (const c of fresh) if (!newMembers.includes(c.claim_pubkey)) newMembers.push(c.claim_pubkey);

  const satisfiedInvitePubs = new Set(fresh.map((c) => c.invite_pub));
  const remainingPending = currentPendingInvites(room.attributes).filter(
    (p) => !satisfiedInvitePubs.has(p.invitePub),
  );

  const declTemplate = buildAudienceDeclaration({
    audIdPub: room.audIdPubHex,
    slug,
    name: pickTitle(room.attributes),
    description: pickDescription(room.attributes),
    epoch: newEpoch,
    epochPub: newEpochPub,
    members: newMembers,
    pending: remainingPending,
  });
  const declUnsigned = {
    pubkey: room.audIdPubHex,
    kind: declTemplate.kind,
    created_at: declTemplate.created_at,
    tags: declTemplate.tags,
    content: declTemplate.content,
  };
  const declSigned = __signEvent(declUnsigned, audIdPriv);

  // 3. Mint one kind:30521 key-grant per member of the new epoch — every
  //    existing member + each fresh claimer needs the new epoch_priv.
  const grants: NostrEvent[] = [];
  for (const recipient of newMembers) {
    const ciphertext = nip44Encrypt(newEpochPriv, audIdPriv, recipient);
    const grantTemplate = buildKeyGrant({
      audIdPub: room.audIdPubHex,
      slug,
      epoch: newEpoch,
      recipientPub: recipient,
      ciphertext,
    });
    const grantUnsigned = {
      pubkey: room.audIdPubHex,
      kind: grantTemplate.kind,
      created_at: grantTemplate.created_at,
      tags: grantTemplate.tags,
      content: grantTemplate.content,
    };
    grants.push(__signEvent(grantUnsigned, audIdPriv));
  }

  // 4. POST raw/rotate. The gateway publishes the new declaration + every
  //    grant in one call.
  let rotateRes: RawRotateResponse;
  try {
    rotateRes = await ctx.gateway.rawRotate({
      audience_address: room.audienceAddress,
      declaration: toEventLike(declSigned),
      grants: grants.map(toEventLike),
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new HttpError(502, "gateway_unavailable", `raw/rotate failed: ${msg}`);
  }

  // 5. Persist the new epoch_priv locally. Existing room secrets use the
  //    verbose `{epochs: {<n>: {epoch, priv_hex, pub_hex}}}` shape that
  //    `loadRoomCtx` reads; SSEClient.persistEpochKeys writes a flat
  //    `{<n>: <hex>}` shape. To keep both readers happy across the format
  //    skew we preserve the verbose record AND mirror a flat key — either
  //    consumer finds what it needs.
  await mergeEpochKeysSecret(
    room.attributes["epoch_keys_secret_name"] === undefined
      ? `studio:room:${slug}:epoch_keys`
      : String(room.attributes["epoch_keys_secret_name"]),
    slug,
    newEpoch,
    bytesToHex(newEpochPriv),
    newEpochPub,
  );

  // 6. Patch local studio_room — current_epoch + members + pending_invites.
  await entity.patch({
    id: room.entityId,
    attributes: {
      current_epoch: newEpoch,
      members: newMembers,
      pending_invites: remainingPending,
    },
  });

  // 7. Sort relay-acks into per-recipient outcomes. The gateway returns a
  //    parallel array `grants[]` keyed by recipient; treat any
  //    "rejected"/"failed" relay_ack on a grant as a partial failure but
  //    keep the action's overall status truthful.
  const admitted: AdmittedEntry[] = [];
  const failed: FailedRecipient[] = [];
  const claimByPub = new Map(fresh.map((c) => [c.claim_pubkey, c]));
  for (const g of rotateRes.grants ?? []) {
    const recipient = String(g.recipient ?? "").toLowerCase();
    const claim = claimByPub.get(recipient);
    if (!claim) continue;
    const allFailed = (g.relay_acks ?? []).length > 0
      && (g.relay_acks ?? []).every((a) => a.status !== "accepted");
    if (allFailed) {
      failed.push({
        recipient,
        reason: "all relays rejected the grant",
      });
    } else {
      admitted.push({
        claim_pubkey: recipient,
        key_grant_event_id: g.event_id,
      });
    }
  }

  if (failed.length > 0) {
    return {
      ok: false,
      admitted,
      failed,
      new_epoch: newEpoch,
      declaration_event_id: rotateRes.declaration_event_id ?? null,
      error: "partial_rotate",
    };
  }
  return {
    ok: true,
    admitted,
    new_epoch: newEpoch,
    declaration_event_id: rotateRes.declaration_event_id ?? null,
  };
}

function parseMaxAdmit(v: unknown): number | null {
  if (v === undefined || v === null) return null;
  const n = Number(v);
  if (!Number.isInteger(n) || n < 1) {
    throw new HttpError(400, "bad_request", `max_admit must be a positive integer`);
  }
  return n;
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

async function mergeEpochKeysSecret(
  secretName: string,
  slug: string,
  epoch: number,
  privHex: string,
  pubHex: string,
): Promise<void> {
  let parsed: Record<string, unknown> = {};
  try {
    const got = await secret.get(secretName);
    if (got?.value) {
      const v = JSON.parse(got.value);
      if (v && typeof v === "object" && !Array.isArray(v)) {
        parsed = v as Record<string, unknown>;
      }
    }
  } catch {
    // first-write — start with empty record
  }
  const epochsRaw = parsed["epochs"];
  const epochs: Record<string, { epoch: number; priv_hex: string; pub_hex: string }> =
    epochsRaw && typeof epochsRaw === "object" && !Array.isArray(epochsRaw)
      ? (epochsRaw as Record<string, { epoch: number; priv_hex: string; pub_hex: string }>)
      : {};
  epochs[String(epoch)] = { epoch, priv_hex: privHex, pub_hex: pubHex };
  // Mirror the flat `{[n]: <hex>}` shape SSEClient.persistEpochKeys writes,
  // so a flat-format consumer can still read the new key.
  const next: Record<string, unknown> = { ...parsed, epochs };
  next[String(epoch)] = privHex;
  await secret.set({
    name: secretName,
    value: JSON.stringify(next),
    description: `epoch keys for studio room "${slug}"`,
  });
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

// Test-only: surface the per-room lock map so unit tests can verify
// concurrent admit() calls serialize. Not part of the public action API.
export const __admitInternals = {
  admitLocks,
  withRoomLock,
};

// Re-export the StudioRoomCtx type purely so tests that mock loadRoomCtx
// have a canonical shape to import from this module's neighborhood.
export type { StudioRoomCtx };

export const room_admit = {
  admit(body: unknown, ctx: ActionCtx): Promise<RoomAdmitResult> {
    return admitRoom((body ?? {}) as RoomAdmitRequest, ctx);
  },
};
