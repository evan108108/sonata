// NIP-44 v2 + NIP-17 round-trip parity with the gateway's implementations.
//
// The plugin's nip44.ts and nip17.ts are copied verbatim from the gateway's
// gateway/src/lib/{nip44,nip17}.ts at build time (see build.sh §3.5). The
// tests below replicate the round-trip checks that the gateway test suite
// runs, using the same fixed-seed key pairs the gateway uses, so a build-
// time copy that silently corrupts either file fails immediately.
//
// Why not import gateway tests directly: they're written for vitest and
// pull in nostr-tools for cross-impl checks; the plugin runs under
// `bun test` and avoids that transitive dep. The compatibility check that
// matters end-to-end is "an event encrypted by the plugin decrypts on the
// gateway and vice-versa" — that's covered by both sides running the same
// source file.

import { describe, expect, it } from "bun:test";
import { schnorr } from "@noble/curves/secp256k1.js";
import { hexToBytes, bytesToHex } from "@noble/hashes/utils.js";
import {
  decrypt,
  decryptString,
  encrypt,
  encryptString,
  getConversationKey,
  isStructurallyValid,
} from "../src/crypto/nip44";
import {
  KIND_GIFT_WRAP,
  KIND_SEAL,
  __signEvent,
  unwrap,
  wrap,
  type NostrEvent,
} from "../src/crypto/nip17";

function fixedKeypair(seedHex: string): { priv: Uint8Array; pub: string } {
  const priv = hexToBytes(seedHex);
  return { priv, pub: bytesToHex(schnorr.getPublicKey(priv)) };
}

const SENDER = fixedKeypair(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
);
const RECIPIENT = fixedKeypair(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
);

describe("nip44 — round-trip", () => {
  it("getConversationKey is symmetric", () => {
    const ck1 = getConversationKey(SENDER.priv, RECIPIENT.pub);
    const ck2 = getConversationKey(RECIPIENT.priv, SENDER.pub);
    expect(bytesToHex(ck1)).toEqual(bytesToHex(ck2));
  });

  it("round-trips a short utf8 string", () => {
    const wire = encryptString("hello team-design", SENDER.priv, RECIPIENT.pub);
    expect(decryptString(wire, RECIPIENT.priv, SENDER.pub)).toEqual(
      "hello team-design",
    );
  });

  it("round-trips the raw 32-byte secp256k1 scalar (key-grant payload)", () => {
    // SPEC-v0.5 §2.2 — bare scalar, no JSON wrapper, no hex re-encoding.
    const epochPriv = hexToBytes(
      "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    );
    const wire = encrypt(epochPriv, SENDER.priv, RECIPIENT.pub);
    const got = decrypt(wire, RECIPIENT.priv, SENDER.pub);
    expect(bytesToHex(got)).toEqual(bytesToHex(epochPriv));
  });

  it("round-trips a 4096-byte plaintext", () => {
    const big = new Uint8Array(4096);
    for (let i = 0; i < big.length; i++) big[i] = i & 0xff;
    const wire = encrypt(big, SENDER.priv, RECIPIENT.pub);
    expect(bytesToHex(decrypt(wire, RECIPIENT.priv, SENDER.pub))).toEqual(
      bytesToHex(big),
    );
  });

  it("isStructurallyValid accepts our own ciphertext and rejects garbage", () => {
    const wire = encryptString("ok", SENDER.priv, RECIPIENT.pub);
    expect(isStructurallyValid(wire)).toBe(true);
    expect(isStructurallyValid("not-base64-!!!")).toBe(false);
    expect(isStructurallyValid("")).toBe(false);
  });

  it("rejects MAC tamper", () => {
    const wire = encryptString("payload", SENDER.priv, RECIPIENT.pub);
    // Flip a bit in the last MAC byte (after re-base64-decoding/encoding).
    const buf = Uint8Array.from(atob(wire), (c) => c.charCodeAt(0));
    buf[buf.length - 1]! ^= 0x01;
    const tampered = btoa(String.fromCharCode(...buf));
    expect(() => decryptString(tampered, RECIPIENT.priv, SENDER.pub)).toThrow();
  });
});

describe("nip17 — round-trip", () => {
  it("wrap+unwrap recovers the rumor and the publisher pubkey", () => {
    const rumor: NostrEvent = __signEvent(
      {
        pubkey: SENDER.pub,
        kind: 30530,
        created_at: 1777344600,
        tags: [
          ["d", "team-design-card-1"],
          ["fa:context", "https://4a4.ai/ns/v0"],
          ["alt", "Studio Card in team-design"],
          ["a", "30520:" + "00".repeat(32) + ":team-design"],
          ["fa:epoch", "1"],
          ["p", RECIPIENT.pub],
        ],
        content: "encrypted-card-ciphertext-stub",
      },
      SENDER.priv,
    );
    const giftWrap = wrap(rumor, SENDER.priv, RECIPIENT.pub);
    expect(giftWrap.kind).toBe(KIND_GIFT_WRAP);
    expect(giftWrap.tags).toEqual(expect.arrayContaining([["p", RECIPIENT.pub]]));

    const unwrapped = unwrap(giftWrap, RECIPIENT.priv);
    expect(unwrapped.publisherPub).toBe(SENDER.pub);
    expect(unwrapped.rumor.id).toBe(rumor.id);
    expect(unwrapped.rumor.kind).toBe(30530);
  });

  it("a wrap addressed to a different recipient fails to unwrap", () => {
    const stranger = fixedKeypair(
      "ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc1cc",
    );
    const rumor = __signEvent(
      {
        pubkey: SENDER.pub,
        kind: 30510,
        created_at: 1777344600,
        tags: [
          ["d", "x"],
          ["fa:context", "https://4a4.ai/ns/v0"],
          ["alt", "x"],
          ["a", "30520:" + "00".repeat(32) + ":x"],
          ["fa:epoch", "1"],
          ["p", RECIPIENT.pub],
        ],
        content: "ct",
      },
      SENDER.priv,
    );
    const giftWrap = wrap(rumor, SENDER.priv, RECIPIENT.pub);
    expect(() => unwrap(giftWrap, stranger.priv)).toThrow();
  });

  it("seal and gift-wrap use distinct ephemeral keys (privacy property)", () => {
    const rumor = __signEvent(
      {
        pubkey: SENDER.pub,
        kind: 30530,
        created_at: 1777344600,
        tags: [],
        content: "ct",
      },
      SENDER.priv,
    );
    const w1 = wrap(rumor, SENDER.priv, RECIPIENT.pub);
    const w2 = wrap(rumor, SENDER.priv, RECIPIENT.pub);
    // Each wrap uses a fresh ephemeral seal key, so even back-to-back wraps
    // of the same rumor have distinct gift-wrap pubkeys + ids.
    expect(w1.pubkey).not.toEqual(w2.pubkey);
    expect(w1.id).not.toEqual(w2.id);
    expect(w1.kind).toBe(KIND_GIFT_WRAP);
    expect(w2.kind).toBe(KIND_GIFT_WRAP);
  });

  it("KIND_SEAL and KIND_GIFT_WRAP match the spec constants", () => {
    expect(KIND_SEAL).toBe(13);
    expect(KIND_GIFT_WRAP).toBe(1059);
  });
});
