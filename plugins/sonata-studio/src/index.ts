// sonata-studio entry — HTTP server boot, lifecycle. Per plan §3.
//
// On startup:
//   1. Wait for Sonata (60s budget, 1s ticks).
//   2. Load (or first-run-init) plugin config.
//   3. Bind HTTP server on $PORT, expose /api/actions discovery + per-action
//      stub routes (T5 fills in handlers).
//
// `bin/sonata-studio stop` is a no-op exit, per Sonata's plugin restart
// protocol (Sonata calls `stop` before respawning).

if (process.argv.includes("stop")) {
  process.exit(0);
}

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import {
  ACTIONS,
  ROUTES,
  HttpError,
  errorPayload,
  type ActionCtx,
} from "./actions";
import { GatewayClient } from "./a4-client";
import { loadOrInitConfig, type PluginConfig } from "./config";
import { entity, secret, waitForSonata } from "./memory-client";
import { log } from "./logger";
import { SSEManager } from "./sse/manager";
import { initAutoRunContext } from "./auto-run/context";
import { AutoRunWatcher } from "./auto-run/watcher";

const PORT = parseInt(process.env["PORT"] ?? "4200", 10);

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

function startServer(cfg: PluginConfig, gateway: GatewayClient, sse: SSEManager): void {
  const ctx: ActionCtx = { cfg, gateway, sseManager: sse };

  // Auto-run subsystem: hand the action context to the auto-run modules and
  // boot the task watcher. The hook itself runs synchronously from
  // projectCard() — registering the context is what unblocks it. The watcher
  // polls Sonata's task table for completion of dispatched auto-run tasks.
  initAutoRunContext(ctx);
  const autoRunWatcher = new AutoRunWatcher();
  autoRunWatcher.start();

  const server = createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", `http://localhost:${PORT}`);
    const path = url.pathname;
    const method = (req.method ?? "GET").toUpperCase();

    try {
      if (path === "/api/actions" && method === "GET") {
        return jsonResponse(res, 200, ACTIONS);
      }

      if (path === "/api/health" && method === "GET") {
        return jsonResponse(res, 200, { ok: true });
      }

      const route = ROUTES[path];
      if (route) {
        if (route.method !== method.toLowerCase()) {
          res.writeHead(405, { Allow: route.method.toUpperCase() });
          return res.end();
        }
        const body = await readBody(req);
        const query = readQuery(url);
        // Per-request shallow-copy of ctx with the request headers attached.
        // Action handlers that care (cycle-break in card.post) read
        // `ctx.headers["x-studio-source"]`; everything else ignores it.
        const headers: Record<string, string> = {};
        for (const [k, v] of Object.entries(req.headers)) {
          if (typeof v === "string") headers[k.toLowerCase()] = v;
          else if (Array.isArray(v) && v.length > 0) headers[k.toLowerCase()] = v[0]!;
        }
        const reqCtx: ActionCtx = { ...ctx, headers };
        try {
          const result = await route.handler(body, query, reqCtx);
          return jsonResponse(res, 200, { ok: true, result });
        } catch (err) {
          if (err instanceof HttpError) {
            return jsonResponse(res, err.status, errorPayload(err));
          }
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

      jsonResponse(res, 404, { ok: false, error: "not_found", message: `no route: ${method} ${path}`, status: 404 });
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
    autoRunWatcher.stop();
    void sse.stop();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

async function main(): Promise<void> {
  log.info("sonata-studio booting", { pid: process.pid, port: PORT });
  await waitForSonata(60_000);
  const cfg = await loadOrInitConfig();
  log.info("Config loaded", {
    plugin_pub: cfg.pluginPub,
    gateway: cfg.gatewayBaseUrl,
    sonata_host: cfg.sonataHost,
  });
  const gateway = new GatewayClient({
    pluginPriv: cfg.pluginPriv,
    gatewayBaseUrl: cfg.gatewayBaseUrl,
  });
  const sse = new SSEManager(cfg, gateway, { entity, secret });
  startServer(cfg, gateway, sse);
  await sse.start();
}

main().catch((err) => {
  const msg = err instanceof Error ? err.stack ?? err.message : String(err);
  log.error("Fatal startup error", { err: msg });
  process.exit(1);
});
