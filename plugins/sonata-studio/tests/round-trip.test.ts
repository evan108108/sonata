// Phase 2 T8 — Round-trip self-test (acceptance gate). Per plan §8 of
// /Users/evan/memory/claude/documents/plans/sonata-studio-v0-phase2-plan.md.
//
// Spawns the plugin binary (bin/sonata-studio) against an in-process Sonata
// memory shim and the live api.4a4.ai gateway. Walks steps 1–13 of §8:
// room create → wait → card post → wait → list → room list → second track
// → list filter inbox/staging → tear down. Captures every gateway response
// and the plugin log tail to tests/round-trip.fixture.json on success.
//
// Flake-tolerant: 3 retries on relay-attributable failures (gateway 502
// `relay_failure`, NIP-98 transport faults, SSE-attributable errors). Other
// failures abort immediately.
//
// Run with: bun test tests/round-trip.test.ts
//
// Override gateway: STUDIO_RT_GATEWAY=https://staging.4a4.ai bun test ...

import { test, expect } from "bun:test";
import { spawn, type Subprocess } from "bun";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";
import type { AddressInfo } from "node:net";
import { fileURLToPath } from "node:url";

// ── Knobs ───────────────────────────────────────────────────────────────────

const GATEWAY = process.env["STUDIO_RT_GATEWAY"] ?? "https://api.4a4.ai";
const MAX_RETRIES = 3;
const PLUGIN_HEALTH_TIMEOUT_MS = 60_000;
const SSE_SETTLE_MS = 2_000;
const CARD_SETTLE_MS = 5_000;
const TRACK_SETTLE_MS = 2_000;
const PER_ATTEMPT_TIMEOUT_MS = 90_000;

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(TEST_DIR, "..");
const PLUGIN_BIN = join(PROJECT_ROOT, "bin", "sonata-studio");
const FIXTURE_OUT = join(TEST_DIR, "round-trip.fixture.json");

// ── Memory shim (stand-in for the Sonata app's HTTP API) ────────────────────

interface EntityRow {
  id: string;
  name: string;
  type: string;
  description: string;
  attributes: Record<string, unknown>;
  referenceCount: number;
  createdAt: number;
  updatedAt: number;
}

interface RelationRow {
  id: string;
  sourceId: string;
  sourceType: "memory" | "entity";
  targetId: string;
  targetType: "memory" | "entity";
  relation: string;
  createdAt: number;
}

interface ShimState {
  entities: Map<string, EntityRow>;
  secrets: Map<string, string>;
  relations: Map<string, RelationRow>;
  pluginConfigs: Map<string, Record<string, unknown>>;
  requestLog: Array<{ method: string; path: string }>;
}

function newShimState(): ShimState {
  return {
    entities: new Map(),
    secrets: new Map(),
    relations: new Map(),
    pluginConfigs: new Map(),
    requestLog: [],
  };
}

function genId(): string {
  // 16 hex chars is plenty for an in-process test shim.
  return Math.random().toString(16).slice(2).padEnd(16, "0").slice(0, 16);
}

async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  return new Promise((res) => {
    let buf = "";
    req.on("data", (c) => {
      buf += c;
    });
    req.on("end", () => {
      if (buf.length === 0) return res({});
      try {
        const v = JSON.parse(buf);
        res(v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
      } catch {
        res({});
      }
    });
    req.on("error", () => res({}));
  });
}

