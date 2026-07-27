// AUTO-GENERATED — copied at build time from:
//   /Users/evan/projects/4a/gateway/src/lib/nip44.ts
// Edits will be overwritten by build.sh on the next compile.

// NIP-44 v2 — ChaCha20 + HMAC over secp256k1 ECDH, with byte-oriented plaintexts.
//
// Scope: 4A v0.5 needs to encrypt two kinds of payloads under NIP-44 v2:
//   1. The raw 32-byte secp256k1 scalar of an audience epoch's private key
//      (kind:30521 key-grant content; SPEC-v0.5 §2.2 mandates the bare scalar,
//      no JSON wrapper, no hex re-encoding).
//   2. UTF-8 JSON-LD strings (kind:30510-30514 encrypted variants and the
//      seal/gift-wrap layers).
//
// nostr-tools' nip44.ts is well-tested but is wired for `string` plaintexts
// (utf8 encode internally). We accept Uint8Array directly so the key-grant
// path can pass the raw scalar without round-tripping through utf8 — which
// matters because the raw scalar may contain bytes that aren't valid utf8.
//
// Wire format (per https://github.com/nostr-protocol/nips/blob/master/44.md):
//   0x02 || nonce(32) || ciphertext(L) || mac(32), base64-encoded
//   conversation_key = HKDF_extract(salt="nip44-v2", IKM=ECDH_X(a, b))
//   message_keys     = HKDF_expand(prk=conversation_key, info=nonce, len=76)
//                       => chacha_key(32) || chacha_nonce(12) || hmac_key(32)
//   plaintext_padded = u16_be(len) || plaintext || zero-pad-to-bucket
//   ciphertext       = ChaCha20(chacha_key, chacha_nonce, plaintext_padded)
//   mac              = HMAC-SHA256(hmac_key, nonce || ciphertext)
//
// On decrypt the inverse: parse, derive keys, verify MAC (constant-time),
// decrypt, strip padding header.

import { chacha20 } from "@noble/ciphers/chacha.js";
import { equalBytes } from "@noble/ciphers/utils.js";
import { secp256k1 } from "@noble/curves/secp256k1.js";
import { extract as hkdfExtract, expand as hkdfExpand } from "@noble/hashes/hkdf.js";
import { hmac } from "@noble/hashes/hmac.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { concatBytes, hexToBytes, randomBytes } from "@noble/hashes/utils.js";
import { base64 } from "@scure/base";

const VERSION = 0x02;
const NIP44_SALT = new TextEncoder().encode("nip44-v2");

const MIN_PLAINTEXT_BYTES = 1;
const MAX_PLAINTEXT_BYTES = 65535;

function calcPaddedLen(len: number): number {
  if (!Number.isSafeInteger(len) || len < 1) {
    throw new Error("expected positive integer plaintext length");
  }
  if (len <= 32) return 32;
  const nextPower = 1 << (Math.floor(Math.log2(len - 1)) + 1);
  const chunk = nextPower <= 256 ? 32 : nextPower / 8;
  return chunk * (Math.floor((len - 1) / chunk) + 1);
}

function u16beWrite(n: number): Uint8Array {
  if (n < MIN_PLAINTEXT_BYTES || n > MAX_PLAINTEXT_BYTES) {
    throw new Error(`plaintext length out of range: ${n}`);
  }
  const out = new Uint8Array(2);
  new DataView(out.buffer).setUint16(0, n, false);
  return out;
}

function pad(plaintext: Uint8Array): Uint8Array {
  const prefix = u16beWrite(plaintext.length);
  const suffix = new Uint8Array(calcPaddedLen(plaintext.length) - plaintext.length);
  return concatBytes(prefix, plaintext, suffix);
}

function unpad(padded: Uint8Array): Uint8Array {
  if (padded.length < 2) throw new Error("invalid padding: payload too short");
  const view = new DataView(padded.buffer, padded.byteOffset, padded.byteLength);
  const declared = view.getUint16(0, false);
  if (declared < MIN_PLAINTEXT_BYTES || declared > MAX_PLAINTEXT_BYTES) {
    throw new Error("invalid padding: declared length out of range");
  }
  const expected = 2 + calcPaddedLen(declared);
  if (padded.length !== expected) {
    throw new Error(
      `invalid padding: expected ${expected} bytes total, got ${padded.length}`,
    );
  }
  return padded.subarray(2, 2 + declared);
}

/**
 * Compute the NIP-44 v2 conversation key from one party's private key and
 * the other party's x-only Nostr pubkey. Symmetric: both sides derive the
 * same conversation key.
 */
export function getConversationKey(
  privA: Uint8Array,
  pubBHex: string,
): Uint8Array {
  if (privA.length !== 32) throw new Error("private key must be 32 bytes");
  if (!/^[0-9a-f]{64}$/i.test(pubBHex)) {
    throw new Error("public key must be 32-byte hex");
  }
  // Nostr uses x-only pubkeys; pin the y-coordinate to even (0x02) for ECDH.
  const sharedX = secp256k1
    .getSharedSecret(privA, hexToBytes("02" + pubBHex.toLowerCase()))
    .subarray(1, 33);
  return hkdfExtract(sha256, sharedX, NIP44_SALT);
}

