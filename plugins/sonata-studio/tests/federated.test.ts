// Phase 3 T4 — Cross-machine federated round-trip test. Per plan §2.3 of
// /Users/evan/memory/claude/documents/evenflow/sonata-studio-v0-phase3-plan.md.
//
// Two plugin processes:
//   - Workstation: spawned in-process against the same memory shim used by
//     round-trip.test.ts. The shim represents the workstation's Sonata.
//   - Scout: a long-lived plugin already running on 192.168.0.17:4200, backed
//     by Scout's real Sonata at 192.168.0.17:3211.
//
// Walks plan §2.3 lines 201-232:
//   create → invite → join (Scout) → admit → state flip → 5× scout→ws timed
//   posts → 5× ws→scout timed posts → fixture writeout. Asserts median ≤
//   LATENCY_BUDGET_MS, p99 ≤ 2× budget.
//
// SKIPS unless STUDIO_FEDERATED=1 — Scout availability is environmental;
// CI must not depend on the workstation→Scout LAN.
//
// Flake-tolerant: 3 retries on relay-attributable failures (gateway 502
// `relay_failure`, NIP-98 transport, SSE). Same shape as round-trip.test.ts.
//
// Run with: STUDIO_FEDERATED=1 bun test tests/federated.test.ts
//
// Divergence from §2.3 step 2.5: there is no Sonata HTTP endpoint that exposes
// a plugin's stored plugin_pub (PluginManager.listPlugins omits config_json),
// and the studio plugin only exposes /api/health. The key-reuse guard
// therefore fires after step 7's state flip — once Scout's pub appears in
// the workstation room.members array, we derive Scout's pluginPub and assert
// inequality. Same effect, slightly later step. If they collide we abort
// with "scout_keypair_collision — investigate config-leak".

import { test, expect, beforeAll, afterAll } from "bun:test";
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

const SCOUT_HTTP = process.env["STUDIO_SCOUT_HTTP"] ?? "http://192.168.0.17:4200";
// Scout's Sonata.app binds 3211 to localhost only — the workstation reaches it
// via an SSH tunnel established by beforeAll() below. Default points at the
// tunnel's local end; override STUDIO_SCOUT_SONATA to point at a pre-existing
// tunnel or a Scout configured to listen on the LAN. STUDIO_SCOUT_SSH_TUNNEL
// can be set to "skip" to suppress the auto-tunnel (operator-managed tunnel).
const SCOUT_SONATA = process.env["STUDIO_SCOUT_SONATA"] ?? "http://127.0.0.1:3212";
const SCOUT_SSH_HOST = process.env["STUDIO_SCOUT_SSH_HOST"] ?? "scout@192.168.0.17";
const SCOUT_SSH_KEY = process.env["STUDIO_SCOUT_SSH_KEY"] ?? `${process.env["HOME"] ?? ""}/.ssh/scout_ed25519`;
const SCOUT_SSH_TUNNEL_LOCAL_PORT = Number(process.env["STUDIO_SCOUT_SSH_TUNNEL_LOCAL_PORT"] ?? "3212");
const SCOUT_SSH_TUNNEL_REMOTE_PORT = Number(process.env["STUDIO_SCOUT_SSH_TUNNEL_REMOTE_PORT"] ?? "3211");
const SCOUT_SSH_TUNNEL_MODE = process.env["STUDIO_SCOUT_SSH_TUNNEL"] ?? "auto";
const GATEWAY = process.env["STUDIO_RT_GATEWAY"] ?? "https://api.4a4.ai";
const LATENCY_BUDGET_MS = Number(process.env["STUDIO_LATENCY_BUDGET_MS"] ?? "2000");

const FEDERATED_ENABLED = process.env["STUDIO_FEDERATED"] === "1";

const MAX_RETRIES = 3;
const PLUGIN_HEALTH_TIMEOUT_MS = 60_000;
const STATE_FLIP_DEADLINE_MS = 10_000;
const STATE_FLIP_POLL_MS = 250;
const CARD_RECV_DEADLINE_MS = 10_000;
const CARD_RECV_POLL_MS = 100;
const ITERATIONS = 5;
const PER_ATTEMPT_TIMEOUT_MS = 180_000;
const SCOUT_HTTP_TIMEOUT_MS = 30_000;

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(TEST_DIR, "..");
const PLUGIN_BIN = join(PROJECT_ROOT, "bin", "sonata-studio");
const FIXTURE_OUT = join(TEST_DIR, "federated.fixture.json");

