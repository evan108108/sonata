// Shared test helpers — mock fetch + ActionCtx fixture.
//
// We mock at the global fetch level so handlers can use the real GatewayClient
// (which signs NIP-98 internally) and the real memory-client (which posts JSON
// to SONATA_HOST). Each test installs its handler, runs the action, and asserts
// on captured request bodies.
//
// `decryptRumorContent(rumor, recipientPriv, senderPub)` lets tests verify the
// rumor's plaintext payload without relying on validators alone.

import { schnorr } from "@noble/curves/secp256k1.js";
import { bytesToHex, hexToBytes, randomBytes } from "@noble/hashes/utils.js";

import { GatewayClient } from "../../src/a4-client";
import type { PluginConfig } from "../../src/config";
import { decryptString } from "../../src/crypto/nip44";
import { unwrap, type NostrEvent } from "../../src/crypto/nip17";
import type { ActionCtx } from "../../src/actions";

export function genKey(): { priv: Uint8Array; privHex: string; pubHex: string } {
  const priv = randomBytes(32);
  return { priv, privHex: bytesToHex(priv), pubHex: bytesToHex(schnorr.getPublicKey(priv)) };
}

export interface FetchCall {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: unknown;
}

export interface MockFetchOptions {
  /** Map of (METHOD url-substring) → response builder. */
  routes: Array<{
    match: (url: string, method: string) => boolean;
    respond: (
      url: string,
      method: string,
      body: unknown,
    ) => { status: number; body: unknown };
  }>;
  /** Default response if no route matches (404). */
  defaultStatus?: number;
}

export function installMockFetch(opts: MockFetchOptions): {
  calls: FetchCall[];
  restore: () => void;
} {
  const calls: FetchCall[] = [];
  const orig = globalThis.fetch;

  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    const method = (init?.method ?? "GET").toUpperCase();
    const headers: Record<string, string> = {};
    if (init?.headers) {
      const h = init.headers as Record<string, string>;
      for (const k of Object.keys(h)) headers[k.toLowerCase()] = h[k]!;
    }
    let body: unknown = null;
    if (init?.body) {
      const raw = init.body instanceof Uint8Array ? new TextDecoder().decode(init.body) : String(init.body);
      try {
        body = JSON.parse(raw);
      } catch {
        body = raw;
      }
    }
    calls.push({ url, method, headers, body });

    for (const r of opts.routes) {
      if (r.match(url, method)) {
        const resp = r.respond(url, method, body);
        return new Response(JSON.stringify(resp.body), {
          status: resp.status,
          headers: { "Content-Type": "application/json" },
        });
      }
    }
    return new Response(JSON.stringify({ error: "no_route", message: `${method} ${url}` }), {
      status: opts.defaultStatus ?? 404,
      headers: { "Content-Type": "application/json" },
    });
  }) as typeof fetch;

  return {
    calls,
    restore: () => {
      globalThis.fetch = orig;
    },
  };
}

export interface FixtureCtx {
  ctx: ActionCtx;
  cfg: PluginConfig;
  pluginPriv: Uint8Array;
  pluginPub: string;
}

/**
 * Build a minimal ActionCtx around a real GatewayClient — the test fetcher
 * is installed at the global level by `installMockFetch`.
 */
export function makeCtx(): FixtureCtx {
  const k = genKey();
  const cfg: PluginConfig = {
    pluginPriv: k.priv,
    pluginPub: k.pubHex,
    gatewayBaseUrl: "https://gateway.test",
    sonataHost: "http://127.0.0.1:3211",
    pluginDataDir: "/tmp/sonata-studio-test",
  };
  // Use a runtime-resolved fetcher so installMockFetch (which swaps
  // globalThis.fetch) works regardless of construction order.
  const gateway = new GatewayClient(
    { pluginPriv: cfg.pluginPriv, gatewayBaseUrl: cfg.gatewayBaseUrl },
    {
      retryDelaysMs: [0, 0, 0, 0],
      fetcher: ((input: RequestInfo | URL, init?: RequestInit) =>
        globalThis.fetch(input, init)) as typeof fetch,
    },
  );
  return { ctx: { cfg, gateway }, cfg, pluginPriv: k.priv, pluginPub: k.pubHex };
}

/**
 * Match a Sonata memory-client URL prefix for routing in installMockFetch.
 */
export function matchMemoryUrl(prefix: string) {
  return (url: string) => url.startsWith("http://127.0.0.1:3211" + prefix);
}

export function matchGatewayUrl(suffix: string) {
  return (url: string) => url.startsWith("https://gateway.test" + suffix);
}

/**
 * Capture the gift-wrap body posted to /v0/audience/raw/publish-wraps and
 * unwrap it back to the rumor + decrypted payload. Recipient priv is the
 * member key whose `p` tag we want to peel.
 */
export interface UnwrappedPublication {
  rumor: NostrEvent;
  payload: Record<string, unknown>;
}

export function unwrapFirstPublication(
  publishWrapsCalls: FetchCall[],
  recipientPriv: Uint8Array,
  epochPriv: Uint8Array,
  publisherPub: string,
): UnwrappedPublication {
  const lastCall = publishWrapsCalls[publishWrapsCalls.length - 1];
  if (!lastCall) throw new Error("no publish-wraps call captured");
  const body = lastCall.body as { gift_wraps?: NostrEvent[] };
  const wraps = body?.gift_wraps;
  if (!Array.isArray(wraps) || wraps.length === 0) {
    throw new Error("gift_wraps array empty in publish-wraps body");
  }
  // Pick the wrap whose `p` tag matches our recipient.
  const recipientPub = bytesToHex(schnorr.getPublicKey(recipientPriv));
  const wrap = wraps.find((w) => w.tags.some((t) => t[0] === "p" && (t[1] ?? "").toLowerCase() === recipientPub));
  if (!wrap) throw new Error(`no wrap for recipient ${recipientPub}`);
  const { rumor } = unwrap(wrap, recipientPriv);
  const plaintext = decryptString(rumor.content, epochPriv, publisherPub);
  return { rumor, payload: JSON.parse(plaintext) as Record<string, unknown> };
}

export function hex(bytes: Uint8Array): string {
  return bytesToHex(bytes);
}

export { hexToBytes };
