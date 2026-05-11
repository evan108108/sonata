// AUTO-GENERATED — copied at build time from:
//   /Users/evan/projects/4a/gateway/src/lib/blake3-tag.ts
// Edits will be overwritten by build.sh on the next compile.

// Canonical BLAKE3 content tag helper for 4A events.
//
// Per SPEC.md §Content addressing, every 4A event carries a `blake3` tag whose
// value is `bk-` + RFC 4648 base32 (lowercase, no padding) of BLAKE3(content).
// This helper is the single source of truth: signing paths use it on publish,
// the relay-pool ingester uses it to verify on read, and the format validators
// use it to check well-formedness. It must match `scripts/genesis.mjs`.

import { blake3 } from "@noble/hashes/blake3.js";

const BASE32_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";

export function base32Encode(bytes: Uint8Array): string {
  let bits = 0,
    value = 0,
    out = "";
  for (let i = 0; i < bytes.length; i++) {
    value = (value << 8) | bytes[i]!;
    bits += 8;
    while (bits >= 5) {
      out += BASE32_ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += BASE32_ALPHABET[(value << (5 - bits)) & 31];
  return out;
}

export function blake3ContentTag(content: string): string {
  return "bk-" + base32Encode(blake3(new TextEncoder().encode(content)));
}