// ── Memory shim (matches round-trip.test.ts) ────────────────────────────────

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

function rowOut(e: EntityRow): EntityRow & { attributes: string } {
  return { ...e, attributes: JSON.stringify(e.attributes) };
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

    if (path === "/api/ping") return send(res, 200, { ok: true });

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

// ── Plugin process (workstation only — Scout is long-lived) ─────────────────

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

  const dataDir = mkdtempSync(join(tmpdir(), "studio-fed-data-"));
  mkdirSync(join(dataDir, "logs"), { recursive: true });
  const port = await freePort();

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
    if (out.length > 2000) out.splice(0, out.length - 2000);
  }
}

async function killPlugin(p: PluginHandle): Promise<void> {
  try {
    p.proc.kill("SIGTERM");
  } catch {
    /* ignore */
  }
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

// ── HTTP clients ────────────────────────────────────────────────────────────

interface PluginResponse<T = unknown> {
  ok: boolean;
  result?: T;
  error?: string;
  message?: string;
  status?: number;
}

async function callPluginAt<T = unknown>(
  baseUrl: string,
  pathAndQuery: string,
  method: "GET" | "POST",
  body?: Record<string, unknown>,
  timeoutMs: number = SCOUT_HTTP_TIMEOUT_MS,
): Promise<PluginResponse<T>> {
  const url = `${baseUrl}${pathAndQuery}`;
  const init: RequestInit = { method };
  if (method === "POST" && body !== undefined) {
    init.headers = { "Content-Type": "application/json" };
    init.body = JSON.stringify(body);
  }
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  init.signal = ctrl.signal;
  try {
    const res = await fetch(url, init);
    const text = await res.text();
    try {
      return JSON.parse(text) as PluginResponse<T>;
    } catch {
      throw new Error(
        `${url} returned non-JSON (HTTP ${res.status}): ${text.slice(0, 200)}`,
      );
    }
  } finally {
    clearTimeout(t);
  }
}

async function waitForPluginHealth(baseUrl: string, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let lastErr = "no attempt";
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${baseUrl}/api/health`);
      if (res.ok) return;
      lastErr = `status=${res.status}`;
    } catch (e) {
      lastErr = e instanceof Error ? e.message : String(e);
    }
    await sleep(250);
  }
  throw new Error(
    `${baseUrl}/api/health never returned 200 within ${timeoutMs}ms: ${lastErr}`,
  );
}

const sleep = (ms: number): Promise<void> =>
  new Promise((r) => setTimeout(r, ms));

// ── Scout Sonata entity polling (real Sonata HTTP API) ──────────────────────

interface SonataEntityRow {
  id: string;
  name: string;
  type: string;
  attributes: string; // JSON string
}

async function fetchScoutEntity(name: string): Promise<SonataEntityRow | null> {
  const url = `${SCOUT_SONATA}/api/entity?name=${encodeURIComponent(name)}`;
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), SCOUT_HTTP_TIMEOUT_MS);
  try {
    const res = await fetch(url, { signal: ctrl.signal });
    if (!res.ok) return null;
    const body = await res.json();
    if (body && typeof body === "object" && "name" in body) {
      return body as SonataEntityRow;
    }
    return null;
  } finally {
    clearTimeout(t);
  }
}

function parseAttrs(raw: string | undefined | null): Record<string, unknown> {
  if (!raw) return {};
  try {
    const v = JSON.parse(raw);
    if (v && typeof v === "object" && !Array.isArray(v)) {
      return v as Record<string, unknown>;
    }
  } catch {
    /* ignore */
  }
  return {};
}

// ── Result types (mirror plugin handler returns) ────────────────────────────

interface RoomCreateResult {
  audience_address: string;
  room_event_id: string;
  declaration_event_id: string;
  founding_grant_event_id: string;
  members: string[];
  epoch: number;
  default_tracks: string[];
}

interface RoomInviteResult {
  s4a_url: string;
  https_url: string;
  invite_pub: string;
  expires_at: number;
}

interface RoomJoinResult {
  audience_address: string;
  room_slug: string;
  epoch: number;
  claim_event_id: string;
  state: "active" | "pending-grant";
}

interface AdmittedEntry {
  claim_pubkey: string;
  key_grant_event_id: string;
}

interface RoomAdmitResult {
  ok: boolean;
  admitted: AdmittedEntry[];
  new_epoch: number;
  declaration_event_id: string | null;
  failed?: Array<{ recipient: string; reason: string }>;
  error?: string;
}

interface CardPostResult {
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
  return /relay_failure|gateway_unavailable|network_error|ECONN|ETIMEDOUT|fetch failed|aborted|SSE/i.test(
    msg,
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

// ── Latency stats ───────────────────────────────────────────────────────────

function median(xs: number[]): number {
  if (xs.length === 0) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 === 0 ? (s[mid - 1]! + s[mid]!) / 2 : s[mid]!;
}

function percentile(xs: number[], p: number): number {
  if (xs.length === 0) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const idx = Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1));
  return s[idx]!;
}

// ── Fixture types ───────────────────────────────────────────────────────────

interface IterationEntry {
  direction: "scout->workstation" | "workstation->scout";
  t_post_ms: number;
  t_recv_ms: number;
  latency_ms: number;
  card_event_id: string;
}

interface EventLogEntry {
  t: number;
  actor: "workstation" | "scout";
  action: string;
  result: unknown;
}

interface Fixture {
  ts: string;
  gateway: string;
  workstation_pub: string;
  scout_pub: string;
  audience_address: string;
  room_slug: string;
  iterations: IterationEntry[];
  summary: { median_ms: number; p99_ms: number; max_ms: number };
  events: EventLogEntry[];
  attempts: number;
  workstation_log_tail: string[];
}

// ── SSH tunnel to Scout's Sonata ────────────────────────────────────────────
// Scout's Sonata.app binds 3211 to localhost; the workstation reaches it via
// an `ssh -NL <local>:localhost:<remote>` tunnel kept open for the duration
// of the test. Spawned without -f so we hold a Subprocess handle and can
// reliably kill it in afterAll(). Set STUDIO_SCOUT_SSH_TUNNEL=skip to
// suppress (e.g. when an operator-managed tunnel is already up, or when
// STUDIO_SCOUT_SONATA points somewhere else).

let sshTunnel: Subprocess | null = null;

async function probeTcp(host: string, port: number, timeoutMs: number): Promise<boolean> {
  const url = `http://${host}:${port}/api/ping`;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const r = await fetch(url, { signal: AbortSignal.timeout(1_000) });
      if (r.ok) return true;
    } catch {
      // ignore
    }
    await sleep(100);
  }
  return false;
}