function send(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

function startMemoryShim(): Promise<{
  server: Server;
  state: ShimState;
  baseUrl: string;
  close: () => Promise<void>;
}> {
  const state = newShimState();

  const handler = async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    const method = (req.method ?? "GET").toUpperCase();
    const url = new URL(req.url ?? "/", "http://shim");
    const path = url.pathname;
    state.requestLog.push({ method, path });

    // ── /api/ping ─────────────────────────────────────────────────────────
    if (path === "/api/ping") return send(res, 200, { ok: true });

    // ── /api/entity ───────────────────────────────────────────────────────
    if (path === "/api/entity/" || path === "/api/entity") {
      if (method === "POST") {
        const body = (await readJson(req)) as {
          name?: string;
          type?: string;
          description?: string;
          attributes?: Record<string, unknown>;
        };
        const name = String(body.name ?? "");
        const existing = [...state.entities.values()].find((e) => e.name === name);
        const now = Date.now();
        if (existing) {
          existing.type = String(body.type ?? existing.type);
          existing.description = String(body.description ?? existing.description);
          existing.attributes = body.attributes ?? existing.attributes;
          existing.updatedAt = now;
          return send(res, 200, { id: existing.id });
        }
        const id = genId();
        state.entities.set(id, {
          id,
          name,
          type: String(body.type ?? ""),
          description: String(body.description ?? ""),
          attributes: body.attributes ?? {},
          referenceCount: 0,
          createdAt: now,
          updatedAt: now,
        });
        return send(res, 200, { id });
      }
      if (method === "GET") {
        const queryName = url.searchParams.get("name");
        if (queryName) {
          const found = [...state.entities.values()].find((e) => e.name === queryName);
          return send(res, 200, found ? rowOut(found) : null);
        }
        return send(res, 400, { error: "bad_request", message: "missing name param" });
      }
      if (method === "PATCH") {
        const body = (await readJson(req)) as {
          id?: string;
          attributes?: Record<string, unknown>;
        };
        const ent = body.id ? state.entities.get(String(body.id)) : null;
        if (!ent) return send(res, 404, { error: "not_found" });
        ent.attributes = body.attributes ?? ent.attributes;
        ent.updatedAt = Date.now();
        return send(res, 200, { id: ent.id });
      }
      if (method === "DELETE") {
        const id = url.searchParams.get("id");
        if (id && state.entities.has(id)) {
          state.entities.delete(id);
          return send(res, 200, { success: true });
        }
        return send(res, 404, { error: "not_found" });
      }
    }
    if (path === "/api/entity/list" && method === "GET") {
      const type = url.searchParams.get("type") ?? undefined;
      const limit = Number(url.searchParams.get("limit") ?? "200");
      const rows = [...state.entities.values()]
        .filter((e) => (type ? e.type === type : true))
        .slice(0, Number.isFinite(limit) ? limit : 200)
        .map(rowOut);
      return send(res, 200, rows);
    }
    if (path === "/api/entity/get" && method === "POST") {
      const body = (await readJson(req)) as { id?: string };
      const ent = body.id ? state.entities.get(String(body.id)) : null;
      return send(res, 200, ent ? rowOut(ent) : null);
    }
    if (path === "/api/entity/touch" && method === "POST") {
      const body = (await readJson(req)) as { id?: string };
      const ent = body.id ? state.entities.get(String(body.id)) : null;
      if (ent) ent.updatedAt = Date.now();
      return send(res, 200, { success: !!ent });
    }

    // ── /api/secrets ──────────────────────────────────────────────────────
    if (path === "/api/secrets/" || path === "/api/secrets") {
      if (method === "POST") {
        const body = (await readJson(req)) as { name?: string; value?: string };
        if (typeof body.name !== "string" || typeof body.value !== "string") {
          return send(res, 400, { error: "bad_request" });
        }
        state.secrets.set(body.name, body.value);
        return send(res, 200, { success: true, name: body.name });
      }
    }
    if (path.startsWith("/api/secrets/")) {
      const name = decodeURIComponent(path.slice("/api/secrets/".length));
      if (method === "GET") {
        const value = state.secrets.get(name);
        if (value === undefined) return send(res, 404, { error: "not_found" });
        return send(res, 200, { name, value });
      }
      if (method === "DELETE") {
        const had = state.secrets.delete(name);
        return send(res, had ? 200 : 404, { success: had });
      }
    }

    // ── /api/relation ─────────────────────────────────────────────────────
    if (path === "/api/relation/" || path === "/api/relation") {
      if (method === "POST") {
        const body = (await readJson(req)) as Partial<RelationRow>;
        const id = genId();
        state.relations.set(id, {
          id,
          sourceId: String(body.sourceId ?? ""),
          sourceType: (body.sourceType as RelationRow["sourceType"]) ?? "entity",
          targetId: String(body.targetId ?? ""),
          targetType: (body.targetType as RelationRow["targetType"]) ?? "entity",
          relation: String(body.relation ?? ""),
          createdAt: Date.now(),
        });
        return send(res, 200, { id });
      }
      if (method === "DELETE") {
        const id = url.searchParams.get("id");
        if (id && state.relations.has(id)) {
          state.relations.delete(id);
          return send(res, 200, { success: true });
        }
        return send(res, 404, { error: "not_found" });
      }
    }
    if (path === "/api/relation/list" && method === "GET") {
      const limit = Number(url.searchParams.get("limit") ?? "200");
      return send(
        res,
        200,
        [...state.relations.values()].slice(0, Number.isFinite(limit) ? limit : 200),
      );
    }

    // ── /api/plugins/:name/config ─────────────────────────────────────────
    const pluginCfgMatch = /^\/api\/plugins\/([^/]+)\/config$/.exec(path);
    if (pluginCfgMatch && method === "POST") {
      const body = (await readJson(req)) as { config?: Record<string, unknown> };
      state.pluginConfigs.set(pluginCfgMatch[1]!, body.config ?? {});
      return send(res, 200, { ok: true });
    }

    return send(res, 404, { error: "shim_unmapped", path, method });
  };

  const server = createServer(handler);
  return new Promise((resolveStart) => {
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address() as AddressInfo;
      const baseUrl = `http://127.0.0.1:${addr.port}`;
      resolveStart({
        server,
        state,
        baseUrl,
        close: () =>
          new Promise<void>((r) => server.close(() => r())),
      });
    });
  });
}

