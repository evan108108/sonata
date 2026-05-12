// SSEClient — happy-path delivery, reconnect with cursor, key-grant draining,
// and dedup window. All gift-wraps are real round-trips through the plugin's
// own nip17 + nip44 modules so the test exercises the full unwrap+decrypt
// path, not just the stream parser.

import { describe, expect, test } from "bun:test";
import { schnorr } from "@noble/curves/secp256k1.js";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils.js";
import { GatewayClient } from "../../src/a4-client";
import { encrypt, encryptString } from "../../src/crypto/nip44";
import {
  __signEvent,
  wrap as nip17Wrap,
  type NostrEvent,
} from "../../src/crypto/nip17";
import { SSEClient } from "../../src/sse/client";
import type { StudioRumor } from "../../src/projection/types";
import { FakeSSEMemory, sseResponse, type SSEEvent } from "./fakes";

const SEED_PLUGIN = "11".repeat(32);
const SEED_PUBLISHER = "22".repeat(32);
const SEED_AUDIENCE = "33".repeat(32);
const SEED_EPOCH1 = "44".repeat(32);
const SEED_EPOCH2 = "55".repeat(32);

const PLUGIN_PRIV = hexToBytes(SEED_PLUGIN);
const PLUGIN_PUB = bytesToHex(schnorr.getPublicKey(PLUGIN_PRIV));
const PUBLISHER_PRIV = hexToBytes(SEED_PUBLISHER);
const PUBLISHER_PUB = bytesToHex(schnorr.getPublicKey(PUBLISHER_PRIV));
const AUD_PRIV = hexToBytes(SEED_AUDIENCE);
const AUD_PUB = bytesToHex(schnorr.getPublicKey(AUD_PRIV));
const EPOCH1_PRIV = hexToBytes(SEED_EPOCH1);
const EPOCH1_PUB = bytesToHex(schnorr.getPublicKey(EPOCH1_PRIV));
const EPOCH2_PRIV = hexToBytes(SEED_EPOCH2);

const ROOM_SLUG = "test-room";
const AUDIENCE_ADDR = `30520:${AUD_PUB}:${ROOM_SLUG}`;

function cardPayload(title: string): Record<string, unknown> {
  return {
    "@context": "https://sonata.4a4.ai/ns/studio-v0",
    "@type": "Card",
    createdBy: PUBLISHER_PUB,
    kind: "note",
    track: "inbox",
    title,
    summary: `summary for ${title}`,
    blocks: [{ type: "text", body: "body" }],
  };
}

function buildGiftWrap(opts: {
  title?: string;
  epoch?: number;
  epochPub?: string;
  publisherPriv?: Uint8Array;
  publisherPub?: string;
  dTag?: string;
  createdAt?: number;
}): NostrEvent {
  const epoch = opts.epoch ?? 1;
  const epochPub = opts.epochPub ?? EPOCH1_PUB;
  const publisherPriv = opts.publisherPriv ?? PUBLISHER_PRIV;
  const publisherPub = opts.publisherPub ?? PUBLISHER_PUB;
  const dTag = opts.dTag ?? `card-${Math.random().toString(36).slice(2, 8)}`;
  const ciphertext = encryptString(
    JSON.stringify(cardPayload(opts.title ?? "hello")),
    publisherPriv,
    epochPub,
  );
  const rumor = __signEvent(
    {
      pubkey: publisherPub,
      created_at: opts.createdAt ?? Math.floor(Date.now() / 1000),
      kind: 30530,
      tags: [
        ["d", dTag],
        ["fa:context", "https://4a4.ai/ns/v0"],
        ["alt", "Studio v0 card"],
        ["a", AUDIENCE_ADDR],
        ["fa:epoch", String(epoch)],
        ["p", PLUGIN_PUB],
        ["blake3", "stub"],
      ],
      content: ciphertext,
    },
    publisherPriv,
  );
  return nip17Wrap(rumor, publisherPriv, PLUGIN_PUB);
}

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

function giftWrapEvent(wrap: NostrEvent, receivedAtMs: number): SSEEvent {
  return {
    event: "gift-wrap",
    id: wrap.id,
    data: { wrap_event: wrap, received_at_ms: receivedAtMs },
  };
}