async function startScoutTunnel(): Promise<void> {
  if (!FEDERATED_ENABLED) return;
  if (SCOUT_SSH_TUNNEL_MODE === "skip") return;
  // Already reachable (operator-managed tunnel, or non-default override).
  if (await probeTcp("127.0.0.1", SCOUT_SSH_TUNNEL_LOCAL_PORT, 500)) return;

  const args = [
    "-N",
    "-L",
    `${SCOUT_SSH_TUNNEL_LOCAL_PORT}:localhost:${SCOUT_SSH_TUNNEL_REMOTE_PORT}`,
    "-o",
    "IdentitiesOnly=yes",
    "-o",
    "ExitOnForwardFailure=yes",
    "-o",
    "ServerAliveInterval=30",
    "-o",
    "StrictHostKeyChecking=accept-new",
    "-i",
    SCOUT_SSH_KEY,
    SCOUT_SSH_HOST,
  ];
  sshTunnel = spawn({
    cmd: ["ssh", ...args],
    stdout: "pipe",
    stderr: "pipe",
    stdin: "ignore",
  });
  const ok = await probeTcp("127.0.0.1", SCOUT_SSH_TUNNEL_LOCAL_PORT, 8_000);
  if (!ok) {
    try {
      sshTunnel?.kill();
    } catch {
      // ignore
    }
    sshTunnel = null;
    throw new Error(
      `failed to establish SSH tunnel ${SCOUT_SSH_TUNNEL_LOCAL_PORT}:localhost:${SCOUT_SSH_TUNNEL_REMOTE_PORT} via ${SCOUT_SSH_HOST} — ` +
        `set STUDIO_SCOUT_SSH_TUNNEL=skip and provide your own tunnel, or fix STUDIO_SCOUT_SSH_KEY/STUDIO_SCOUT_SSH_HOST.`,
    );
  }
}

async function stopScoutTunnel(): Promise<void> {
  if (!sshTunnel) return;
  try {
    sshTunnel.kill();
    await sshTunnel.exited;
  } catch {
    // ignore
  }
  sshTunnel = null;
}

beforeAll(async () => {
  await startScoutTunnel();
});

afterAll(async () => {
  await stopScoutTunnel();
});

// ── The test ────────────────────────────────────────────────────────────────

