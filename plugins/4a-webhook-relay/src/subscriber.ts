// InboxSubscriber — long-lived SSE tail of the gateway's per-pubkey inbox.
//
//   GET ${gateway}/v0/inbox/<identityPub>/stream?since=<sec>&replay_limit=1000
//   Authorization: Nostr <NIP-98 event signed by identityPriv>
//
// The gateway requires auth pubkey === path pubkey (plan invariant 1).
// Reconnect with exponential backoff capped at 30s (invariant 2), retries
// reset on the stream's `hello` event.
//
// Per-wrap flow:
//   unwrapHook → `["fa:hook", slug]` filter (post-unwrap — outer wraps only
//   carry a p-tag) → parse rumor content → POST to Sonata → on 2xx advance
//   the persistent cursor. A wrap that is garbage (undecryptable, not a
//   hook, malformed content) advances the cursor too — replaying it can
//   never succeed. Same for a Sonata 4xx (unregistered slug, bad bearer):
//   permanent as-configured, so log-and-advance rather than wedging the
//   stream head. Only a TRANSIENT failure (Sonata 5xx / network error)
//   aborts the stream WITHOUT advancing, so the next reconnect replays it —
//   at-least-once, in order, no delivery skipped past a transient failure.

import { signNip98 } from "./crypto/nip98";
import type { NostrEvent } from "./crypto/nip17";
import { hookSlug, unwrapHook } from "./crypto/unwrap-hook";
import { Cursor } from "./cursor";
import type { Forwarder, HookDelivery } from "./forwarder";
import { log } from "./logger";
import { parseSSEStream } from "./sse/parser";

const MAX_BACKOFF_MS = 30_000;
const BASE_BACKOFF_MS = 500;
const REPLAY_LIMIT_MAX = 1_000;
const DEDUP_WINDOW_MS = 5_000;

/** Thrown when Sonata refuses a delivery — restarts the stream sans cursor advance. */
class DeliveryRefusedError extends Error {
  constructor(wrapEventId: string) {
    super(`Sonata refused delivery for wrap ${wrapEventId}`);
    this.name = "DeliveryRefusedError";
  }
}

function defaultBackoff(retries: number): number {
  const base = Math.min(MAX_BACKOFF_MS, BASE_BACKOFF_MS * Math.pow(2, retries));
  const jitter = 0.8 + Math.random() * 0.4; // ±20%
  return Math.floor(base * jitter);
}

interface AbortFlag {
  readonly aborted: boolean;
}

function sleep(ms: number, signal?: AbortFlag): Promise<void> {
  if (ms <= 0) return Promise.resolve();
  return new Promise((resolve) => {
    const t = setTimeout(resolve, ms);
    if (signal) {
      const tick = setInterval(() => {
        if (signal.aborted) {
          clearTimeout(t);
          clearInterval(tick);
          resolve();
        }
      }, Math.min(ms, 100));
      (tick as unknown as { unref?: () => void }).unref?.();
      (t as unknown as { unref?: () => void }).unref?.();
    }
  });
}

/** Shape of the gateway rumor's JSON content (webhook-receiver.ts). */
interface HookRumorContent {
  received_at_ms: number;
  source_ip?: string;
  headers: Record<string, string>;
  body_b64: string;
  slug: string;
}

function parseRumorContent(raw: string): HookRumorContent | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  const c = parsed as Record<string, unknown>;
  if (typeof c["body_b64"] !== "string") return null;
  if (typeof c["slug"] !== "string" || c["slug"].length === 0) return null;
  if (typeof c["received_at_ms"] !== "number") return null;
  const headers: Record<string, string> = {};
  if (c["headers"] && typeof c["headers"] === "object" && !Array.isArray(c["headers"])) {
    for (const [k, v] of Object.entries(c["headers"] as Record<string, unknown>)) {
      if (typeof v === "string") headers[k] = v;
    }
  }
  return {
    received_at_ms: c["received_at_ms"],
    source_ip: typeof c["source_ip"] === "string" ? c["source_ip"] : undefined,
    headers,
    body_b64: c["body_b64"],
    slug: c["slug"],
  };
}

export interface InboxSubscriberOptions {
  fetcher?: typeof fetch;
  /** Override the backoff schedule (tests pass () => 0). */
  backoff?: (retries: number) => number;
  /** Disable the reconnect loop (single-shot tests). */
  reconnect?: boolean;
}

export class InboxSubscriber implements AbortFlag {
  aborted = false;
  private retries = 0;
  private recentEventIds = new Map<string, number>();
  private abortController = new AbortController();
  private readonly fetcher: typeof fetch;
  private readonly backoff: (retries: number) => number;
  private readonly reconnect: boolean;

  constructor(
    private readonly gatewayBaseUrl: string,
    private readonly identityPriv: Uint8Array,
    private readonly identityPub: string,
    private readonly forwarder: Forwarder,
    private readonly cursor: Cursor,
    opts: InboxSubscriberOptions = {},
  ) {
    this.fetcher = opts.fetcher ?? fetch.bind(globalThis);
    this.backoff = opts.backoff ?? defaultBackoff;
    this.reconnect = opts.reconnect ?? true;
  }

