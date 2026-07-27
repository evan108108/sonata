// InboxSubscriber behavior: NIP-98-authenticated connect, forward-on-hook,
// cursor semantics (advance on 2xx / garbage, hold on refusal).

import { describe, expect, test } from "bun:test";
import { schnorr, secp256k1 } from "@noble/curves/secp256k1.js";
import { bytesToHex, randomBytes } from "@noble/hashes/utils.js";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { __signEvent, wrap, type NostrEvent } from "../src/crypto/nip17";
import { Cursor } from "../src/cursor";
import type { DeliverResult, Forwarder, HookDelivery } from "../src/forwarder";
import { InboxSubscriber } from "../src/subscriber";

const GATEWAY = "https://api.4a4.ai";

function makeIdentity(): { priv: Uint8Array; pub: string } {
  const priv = secp256k1.utils.randomSecretKey();
  return { priv, pub: bytesToHex(schnorr.getPublicKey(priv)) };
}

function makeHookWrap(recipientPub: string, slug: string, bodyB64 = "aGk="): NostrEvent {
  const throwawayPriv = randomBytes(32);
  const rumor = __signEvent(
    {
      pubkey: bytesToHex(schnorr.getPublicKey(throwawayPriv)),
      created_at: Math.floor(Date.now() / 1000),
      kind: 1069,
      tags: [
        ["fa:hook", slug],
        ["p", recipientPub],
      ],
      content: JSON.stringify({
        received_at_ms: 1_753_000_000_000,
        source_ip: "203.0.113.7",
        headers: { "content-type": "application/json" },
        body_b64: bodyB64,
        slug,
      }),
    },
    throwawayPriv,
  );
  return wrap(rumor, throwawayPriv, recipientPub);
}

function sseBody(frames: { event: string; data: unknown }[]): ReadableStream<Uint8Array> {
  const text = frames
    .map((f) => `event: ${f.event}\ndata: ${JSON.stringify(f.data)}\n\n`)
    .join("");
  return new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode(text));
      controller.close();
    },
  });
}

interface RecordedRequest {
  url: string;
  headers: Record<string, string>;
}

function streamFetcher(
  frames: { event: string; data: unknown }[],
  recorded: RecordedRequest[],
): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    const headers: Record<string, string> = {};
    for (const [k, v] of Object.entries((init?.headers as Record<string, string>) ?? {})) {
      headers[k.toLowerCase()] = v;
    }
    recorded.push({ url, headers });
    return new Response(sseBody(frames), {
      status: 200,
      headers: { "Content-Type": "text/event-stream" },
    });
  }) as typeof fetch;
}

class FakeForwarder implements Forwarder {
  deliveries: HookDelivery[] = [];
  result: DeliverResult = { kind: "ok" };
  async deliver(d: HookDelivery): Promise<DeliverResult> {
    this.deliveries.push(d);
    return this.result;
  }
}

function makeSubscriber(args: {
  frames: { event: string; data: unknown }[];
  forwarder: FakeForwarder;
  cursor: Cursor;
  identity: { priv: Uint8Array; pub: string };
  recorded?: RecordedRequest[];
}): InboxSubscriber {
  return new InboxSubscriber(
    GATEWAY,
    args.identity.priv,
    args.identity.pub,
    args.forwarder,
    args.cursor,
    {
      fetcher: streamFetcher(args.frames, args.recorded ?? []),
      backoff: () => 0,
      reconnect: false,
    },
  );
}