function rowOut(e: EntityRow): EntityRow & { attributes: string } {
  return { ...e, attributes: JSON.stringify(e.attributes) };
}

// ── Plugin process ──────────────────────────────────────────────────────────

interface PluginHandle {
  proc: Subprocess;
  port: number;
  dataDir: string;
  stdoutBuf: string[];
  stderrBuf: string[];
}

async function freePort(): Promise<number> {
  return new Promise((res, rej) => {
    const probe = createServer();
    probe.listen(0, "127.0.0.1", () => {
      const addr = probe.address() as AddressInfo;
      probe.close(() => res(addr.port));
    });
    probe.on("error", rej);
  });
}

async function startPlugin(shimBaseUrl: string): Promise<PluginHandle> {
  if (!existsSync(PLUGIN_BIN)) {
    throw new Error(
      `plugin binary not found at ${PLUGIN_BIN} — run ./build.sh first`,
    );
  }

  const dataDir = mkdtempSync(join(tmpdir(), "studio-rt-data-"));
  mkdirSync(join(dataDir, "logs"), { recursive: true });
  const port = await freePort();

  // The plugin reads SONATA_HOST and SONATA_PLUGIN_DATA_DIR. Gateway URL
  // override is `SONATA-STUDIO_GATEWAY_BASE_URL` (yes, the hyphen is literal —
  // see config.ts ENV_PREFIX). On first run the plugin generates a fresh
  // keypair and POSTs it to /api/plugins/sonata-studio/config; the shim
  // captures it.
  const env: Record<string, string> = {
    ...process.env,
    PORT: String(port),
    SONATA_HOST: shimBaseUrl,
    SONATA_PLUGIN_DATA_DIR: dataDir,
    "SONATA-STUDIO_GATEWAY_BASE_URL": GATEWAY,
  };

  const proc = spawn({
    cmd: [PLUGIN_BIN],
    cwd: PROJECT_ROOT,
    env,
    stdout: "pipe",
    stderr: "pipe",
  });

  const stdoutBuf: string[] = [];
  const stderrBuf: string[] = [];
  void drainStream(proc.stdout, stdoutBuf);
  void drainStream(proc.stderr, stderrBuf);

  return { proc, port, dataDir, stdoutBuf, stderrBuf };
}

async function drainStream(
  stream: ReadableStream<Uint8Array> | null,
  out: string[],
): Promise<void> {
  if (!stream) return;
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let pending = "";
  for (;;) {
    let chunk: ReadableStreamReadResult<Uint8Array>;
    try {
      chunk = await reader.read();
    } catch {
      return;
    }
    if (chunk.done) {
      if (pending.length > 0) out.push(pending);
      return;
    }
    pending += decoder.decode(chunk.value, { stream: true });
    const lines = pending.split("\n");
    pending = lines.pop() ?? "";
    for (const l of lines) out.push(l);
    // Keep the buffer bounded — last 2000 lines is plenty for fixture export.
    if (out.length > 2000) out.splice(0, out.length - 2000);
  }
}