  /** Connect → consume → reconnect until aborted. */
  async run(): Promise<void> {
    while (!this.aborted) {
      try {
        const resp = await this.openStream();
        if (!resp.body) throw new Error("inbox stream response had no body");
        await this.consume(resp.body);
      } catch (err) {
        if (this.aborted) {
          // Expected during shutdown — the fetch was aborted via the signal.
        } else if (err instanceof DeliveryRefusedError) {
          log.warn("[inbox] delivery refused, reconnecting without cursor advance", {
            err: err.message,
          });
        } else {
          log.warn("[inbox] stream error, will reconnect", {
            err: err instanceof Error ? err.message : String(err),
          });
        }
      }
      if (!this.reconnect || this.aborted) break;
      this.retries++;
      await sleep(this.backoff(this.retries), this);
    }
  }

  abort(): void {
    if (this.aborted) return;
    this.aborted = true;
    this.abortController.abort();
  }

  private async openStream(): Promise<Response> {
    const params = new URLSearchParams();
    if (this.cursor.ms > 0) params.set("since", String(this.cursor.sinceSeconds));
    params.set("replay_limit", String(REPLAY_LIMIT_MAX));
    const url = `${this.gatewayBaseUrl}/v0/inbox/${this.identityPub}/stream?${params.toString()}`;
    const auth = await signNip98({
      url,
      method: "GET",
      pluginPriv: this.identityPriv,
    });
    const res = await this.fetcher(url, {
      method: "GET",
      headers: {
        Authorization: auth,
        Accept: "text/event-stream",
      },
      signal: this.abortController.signal,
    });
    if (!res.ok) {
      throw new Error(`inbox stream connect failed: HTTP ${res.status}`);
    }
    return res;
  }

  private async consume(body: ReadableStream<Uint8Array>): Promise<void> {
    for await (const evt of parseSSEStream(body)) {
      if (this.aborted) return;
      switch (evt.event) {
        case "hello":
          this.retries = 0;
          break;
        case "gift-wrap":
          // Deliberately NOT swallowing errors here: DeliveryRefusedError
          // must propagate to run() so the stream restarts without a
          // cursor advance.
          await this.handleGiftWrap(evt.data);
          break;
        case "error":
          log.warn("[inbox] gateway error event", { data: evt.data });
          break;
        case "keepalive":
        case "message":
          break;
        default:
          log.debug("[inbox] unknown event type", { event: evt.event });
      }
    }
  }

  private async handleGiftWrap(data: unknown): Promise<void> {
    if (!data || typeof data !== "object") return;
    const payload = data as { wrap_event?: NostrEvent; received_at_ms?: number };
    const wrap = payload.wrap_event;
    const receivedAtMs = payload.received_at_ms;
    if (!wrap || typeof receivedAtMs !== "number") return;

    if (this.isDuplicateEvent(wrap.id, receivedAtMs)) {
      log.debug("[inbox] gift-wrap duplicate-skip", { wrap_id: wrap.id });
      return;
    }

    let rumor: NostrEvent;
    try {
      rumor = unwrapHook(wrap, this.identityPriv);
    } catch (e) {
      log.info("[inbox] gift-wrap unwrap failed, skipping", {
        wrap_id: wrap.id,
        err: e instanceof Error ? e.message : String(e),
      });
      this.cursor.advance(receivedAtMs);
      return;
    }

    // Post-unwrap filter (plan invariant 4): outer wraps only carry a p-tag;
    // the hook marker lives on the inner rumor.
    const slug = hookSlug(rumor);
    if (!slug) {
      log.info("[inbox] rumor has no fa:hook tag, skipping", { rumor_id: rumor.id });
      this.cursor.advance(receivedAtMs);
      return;
    }

    const content = parseRumorContent(rumor.content);
    if (!content) {
      log.warn("[inbox] hook rumor content malformed, skipping", { rumor_id: rumor.id });
      this.cursor.advance(receivedAtMs);
      return;
    }

    const delivery: HookDelivery = {
      slug: content.slug,
      body_b64: content.body_b64,
      headers: content.headers,
      receivedAtMs: content.received_at_ms,
      sourceIp: content.source_ip ?? null,
      wrapEventId: rumor.id,
    };
    const result = await this.forwarder.deliver(delivery);
    switch (result.kind) {
      case "ok":
        log.info("[inbox] hook forwarded", {
          slug: delivery.slug,
          wrap_event_id: delivery.wrapEventId,
        });
        this.cursor.advance(receivedAtMs);
        return;
      case "client_error":
        // Permanent as-configured (unregistered slug → 404, bad bearer →
        // 401): retrying can never succeed, so drop it and move on. Grep
        // for this line to find silently-dropped deliveries.
        log.warn("[inbox] delivery dropped — Sonata rejected it as-configured", {
          slug: delivery.slug,
          wrap_event_id: delivery.wrapEventId,
          status: result.status,
        });
        this.cursor.advance(receivedAtMs);
        return;
      case "server_error":
      case "network_error":
        // Transient — hold the cursor and restart the stream so the next
        // reconnect's replay retries this wrap.
        log.warn("[inbox] delivery failed transiently, will retry via replay", {
          slug: delivery.slug,
          wrap_event_id: delivery.wrapEventId,
          ...(result.kind === "server_error"
            ? { status: result.status }
            : { err: result.message }),
        });
        throw new DeliveryRefusedError(rumor.id);
    }
  }

  private isDuplicateEvent(id: string, nowMs: number): boolean {
    for (const [k, t] of this.recentEventIds) {
      if (nowMs - t > DEDUP_WINDOW_MS) this.recentEventIds.delete(k);
    }
    if (this.recentEventIds.has(id)) return true;
    this.recentEventIds.set(id, nowMs);
    return false;
  }
}