const describeIfFederated = FEDERATED_ENABLED ? test : test.skip;

describeIfFederated(
  "federated round-trip (Phase 3 acceptance gate)",
  async () => {
    const errors: unknown[] = [];

    for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
      try {
        const fixture = await runOnce(attempt);
        writeFileSync(FIXTURE_OUT, JSON.stringify(fixture, null, 2));
        return;
      } catch (err) {
        errors.push(err);
        const retryable = isRelayAttributable(err);
        if (!retryable || attempt === MAX_RETRIES) {
          const tail = errors
            .map((e, i) => {
              const m = e instanceof Error ? e.message : String(e);
              return `  attempt ${i + 1}: ${m}`;
            })
            .join("\n");
          throw new Error(
            `federated round-trip failed after ${attempt} attempt(s):\n${tail}`,
          );
        }
        await sleep(2_000 * attempt);
      }
    }
    throw new Error("unreachable");
  },
  PER_ATTEMPT_TIMEOUT_MS * MAX_RETRIES + 30_000,
);

if (!FEDERATED_ENABLED) {
  test("federated round-trip skipped (set STUDIO_FEDERATED=1 to run)", () => {
    expect(FEDERATED_ENABLED).toBe(false);
  });
}

// ── Run a single attempt ────────────────────────────────────────────────────

