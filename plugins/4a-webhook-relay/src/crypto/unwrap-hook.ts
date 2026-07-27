// Hook-branch NIP-59 unwrap — plugin-authored, NOT auto-generated.
//
// The audience path (sonata-studio, and `unwrap()` in the auto-copied
// nip17.ts) verifies the seal's signature and binds the rumor's pubkey to
// the seal signer, because there the seal signer IS the known audience
// publisher and that binding is load-bearing.
//
// Hook wraps are different by design (plan rev 3, invariant 3): the gateway
// signs each delivery's rumor + seal with a THROWAWAY 32-byte priv, so there
// is no known publisher pub to validate against and the seal-signer identity
// carries zero information. This branch therefore SKIPS seal-signer
// validation entirely: no seal signature check, no rumor↔seal pubkey
// binding. Authenticity is not decided here — Sonata verifies the third
// party's own HMAC/bearer against the user-configured per-slug secret, and
// that is the real check per the trust story.
//
// What we DO still require:
//   - outer kind is 1059 and both NIP-44 layers decrypt with our identity
//     priv (only the addressed plugin can get this far), and
//   - the rumor's event id is internally consistent (recomputed hash matches)
//     so the `wrapEventId` we forward for dedup is well-formed.

import { bytesToHex } from "@noble/hashes/utils.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { decryptString } from "./nip44";
import { KIND_GIFT_WRAP, KIND_SEAL, type NostrEvent } from "./nip17";

function eventHash(evt: NostrEvent): string {
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

/**
 * Unwrap a hook gift-wrap down to its inner rumor. Throws on any structural
 * failure or NIP-44 MAC mismatch — callers catch and skip the wrap.
 */
export function unwrapHook(giftWrap: NostrEvent, recipientPriv: Uint8Array): NostrEvent {
  if (giftWrap.kind !== KIND_GIFT_WRAP) {
    throw new Error(`expected kind:${KIND_GIFT_WRAP}, got ${giftWrap.kind}`);
  }
  const sealJson = decryptString(giftWrap.content, recipientPriv, giftWrap.pubkey);
  let seal: NostrEvent;
  try {
    seal = JSON.parse(sealJson);
  } catch (err) {
    throw new Error(`seal JSON parse failed: ${err instanceof Error ? err.message : err}`);
  }
  if (seal.kind !== KIND_SEAL) {
    throw new Error(`expected seal kind:${KIND_SEAL}, got ${seal.kind}`);
  }
  // Deliberately NO seal signature verification and NO publisher binding —
  // see module comment.
  const rumorJson = decryptString(seal.content, recipientPriv, seal.pubkey);
  let rumor: NostrEvent;
  try {
    rumor = JSON.parse(rumorJson);
  } catch (err) {
    throw new Error(`rumor JSON parse failed: ${err instanceof Error ? err.message : err}`);
  }
  if (typeof rumor.id !== "string" || eventHash(rumor) !== rumor.id.toLowerCase()) {
    throw new Error("rumor id does not match recomputed event hash");
  }
  return rumor;
}

/** Return the slug from the rumor's `["fa:hook", slug]` tag, or null. */
export function hookSlug(rumor: NostrEvent): string | null {
  if (!Array.isArray(rumor.tags)) return null;
  for (const t of rumor.tags) {
    if (Array.isArray(t) && t[0] === "fa:hook" && typeof t[1] === "string" && t[1].length > 0) {
      return t[1];
    }
  }
  return null;
}
