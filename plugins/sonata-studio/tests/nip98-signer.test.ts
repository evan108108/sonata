// Round-trip the NIP-98 signer against a re-implementation of the gateway's
// verifyNip98 logic. This is the parity check that protects against drift
// between sonata-studio and 4A — if either side changes the canonical event
// shape (tag order, payload-hash format, kind), this test fails before
// audiences silently break in production.
//
// Why replicate instead of import the gateway's verifier: the gateway lives
// in a sibling repo with its own deps tree; pulling it in transitively
// would entangle bun's test runner with @cloudflare/workers-types. The
// verify logic is small and the spec is fixed; replication is cheaper than
// a cross-repo import.

import { describe, expect, it } from "bun:test";
import { schnorr } from "@noble/curves/secp256k1.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { hexToBytes, bytesToHex } from "@noble/hashes/utils.js";
import { signNip98 } from "../src/crypto/nip98";

const NIP98_KIND = 27235;
const HEX64 = /^[0-9a-f]{64}$/;
const HEX128 = /^[0-9a-f]{128}$/;

interface Nip98Event {
  id: string;
  pubkey: string;
  created_at: number;
  kind: number;
  tags: string[][];
  content: string;
  sig: string;
}

function findTag(tags: string[][], name: string): string | undefined {
  for (const t of tags) if (t[0] === name) return t[1];
  return undefined;
}

function canonicalEventId(e: Nip98Event): string {
  const ser = JSON.stringify([0, e.pubkey, e.created_at, e.kind, e.tags, e.content]);
  return bytesToHex(sha256(new TextEncoder().encode(ser)));
}

interface VerifyResult {
  ok: boolean;
  reason?: string;
  pubkey?: string;
}

async function verifyAuthHeader(
  headerValue: string,
  url: string,
  method: string,
  body: Uint8Array | undefined,
): Promise<VerifyResult> {
  const m = /^Nostr\s+(\S+)\s*$/i.exec(headerValue);
  if (!m) return { ok: false, reason: "malformed_header" };
  let parsed: Nip98Event;
  try {
    parsed = JSON.parse(atob(m[1]!)) as Nip98Event;
  } catch {
    return { ok: false, reason: "malformed_event" };
  }
  if (parsed.kind !== NIP98_KIND) return { ok: false, reason: "wrong_kind" };
  if (!HEX64.test(parsed.id) || !HEX64.test(parsed.pubkey) || !HEX128.test(parsed.sig)) {
    return { ok: false, reason: "malformed_event" };
  }

  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - parsed.created_at) > 60) {
    return { ok: false, reason: "stale" };
  }

  const uTag = findTag(parsed.tags, "u");
  const methodTag = findTag(parsed.tags, "method");
  if (uTag === undefined || methodTag === undefined) {
    return { ok: false, reason: "missing_required_tag" };
  }
  if (methodTag.toUpperCase() !== method.toUpperCase()) {
    return { ok: false, reason: "method_mismatch" };
  }
  if (new URL(uTag).toString() !== new URL(url).toString()) {
    return { ok: false, reason: "url_mismatch" };
  }

  if (body !== undefined) {
    const payloadTag = findTag(parsed.tags, "payload");
    if (payloadTag === undefined) {
      return { ok: false, reason: "missing_payload_tag" };
    }
    const want = bytesToHex(sha256(body));
    if (want !== payloadTag.toLowerCase()) {
      return { ok: false, reason: "payload_hash_mismatch" };
    }
  }

  if (canonicalEventId(parsed) !== parsed.id) {
    return { ok: false, reason: "id_mismatch" };
  }
  let sigOk = false;
  try {
    sigOk = schnorr.verify(
      hexToBytes(parsed.sig),
      hexToBytes(parsed.id),
      hexToBytes(parsed.pubkey),
    );
  } catch {
    sigOk = false;
  }
  if (!sigOk) return { ok: false, reason: "bad_signature" };
  return { ok: true, pubkey: parsed.pubkey };
}

const PRIV = hexToBytes(
  "1111111111111111111111111111111111111111111111111111111111111111",
);
const PUB = bytesToHex(schnorr.getPublicKey(PRIV));

describe("signNip98 — round-trip with gateway verifier shape", () => {
  it("GET request without body verifies under the gateway's expected shape", async () => {
    const url = "https://api.4a4.ai/v0/audience/team-design/stream?aud_id_pub=" + "a".repeat(64);
    const auth = await signNip98({ url, method: "GET", pluginPriv: PRIV });
    const result = await verifyAuthHeader(auth, url, "GET", undefined);
    expect(result.ok).toBe(true);
    expect(result.pubkey).toBe(PUB);
  });

  it("POST request with body includes payload hash and verifies", async () => {
    const url = "https://api.4a4.ai/v0/audience/raw/create";
    const body = new TextEncoder().encode(JSON.stringify({ slug: "team-design" }));
    const auth = await signNip98({
      url,
      method: "POST",
      body,
      pluginPriv: PRIV,
    });
    const result = await verifyAuthHeader(auth, url, "POST", body);
    expect(result.ok).toBe(true);
    expect(result.pubkey).toBe(PUB);
  });

  it("uppercases lowercased methods", async () => {
    const url = "https://api.4a4.ai/v0/x";
    const auth = await signNip98({ url, method: "post", pluginPriv: PRIV });
    const result = await verifyAuthHeader(auth, url, "POST", undefined);
    expect(result.ok).toBe(true);
  });

  it("verification fails when the verifier sees a different body than was signed", async () => {
    const url = "https://api.4a4.ai/v0/x";
    const signedBody = new TextEncoder().encode("original");
    const auth = await signNip98({
      url,
      method: "POST",
      body: signedBody,
      pluginPriv: PRIV,
    });
    const tamperedBody = new TextEncoder().encode("tampered");
    const result = await verifyAuthHeader(auth, url, "POST", tamperedBody);
    expect(result.ok).toBe(false);
    expect(result.reason).toBe("payload_hash_mismatch");
  });

  it("verification fails when URL doesn't match", async () => {
    const url = "https://api.4a4.ai/v0/x";
    const auth = await signNip98({ url, method: "GET", pluginPriv: PRIV });
    const result = await verifyAuthHeader(
      auth,
      "https://api.4a4.ai/v0/y",
      "GET",
      undefined,
    );
    expect(result.ok).toBe(false);
    expect(result.reason).toBe("url_mismatch");
  });

  it("verification fails when method doesn't match", async () => {
    const url = "https://api.4a4.ai/v0/x";
    const auth = await signNip98({ url, method: "GET", pluginPriv: PRIV });
    const result = await verifyAuthHeader(auth, url, "POST", undefined);
    expect(result.ok).toBe(false);
    expect(result.reason).toBe("method_mismatch");
  });

  it("rejects pluginPriv that is not 32 bytes", () => {
    expect(() =>
      signNip98({
        url: "https://api.4a4.ai/v0/x",
        method: "GET",
        pluginPriv: new Uint8Array(31),
      }),
    ).toThrow();
  });
});