async function runOnce(attempt: number): Promise<Fixture> {
  const events: EventLogEntry[] = [];
  const t0 = Date.now();
  const logEvent = (
    actor: EventLogEntry["actor"],
    action: string,
    result: unknown,
  ): void => {
    events.push({ t: Date.now() - t0, actor, action, result });
  };

  // Step 1: spawn workstation plugin against in-process shim.
  const shim = await startMemoryShim();
  let workstation: PluginHandle | null = null;
  const slug = `fed-rt-${Math.random().toString(16).slice(2, 8)}`;

  try {
    workstation = await startPlugin(shim.baseUrl);
    await waitForPluginHealth(`http://127.0.0.1:${workstation.port}`, PLUGIN_HEALTH_TIMEOUT_MS);

    const wsCfg = shim.state.pluginConfigs.get("sonata-studio") ?? {};
    const workstationPub = String(wsCfg["plugin_pub"] ?? "").toLowerCase();
    if (workstationPub.length !== 64) {
      throw new Error(
        `workstation plugin did not register a 64-hex pubkey (got "${workstationPub}")`,
      );
    }

    // Step 2: probe Scout health endpoints. Skip with a clear message if
    // either fails. Expressed as an early throw — caller surfaces it.
    try {
      await waitForPluginHealth(SCOUT_HTTP, 5_000);
    } catch (e) {
      throw new Error(
        `Scout plugin /api/health unreachable at ${SCOUT_HTTP} — ${
          e instanceof Error ? e.message : String(e)
        }. Set STUDIO_SCOUT_HTTP or skip with STUDIO_FEDERATED unset.`,
      );
    }
    try {
      const ping = await fetch(`${SCOUT_SONATA}/api/ping`);
      if (!ping.ok) {
        throw new Error(`HTTP ${ping.status}`);
      }
    } catch (e) {
      throw new Error(
        `Scout Sonata /api/ping unreachable at ${SCOUT_SONATA} — ${
          e instanceof Error ? e.message : String(e)
        }`,
      );
    }

    // (Step 2.5 deferred — see file header. Scout's plugin_pub is not
    // exposed via Sonata's HTTP API; we derive it from the room.members
    // array post-admit and assert inequality there.)

    // Step 3: workstation studio_room_create.
    const wsBase = `http://127.0.0.1:${workstation.port}`;
    const createRaw = await callPluginAt<RoomCreateResult>(
      wsBase,
      "/api/room/create",
      "POST",
      {
        slug,
        title: "Federated RT",
        default_tracks: ["main"],
      },
    );
    logEvent("workstation", "studio_room_create", createRaw);
    const create = ensureOk("studio_room_create", createRaw);
    expect(create.audience_address.length).toBeGreaterThan(0);
    expect(create.members.map((m) => m.toLowerCase())).toEqual([workstationPub]);
    expect(create.epoch).toBe(1);
    const audienceAddress = create.audience_address;

    // Step 4: workstation studio_room_invite.
    const inviteRaw = await callPluginAt<RoomInviteResult>(
      wsBase,
      "/api/room/invite",
      "POST",
      { room_slug: slug },
    );
    logEvent("workstation", "studio_room_invite", inviteRaw);
    const invite = ensureOk("studio_room_invite", inviteRaw);
    expect(invite.s4a_url.startsWith("s4a://invite/")).toBe(true);

    // Step 5: Scout studio_room_join via the s4a:// invite URL.
    const joinRaw = await callPluginAt<RoomJoinResult>(
      SCOUT_HTTP,
      "/api/room/join",
      "POST",
      { invite_url: invite.s4a_url },
    );
    logEvent("scout", "studio_room_join", joinRaw);
    const join = ensureOk("studio_room_join", joinRaw);
    expect(join.state).toBe("pending-grant");
    expect(join.audience_address).toBe(audienceAddress);
    expect(join.room_slug).toBe(slug);

    // Step 6: workstation studio_room_admit.
    const admitRaw = await callPluginAt<RoomAdmitResult>(
      wsBase,
      "/api/room/admit",
      "POST",
      { room_slug: slug },
    );
    logEvent("workstation", "studio_room_admit", admitRaw);
    const admit = ensureOk("studio_room_admit", admitRaw);
    if (!admit.ok || admit.admitted.length < 1) {
      throw new Error(
        `studio_room_admit returned no admitted entries: ${JSON.stringify(admit)}`,
      );
    }
    const scoutPub = admit.admitted[0]!.claim_pubkey.toLowerCase();
    if (scoutPub.length !== 64) {
      throw new Error(`admit returned invalid claim_pubkey: ${scoutPub}`);
    }

    // Key-reuse guard (deferred from §2.3 step 2.5 — see file header).
    if (scoutPub === workstationPub) {
      throw new Error(
        `scout_keypair_collision — investigate config-leak (workstation_pub=${workstationPub}, scout_pub=${scoutPub})`,
      );
    }

    // Step 7: wait for Scout's room state to flip to "active". Poll Scout's
    // real Sonata at SCOUT_SONATA/api/entity?name=studio:room:<slug>.
    const scoutRoomName = `studio:room:${slug}`;
    const flipDeadline = Date.now() + STATE_FLIP_DEADLINE_MS;
    let scoutRoomAttrs: Record<string, unknown> | null = null;
    while (Date.now() < flipDeadline) {
      const ent = await fetchScoutEntity(scoutRoomName);
      if (ent) {
        const a = parseAttrs(ent.attributes);
        if (a["state"] === "active") {
          scoutRoomAttrs = a;
          break;
        }
      }
      await sleep(STATE_FLIP_POLL_MS);
    }
    if (!scoutRoomAttrs) {
      throw new RelayAttributableError(
        `Scout room state did not flip to "active" within ${STATE_FLIP_DEADLINE_MS}ms (last entity attrs unread)`,
      );
    }
    logEvent("scout", "state_flip_active", { name: scoutRoomName, attrs: scoutRoomAttrs });

    const scoutMembers = Array.isArray(scoutRoomAttrs["members"])
      ? (scoutRoomAttrs["members"] as unknown[]).map((m) => String(m).toLowerCase())
      : [];
    expect(scoutMembers).toContain(workstationPub);
    expect(scoutMembers).toContain(scoutPub);
    expect(Number(scoutRoomAttrs["current_epoch"] ?? 0)).toBe(2);

    // Steps 8-12: forward direction (Scout posts → workstation receives) ×5.
    const forwardIterations: IterationEntry[] = [];
    for (let i = 0; i < ITERATIONS; i++) {
      const iter = await timedPost({
        direction: "scout->workstation",
        senderBaseUrl: SCOUT_HTTP,
        senderPub: scoutPub,
        recvLookup: (entityName) => fetchShimEntity(shim.state, entityName),
        room: slug,
        track: "main",
        title: `fed-rt-fwd-${i}`,
        summary: `hello from Scout #${i}`,
      });
      forwardIterations.push(iter);
      logEvent("scout", "studio_card_post", iter);
    }

    // Step 13: reverse direction (workstation posts → Scout receives) ×5.
    const reverseIterations: IterationEntry[] = [];
    for (let i = 0; i < ITERATIONS; i++) {
      const iter = await timedPost({
        direction: "workstation->scout",
        senderBaseUrl: wsBase,
        senderPub: workstationPub,
        recvLookup: (entityName) => fetchScoutEntityRaw(entityName),
        room: slug,
        track: "main",
        title: `fed-rt-rev-${i}`,
        summary: `hello from workstation #${i}`,
      });
      reverseIterations.push(iter);
      logEvent("workstation", "studio_card_post", iter);
    }

    // Step 11/12: latency assertions per direction.
    const allIterations = [...forwardIterations, ...reverseIterations];
    const latencies = allIterations.map((i) => i.latency_ms);
    const med = median(latencies);
    const p99 = percentile(latencies, 99);
    const max = Math.max(...latencies);

    expect(med).toBeLessThanOrEqual(LATENCY_BUDGET_MS);
    expect(p99).toBeLessThanOrEqual(LATENCY_BUDGET_MS * 2);
    for (const it of allIterations) {
      // Per-iteration upper bound — surfaces an outlier without aborting
      // the whole assertion suite (Bun's `expect` is fail-fast).
      if (it.latency_ms > LATENCY_BUDGET_MS * 2) {
        throw new Error(
          `iteration ${it.direction} latency=${it.latency_ms}ms exceeds 2× budget`,
        );
      }
    }

    // Step 14: build fixture.
    const logTail = readWorkstationLogTail(workstation);
    return {
      ts: new Date().toISOString(),
      gateway: GATEWAY,
      workstation_pub: workstationPub,
      scout_pub: scoutPub,
      audience_address: audienceAddress,
      room_slug: slug,
      iterations: allIterations,
      summary: { median_ms: med, p99_ms: p99, max_ms: max },
      events,
      attempts: attempt,
      workstation_log_tail: logTail.slice(-200),
    };
  } finally {
    // Step 15: SIGTERM workstation; LEAVE Scout running; LEAVE rooms intact.
    if (workstation) {
      await killPlugin(workstation);
      try {
        rmSync(workstation.dataDir, { recursive: true, force: true });
      } catch {
        /* ignore */
      }
    }
    await shim.close();
  }
}

