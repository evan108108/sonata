// Local builders for 4A v0.5 audience event templates.
//
// Mirrors gateway/src/lib/audience-events.ts (the v0.5 SPEC implementation),
// restated locally so the plugin can compile without a cross-repo import.
// Drift here = silent on-wire incompatibility, so any change must round-trip
// through the gateway's parser. The handful of builders we need:
//
//   kind:30520  — buildAudienceDeclaration  (room.create)
//   kind:30521  — buildKeyGrant             (room.create founding grant)
//   kind:30522  — buildAudienceClaim        (room.join)
//
// Encrypted-variant rumor builder (kinds 30530-30536) lives in
// `actions/util.ts`'s `buildSignedRumor` since it's tightly coupled to
// gift-wrap + room context.

import { blake3ContentTag } from "./crypto/blake3-tag";

export const FA_CONTEXT_V0 = "https://4a4.ai/ns/v0";
export const KIND_AUDIENCE = 30520;
export const KIND_KEYGRANT = 30521;
export const KIND_CLAIM = 30522;

export interface EventTemplate {
  kind: number;
  created_at: number;
  tags: string[][];
  content: string;
}

function nowSec(): number {
  return Math.floor(Date.now() / 1000);
}

export interface BuildAudienceDeclarationInput {
  audIdPub: string;
  slug: string;
  name: string;
  description?: string;
  epoch: number;
  epochPub: string;
  members: string[];
  pending?: { invitePub: string; expirationUnix: number }[];
  expiration?: number;
  createdAt?: number;
  /**
   * Room lifecycle status (sonata-studio-room-lifecycle.md §4.1). Absence
   * means "active"; only "closed" carries a wire-level effect. Founders
   * close the room by republishing with status="closed".
   */
  status?: "active" | "closed";
  /** Unix-seconds when the founder closed the room. Required if status="closed". */
  closedAt?: number;
}

export function buildAudienceDeclaration(
  input: BuildAudienceDeclarationInput,
): EventTemplate {
  const memberCount = input.members.length;
  const isClosed = input.status === "closed";
  const altSummary = `Audience: ${input.slug} (${memberCount} member${memberCount === 1 ? "" : "s"}, epoch ${input.epoch}${isClosed ? ", closed" : ""})`;
  const tags: string[][] = [
    ["d", input.slug],
    ["fa:context", FA_CONTEXT_V0],
    ["alt", altSummary],
    ["fa:epoch", String(input.epoch)],
    ["fa:epoch-pubkey", input.epochPub],
  ];
  if (isClosed) {
    tags.push(["fa:status", "closed"]);
    const closedAt =
      typeof input.closedAt === "number" && input.closedAt > 0
        ? input.closedAt
        : nowSec();
    tags.push(["fa:closed-at", String(closedAt)]);
  }
  for (const m of input.members) tags.push(["p", m]);
  for (const p of input.pending ?? []) {
    tags.push(["fa:pending", `${p.invitePub}:${p.expirationUnix}`]);
  }
  if (input.expiration !== undefined) {
    tags.push(["expiration", String(input.expiration)]);
  }
  const contentObj: Record<string, unknown> = {
    "@context": FA_CONTEXT_V0,
    "@type": "Audience",
    name: input.name,
    epoch: input.epoch,
  };
  if (input.description !== undefined) contentObj.description = input.description;
  return {
    kind: KIND_AUDIENCE,
    created_at: input.createdAt ?? nowSec(),
    tags,
    content: JSON.stringify(contentObj),
  };
}

export interface BuildKeyGrantInput {
  audIdPub: string;
  slug: string;
  epoch: number;
  recipientPub: string;
  /** NIP-44 v2 ciphertext of the bare 32-byte epoch private key. */
  ciphertext: string;
  createdAt?: number;
}

export function buildKeyGrant(input: BuildKeyGrantInput): EventTemplate {
  const aTag = `${KIND_AUDIENCE}:${input.audIdPub}:${input.slug}`;
  const dTag = `${input.slug}:${input.epoch}:${input.recipientPub}`;
  return {
    kind: KIND_KEYGRANT,
    created_at: input.createdAt ?? nowSec(),
    tags: [
      ["d", dTag],
      ["fa:context", FA_CONTEXT_V0],
      ["alt", `KeyGrant: ${input.slug} epoch ${input.epoch}`],
      ["a", aTag],
      ["fa:epoch", String(input.epoch)],
      ["p", input.recipientPub],
    ],
    content: input.ciphertext,
  };
}