async function killPlugin(p: PluginHandle): Promise<void> {
  try {
    p.proc.kill("SIGTERM");
  } catch {
    /* ignore */
  }
  // Give it 3s to flush + exit; SIGKILL otherwise.
  const exited = p.proc.exited;
  await Promise.race([
    exited,
    new Promise<void>((r) => setTimeout(r, 3_000)),
  ]);
  if (p.proc.exitCode === null) {
    try {
      p.proc.kill("SIGKILL");
    } catch {
      /* ignore */
    }
    await exited.catch(() => {});
  }
}

// ── Plugin HTTP client ──────────────────────────────────────────────────────

interface PluginResponse<T = unknown> {
  ok: boolean;
  result?: T;
  error?: string;
  message?: string;
  status?: number;
}

async function callPlugin<T = unknown>(
  port: number,
  pathAndQuery: string,
  method: "GET" | "POST",
  body?: Record<string, unknown>,
): Promise<PluginResponse<T>> {
  const url = `http://127.0.0.1:${port}${pathAndQuery}`;
  const init: RequestInit = { method };
  if (method === "POST" && body !== undefined) {
    init.headers = { "Content-Type": "application/json" };
    init.body = JSON.stringify(body);
  }
  const res = await fetch(url, init);
  const text = await res.text();
  try {
    return JSON.parse(text) as PluginResponse<T>;
  } catch {
    throw new Error(
      `plugin returned non-JSON (HTTP ${res.status}): ${text.slice(0, 200)}`,
    );
  }
}