interface MessageKeys {
  chachaKey: Uint8Array;
  chachaNonce: Uint8Array;
  hmacKey: Uint8Array;
}

function getMessageKeys(conversationKey: Uint8Array, nonce: Uint8Array): MessageKeys {
  if (nonce.length !== 32) throw new Error("nonce must be 32 bytes");
  const expanded = hkdfExpand(sha256, conversationKey, nonce, 76);
  return {
    chachaKey: expanded.subarray(0, 32),
    chachaNonce: expanded.subarray(32, 44),
    hmacKey: expanded.subarray(44, 76),
  };
}

function macWithAad(key: Uint8Array, ciphertext: Uint8Array, aad: Uint8Array): Uint8Array {
  if (aad.length !== 32) throw new Error("AAD must be 32 bytes");
  return hmac(sha256, key, concatBytes(aad, ciphertext));
}

/**
 * Encrypt a byte plaintext to a recipient's Nostr pubkey. Returns the
 * standard NIP-44 v2 base64 wire string.
 *
 * The plaintext is bytes (not utf-8 string) so callers can pass arbitrary
 * binary payloads — required for kind:30521 key-grants where the inner
 * payload is the raw 32-byte secp256k1 scalar.
 */
export function encrypt(
  plaintext: Uint8Array,
  senderPriv: Uint8Array,
  recipientPubHex: string,
  options?: { nonce?: Uint8Array },
): string {
  const conversationKey = getConversationKey(senderPriv, recipientPubHex);
  const nonce = options?.nonce ?? randomBytes(32);
  if (nonce.length !== 32) throw new Error("nonce must be 32 bytes");
  const { chachaKey, chachaNonce, hmacKey } = getMessageKeys(conversationKey, nonce);
  const padded = pad(plaintext);
  const ciphertext = chacha20(chachaKey, chachaNonce, padded);
  const mac = macWithAad(hmacKey, ciphertext, nonce);
  const payload = concatBytes(new Uint8Array([VERSION]), nonce, ciphertext, mac);
  return base64.encode(payload);
}

/**
 * Decrypt a NIP-44 v2 base64 wire string from the named sender. Returns the
 * raw plaintext bytes.
 *
 * Throws on version mismatch, MAC failure, or malformed padding. The MAC
 * check is constant-time via @noble/ciphers' equalBytes.
 */
export function decrypt(
  ciphertextB64: string,
  recipientPriv: Uint8Array,
  senderPubHex: string,
): Uint8Array {
  if (typeof ciphertextB64 !== "string" || ciphertextB64.length === 0) {
    throw new Error("ciphertext must be a non-empty string");
  }
  if (ciphertextB64[0] === "#") {
    throw new Error("unsupported NIP-44 version prefix '#'");
  }
  let payload: Uint8Array;
  try {
    payload = base64.decode(ciphertextB64);
  } catch (err) {
    throw new Error(
      `invalid base64: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
  if (payload.length < 1 + 32 + 32 + 32) {
    throw new Error("payload too short");
  }
  if (payload[0] !== VERSION) {
    throw new Error(`unsupported NIP-44 version: 0x${payload[0]!.toString(16)}`);
  }
  const nonce = payload.subarray(1, 33);
  const ciphertext = payload.subarray(33, payload.length - 32);
  const mac = payload.subarray(payload.length - 32);

  const conversationKey = getConversationKey(recipientPriv, senderPubHex);
  const { chachaKey, chachaNonce, hmacKey } = getMessageKeys(conversationKey, nonce);

  const expectedMac = macWithAad(hmacKey, ciphertext, nonce);
  if (!equalBytes(mac, expectedMac)) {
    throw new Error("MAC verification failed");
  }
  const padded = chacha20(chachaKey, chachaNonce, ciphertext);
  return unpad(padded);
}

/**
 * Convenience wrappers for the common "plaintext is utf8 string" case
 * (encrypted-variant payloads in §3, seal content, gift-wrap content).
 */
export function encryptString(
  plaintext: string,
  senderPriv: Uint8Array,
  recipientPubHex: string,
  options?: { nonce?: Uint8Array },
): string {
  return encrypt(new TextEncoder().encode(plaintext), senderPriv, recipientPubHex, options);
}

export function decryptString(
  ciphertextB64: string,
  recipientPriv: Uint8Array,
  senderPubHex: string,
): string {
  return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(
    decrypt(ciphertextB64, recipientPriv, senderPubHex),
  );
}

/**
 * Structural-validity check used by validators (§2.6, §3.6, §4.5). Verifies
 * version byte and length envelope without attempting decryption.
 */
export function isStructurallyValid(ciphertextB64: string): boolean {
  if (typeof ciphertextB64 !== "string" || ciphertextB64.length === 0) return false;
  if (ciphertextB64[0] === "#") return false;
  let payload: Uint8Array;
  try {
    payload = base64.decode(ciphertextB64);
  } catch {
    return false;
  }
  if (payload.length < 1 + 32 + 32 + 32) return false;
  if (payload[0] !== VERSION) return false;
  // Ciphertext length must produce a valid padded length when MAC is stripped:
  // len(ciphertext) = padded_len, and padded_len must be 32 + 2 (header) at minimum.
  const ciphertextLen = payload.length - 1 - 32 - 32;
  if (ciphertextLen < 2 + 32) return false;
  return true;
}