function keyGrantEvent(grant: NostrEvent, receivedAtMs: number): SSEEvent {
  return {
    event: "key-grant",
    id: grant.id,
    data: { grant_event: grant, received_at_ms: receivedAtMs },
  };
}

function makeMemoryWithRoom(opts?: {
  cursor?: number;
  withEpoch1Key?: boolean;
}): FakeSSEMemory {
  const mem = new FakeSSEMemory();
  const epochSecretName = `studio:room:${ROOM_SLUG}:epoch_keys`;
  mem.upsertRoom(ROOM_SLUG, {
    aud_id_pub_hex: AUD_PUB,
    aud_id_priv_secret_name: `studio:room:${ROOM_SLUG}:aud_id_priv`,
    epoch_keys_secret_name: epochSecretName,
    current_epoch: opts?.withEpoch1Key ? 1 : 0,
    members: [PLUGIN_PUB, PUBLISHER_PUB],
    last_seen_wrap_at_ms: opts?.cursor ?? 0,
    state: opts?.withEpoch1Key ? "active" : "pending-grant",
  });
  if (opts?.withEpoch1Key) {
    mem.setSecret(
      epochSecretName,
      JSON.stringify({ "1": bytesToHex(EPOCH1_PRIV) }),
    );
  }
  return mem;
}

function makeGateway(
  fetcher: typeof fetch,
): GatewayClient {
  return new GatewayClient(
    { pluginPriv: PLUGIN_PRIV, gatewayBaseUrl: "https://api.4a4.ai" },
    { fetcher, retryDelaysMs: [0, 0, 0, 0] },
  );
}

// ─── tests ────────────────────────────────────────────────────────────────────

describe("SSEClient — happy path", () => {
  test("delivers 5 gift-wraps to the projector", async () => {
    const mem = makeMemoryWithRoom({ withEpoch1Key: true });
    const events: SSEEvent[] = [helloEvent(1)];
    for (let i = 0; i < 5; i++) {
      events.push(
        giftWrapEvent(
          buildGiftWrap({ title: `card-${i}`, dTag: `d-${i}` }),
          1_000 + i,
        ),
      );
    }
    const fetcher: typeof fetch = async () => sseResponse(events);
    const projected: Array<Record<string, unknown>> = [];
    const client = new SSEClient(
      ROOM_SLUG,
      PLUGIN_PRIV,
      makeGateway(fetcher),
      mem.asClient(),
      {
        project: async (_rumor, payload) => {
          projected.push(payload);
        },
        cursorDebounceMs: 1,
        backoff: () => 0,
        reconnect: false,
      },
    );
    await client.run();
    expect(projected).toHaveLength(5);
    expect(projected.map((p) => p["title"])).toEqual([
      "card-0",
      "card-1",
      "card-2",
      "card-3",
      "card-4",
    ]);
  });
});

describe("SSEClient — reconnect with cursor", () => {
  test("second connect uses since_ts from latest received_at_ms", async () => {
    const mem = makeMemoryWithRoom({ withEpoch1Key: true });
    const wrap1 = buildGiftWrap({ title: "first", dTag: "d-1" });
    const wrap2 = buildGiftWrap({ title: "second", dTag: "d-2" });

    const calls: string[] = [];
    let callCount = 0;
    const fetcher: typeof fetch = async (input) => {
      const url = typeof input === "string" ? input : (input as Request).url;
      calls.push(url);
      callCount++;
      if (callCount === 1) {
        return sseResponse([helloEvent(1), giftWrapEvent(wrap1, 5_000)]);
      }
      return sseResponse([helloEvent(1), giftWrapEvent(wrap2, 7_000)]);
    };

    const projected: Array<Record<string, unknown>> = [];
    let clientRef: SSEClient | null = null;
    const client: SSEClient = new SSEClient(
      ROOM_SLUG,
      PLUGIN_PRIV,
      makeGateway(fetcher),
      mem.asClient(),
      {
        project: async (_r, p) => {
          projected.push(p);
          if (projected.length === 2) clientRef?.abort();
        },
        cursorDebounceMs: 1,
        backoff: () => 5,
      },
    );
    clientRef = client;
    await client.run();

    expect(projected).toHaveLength(2);
    expect(calls.length).toBeGreaterThanOrEqual(2);
    expect(calls[0]).not.toContain("since_ts=");
    expect(calls[1]!).toContain("since_ts=5000");
  });
});

