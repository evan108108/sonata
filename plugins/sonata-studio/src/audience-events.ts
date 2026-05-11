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
}

export function buildAudienceDeclaration(
  input: BuildAudienceDeclarationInput,
): EventTemplate {
  const memberCount = input.members.length;
  const altSummary = `Audience: ${input.slug} (${memberCount} member${memberCount === 1 ? "" : "s"}, epoch ${input.epoch})`;
  const tags: string[][] = [
    ["d", input.slug],
    ["fa:context", FA_CONTEXT_V0],
    ["alt", altSummary],
    ["fa:epoch", String(input.epoch)],
    ["fa:epoch-pubkey", input.epochPub],
  ];
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
  return {
    kind: KIND_CLAIM,
    created_at: input.createdAt ?? nowSec(),
    tags,
    content: JSON.stringify(contentObj),
  };
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