// ── Timed post helper ───────────────────────────────────────────────────────

interface TimedPostArgs {
  direction: IterationEntry["direction"];
  senderBaseUrl: string;
  senderPub: string;
  recvLookup: (entityName: string) => Promise<{ attributes: Record<string, unknown> } | null>;
  room: string;
  track: string;
  title: string;
  summary: string;
}

async function timedPost(args: TimedPostArgs): Promise<IterationEntry> {
  const postRaw = await callPluginAt<CardPostResult>(
    args.senderBaseUrl,
    "/api/card/post",
    "POST",
    {
      room: args.room,
      track: args.track,
      kind: "note",
      title: args.title,
      summary: args.summary,
      blocks: [{ type: "text", body: args.summary }],
    },
  );
  const t_post = Date.now();
  const post = ensureOk(`studio_card_post (${args.direction})`, postRaw);

  const entityName = `studio:card:${args.room}:${args.senderPub}:${post.d_tag}`;
  const deadline = Date.now() + CARD_RECV_DEADLINE_MS;
  let t_recv = 0;
  while (Date.now() < deadline) {
    try {
      const found = await args.recvLookup(entityName);
      if (found) {
        const eventId = String(found.attributes["event_id"] ?? "");
        if (eventId === post.rumor_event_id) {
          t_recv = Date.now();
          break;
        }
      }
    } catch {
      /* keep polling */
    }
    await sleep(CARD_RECV_POLL_MS);
  }

  if (t_recv === 0) {
    throw new RelayAttributableError(
      `card not received within ${CARD_RECV_DEADLINE_MS}ms (${args.direction}, event_id=${post.rumor_event_id})`,
    );
  }

  return {
    direction: args.direction,
    t_post_ms: t_post,
    t_recv_ms: t_recv,
    latency_ms: t_recv - t_post,
    card_event_id: post.rumor_event_id,
  };
}

async function fetchShimEntity(
  state: ShimState,
  name: string,
): Promise<{ attributes: Record<string, unknown> } | null> {
  const found = [...state.entities.values()].find((e) => e.name === name);
  if (!found) return null;
  return { attributes: found.attributes };
}

async function fetchScoutEntityRaw(
  name: string,
): Promise<{ attributes: Record<string, unknown> } | null> {
  const ent = await fetchScoutEntity(name);
  if (!ent) return null;
  return { attributes: parseAttrs(ent.attributes) };
}

// ── Workstation log tail (for fixture diagnostics) ──────────────────────────

function readWorkstationLogTail(p: PluginHandle): string[] {
  const tail: string[] = [];
  for (const l of p.stdoutBuf) tail.push(`[stdout] ${l}`);
  for (const l of p.stderrBuf) tail.push(`[stderr] ${l}`);
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
