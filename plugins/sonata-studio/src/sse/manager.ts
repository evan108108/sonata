// SSEManager — owns one SSEClient per joined Studio room.
//
// Plan §6.1: on start, scan memory for every studio_room entity (any state,
// including "pending-grant") and open a client for each. open() and close()
// add or remove rooms after first-run; stop() shuts everything down.
//
// Each client runs its connect → consume → reconnect loop on a detached
// promise. We track those promises for graceful shutdown.

import type { GatewayClient } from "../a4-client";
import type { PluginConfig } from "../config";
import { log } from "../logger";
import { SSEClient, type SSEClientOptions, type SSEMemoryClient } from "./client";

export interface ManagedSSEClient {
  run(): Promise<void>;
  abort(): void;
}

interface ClientHandle {
  client: ManagedSSEClient;
  runPromise: Promise<void>;
}

export interface SSEManagerOptions extends SSEClientOptions {
  /** Override the SSEClient factory (test seam). */
  clientFactory?: (
    roomSlug: string,
    pluginPriv: Uint8Array,
    gateway: GatewayClient,
    memory: SSEMemoryClient,
    opts: SSEClientOptions,
  ) => ManagedSSEClient;
}

export class SSEManager {
  private clients = new Map<string, ClientHandle>();
  private started = false;
  private readonly clientFactory: NonNullable<SSEManagerOptions["clientFactory"]>;
  private readonly clientOpts: SSEClientOptions;

  constructor(
    private readonly cfg: PluginConfig,
    private readonly gateway: GatewayClient,
    private readonly memory: SSEMemoryClient,
    opts: SSEManagerOptions = {},
  ) {
    const { clientFactory, ...rest } = opts;
    this.clientOpts = rest;
    this.clientFactory =
      clientFactory ??
      ((slug, priv, gw, mem, o) => new SSEClient(slug, priv, gw, mem, o));
  }

  /** Boot scan: open one client per studio_room entity in memory. */
  async start(): Promise<void> {
    if (this.started) return;
    this.started = true;
    let rooms: { name: string }[] = [];
    try {
      rooms = await this.memory.entity.list({ type: "studio_room" });
    } catch (err) {
      log.warn("[sse] start: failed to list studio_room entities", {
        err: err instanceof Error ? err.message : String(err),
      });
      return;
    }
    for (const r of rooms) {
      const slug = this.slugFromName(r.name);
      if (!slug) continue;
      this.openInternal(slug);
    }
    log.info("[sse] manager started", { rooms: this.clients.size });
  }

  /** Open a client for a newly-joined room. Idempotent. */
  async open(roomSlug: string): Promise<void> {
    if (!this.started) this.started = true;
    if (this.clients.has(roomSlug)) return;
    this.openInternal(roomSlug);
  }

  /** Close the client for a room (e.g. on leave or delete).
   *
   * `client.abort()` aborts the in-flight fetch and propagates through the
   * SSE parser's `reader.read()`, so `runPromise` resolves promptly without
   * any defensive timeout. */
  async close(roomSlug: string): Promise<void> {
    const handle = this.clients.get(roomSlug);
    if (!handle) return;
    this.clients.delete(roomSlug);
    handle.client.abort();
    try {
      await handle.runPromise;
    } catch {
      // run() catches its own errors
    }
  }

  /** Graceful shutdown — abort every client and await their loops. */
  async stop(): Promise<void> {
    const handles = Array.from(this.clients.values());
    this.clients.clear();
    for (const h of handles) h.client.abort();
    await Promise.allSettled(handles.map((h) => h.runPromise));
    this.started = false;
    log.info("[sse] manager stopped");
  }

  /** Test-only: list active room slugs. */
  activeRooms(): string[] {
    return Array.from(this.clients.keys()).sort();
  }

  // ── internals ─────────────────────────────────────────────────────────────

  private openInternal(roomSlug: string): void {
    const client = this.clientFactory(
      roomSlug,
      this.cfg.pluginPriv,
      this.gateway,
      this.memory,
      this.clientOpts,
    );
    const runPromise = client.run().catch((err) => {
      log.error("[sse] client run() rejected", {
        room: roomSlug,
        err: err instanceof Error ? err.message : String(err),
      });
    });
    this.clients.set(roomSlug, { client, runPromise });
    log.debug("[sse] opened client", { room: roomSlug });
  }

  private slugFromName(name: string): string | null {
    // entity name shape: studio:room:<slug>
    const prefix = "studio:room:";
    if (!name.startsWith(prefix)) return null;
    const slug = name.slice(prefix.length);
    return slug.length > 0 ? slug : null;
  }
}