async function waitForPluginHealth(port: number, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let lastErr = "no attempt";
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/api/health`);
      if (res.ok) return;
      lastErr = `status=${res.status}`;
    } catch (e) {
      lastErr = e instanceof Error ? e.message : String(e);
    }
    await sleep(250);
  }
  throw new Error(
    `plugin /api/health never returned 200 within ${timeoutMs}ms: ${lastErr}`,
  );
}

const sleep = (ms: number): Promise<void> =>
  new Promise((r) => setTimeout(r, ms));

// ── Result types (mirror handler returns) ───────────────────────────────────

interface RoomCreateResult {
  audience_address: string;
  room_event_id: string;
  declaration_event_id: string;
  founding_grant_event_id: string;
  members: string[];
  epoch: number;
  default_tracks: string[];
}

interface CardPostResult {
  rumor_event_id: string;
  audience_address: string;
  d_tag: string;
}

interface CardListResult {
  cards: Array<{
    event_id: string;
    d_tag: string;
    track: string;
    kind: string;
    title: string;
    summary: string;
    created_by: string;
    created_at: number;
    blocks: unknown[];
    tags: string[];
    related_to: string[];
  }>;
}

interface RoomListResult {
  rooms: Array<{
    audience_address: string;
    slug: string;
    title: string;
    epoch: number;
    members: string[];
    pending_invites: number;
    last_card_at?: number;
    state: string;
  }>;
}

interface TrackCreateResult {
  rumor_event_id: string;
  audience_address: string;
  d_tag: string;
}

// ── Retry classification ────────────────────────────────────────────────────

class RelayAttributableError extends Error {
  constructor(message: string, public readonly cause?: unknown) {
    super(message);
    this.name = "RelayAttributableError";
  }
}

function isRelayAttributable(err: unknown): boolean {
  if (err instanceof RelayAttributableError) return true;
  const msg = err instanceof Error ? err.message : String(err);
  return (
    /relay_failure|gateway_unavailable|network_error|ECONN|ETIMEDOUT|fetch failed/i.test(
      msg,
    )
  );
}

function ensureOk<T>(label: string, res: PluginResponse<T>): T {
  if (!res.ok) {
    const code = res.error ?? "unknown";
    const msg = `${label} failed: ${code}: ${res.message ?? ""}`;
    if (code === "gateway_unavailable" || code === "relay_failure") {
      throw new RelayAttributableError(msg);
    }
    throw new Error(msg);
  }
  if (res.result === undefined) {
    throw new Error(`${label}: response had no result field`);
  }
  return res.result;
}

// ── The test ────────────────────────────────────────────────────────────────

interface Fixture {
  ts: string;
  gateway: string;
  plugin_pub: string;
  responses: Record<string, unknown>;
  plugin_log_tail: string[];
  attempts: number;
}

test(
  "round-trip self-test (Phase 2 acceptance gate)",
  async () => {
    const errors: unknown[] = [];
    let lastFixture: Fixture | null = null;

    for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
      try {
        lastFixture = await runOnce(attempt);
        writeFileSync(FIXTURE_OUT, JSON.stringify(lastFixture, null, 2));
        return;
      } catch (err) {
        errors.push(err);
        const retryable = isRelayAttributable(err);
        if (!retryable || attempt === MAX_RETRIES) {
          // Surface every captured error so the operator can see the chain.
          const tail = errors
            .map((e, i) => {
              const m = e instanceof Error ? e.message : String(e);
              return `  attempt ${i + 1}: ${m}`;
            })
            .join("\n");
          throw new Error(
            `round-trip failed after ${attempt} attempt(s):\n${tail}`,
          );
        }
        // Backoff between attempts to let transient relay weather pass.
        await sleep(2_000 * attempt);
      }
    }
    throw new Error("unreachable");
  },
  PER_ATTEMPT_TIMEOUT_MS * MAX_RETRIES + 30_000,
);

async function runOnce(attempt: number): Promise<Fixture> {
  const shim = await startMemoryShim();
  let plugin: PluginHandle | null = null;
  const responses: Record<string, unknown> = {};

  try {
    plugin = await startPlugin(shim.baseUrl);
    await waitForPluginHealth(plugin.port, PLUGIN_HEALTH_TIMEOUT_MS);

    // Resolve plugin pub from the first-run config the plugin posted to the
    // shim, or fall back to the entity attributes if env injection was used.
    const cfgRecord = shim.state.pluginConfigs.get("sonata-studio") ?? {};
    const pluginPub = String(cfgRecord["plugin_pub"] ?? "").toLowerCase();
    if (pluginPub.length !== 64) {
      throw new Error(
        `plugin did not register a 64-hex pubkey via /api/plugins/sonata-studio/config (got "${pluginPub}")`,
      );
    }

    // Step 4: studio_room_create
    const r1raw = await callPlugin<RoomCreateResult>(
      plugin.port,
      "/api/room/create",
      "POST",
      {
        slug: "rt-test",
        title: "Round-trip",
        default_tracks: ["inbox"],
      },
    );
    responses["room_create"] = r1raw;
    const r1 = ensureOk("studio_room_create", r1raw);
    expect(typeof r1.audience_address).toBe("string");
    expect(r1.audience_address.length).toBeGreaterThan(0);
    expect(typeof r1.room_event_id).toBe("string");
    expect(r1.room_event_id.length).toBe(64);
    expect(r1.members.length).toBe(1);
    expect(r1.members[0]?.toLowerCase()).toBe(pluginPub);
    expect(r1.epoch).toBe(1);

    // Step 5: SSE round-trip on relays
    await sleep(SSE_SETTLE_MS);

    // Step 6: studio_card_post (inbox)
    const r2raw = await callPlugin<CardPostResult>(
      plugin.port,
      "/api/card/post",
      "POST",
      {
        room: "rt-test",
        track: "inbox",
        kind: "note",
        title: "hello",
        summary: "hi",
        blocks: [{ type: "text", body: "world" }],
      },
    );
    responses["card_post_inbox"] = r2raw;
    const r2 = ensureOk("studio_card_post", r2raw);
    expect(typeof r2.rumor_event_id).toBe("string");
    expect(r2.rumor_event_id.length).toBe(64);

    // Step 7: card settle
    await sleep(CARD_SETTLE_MS);

    // Step 8: studio_card_list — exactly 1 card, title "hello"
    const r3raw = await callPlugin<CardListResult>(
      plugin.port,
      "/api/card/list?room=rt-test",
      "GET",
    );
    responses["card_list_all"] = r3raw;
    const r3 = ensureOk("studio_card_list (initial)", r3raw);
    expect(r3.cards.length).toBe(1);
    expect(r3.cards[0]?.title).toBe("hello");
    expect(r3.cards[0]?.track).toBe("inbox");

    // Step 9: studio_room_list — epoch=1, members=[plugin_pub], state=active
    const r4raw = await callPlugin<RoomListResult>(
      plugin.port,
      "/api/room/list",
      "GET",
    );
    responses["room_list"] = r4raw;
    const r4 = ensureOk("studio_room_list", r4raw);
    expect(r4.rooms.length).toBe(1);
    const room = r4.rooms[0]!;
    expect(room.epoch).toBe(1);
    expect(room.members.map((m) => m.toLowerCase())).toEqual([pluginPub]);
    expect(room.state).toBe("active");

    // Step 10a: studio_track_create("staging")
    const r5raw = await callPlugin<TrackCreateResult>(
      plugin.port,
      "/api/track/create",
      "POST",
      { room: "rt-test", name: "staging", title: "Staging" },
    );
    responses["track_create_staging"] = r5raw;
    ensureOk("studio_track_create", r5raw);

    // Step 10b: studio_card_post to staging
    const r6raw = await callPlugin<CardPostResult>(
      plugin.port,
      "/api/card/post",
      "POST",
      {
        room: "rt-test",
        track: "staging",
        kind: "note",
        title: "stage-only",
        summary: "from staging",
        blocks: [{ type: "text", body: "stage body" }],
      },
    );
    responses["card_post_staging"] = r6raw;
    ensureOk("studio_card_post (staging)", r6raw);

    await sleep(TRACK_SETTLE_MS);

    // Step 11: list filtered to inbox — original card only
    const r7raw = await callPlugin<CardListResult>(
      plugin.port,
      "/api/card/list?room=rt-test&track=inbox",
      "GET",
    );
    responses["card_list_inbox"] = r7raw;
    const r7 = ensureOk("studio_card_list (inbox filter)", r7raw);
    expect(r7.cards.length).toBe(1);
    expect(r7.cards[0]?.title).toBe("hello");
    expect(r7.cards[0]?.track).toBe("inbox");

    // Step 12: list filtered to staging — new card only
    const r8raw = await callPlugin<CardListResult>(
      plugin.port,
      "/api/card/list?room=rt-test&track=staging",
      "GET",
    );
    responses["card_list_staging"] = r8raw;
    const r8 = ensureOk("studio_card_list (staging filter)", r8raw);
    expect(r8.cards.length).toBe(1);
    expect(r8.cards[0]?.title).toBe("stage-only");
    expect(r8.cards[0]?.track).toBe("staging");

    // Pass-criteria sweep: relay-failure / panic in any captured response or
    // log line is a fail. ensureOk already screens responses; check logs +
    // fixture-wide for stragglers.
    const logs = readPluginLogTail(plugin);
    assertNoPanics(logs);
    assertNoRelayFailures(responses);

    return {
      ts: new Date().toISOString(),
      gateway: GATEWAY,
      plugin_pub: pluginPub,
      responses,
      plugin_log_tail: logs.slice(-200),
      attempts: attempt,
    };
  } finally {
    if (plugin) {
      // Step 13: tear down (kill plugin, drop test "db").
      await killPlugin(plugin);
      try {
        rmSync(plugin.dataDir, { recursive: true, force: true });
      } catch {
        /* ignore */
      }
    }
    await shim.close();
  }
}

function readPluginLogTail(p: PluginHandle): string[] {
  const tail: string[] = [];
  // 1) stdout/stderr buffers we drained live.
  for (const l of p.stdoutBuf) tail.push(`[stdout] ${l}`);
  for (const l of p.stderrBuf) tail.push(`[stderr] ${l}`);
  // 2) the JSON log file the plugin's logger.ts writes.
  const logFile = join(p.dataDir, "logs", "sonata-studio.log");
  if (existsSync(logFile)) {
    try {
      const raw = readFileSync(logFile, "utf8");
      for (const line of raw.split("\n")) {
        if (line.length > 0) tail.push(`[log] ${line}`);
      }
    } catch {
      /* ignore */
    }
  }
  return tail;
}

function assertNoPanics(logs: string[]): void {
  const banned = /\b(panic|fatal startup error|UnhandledPromiseRejection)\b/i;
  const hit = logs.find((l) => banned.test(l));
  if (hit) {
    throw new Error(`plugin log contained panic-class line: ${hit}`);
  }
}

function assertNoRelayFailures(responses: Record<string, unknown>): void {
  for (const [label, body] of Object.entries(responses)) {
    if (!body || typeof body !== "object") continue;
    const o = body as PluginResponse;
    if (o.ok === false && (o.error === "relay_failure" || o.error === "gateway_unavailable")) {
      throw new RelayAttributableError(
        `${label} surfaced ${o.error}: ${o.message ?? ""}`,
      );
    }
  }
}
