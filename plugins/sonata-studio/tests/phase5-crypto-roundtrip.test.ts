// Phase 5 hybrid-encryption plumbing audit — round-trip checks.
//
// Sonata Studio Phase 5 (file attachments) moves off the Phase 4 single-shot
// NIP-44 encryption (capped at NIP-44 v2's 65,535-byte plaintext) in favor of
// the standard envelope-encryption pattern:
//
//   1. Generate fresh 32-byte file_key per blob.
//   2. Encrypt file plaintext with ChaCha20-Poly1305(file_key, nonce) → ciphertext.
//   3. NIP-44-wrap the 32-byte file_key under each recipient's identity key
//      (or, in the audience case, under aud_epoch_n_pub).
//
// This file covers the building-block round-trips (bulk AEAD on its own,
// NIP-44 wrap of a 32-byte key on its own). The combined hybrid pattern and
// the multi-recipient fan-out land in a follow-up commit.
//
// Audit doc: /Users/evan/memory/claude/documents/evenflow/sonata-studio-phase5-plumbing-audit.md

import { describe, expect, it } from "bun:test";
import { randomBytes as nodeRandomBytes } from "node:crypto";
import { chacha20poly1305 } from "@noble/ciphers/chacha.js";
import { schnorr } from "@noble/curves/secp256k1.js";
import { hexToBytes, bytesToHex } from "@noble/hashes/utils.js";
import { base64 } from "@scure/base";

import { decrypt as nip44Decrypt, encrypt as nip44Encrypt } from "../src/crypto/nip44";

// @noble/hashes' randomBytes caps at 65,536 bytes per WebCrypto's quota.
// Node's crypto.randomBytes has no such cap and is what we use here for the
// multi-megabyte plaintext generators. Returns Uint8Array (Buffer subclass).
function randomBytes(n: number): Uint8Array {
  return new Uint8Array(nodeRandomBytes(n).buffer.slice(0, n));
}

function fixedKeypair(seedHex: string): { priv: Uint8Array; pub: string } {
  const priv = hexToBytes(seedHex);
  return { priv, pub: bytesToHex(schnorr.getPublicKey(priv)) };
}

// Three fixed identities so the multi-recipient case is reproducible.
const SENDER = fixedKeypair(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
);
const RECIPIENT_A = fixedKeypair(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
);
const ATTACKER = fixedKeypair(
  "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
);

describe("phase5 — ChaCha20-Poly1305 round-trip", () => {
  for (const [label, size] of [
    ["1 KB", 1024],
    ["1 MB", 1024 * 1024],
    ["20 MB", 20 * 1024 * 1024],
  ] as const) {
    it(`encrypts and decrypts ${label} cleanly`, () => {
      const fileKey = randomBytes(32);
      const nonce = randomBytes(12);
      const plaintext = randomBytes(size);

      const cipher = chacha20poly1305(fileKey, nonce);
      const ciphertext = cipher.encrypt(plaintext);
      // Poly1305 appends a 16-byte tag.
      expect(ciphertext.length).toBe(plaintext.length + 16);

      const decipher = chacha20poly1305(fileKey, nonce);
      const recovered = decipher.decrypt(ciphertext);
      expect(recovered.length).toBe(plaintext.length);
      // Byte-equality — Buffer.compare-style; avoids materializing a string.
      expect(recovered).toEqual(plaintext);
    });
  }

  it("rejects wrong key with AEAD failure (no silent corruption)", () => {
    const goodKey = randomBytes(32);
    const wrongKey = randomBytes(32);
    const nonce = randomBytes(12);
    const plaintext = randomBytes(1024);

    const ciphertext = chacha20poly1305(goodKey, nonce).encrypt(plaintext);
    expect(() =>
      chacha20poly1305(wrongKey, nonce).decrypt(ciphertext),
    ).toThrow(/invalid tag|Poly1305|MAC/i);
  });

  it("rejects tampered ciphertext (flipped byte) with AEAD failure", () => {
    const fileKey = randomBytes(32);
    const nonce = randomBytes(12);
    const plaintext = randomBytes(1024);
    const ciphertext = chacha20poly1305(fileKey, nonce).encrypt(plaintext);
    // Flip a byte in the middle of the ciphertext (not the tag) — Poly1305
    // MUST still catch it.
    ciphertext[100] = ciphertext[100]! ^ 0x01;
    expect(() =>
      chacha20poly1305(fileKey, nonce).decrypt(ciphertext),
    ).toThrow(/invalid tag|Poly1305|MAC/i);
  });
});

describe("phase5 — NIP-44 wrap of 32-byte file_key", () => {
  it("wraps and unwraps a 32-byte file_key byte-for-byte", () => {
    const fileKey = randomBytes(32);
    const wrappedB64 = nip44Encrypt(fileKey, SENDER.priv, RECIPIENT_A.pub);
    const unwrapped = nip44Decrypt(wrappedB64, RECIPIENT_A.priv, SENDER.pub);
    expect(unwrapped.length).toBe(32);
    expect(unwrapped).toEqual(fileKey);
  });

  it("wrong recipient priv cannot decrypt (MAC failure)", () => {
    const fileKey = randomBytes(32);
    const wrappedB64 = nip44Encrypt(fileKey, SENDER.priv, RECIPIENT_A.pub);
    expect(() =>
      nip44Decrypt(wrappedB64, ATTACKER.priv, SENDER.pub),
    ).toThrow(/MAC verification failed/);
  });

  it("each wrap uses a fresh nonce (no reuse across N recipients)", () => {
    const fileKey = randomBytes(32);
    const wraps = new Set<string>();
    for (let i = 0; i < 10; i++) {
      const wireB64 = nip44Encrypt(fileKey, SENDER.priv, RECIPIENT_A.pub);
      // Decode the wire and extract the 32-byte nonce (offset 1, length 32).
      const payload = base64.decode(wireB64);
      const nonce = payload.subarray(1, 33);
      wraps.add(bytesToHex(nonce));
    }
    // 10 calls, 10 distinct nonces — confirms the randomBytes() default path
    // inside nip44.encrypt() draws fresh entropy per call. If anyone refactors
    // toward a cached nonce this test trips.
    expect(wraps.size).toBe(10);
  });

  it("wire ciphertext size for a 32-byte plaintext is the documented ~150 B", () => {
    const fileKey = randomBytes(32);
    const wireB64 = nip44Encrypt(fileKey, SENDER.priv, RECIPIENT_A.pub);
    // Per NIP-44 v2:
    //   1 (version) + 32 (nonce) + 2 (length prefix) + 32 (padded plaintext bucket) + 32 (HMAC) = 99 bytes
    //   base64 of 99 bytes = ceil(99/3)*4 = 132 bytes
    // Audit doc Pass 3 §8 expects ~150-200 B; assert the actual measured size
    // is well under that envelope so the audit's headroom claim is grounded.
    const wireBytes = wireB64.length; // base64 char count == byte count for ASCII transport
    expect(wireBytes).toBeGreaterThan(120);
    expect(wireBytes).toBeLessThan(160);
  });
});
