// GatewayClient — retry policy, error mapping, NIP-98 attachment.
//
// Coverage goals from plan §4.2:
//   - 5xx → retry with exponential backoff (250ms, 500ms, 1s, 2s).
//   - 4xx → no retry; surface as GatewayError with the gateway's code.
//   - Network error → same retry as 5xx.
//   - Each method signs NIP-98 with (url, method, body) and attaches it.
//   - 2xx body parsed and returned typed.
//
// Tests pass `retryDelaysMs: [0, 0, 0, 0]` to skip real waits.

import { describe, expect, it } from "bun:test";
import { hexToBytes } from "@noble/hashes/utils.js";
import { GatewayClient, GatewayError } from "../src/a4-client";

const PRIV = hexToBytes(
  "1111111111111111111111111111111111111111111111111111111111111111",
);
const CFG = {
  pluginPriv: PRIV,
  gatewayBaseUrl: "https://api.4a4.ai",
};
const NO_DELAYS = [0, 0, 0, 0] as const;

interface MockCall {
  url: string;
  method: string;
  authorization: string | null;
  bodyText: string | null;
}

function mockFetcher(
  responder: (req: MockCall, callIndex: number) => Response | Promise<Response>,
): { fetcher: typeof fetch; calls: MockCall[] } {
  const calls: MockCall[] = [];
  const fetcher: typeof fetch = async (input, init) => {
    const url = typeof input === "string" ? input : (input as Request).url;
    const method = (init?.method ?? "GET").toUpperCase();
    const headers = new Headers(init?.headers ?? {});
    let bodyText: string | null = null;
    if (init?.body !== undefined && init.body !== null) {
      if (typeof init.body === "string") bodyText = init.body;
      else if (init.body instanceof Uint8Array) {
        bodyText = new TextDecoder().decode(init.body);
      }
    }
    const call: MockCall = {
      url,
      method,
      authorization: headers.get("Authorization"),
      bodyText,
    };
    calls.push(call);
    return responder(call, calls.length - 1);
  };
  return { fetcher, calls };
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("GatewayClient — happy path", () => {
  it("attaches Authorization: Nostr <event> on POST and parses 2xx JSON", async () => {
    const { fetcher, calls } = mockFetcher(() =>
      jsonResponse(200, {
        ok: true,
        audience_address: "30520:abc:team-design",
        declaration_event_id: "decl-id",
        founding_grant_event_id: "grant-id",
        relay_acks: { declaration: [], founding_grant: [] },
      }),
    );
    const client = new GatewayClient(CFG, { fetcher });
    const res = await client.rawCreate({
      declaration: makeFakeEvent(30520),
      founding_grant: makeFakeEvent(30521),
    });
    expect(res.audience_address).toBe("30520:abc:team-design");
    expect(calls).toHaveLength(1);
    expect(calls[0]!.method).toBe("POST");
    expect(calls[0]!.url).toBe("https://api.4a4.ai/v0/audience/raw/create");
    expect(calls[0]!.authorization).toMatch(/^Nostr [A-Za-z0-9+/=]+$/);
  });

  it("openStream does GET with NIP-98 and returns the raw Response", async () => {
    const { fetcher, calls } = mockFetcher(
      () =>
        new Response("data: ...\n\n", {
          status: 200,
          headers: { "Content-Type": "text/event-stream" },
        }),
    );
    const client = new GatewayClient(CFG, { fetcher });
    const res = await client.openStream({
      audience_slug: "team-design",
      aud_id_pub: "a".repeat(64),
      since_ts: 1234,
      replay_limit: 50,
    });
    expect(res.status).toBe(200);
    expect(calls).toHaveLength(1);
    expect(calls[0]!.method).toBe("GET");
    expect(calls[0]!.url).toContain("/v0/audience/team-design/stream");
    expect(calls[0]!.url).toContain("aud_id_pub=" + "a".repeat(64));
    expect(calls[0]!.url).toContain("since_ts=1234");
    expect(calls[0]!.url).toContain("replay_limit=50");
    expect(calls[0]!.authorization).toMatch(/^Nostr /);
  });

  it("getDeclaration is unauthenticated public read", async () => {
    const { fetcher, calls } = mockFetcher(() =>
      jsonResponse(200, { ok: true, declaration: makeFakeEvent(30520) }),
    );
    const client = new GatewayClient(CFG, { fetcher });
    await client.getDeclaration({
      slug: "team-design",
      aud_id_pub: "a".repeat(64),
    });
    expect(calls[0]!.method).toBe("GET");
    expect(calls[0]!.authorization).toBeNull();
  });
});

describe("GatewayClient — retry policy", () => {
  it("retries on 503 up to 4 times then throws GatewayError(503)", async () => {
    const { fetcher, calls } = mockFetcher(() =>
      jsonResponse(503, { error: "service_unavailable", message: "down" }),
    );
    const client = new GatewayClient(CFG, {
      fetcher,
      retryDelaysMs: NO_DELAYS,
    });
    await expect(
      client.rawClaim({
        audience_address: "30520:a:s",
        claim: makeFakeEvent(30522),
      }),
    ).rejects.toMatchObject({
      name: "GatewayError",
      status: 503,
      code: "service_unavailable",
    });
    expect(calls).toHaveLength(4);
  });

  it("succeeds on the 3rd attempt after two 503s", async () => {
    const { fetcher, calls } = mockFetcher((_, i) => {
      if (i < 2) {
        return jsonResponse(503, { error: "service_unavailable", message: "" });
      }
      return jsonResponse(200, {
        ok: true,
        claim_event_id: "id",
        relay_acks: [],
      });
    });
    const client = new GatewayClient(CFG, {
      fetcher,
      retryDelaysMs: NO_DELAYS,
    });
    const res = await client.rawClaim({
      audience_address: "30520:a:s",
      claim: makeFakeEvent(30522),
    });
    expect(res.claim_event_id).toBe("id");
    expect(calls).toHaveLength(3);
  });

  it("does NOT retry on 4xx — fails fast with GatewayError", async () => {
    const { fetcher, calls } = mockFetcher(() =>
      jsonResponse(403, { error: "forbidden", message: "not a member" }),
    );
    const client = new GatewayClient(CFG, {
      fetcher,
      retryDelaysMs: NO_DELAYS,
    });
    await expect(
      client.rawPublishWraps({
        audience_address: "30520:a:s",
        gift_wraps: [],
      }),
    ).rejects.toMatchObject({
      name: "GatewayError",
      status: 403,
      code: "forbidden",
      message: "not a member",
    });
    expect(calls).toHaveLength(1);
  });

  it("retries on network error then surfaces a GatewayError(0, network_error)", async () => {
    const { fetcher, calls } = mockFetcher(() => {
      throw new TypeError("fetch failed");
    });
    const client = new GatewayClient(CFG, {
      fetcher,
      retryDelaysMs: NO_DELAYS,
    });
    let caught: unknown;
    try {
      await client.rawProcessClaims({ audience_address: "30520:a:s" });
    } catch (err) {
      caught = err;
    }
    expect(caught).toBeInstanceOf(GatewayError);
    expect((caught as GatewayError).status).toBe(0);
    expect((caught as GatewayError).code).toBe("network_error");
    expect(calls).toHaveLength(4);
  });

  it("backs off with the configured delays in order", async () => {
    const callTimestamps: number[] = [];
    const { fetcher } = mockFetcher(() => {
      callTimestamps.push(Date.now());
      return jsonResponse(503, { error: "x", message: "y" });
    });
    const client = new GatewayClient(CFG, {
      fetcher,
      retryDelaysMs: [20, 40, 60, 0],
    });
    await expect(
      client.rawProcessClaims({ audience_address: "30520:a:s" }),
    ).rejects.toBeInstanceOf(GatewayError);
    expect(callTimestamps).toHaveLength(4);
    const d1 = callTimestamps[1]! - callTimestamps[0]!;
    const d2 = callTimestamps[2]! - callTimestamps[1]!;
    const d3 = callTimestamps[3]! - callTimestamps[2]!;
    // Allow generous slack for scheduler jitter; the assertion is that
    // delays grow, not their absolute precision.
    expect(d1).toBeGreaterThanOrEqual(15);
    expect(d2).toBeGreaterThan(d1 - 10);
    expect(d3).toBeGreaterThan(d2 - 10);
  });
});

// ── helpers ─────────────────────────────────────────────────────────────────

function makeFakeEvent(kind: number) {
  return {
    id: "00".repeat(32),
    pubkey: "11".repeat(32),
    created_at: 1777344600,
    kind,
    tags: [],
    content: "",
    sig: "00".repeat(64),
  };
}