describe("InboxSubscriber", () => {
  test("connects with NIP-98 auth to the per-pubkey inbox stream", async () => {
    const identity = makeIdentity();
    const recorded: RecordedRequest[] = [];
    const cursor = new Cursor(mkdtempSync(join(tmpdir(), "sub-")));
    cursor.advance(1_753_000_111_999);
    const sub = makeSubscriber({
      frames: [{ event: "hello", data: {} }],
      forwarder: new FakeForwarder(),
      cursor,
      identity,
      recorded,
    });
    await sub.run();

    expect(recorded.length).toBe(1);
    const req = recorded[0]!;
    expect(req.url).toStartWith(`${GATEWAY}/v0/inbox/${identity.pub}/stream?`);
    expect(req.url).toContain("since=1753000111");
    expect(req.url).toContain("replay_limit=1000");
    expect(req.headers["authorization"]).toStartWith("Nostr ");
    expect(req.headers["accept"]).toBe("text/event-stream");
  });

  test("forwards a hook wrap and advances the cursor on 2xx", async () => {
    const identity = makeIdentity();
    const forwarder = new FakeForwarder();
    const cursor = new Cursor(mkdtempSync(join(tmpdir(), "sub-")));
    const wrapEvent = makeHookWrap(identity.pub, "agentmail");
    const sub = makeSubscriber({
      frames: [
        { event: "hello", data: {} },
        { event: "gift-wrap", data: { wrap_event: wrapEvent, received_at_ms: 1_753_000_222_000 } },
      ],
      forwarder,
      cursor,
      identity,
    });
    await sub.run();

    expect(forwarder.deliveries.length).toBe(1);
    const d = forwarder.deliveries[0]!;
    expect(d.slug).toBe("agentmail");
    expect(d.body_b64).toBe("aGk=");
    expect(d.receivedAtMs).toBe(1_753_000_000_000);
    expect(d.sourceIp).toBe("203.0.113.7");
    expect(d.wrapEventId).toMatch(/^[0-9a-f]{64}$/);
    expect(cursor.ms).toBe(1_753_000_222_000);
  });

  test.each<DeliverResult>([
    { kind: "server_error", status: 500 },
    { kind: "network_error", message: "ECONNREFUSED" },
  ])("holds the cursor on a transient failure (%j)", async (result) => {
    const identity = makeIdentity();
    const forwarder = new FakeForwarder();
    forwarder.result = result;
    const cursor = new Cursor(mkdtempSync(join(tmpdir(), "sub-")));
    const wrapEvent = makeHookWrap(identity.pub, "agentmail");
    const sub = makeSubscriber({
      frames: [
        { event: "gift-wrap", data: { wrap_event: wrapEvent, received_at_ms: 1_753_000_333_000 } },
      ],
      forwarder,
      cursor,
      identity,
    });
    await sub.run();

    expect(forwarder.deliveries.length).toBe(1);
    expect(cursor.ms).toBe(0);
  });

  test("drops the delivery and advances the cursor on a Sonata 4xx", async () => {
    const identity = makeIdentity();
    const forwarder = new FakeForwarder();
    forwarder.result = { kind: "client_error", status: 404 };
    const cursor = new Cursor(mkdtempSync(join(tmpdir(), "sub-")));
    const wrapEvent = makeHookWrap(identity.pub, "unregistered-slug");
    const sub = makeSubscriber({
      frames: [
        { event: "gift-wrap", data: { wrap_event: wrapEvent, received_at_ms: 1_753_000_334_000 } },
      ],
      forwarder,
      cursor,
      identity,
    });
    await sub.run();

    expect(forwarder.deliveries.length).toBe(1);
    expect(cursor.ms).toBe(1_753_000_334_000);
  });

  test("skips (and advances past) wraps without an fa:hook tag", async () => {
    const identity = makeIdentity();
    const forwarder = new FakeForwarder();
    const cursor = new Cursor(mkdtempSync(join(tmpdir(), "sub-")));
    const throwawayPriv = randomBytes(32);
    const rumor = __signEvent(
      {
        pubkey: bytesToHex(schnorr.getPublicKey(throwawayPriv)),
        created_at: Math.floor(Date.now() / 1000),
        kind: 1069,
        tags: [["p", identity.pub]],
        content: "{}",
      },
      throwawayPriv,
    );
    const wrapEvent = wrap(rumor, throwawayPriv, identity.pub);
    const sub = makeSubscriber({
      frames: [
        { event: "gift-wrap", data: { wrap_event: wrapEvent, received_at_ms: 1_753_000_444_000 } },
      ],
      forwarder,
      cursor,
      identity,
    });
    await sub.run();

    expect(forwarder.deliveries.length).toBe(0);
    expect(cursor.ms).toBe(1_753_000_444_000);
  });

  test("skips (and advances past) undecryptable wraps", async () => {
    const identity = makeIdentity();
    const other = makeIdentity();
    const forwarder = new FakeForwarder();
    const cursor = new Cursor(mkdtempSync(join(tmpdir(), "sub-")));
    // Wrap addressed to a different pubkey — decrypt must fail for us.
    const wrapEvent = makeHookWrap(other.pub, "agentmail");
    const sub = makeSubscriber({
      frames: [
        { event: "gift-wrap", data: { wrap_event: wrapEvent, received_at_ms: 1_753_000_555_000 } },
      ],
      forwarder,
      cursor,
      identity,
    });
    await sub.run();

    expect(forwarder.deliveries.length).toBe(0);
    expect(cursor.ms).toBe(1_753_000_555_000);
  });

  test("dedupes the same wrap id within the rolling window", async () => {
    const identity = makeIdentity();
    const forwarder = new FakeForwarder();
    const cursor = new Cursor(mkdtempSync(join(tmpdir(), "sub-")));
    const wrapEvent = makeHookWrap(identity.pub, "agentmail");
    const frame = { wrap_event: wrapEvent, received_at_ms: 1_753_000_666_000 };
    const sub = makeSubscriber({
      frames: [
        { event: "gift-wrap", data: frame },
        { event: "gift-wrap", data: frame },
      ],
      forwarder,
      cursor,
      identity,
    });
    await sub.run();

    expect(forwarder.deliveries.length).toBe(1);
  });
});
