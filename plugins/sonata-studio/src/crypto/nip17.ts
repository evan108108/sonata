// AUTO-GENERATED — copied at build time from:
//   /Users/evan/projects/4a/gateway/src/lib/nip17.ts
// Edits will be overwritten by build.sh on the next compile.

// NIP-17 / NIP-59 gift-wrap helpers for 4A v0.5 audience-addressed events.
//
// Per SPEC-v0.5 §4, every encrypted-variant event (kind:30510-30514) MUST be
// delivered as one or more gift-wraps (kind:1059), one per current member.
// The wire shape is three nested layers:
//
//   rumor       (signed kind:30510-30514, our payload event from §3)
//   ↓ wrapped in
//   seal        (kind:13, content = NIP-44(JSON(rumor), publisher → p_i),
//                signed by publisher)
//   ↓ wrapped in
//   gift-wrap   (kind:1059, content = NIP-44(JSON(seal), eph → p_i),
//                signed by a fresh ephemeral key, p tag = [p_i])
//
// On unwrap the recipient runs the inverse: decrypt the gift-wrap with their
// identity key + the gift-wrap's signing pubkey (the ephemeral pub is exactly
// the gift-wrap event's `pubkey` field), parse + verify the seal, decrypt the
// seal with their identity key + the seal's signing pubkey (= publisher),
// parse + verify the rumor.
//
// `created_at` of the seal and the gift-wrap is randomized within ±86400s
// of the actual current time, per NIP-59, to obscure timing correlation.

import { schnorr } from "@noble/curves/secp256k1.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex, hexToBytes, randomBytes } from "@noble/hashes/utils.js";
import { decryptString, encryptString } from "./nip44";

export const KIND_SEAL = 13 as const;
export const KIND_GIFT_WRAP = 1059 as const;

const ONE_DAY_SEC = 86400;
const HEX64 = /^[0-9a-f]{64}$/i;

/**
 * Minimal Nostr event shape used here. We don't reuse RelayPool's NostrEvent
 * to avoid a cross-module import (this module is also called from tests with
 * synthetic events).
 */
export interface NostrEvent {
  id: string;
  pubkey: string;
  created_at: number;
  kind: number;
  tags: string[][];
  content: string;
  sig: string;
}

export interface UnsignedEvent {
  pubkey: string;
  created_at: number;
  kind: number;
  tags: string[][];
  content: string;
}

function nowSec(): number {
  return Math.floor(Date.now() / 1000);
}

/**
 * Pick a created_at uniformly within `[real - 86400, real]` per NIP-59. Past-
 * shifted only — never in the future, since some relays clamp future events.
 */
function jitteredPastTimestamp(realNowSec: number = nowSec()): number {
  const offset = Math.floor(Math.random() * (ONE_DAY_SEC + 1));
  return realNowSec - offset;
}

function getEventHash(evt: UnsignedEvent): string {
  const serialized = JSON.stringify([
    0,
    evt.pubkey,
    evt.created_at,
    evt.kind,
    evt.tags,
    evt.content,
  ]);
  return bytesToHex(sha256(new TextEncoder().encode(serialized)));
}

function signEvent(evt: UnsignedEvent, priv: Uint8Array): NostrEvent {
  const id = getEventHash(evt);
  const sig = bytesToHex(schnorr.sign(hexToBytes(id), priv));
  return { ...evt, id, sig };
}

function verifyEventSignature(evt: NostrEvent): boolean {
  if (!HEX64.test(evt.id) || !HEX64.test(evt.pubkey) || evt.sig.length !== 128) {
    return false;
  }
  // Recompute hash and compare.
  const expected = getEventHash(evt);
  if (expected !== evt.id.toLowerCase()) return false;
  try {
    return schnorr.verify(hexToBytes(evt.sig), hexToBytes(evt.id), hexToBytes(evt.pubkey));
  } catch {
    return false;
  }
}

/**
 * Build a NIP-59 seal (`kind:13`) carrying the rumor encrypted from the
 * publisher to one recipient. The seal is signed by the publisher's identity
 * key. The seal carries no other tags.
 */