/**
 * Optional profile preview embedded in a claim. Avatar is deliberately
 * excluded at claim-time: the joiner has no room-epoch key yet, so it
 * can't encrypt to the room's Blossom server, and using a public Blossom
 * would defeat audience-level privacy. Nickname + bio are exposed in
 * plain JSON because anyone holding the invite URL can read the claim
 * content — joiner is opting into that visibility by attaching a profile.
 * Avatar lands ~2s after admit via the auto-publish `_profile` card.
 */
export interface ClaimProfile {
  nickname?: string;
  bio?: string;
}

export interface BuildAudienceClaimInput {
  audIdPub: string;
  slug: string;
  epoch: number;
  invitePub: string;
  inviterPub: string;
  claimPub: string;
  note?: string;
  expiration?: number;
  createdAt?: number;
  /**
   * Optional profile preview the joiner volunteers so the founder can
   * recognize them in the admit dialog before clicking Admit. See
   * `ClaimProfile` for the visibility tradeoff — anyone with the invite
   * URL can read this; only attach if you're OK with that.
   */
  profile?: ClaimProfile;
}

export function buildAudienceClaim(input: BuildAudienceClaimInput): EventTemplate {
  const aTag = `${KIND_AUDIENCE}:${input.audIdPub}:${input.slug}`;
  const dTag = `${input.slug}:${input.epoch}:${input.invitePub}`;
  const tags: string[][] = [
    ["d", dTag],
    ["fa:context", FA_CONTEXT_V0],
    ["alt", `claim audience ${input.slug} epoch ${input.epoch}`],
    ["a", aTag],
    ["fa:epoch", String(input.epoch)],
    ["p", input.inviterPub],
    ["fa:claim-pubkey", input.claimPub],
  ];
  if (input.expiration !== undefined) {
    tags.push(["expiration", String(input.expiration)]);
  }
  const contentObj: Record<string, unknown> = {
    "@context": FA_CONTEXT_V0,
    "@type": "AudienceClaim",
    audience: input.slug,
    epoch: input.epoch,
    claimPubkey: input.claimPub,
  };
  if (input.note !== undefined) contentObj.note = input.note;
  if (input.profile !== undefined) {
    const cleaned: Record<string, string> = {};
    if (typeof input.profile.nickname === "string" && input.profile.nickname.trim().length > 0) {
      cleaned.nickname = input.profile.nickname.trim().slice(0, 200);
    }
    if (typeof input.profile.bio === "string" && input.profile.bio.trim().length > 0) {
      cleaned.bio = input.profile.bio.trim().slice(0, 500);
    }
    if (Object.keys(cleaned).length > 0) {
      contentObj.profile = cleaned;
    }
  }
  return {
    kind: KIND_CLAIM,
    created_at: input.createdAt ?? nowSec(),
    tags,
    content: JSON.stringify(contentObj),
  };
}

/**
 * Best-effort parse of the `profile` field from a serialized claim event's
 * content. Tolerates malformed JSON, missing fields, and non-string values.
 * Returns null when no parseable profile is present so callers can keep
 * the pre-existing "no preview, just pubkey" UI for old claims.
 */
export function parseClaimProfile(content: string | undefined | null): ClaimProfile | null {
  if (typeof content !== "string" || content.length === 0) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(content);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  const obj = parsed as Record<string, unknown>;
  const raw = obj["profile"];
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const rec = raw as Record<string, unknown>;
  const out: ClaimProfile = {};
  if (typeof rec["nickname"] === "string") {
    const t = (rec["nickname"] as string).trim();
    if (t.length > 0) out.nickname = t.slice(0, 200);
  }
  if (typeof rec["bio"] === "string") {
    const t = (rec["bio"] as string).trim();
    if (t.length > 0) out.bio = t.slice(0, 500);
  }
  return Object.keys(out).length > 0 ? out : null;
}

export function audienceAddress(audIdPub: string, slug: string): string {
  return `${KIND_AUDIENCE}:${audIdPub}:${slug}`;
}

export function parseAudienceAddress(
  address: string,
): { kind: number; pubkey: string; slug: string } | null {
  const parts = address.split(":");
  if (parts.length !== 3) return null;
  const [kindStr, pubkey, slug] = parts as [string, string, string];
  if (kindStr !== String(KIND_AUDIENCE)) return null;
  if (!/^[0-9a-f]{64}$/i.test(pubkey)) return null;
  if (!/^[A-Za-z0-9-]+$/.test(slug)) return null;
  return { kind: KIND_AUDIENCE, pubkey, slug };
}

// blake3 helper kept here so callers wanting just a tag don't need the lib import.
export { blake3ContentTag };