describe("SSEClient — key-grant + pending drain", () => {
  test("queues gift-wraps for unknown epoch and drains on key-grant", async () => {
    // Pending-grant room: no epoch keys yet.
    const mem = makeMemoryWithRoom({ withEpoch1Key: false });
    const wrap = buildGiftWrap({ title: "deferred", dTag: "d-defer" });
    const grant = buildKeyGrant(1, EPOCH1_PRIV);
    const fetcher: typeof fetch = async () =>
      sseResponse([
        helloEvent(1),
        giftWrapEvent(wrap, 100),
        keyGrantEvent(grant, 200),
      ]);

    const projected: Array<Record<string, unknown>> = [];
    const client = new SSEClient(
      ROOM_SLUG,
      PLUGIN_PRIV,
      makeGateway(fetcher),
      mem.asClient(),
      {
        project: async (_r, p) => {
          projected.push(p);
        },
        cursorDebounceMs: 1,
        backoff: () => 0,
        reconnect: false,
      },
    );
    await client.run();

    expect(projected).toHaveLength(1);
    expect(projected[0]!["title"]).toBe("deferred");
    expect(client.epochKeyCount()).toBe(1);
    expect(client.pendingDepth(1)).toBe(0);

    // Epoch keys persisted to the secret store.
    const stored = mem.getSecret(`studio:room:${ROOM_SLUG}:epoch_keys`);
    expect(stored).toBeDefined();
    const parsed = JSON.parse(stored!) as Record<string, string>;
    expect(parsed["1"]).toBe(bytesToHex(EPOCH1_PRIV));
  });

  test("key-grant for a fresh epoch updates current_epoch", async () => {
    const mem = makeMemoryWithRoom({ withEpoch1Key: true });
    const grant = buildKeyGrant(2, EPOCH2_PRIV);
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
    expect(client.epochKeyCount()).toBe(2);
    const attrs = mem.attrs(ROOM_SLUG);
    expect(attrs?.["current_epoch"]).toBe(2);
  });
});

describe("SSEClient — dedup window", () => {
  test("drops a gift-wrap whose id was seen within the last 5s", async () => {
    const mem = makeMemoryWithRoom({ withEpoch1Key: true });
    const wrap1 = buildGiftWrap({ title: "alpha", dTag: "d-alpha" });
    const wrap2 = buildGiftWrap({ title: "beta", dTag: "d-beta" });
    const fetcher: typeof fetch = async () =>
      sseResponse([
        helloEvent(1),
        giftWrapEvent(wrap1, 100),
        giftWrapEvent(wrap1, 100), // duplicate id, same timestamp
        giftWrapEvent(wrap2, 200),
      ]);

    const projected: Array<Record<string, unknown>> = [];
    const client = new SSEClient(
      ROOM_SLUG,
      PLUGIN_PRIV,
      makeGateway(fetcher),
      mem.asClient(),
      {
        project: async (_r, p) => {
          projected.push(p);
        },
        cursorDebounceMs: 1,
        backoff: () => 0,
        reconnect: false,
      },
    );
    await client.run();
    expect(projected.map((p) => p["title"])).toEqual(["alpha", "beta"]);
  });
});

