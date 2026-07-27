// Hook-branch unwrap round-trip. Builds wraps EXACTLY like the gateway's
// webhook-receiver: throwaway 32-byte signer for rumor + seal, ephemeral
// wrap key, `["fa:hook", slug]` + `["p", recipient]` tags on the rumor,
// JSON content carrying base64 body bytes.

import { describe, expect, test } from "bun:test";
import { schnorr, secp256k1 } from "@noble/curves/secp256k1.js";
import { hmac } from "@noble/hashes/hmac.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex, randomBytes } from "@noble/hashes/utils.js";
import { __signEvent, wrap, type NostrEvent } from "../src/crypto/nip17";
import { hookSlug, unwrapHook } from "../src/crypto/unwrap-hook";

const KIND_HOOK_RUMOR = 1069;

function makeRecipient(): { priv: Uint8Array; pub: string } {
  const priv = secp256k1.utils.randomSecretKey();
  return { priv, pub: bytesToHex(schnorr.getPublicKey(priv)) };
}

function makeHookWrap(args: {
  recipientPub: string;
  slug: string;
  bodyBytes: Uint8Array;
  headers?: Record<string, string>;
}): { wrapEvent: NostrEvent; rumor: NostrEvent } {
  const throwawayPriv = randomBytes(32);
  const throwawayPub = bytesToHex(schnorr.getPublicKey(throwawayPriv));
  const content = JSON.stringify({
    received_at_ms: 1_753_000_000_000,
    source_ip: "203.0.113.7",
    headers: args.headers ?? { "content-type": "application/json" },
    body_b64: Buffer.from(args.bodyBytes).toString("base64"),
    slug: args.slug,
  });
  const rumor = __signEvent(
    {
      pubkey: throwawayPub,
      created_at: Math.floor(Date.now() / 1000),
      kind: KIND_HOOK_RUMOR,
      tags: [
        ["fa:hook", args.slug],
        ["p", args.recipientPub],
      ],
      content,
    },
    throwawayPriv,
  );
  return { wrapEvent: wrap(rumor, throwawayPriv, args.recipientPub), rumor };
}

describe("unwrapHook", () => {
  test("round-trips a gateway-shaped hook wrap", () => {
    const recipient = makeRecipient();
    const { wrapEvent, rumor } = makeHookWrap({
      recipientPub: recipient.pub,
      slug: "agentmail",
      bodyBytes: new TextEncoder().encode('{"event":"message.received"}'),
    });

    const unwrapped = unwrapHook(wrapEvent, recipient.priv);
    expect(unwrapped.id).toBe(rumor.id);
    expect(unwrapped.kind).toBe(KIND_HOOK_RUMOR);
    expect(hookSlug(unwrapped)).toBe("agentmail");
  });

  test("preserves body bytes exactly — third-party HMAC still verifies", () => {
    // End-to-end byte-preservation gate from the plan: HMAC computed over
    // the original raw bytes must verify against the base64-decoded body
    // after wrap → unwrap. Any re-serialization in between breaks this.
    const recipient = makeRecipient();
    const secret = new TextEncoder().encode("whsec_test");
    const rawBody = randomBytes(1024); // arbitrary bytes, not valid UTF-8
    const expectedMac = bytesToHex(hmac(sha256, secret, rawBody));

    const { wrapEvent } = makeHookWrap({
      recipientPub: recipient.pub,
      slug: "stripe",
      bodyBytes: rawBody,
      headers: { "stripe-signature": expectedMac },
    });

    const rumor = unwrapHook(wrapEvent, recipient.priv);
    const content = JSON.parse(rumor.content) as { body_b64: string; headers: Record<string, string> };
    const decoded = new Uint8Array(Buffer.from(content.body_b64, "base64"));
    expect(bytesToHex(hmac(sha256, secret, decoded))).toBe(content.headers["stripe-signature"]);
  });

  test("rejects a wrap addressed to someone else", () => {
    const recipient = makeRecipient();
    const other = makeRecipient();
    const { wrapEvent } = makeHookWrap({
      recipientPub: other.pub,
      slug: "agentmail",
      bodyBytes: new Uint8Array([1, 2, 3]),
    });
    expect(() => unwrapHook(wrapEvent, recipient.priv)).toThrow();
  });

  test("rejects a rumor whose id does not match its content", () => {
    const recipient = makeRecipient();
    const { wrapEvent, rumor } = makeHookWrap({
      recipientPub: recipient.pub,
      slug: "agentmail",
      bodyBytes: new Uint8Array([1]),
    });
    // Re-wrap a tampered rumor (id kept from the original).
    const throwawayPriv = randomBytes(32);
    const tampered = { ...rumor, content: rumor.content + " " };
    const evil = wrap(tampered, throwawayPriv, recipient.pub);
    expect(() => unwrapHook(evil, recipient.priv)).toThrow(/recomputed event hash/);
    void wrapEvent;
  });

  test("hookSlug returns null when the tag is absent", () => {
    const recipient = makeRecipient();
    const throwawayPriv = randomBytes(32);
    const rumor = __signEvent(
      {
        pubkey: bytesToHex(schnorr.getPublicKey(throwawayPriv)),
        created_at: Math.floor(Date.now() / 1000),
        kind: KIND_HOOK_RUMOR,
        tags: [["p", recipient.pub]],
        content: "{}",
      },
      throwawayPriv,
    );
    const wrapped = wrap(rumor, throwawayPriv, recipient.pub);
    const unwrapped = unwrapHook(wrapped, recipient.priv);
    expect(hookSlug(unwrapped)).toBeNull();
  });
});
