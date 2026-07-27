// Sonata forwarder — POST decrypted hook deliveries to Sonata core.
//
// Contract (plan invariants 5-8, amended per review):
//   - POST ${SONATA_HOST}/api/webhook/deliver
//   - body {slug, body_b64, headers, receivedAtMs, sourceIp, wrapEventId}
//   - Authorization: Bearer ${SONATA_WEBHOOK_BEARER}
//   - 2xx → caller advances the cursor.
//   - 4xx → permanent as-configured (unregistered slug, bad bearer);
//     retrying can never succeed, so the caller logs and advances — a held
//     cursor would head-of-line-block every later hook. Known v1 limit:
//     these deliveries vanish from Sonata's UI (webhookOrphans is a v2
//     follow-up).
//   - 5xx / network error → transient; caller holds the cursor and the next
//     reconnect's replay retries.

import { log } from "./logger";

export interface HookDelivery {
  slug: string;
  body_b64: string;
  headers: Record<string, string>;
  receivedAtMs: number;
  sourceIp: string | null;
  /** The inner rumor's event id — Sonata's dedup key (wrapEventId UNIQUE). */
  wrapEventId: string;
}

export type DeliverResult =
  | { kind: "ok" }
  | { kind: "client_error"; status: number }
  | { kind: "server_error"; status: number }
  | { kind: "network_error"; message: string };

export interface Forwarder {
  deliver(delivery: HookDelivery): Promise<DeliverResult>;
}

export class SonataForwarder implements Forwarder {
  constructor(
    private readonly sonataHost: string,
    private readonly bearer: string,
    private readonly fetcher: typeof fetch = fetch.bind(globalThis),
  ) {}

  /** Classify Sonata's response for the caller's cursor decision. Never throws. */
  async deliver(delivery: HookDelivery): Promise<DeliverResult> {
    const url = `${this.sonataHost}/api/webhook/deliver`;
    try {
      const res = await this.fetcher(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${this.bearer}`,
        },
        body: JSON.stringify(delivery),
      });
      if (res.ok) return { kind: "ok" };
      if (res.status >= 400 && res.status < 500) {
        return { kind: "client_error", status: res.status };
      }
      return { kind: "server_error", status: res.status };
    } catch (err) {
      return {
        kind: "network_error",
        message: err instanceof Error ? err.message : String(err),
      };
    }
  }
}

/** Block until Sonata's /api/ping answers, or exit (mirrors sonata-studio). */
export async function waitForSonata(sonataHost: string, timeoutMs = 60_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let lastErr: unknown;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${sonataHost}/api/ping`).catch(() => null);
      if (res && res.ok) {
        log.info("Sonata reachable", { host: sonataHost });
        return;
      }
      lastErr = res ? `status=${res.status}` : "fetch failed";
    } catch (e) {
      lastErr = e instanceof Error ? e.message : String(e);
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  log.error("Sonata unreachable — crashing", { host: sonataHost, lastErr: String(lastErr) });
  process.exit(1);
}