describe("SSEClient — pre-admit 403 reconnect", () => {
  test("after 403 not-a-member, second connect uses since_ts within last 60s", async () => {
    // Active room with cursor=0 isolates the new flag from the existing
    // pending-grant lookback path — no other branch produces since_ts here.
    const mem = makeMemoryWithRoom({ withEpoch1Key: true });
    const calls: string[] = [];
    let callCount = 0;
    let clientRef: SSEClient | null = null;
    const fetcher: typeof fetch = async (input) => {
      const url = typeof input === "string" ? input : (input as Request).url;
      calls.push(url);
      callCount++;
      if (callCount === 1) {
        return new Response(
          JSON.stringify({
            error: "forbidden",
            message: "caller is not a current member of the audience",
          }),
          { status: 403, headers: { "content-type": "application/json" } },
        );
      }
      // Second call: abort synchronously before returning so the run loop
      // exits after consuming this one (hello-only) stream. Sync abort
      // beats the next openStream — setTimeout would never fire in the
      // tight microtask loop here.
      clientRef?.abort();
      return sseResponse([helloEvent(1)]);
    };

    const tBefore = Date.now();
    const client = new SSEClient(
      ROOM_SLUG,
      PLUGIN_PRIV,
      makeGateway(fetcher),
      mem.asClient(),
      {
        project: async () => {},
        cursorDebounceMs: 1,
        backoff: () => 0,
        reconnect: true,
      },
    );
    clientRef = client;
    await client.run();
    const tAfter = Date.now();

    expect(calls.length).toBeGreaterThanOrEqual(2);
    // First connect: cursor=0, active room, no flag — no since_ts.
    expect(calls[0]).not.toContain("since_ts=");
    // Second connect: pre-admit flag is set, since_ts ≈ Date.now() - 60_000 (ms).
    const m = calls[1]!.match(/since_ts=(\d+)/);
    expect(m).not.toBeNull();
    const sinceTs = Number(m![1]);
    expect(sinceTs).toBeGreaterThanOrEqual(tBefore - 60_000);
    expect(sinceTs).toBeLessThanOrEqual(tAfter);
    // And is plainly within the last 60s of wall clock at end of run.
    expect(tAfter - sinceTs).toBeLessThanOrEqual(60_000 + 1_000);
  });

  test("flag clears after first successful connect", async () => {
    const mem = makeMemoryWithRoom({ withEpoch1Key: true });
    const calls: string[] = [];
    let callCount = 0;
    let clientRef: SSEClient | null = null;
    const fetcher: typeof fetch = async (input) => {
      const url = typeof input === "string" ? input : (input as Request).url;
      calls.push(url);
      callCount++;
      if (callCount === 1) {
        // Pre-admit 403 → arms the flag.
        return new Response(
          JSON.stringify({
            error: "forbidden",
            message: "caller is not a current member of the audience",
          }),
          { status: 403, headers: { "content-type": "application/json" } },
        );
      }
      if (callCount === 2) {
        // Successful connect — close immediately so we drop into a third
        // reconnect attempt where the flag should already be cleared.
        return sseResponse([helloEvent(1)]);
      }
      // Third call: flag should be cleared, so no since_ts override.
      // Sync abort ends the loop after this iteration.
      clientRef?.abort();
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
        reconnect: true,
      },
    );
    clientRef = client;
    await client.run();

    expect(calls.length).toBeGreaterThanOrEqual(3);
    expect(calls[1]!).toContain("since_ts=");
    // Third call (post-success): no since_ts override, cursor still 0.
    expect(calls[2]!).not.toContain("since_ts=");
  });
});

describe("SSEClient — declaration-updated", () => {
  test("patches members + current_epoch from the declaration event", async () => {
    const mem = makeMemoryWithRoom({ withEpoch1Key: true });
    const newMember = "ab".repeat(32);
    const decl: NostrEvent = __signEvent(
      {
        pubkey: AUD_PUB,
        created_at: Math.floor(Date.now() / 1000),
        kind: 30520,
        tags: [
          ["d", ROOM_SLUG],
          ["fa:epoch", "2"],
          ["p", PLUGIN_PUB],
          ["p", PUBLISHER_PUB],
          ["p", newMember],
        ],
        content: "",
      },
      AUD_PRIV,
    );
    const fetcher: typeof fetch = async () =>
      sseResponse([
        helloEvent(2),
        {
          event: "declaration-updated",
          data: { declaration_event: decl, received_at_ms: 100 },
        },
      ]);

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
    const attrs = mem.attrs(ROOM_SLUG);
    expect(attrs?.["current_epoch"]).toBe(2);
    const members = attrs?.["members"] as string[];
    expect(members).toContain(PLUGIN_PUB);
    expect(members).toContain(PUBLISHER_PUB);
    expect(members).toContain(newMember);
    expect(members).toHaveLength(3);
  });
});
