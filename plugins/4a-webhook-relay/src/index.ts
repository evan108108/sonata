// 4a-webhook-relay entry — HTTP server boot + inbox subscriber lifecycle.
// Modeled on sonata-studio/src/index.ts.
//
// On startup:
//   1. Wait for Sonata (60s budget, 1s ticks).
//   2. Load (or first-run-init) the plugin identity + config.
//   3. Bind HTTP server on $PORT, expose /api/actions discovery + routes.
//   4. If SONATA_WEBHOOK_BEARER is present, start the inbox SSE subscriber.
//      Without it the plugin idles as a documented no-op: it can't
//      authenticate deliveries to Sonata, so tailing the stream would only
//      burn reconnects on guaranteed-401 forwards.
//
// `bin/4a-webhook-relay stop` is a no-op exit, per Sonata's plugin restart
// protocol (Sonata calls `stop` before respawning).

if (process.argv.includes("stop")) {
  process.exit(0);
}

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { ACTIONS, ROUTES, type ActionCtx } from "./actions";
import { loadOrInitConfig, type PluginConfig } from "./config";
import { Cursor } from "./cursor";
import { SonataForwarder, waitForSonata } from "./forwarder";
import { log } from "./logger";
import { InboxSubscriber } from "./subscriber";

const PORT = parseInt(process.env["PORT"] ?? "4300", 10);

function jsonResponse(res: ServerResponse, status: number, payload: unknown): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(payload));
}

async function readBody(req: IncomingMessage): Promise<Record<string, unknown>> {
  if (req.method && req.method.toUpperCase() === "GET") return {};
  return new Promise((resolve) => {
    let buf = "";
    req.on("data", (chunk) => {
      buf += chunk;
    });
    req.on("end", () => {
      if (buf.length === 0) return resolve({});
      try {
        const parsed = JSON.parse(buf);
        resolve(
          parsed && typeof parsed === "object" && !Array.isArray(parsed)
            ? (parsed as Record<string, unknown>)
            : {},
        );
      } catch {
        resolve({});
      }
    });
    req.on("error", () => resolve({}));
  });
}

function readQuery(url: URL): Record<string, string> {
  const out: Record<string, string> = {};
  url.searchParams.forEach((v, k) => {
    out[k] = v;
  });
  return out;
}

function startServer(cfg: PluginConfig, subscriber: InboxSubscriber | null): void {
  const ctx: ActionCtx = { cfg };

  const server = createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", `http://localhost:${PORT}`);
    const path = url.pathname;
    const method = (req.method ?? "GET").toUpperCase();

    try {
      if (path === "/api/actions" && method === "GET") {
        return jsonResponse(res, 200, ACTIONS);
      }

      if (path === "/api/health" && method === "GET") {
        return jsonResponse(res, 200, { ok: true, subscriber_active: subscriber !== null });
      }

      const route = ROUTES[path];
      if (route) {
        if (route.method !== method.toLowerCase()) {
          res.writeHead(405, { Allow: route.method.toUpperCase() });
          return res.end();
        }
        const body = await readBody(req);
        const query = readQuery(url);
        try {
          const result = await route.handler(body, query, ctx);
          return jsonResponse(res, 200, { ok: true, result });
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          log.error("Action handler threw", { path, method, err: msg });
          return jsonResponse(res, 500, {
            ok: false,
            error: "internal_error",
            message: msg,
            status: 500,
          });
        }
      }

      jsonResponse(res, 404, {
        ok: false,
        error: "not_found",
        message: `no route: ${method} ${path}`,
        status: 404,
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      log.error("Unhandled request error", { path, method, err: msg });
      jsonResponse(res, 500, { ok: false, error: "internal_error", message: msg, status: 500 });
    }
  });

  server.listen(PORT, () => {
    log.info("HTTP server listening", { port: PORT, actions: ACTIONS.length });
  });

  const shutdown = (signal: string): void => {
    log.info("Shutting down", { signal });
    subscriber?.abort();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

async function main(): Promise<void> {
  log.info("4a-webhook-relay booting", { pid: process.pid, port: PORT });
  const cfg = loadOrInitConfig();
  await waitForSonata(cfg.sonataHost);
  log.info("Config loaded", {
    pubkey: cfg.identityPub,
    gateway: cfg.gatewayBaseUrl,
    sonata_host: cfg.sonataHost,
    bearer_present: cfg.webhookBearer !== null,
  });

  let subscriber: InboxSubscriber | null = null;
  if (cfg.webhookBearer !== null) {
    const cursor = new Cursor(cfg.pluginDataDir);
    const forwarder = new SonataForwarder(cfg.sonataHost, cfg.webhookBearer);
    subscriber = new InboxSubscriber(
      cfg.gatewayBaseUrl,
      cfg.identityPriv,
      cfg.identityPub,
      forwarder,
      cursor,
    );
  } else {
    log.warn(
      "SONATA_WEBHOOK_BEARER not set — inbox subscriber disabled (no-op mode). " +
        "Sonata injects it once PluginManager supports capabilities.webhookReceiver.",
    );
  }

  startServer(cfg, subscriber);
  if (subscriber) await subscriber.run();
}

main().catch((err) => {
  const msg = err instanceof Error ? err.stack ?? err.message : String(err);
  log.error("Fatal startup error", { err: msg });
  process.exit(1);
});