export function createSeal(
  rumor: NostrEvent,
  publisherPriv: Uint8Array,
  recipientPubHex: string,
): NostrEvent {
  const sealContent = encryptString(JSON.stringify(rumor), publisherPriv, recipientPubHex);
  return signEvent(
    {
      pubkey: bytesToHex(schnorr.getPublicKey(publisherPriv)),
      kind: KIND_SEAL,
      created_at: jitteredPastTimestamp(),
      tags: [],
      content: sealContent,
    },
    publisherPriv,
  );
}

/**
 * Wrap an already-built seal in a gift-wrap (`kind:1059`) addressed to one
 * recipient. The gift-wrap is signed by a fresh ephemeral keypair so the
 * publisher's identity pubkey is concealed from relay-level metadata.
 *
 * Per SPEC-v0.5 §4.5, the gift-wrap MUST carry exactly one `p` tag and no
 * other tags.
 */
export function createGiftWrap(
  seal: NostrEvent,
  recipientPubHex: string,
  ephemeralPriv: Uint8Array = randomBytes(32),
): NostrEvent {
  const ephPub = bytesToHex(schnorr.getPublicKey(ephemeralPriv));
  const wrapContent = encryptString(JSON.stringify(seal), ephemeralPriv, recipientPubHex);
  return signEvent(
    {
      pubkey: ephPub,
      kind: KIND_GIFT_WRAP,
      created_at: jitteredPastTimestamp(),
      tags: [["p", recipientPubHex]],
      content: wrapContent,
    },
    ephemeralPriv,
  );
}

/**
 * Convenience: build a gift-wrap directly from a (signed) rumor event by
 * sealing then wrapping. The single-shot path used for the §4 publish
 * fan-out, called once per current audience member.
 */
export function wrap(
  rumor: NostrEvent,
  publisherPriv: Uint8Array,
  recipientPubHex: string,
): NostrEvent {
  const seal = createSeal(rumor, publisherPriv, recipientPubHex);
  return createGiftWrap(seal, recipientPubHex);
}

export interface UnwrappedRumor {
  /** The fully-decoded inner event (the kind:30510-30514 rumor in 4A). */
  rumor: NostrEvent;
  /** The publisher's identity pubkey (recovered from the seal's `pubkey`). */
  publisherPub: string;
}

/**
 * Reverse the wrap. On any structural failure, signature mismatch, or NIP-44
 * MAC failure throws an Error — callers should catch and discard (gift-wraps
 * for other recipients land on the same subscription and look like garbage).
 */
export function unwrap(giftWrap: NostrEvent, recipientPriv: Uint8Array): UnwrappedRumor {
  if (giftWrap.kind !== KIND_GIFT_WRAP) {
    throw new Error(`expected kind:${KIND_GIFT_WRAP}, got ${giftWrap.kind}`);
  }
  const ephPub = giftWrap.pubkey;
  const sealJson = decryptString(giftWrap.content, recipientPriv, ephPub);
  let seal: NostrEvent;
  try {
    seal = JSON.parse(sealJson);
  } catch (err) {
    throw new Error(`seal JSON parse failed: ${err instanceof Error ? err.message : err}`);
  }
  if (seal.kind !== KIND_SEAL) {
    throw new Error(`expected seal kind:${KIND_SEAL}, got ${seal.kind}`);
  }
  if (!verifyEventSignature(seal)) {
    throw new Error("seal signature verification failed");
  }
  const publisherPub = seal.pubkey;
  const rumorJson = decryptString(seal.content, recipientPriv, publisherPub);
  let rumor: NostrEvent;
  try {
    rumor = JSON.parse(rumorJson);
  } catch (err) {
    throw new Error(`rumor JSON parse failed: ${err instanceof Error ? err.message : err}`);
  }
  // SPEC-v0.5 §4.1 step 1 — rumor is a signed event in 4A; verify the sig.
  if (!verifyEventSignature(rumor)) {
    throw new Error("rumor signature verification failed");
  }
  if (rumor.pubkey !== publisherPub) {
    throw new Error("rumor pubkey does not match seal pubkey");
  }
  return { rumor, publisherPub };
}

// Re-export helpers used by callers that build rumors themselves.
export { signEvent as __signEvent, getEventHash as __getEventHash, verifyEventSignature };
