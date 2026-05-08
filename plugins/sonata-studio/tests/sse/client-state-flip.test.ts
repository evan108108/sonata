// SSEClient — pending-grant → active state flip on first key-grant.
// Phase 3 §1 Gap 3 + §7 Pass B8.
//
// The flip happens in handleKeyGrant after the new epoch priv is persisted.
// It MUST:
//   - flip a room currently at state="pending-grant" to "active"
//   - leave a room already "active" alone (idempotent)
//   - leave any other state ("left", custom operator state) untouched

import { describe, expect, test } from "bun:test";
import { schnorr } from "@noble/curves/secp256k1.js";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils.js";
import { GatewayClient } from "../../src/a4-client";
import { encrypt } from "../../src/crypto/nip44";
import { __signEvent, type NostrEvent } from "../../src/crypto/nip17";
import { SSEClient } from "../../src/sse/client";
import { FakeSSEMemory, sseResponse, type SSEEvent } from "./fakes";

const SEED_PLUGIN = "11".repeat(32);
const SEED_AUDIENCE = "33".repeat(32);
const SEED_EPOCH1 = "44".repeat(32);

const PLUGIN_PRIV = hexToBytes(SEED_PLUGIN);
const PLUGIN_PUB = bytesToHex(schnorr.getPublicKey(PLUGIN_PRIV));
const AUD_PRIV = hexToBytes(SEED_AUDIENCE);
const AUD_PUB = bytesToHex(schnorr.getPublicKey(AUD_PRIV));
const EPOCH1_PRIV = hexToBytes(SEED_EPOCH1);

const ROOM_SLUG = "flip-room";
const AUDIENCE_ADDR = `30520:${AUD_PUB}:${ROOM_SLUG}`;

function buildKeyGrant(epoch: number, epochPriv: Uint8Array): NostrEvent {
  const ciphertext = encrypt(epochPriv, AUD_PRIV, PLUGIN_PUB);
  return __signEvent(
    {
      pubkey: AUD_PUB,
      created_at: Math.floor(Date.now() / 1000),
      kind: 30521,
      tags: [
        ["d", `${ROOM_SLUG}:${epoch}:${PLUGIN_PUB}`],
        ["fa:epoch", String(epoch)],
        ["p", PLUGIN_PUB],
        ["a", AUDIENCE_ADDR],
      ],
      content: ciphertext,
    },
    AUD_PRIV,
  );
}

function helloEvent(epoch: number): SSEEvent {
  return {
    event: "hello",
    data: { audience_slug: ROOM_SLUG, epoch, server_ts_ms: Date.now() },
  };
}

function keyGrantEvent(grant: NostrEvent, receivedAtMs: number): SSEEvent {
  return {
    event: "key-grant",
    id: grant.id,
    data: { grant_event: grant, received_at_ms: receivedAtMs },
  };
}

function makeMemory(state: string): FakeSSEMemory {
  const mem = new FakeSSEMemory();
  mem.upsertRoom(ROOM_SLUG, {
    aud_id_pub_hex: AUD_PUB,
    aud_id_priv_secret_name: null,
    epoch_keys_secret_name: `studio:room:${ROOM_SLUG}:epoch_keys`,
    current_epoch: 1,
    members: [PLUGIN_PUB],
    last_seen_wrap_at_ms: 0,
    state,
  });
  return mem;
}

function makeGateway(fetcher: typeof fetch): GatewayClient {
  return new GatewayClient(
    { pluginPriv: PLUGIN_PRIV, gatewayBaseUrl: "https://api.4a4.ai" },
    { fetcher, retryDelaysMs: [0, 0, 0, 0] },
  );
}

async function runOneGrant(mem: FakeSSEMemory): Promise<void> {
  const grant = buildKeyGrant(2, EPOCH1_PRIV);
  const fetcher: typeof fetch = async () =>
    sseResponse([helloEvent(1), keyGrantEvent(grant, 100)]);
  const client = new SSEClient(
    ROOM_SLUG,
    PLUGIN_PRIV,
    makeGateway(fetcher),
    mem.asClient(),
    {
      project: async () => {},
      cursorDebounceMs: 1,
      backoff: () => 0,
      reconnect: false,
    },
  );
  await client.run();
}

describe("SSEClient — state flip on key-grant", () => {
  test("flips pending-grant → active on first key-grant", async () => {
    const mem = makeMemory("pending-grant");
    await runOneGrant(mem);
    const attrs = mem.attrs(ROOM_SLUG);
    expect(attrs?.["state"]).toBe("active");
    // Sanity — the patch carrying state:"active" was emitted.
    expect(mem.patchCalls.some((p) => p.attributes["state"] === "active")).toBe(true);
  });

  test("leaves active rooms alone (no spurious state patch)", async () => {
    const mem = makeMemory("active");
    await runOneGrant(mem);
    const attrs = mem.attrs(ROOM_SLUG);
    expect(attrs?.["state"]).toBe("active");
    // No patch should have included state — only current_epoch.
    expect(mem.patchCalls.every((p) => !("state" in p.attributes))).toBe(true);
  });

  test("does not promote rooms in 'left' or other custom states", async () => {
    const mem = makeMemory("left");
    await runOneGrant(mem);
    const attrs = mem.attrs(ROOM_SLUG);
    expect(attrs?.["state"]).toBe("left");
    expect(mem.patchCalls.every((p) => !("state" in p.attributes))).toBe(true);
  });
});

describe("SSEClient — pending-grant first-connect since_ts", () => {
  test("first connect for a pending-grant room asks for a 60s replay window", async () => {
    const mem = makeMemory("pending-grant");
    // joined_at_ms recent but before now-60s; we expect since_ts ≈ joinedSec - 60.
    const joinedAt = Date.now();
    mem.upsertRoom(ROOM_SLUG, { joined_at_ms: joinedAt });
    const calls: string[] = [];
    const fetcher: typeof fetch = async (input) => {
      const url = typeof input === "string" ? input : (input as Request).url;
      calls.push(url);
      // Return an empty stream so the client's run loop terminates promptly.
      return sseResponse([helloEvent(1)]);
    };
    const client = new SSEClient(
      ROOM_SLUG,
      PLUGIN_PRIV,
      makeGateway(fetcher),
      mem.asClient(),
      {
        project: async () => {},
        cursorDebounceMs: 1,
        backoff: () => 0,
        reconnect: false,
      },
    );
    await client.run();
    expect(calls.length).toBeGreaterThanOrEqual(1);
    const url = calls[0]!;
    const since = new URL(url).searchParams.get("since_ts");
    expect(since).not.toBeNull();
    const sinceN = Number(since);
    const joinedSec = Math.floor(joinedAt / 1000);
    // Allow 1s of skew on either side to handle fractional second boundaries.
    expect(sinceN).toBeGreaterThanOrEqual(joinedSec - 61);
    expect(sinceN).toBeLessThanOrEqual(joinedSec - 59);
  });

  test("first connect for an active room with no cursor omits since_ts", async () => {
    const mem = makeMemory("active");
    const calls: string[] = [];
    const fetcher: typeof fetch = async (input) => {
      const url = typeof input === "string" ? input : (input as Request).url;
      calls.push(url);
      return sseResponse([helloEvent(1)]);
    };
    const client = new SSEClient(
      ROOM_SLUG,
      PLUGIN_PRIV,
      makeGateway(fetcher),
      mem.asClient(),
      {
        project: async () => {},
        cursorDebounceMs: 1,
        backoff: () => 0,
        reconnect: false,
      },
    );
    await client.run();
    expect(calls[0]!).not.toContain("since_ts=");
  });
});
