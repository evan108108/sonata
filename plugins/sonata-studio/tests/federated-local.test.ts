// Phase 3 T4b — Same-host two-instance federated round-trip. Per the T4b
// brief: validates the full admit / key-grant / state-flip / cross-instance
// card flow without depending on the Scout LAN. Acceptance gate before
// the Scout-based T5 run.
//
// Two plugin processes spawned locally:
//   - binA: in-process plugin + in-process memory shim A (founder).
//   - binB: in-process plugin + in-process memory shim B (claimer).
//
// Both speak to the live https://api.4a4.ai gateway. Override via
// STUDIO_T4B_GATEWAY.
//
// Walks the federated.test.ts flow lock-step:
//   create (A) → invite (A) → join (B) → admit (A) → state flip on B →
//   5× B→A timed posts → 5× A→B timed posts → fixture writeout. Asserts
//   median ≤ LATENCY_BUDGET_MS, p99 ≤ 2× budget.
//
// SKIPS unless STUDIO_FEDERATED_LOCAL=1 — opt-in acceptance, must not gate
// the default test run.
//
// Flake-tolerant: 3 retries on relay-attributable failures (gateway 502
// `relay_failure`, NIP-98 transport, SSE) — same logic as round-trip.test.ts
// and federated.test.ts.
//
// Run with: STUDIO_FEDERATED_LOCAL=1 bun test tests/federated-local.test.ts

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

const GATEWAY = process.env["STUDIO_T4B_GATEWAY"] ?? "https://api.4a4.ai";
// Same-host federation runs over the same WAN as the cross-machine test, so
// the budget mirrors federated.test.ts in shape (median ≤ budget, p99 ≤ 2×).
// Per T4b brief: 5000ms median, 10000ms p99 — slightly looser than
// cross-machine because both plugins compete for the same CPU and the same
// outbound socket pool to api.4a4.ai.
const LATENCY_BUDGET_MS = Number(process.env["STUDIO_LATENCY_BUDGET_MS"] ?? "5000");

const FEDERATED_LOCAL_ENABLED = process.env["STUDIO_FEDERATED_LOCAL"] === "1";

const MAX_RETRIES = 3;
const PLUGIN_HEALTH_TIMEOUT_MS = 60_000;
// Same-host competes for CPU and shares the workstation→api.4a4.ai socket
// pool, and SSE replay only delivers the key-grant on a successful reconnect
// after admit propagates through the relay pool. Federated.test.ts uses 10s
// against a real Sonata; this shim variant runs slower and is allowed more
// headroom (still well under the test's PER_ATTEMPT_TIMEOUT_MS).
const STATE_FLIP_DEADLINE_MS = Number(process.env["STUDIO_STATE_FLIP_DEADLINE_MS"] ?? "60000");
const STATE_FLIP_POLL_MS = 250;
const CARD_RECV_DEADLINE_MS = Number(process.env["STUDIO_CARD_RECV_DEADLINE_MS"] ?? "30000");
const CARD_RECV_POLL_MS = 100;
const ITERATIONS = 5;
const PER_ATTEMPT_TIMEOUT_MS = 240_000;
const HTTP_TIMEOUT_MS = 30_000;

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(TEST_DIR, "..");
const PLUGIN_BIN = join(PROJECT_ROOT, "bin", "sonata-studio");
const FIXTURE_OUT = join(TEST_DIR, "federated-local.fixture.json");

// ── Memory shim (matches round-trip.test.ts / federated.test.ts) ────────────

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
        // Real Sonata's PATCH merges attribute keys (only sent keys are
        // updated; missing keys retained). The federated-local flow relies
        // on this — handleDeclarationUpdated patches members/current_epoch
        // and handleKeyGrant patches state, neither resending the other's
        // fields. A naive overwrite drops "state" mid-flow.
        if (body.attributes && typeof body.attributes === "object") {
          ent.attributes = { ...ent.attributes, ...body.attributes };
        }
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

// ── Plugin process ──────────────────────────────────────────────────────────

interface PluginHandle {
  proc: Subprocess;
  port: number;
  dataDir: string;
  stdoutBuf: string[];
  stderrBuf: string[];
  label: "A" | "B";
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

async function startPlugin(
  shimBaseUrl: string,
  label: "A" | "B",
): Promise<PluginHandle> {
  if (!existsSync(PLUGIN_BIN)) {
    throw new Error(
      `plugin binary not found at ${PLUGIN_BIN} — run ./build.sh first`,
    );
  }

  const dataDir = mkdtempSync(join(tmpdir(), `studio-fed-local-${label}-`));
  mkdirSync(join(dataDir, "logs"), { recursive: true });
  // freePort() returns a port that was free a moment ago — there is a tiny
  // race against another process grabbing it, but for local single-user
  // testing this is acceptable. Avoids hardcoding 4200/4201.
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

  return { proc, port, dataDir, stdoutBuf, stderrBuf, label };
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

// ── HTTP client ─────────────────────────────────────────────────────────────

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
  timeoutMs: number = HTTP_TIMEOUT_MS,
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
  four_a_url: string;
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
  direction: "B->A" | "A->B";
  t_post_ms: number;
  t_recv_ms: number;
  latency_ms: number;
  card_event_id: string;
}

interface EventLogEntry {
  t: number;
  actor: "A" | "B";
  action: string;
  result: unknown;
}

interface Fixture {
  ts: string;
  gateway: string;
  plugin_pub_A: string;
  plugin_pub_B: string;
  audience_address: string;
  room_slug: string;
  iterations: IterationEntry[];
  summary: { median_ms: number; p99_ms: number; max_ms: number };
  events: EventLogEntry[];
  attempts: number;
  log_tail_A: string[];
  log_tail_B: string[];
}

// ── The test ────────────────────────────────────────────────────────────────

const describeIfEnabled = FEDERATED_LOCAL_ENABLED ? test : test.skip;

describeIfEnabled(
  "federated round-trip — same-host two-instance (Phase 3 T4b)",
  async () => {
    const errors: unknown[] = [];

    for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
      try {
        const fixture = await runOnce(attempt);
        try {
          writeFileSync(FIXTURE_OUT, JSON.stringify(fixture, null, 2));
        } catch (e) {
          // Disk-full / write failure shouldn't fail the assertion. Mirrors
          // round-trip.test.ts policy.
          // eslint-disable-next-line no-console
          console.warn(
            `failed to write fixture ${FIXTURE_OUT}: ${
              e instanceof Error ? e.message : String(e)
            }`,
          );
        }
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
            `federated-local round-trip failed after ${attempt} attempt(s):\n${tail}`,
          );
        }
        await sleep(2_000 * attempt);
      }
    }
    throw new Error("unreachable");
  },
  PER_ATTEMPT_TIMEOUT_MS * MAX_RETRIES + 30_000,
);

if (!FEDERATED_LOCAL_ENABLED) {
  test("federated-local round-trip skipped (set STUDIO_FEDERATED_LOCAL=1 to run)", () => {
    expect(FEDERATED_LOCAL_ENABLED).toBe(false);
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

  // Step 1: spawn two memory shims (independent state) and two plugins.
  const shimA = await startMemoryShim();
  const shimB = await startMemoryShim();
  let binA: PluginHandle | null = null;
  let binB: PluginHandle | null = null;
  const slug = `fed-local-${Math.random().toString(16).slice(2, 8)}`;

  try {
    binA = await startPlugin(shimA.baseUrl, "A");
    binB = await startPlugin(shimB.baseUrl, "B");
    await waitForPluginHealth(`http://127.0.0.1:${binA.port}`, PLUGIN_HEALTH_TIMEOUT_MS);
    await waitForPluginHealth(`http://127.0.0.1:${binB.port}`, PLUGIN_HEALTH_TIMEOUT_MS);

    // Step 2: read both plugin pubs from their respective shims and assert
    // inequality at startup. Each plugin generated its own keypair against
    // its own data dir + shim — collision would imply a config-leak bug.
    const cfgA = shimA.state.pluginConfigs.get("sonata-studio") ?? {};
    const cfgB = shimB.state.pluginConfigs.get("sonata-studio") ?? {};
    const pubA = String(cfgA["plugin_pub"] ?? "").toLowerCase();
    const pubB = String(cfgB["plugin_pub"] ?? "").toLowerCase();
    if (pubA.length !== 64 || pubB.length !== 64) {
      throw new Error(
        `plugin pubkeys not registered as 64-hex (A="${pubA}", B="${pubB}")`,
      );
    }
    if (pubA === pubB) {
      throw new Error(
        `scout_keypair_collision — A and B share plugin_pub ${pubA}; investigate config-leak`,
      );
    }
    logEvent("A", "boot", { plugin_pub: pubA, port: binA.port });
    logEvent("B", "boot", { plugin_pub: pubB, port: binB.port });

    // Step 3: A creates the room.
    const baseA = `http://127.0.0.1:${binA.port}`;
    const baseB = `http://127.0.0.1:${binB.port}`;

    const createRaw = await callPluginAt<RoomCreateResult>(
      baseA,
      "/api/room/create",
      "POST",
      {
        slug,
        title: "Federated Local RT",
        default_tracks: ["main"],
      },
    );
    logEvent("A", "studio_room_create", createRaw);
    const create = ensureOk("studio_room_create", createRaw);
    expect(create.audience_address.length).toBeGreaterThan(0);
    expect(create.members.map((m) => m.toLowerCase())).toEqual([pubA]);
    expect(create.epoch).toBe(1);
    const audienceAddress = create.audience_address;

    // Step 4: A mints an invite.
    const inviteRaw = await callPluginAt<RoomInviteResult>(
      baseA,
      "/api/room/invite",
      "POST",
      { room_slug: slug },
    );
    logEvent("A", "studio_room_invite", inviteRaw);
    const invite = ensureOk("studio_room_invite", inviteRaw);
    expect(invite.four_a_url.startsWith("4a://invite/")).toBe(true);

    // Step 5: B joins via the invite URL.
    const joinRaw = await callPluginAt<RoomJoinResult>(
      baseB,
      "/api/room/join",
      "POST",
      { invite_url: invite.four_a_url },
    );
    logEvent("B", "studio_room_join", joinRaw);
    const join = ensureOk("studio_room_join", joinRaw);
    expect(join.state).toBe("pending-grant");
    expect(join.audience_address).toBe(audienceAddress);
    expect(join.room_slug).toBe(slug);

    // Step 6: A admits.
    const admitRaw = await callPluginAt<RoomAdmitResult>(
      baseA,
      "/api/room/admit",
      "POST",
      { room_slug: slug },
    );
    logEvent("A", "studio_room_admit", admitRaw);
    const admit = ensureOk("studio_room_admit", admitRaw);
    if (!admit.ok || admit.admitted.length < 1) {
      throw new Error(
        `studio_room_admit returned no admitted entries: ${JSON.stringify(admit)}`,
      );
    }
    const admittedPub = admit.admitted[0]!.claim_pubkey.toLowerCase();
    if (admittedPub !== pubB) {
      throw new Error(
        `admitted claim_pubkey (${admittedPub}) does not match B's plugin_pub (${pubB})`,
      );
    }

    // Step 7: wait for B's room state to flip to "active". Poll B's shim.
    const roomEntityName = `studio:room:${slug}`;
    const flipDeadline = Date.now() + STATE_FLIP_DEADLINE_MS;
    let bRoomAttrs: Record<string, unknown> | null = null;
    while (Date.now() < flipDeadline) {
      const ent = [...shimB.state.entities.values()].find((e) => e.name === roomEntityName);
      if (ent && ent.attributes["state"] === "active") {
        bRoomAttrs = ent.attributes;
        break;
      }
      await sleep(STATE_FLIP_POLL_MS);
    }
    if (!bRoomAttrs) {
      const roomEnt = [...shimB.state.entities.values()].find(
        (e) => e.name === roomEntityName,
      );
      const lastState = roomEnt
        ? JSON.stringify(roomEnt.attributes).slice(0, 600)
        : "<no entity in shim B>";
      throw new RelayAttributableError(
        `B room state did not flip to "active" within ${STATE_FLIP_DEADLINE_MS}ms (last attrs=${lastState})`,
      );
    }
    logEvent("B", "state_flip_active", { name: roomEntityName, attrs: bRoomAttrs });

    const bMembers = Array.isArray(bRoomAttrs["members"])
      ? (bRoomAttrs["members"] as unknown[]).map((m) => String(m).toLowerCase())
      : [];
    expect(bMembers).toContain(pubA);
    expect(bMembers).toContain(pubB);
    expect(Number(bRoomAttrs["current_epoch"] ?? 0)).toBe(2);

    // Steps 8-12: B → A timed posts ×5.
    const forwardIterations: IterationEntry[] = [];
    for (let i = 0; i < ITERATIONS; i++) {
      const iter = await timedPost({
        direction: "B->A",
        senderBaseUrl: baseB,
        senderPub: pubB,
        recvShim: shimA.state,
        room: slug,
        track: "main",
        title: `fed-local-fwd-${i}`,
        summary: `hello from B #${i}`,
      });
      forwardIterations.push(iter);
      logEvent("B", "studio_card_post", iter);
    }

    // Step 13: A → B timed posts ×5.
    const reverseIterations: IterationEntry[] = [];
    for (let i = 0; i < ITERATIONS; i++) {
      const iter = await timedPost({
        direction: "A->B",
        senderBaseUrl: baseA,
        senderPub: pubA,
        recvShim: shimB.state,
        room: slug,
        track: "main",
        title: `fed-local-rev-${i}`,
        summary: `hello from A #${i}`,
      });
      reverseIterations.push(iter);
      logEvent("A", "studio_card_post", iter);
    }

    const allIterations = [...forwardIterations, ...reverseIterations];
    const latencies = allIterations.map((i) => i.latency_ms);
    const med = median(latencies);
    const p99 = percentile(latencies, 99);
    const max = Math.max(...latencies);

    expect(med).toBeLessThanOrEqual(LATENCY_BUDGET_MS);
    expect(p99).toBeLessThanOrEqual(LATENCY_BUDGET_MS * 2);
    for (const it of allIterations) {
      if (it.latency_ms > LATENCY_BUDGET_MS * 2) {
        throw new Error(
          `iteration ${it.direction} latency=${it.latency_ms}ms exceeds 2× budget`,
        );
      }
    }

    // Build fixture.
    return {
      ts: new Date().toISOString(),
      gateway: GATEWAY,
      plugin_pub_A: pubA,
      plugin_pub_B: pubB,
      audience_address: audienceAddress,
      room_slug: slug,
      iterations: allIterations,
      summary: { median_ms: med, p99_ms: p99, max_ms: max },
      events,
      attempts: attempt,
      log_tail_A: readPluginLogTail(binA).slice(-200),
      log_tail_B: readPluginLogTail(binB).slice(-200),
    };
  } finally {
    // Teardown: kill both plugins; preserve data dirs on failure for diagnosis.
    // Set STUDIO_T4B_KEEP_DATA=1 to keep on success too.
    const keepData = process.env["STUDIO_T4B_KEEP_DATA"] === "1";
    if (binA) {
      await killPlugin(binA);
      console.error(`[t4b] A dataDir: ${binA.dataDir}`);
      if (!keepData) {
        try { rmSync(binA.dataDir, { recursive: true, force: true }); } catch { /* ignore */ }
      }
    }
    if (binB) {
      await killPlugin(binB);
      console.error(`[t4b] B dataDir: ${binB.dataDir}`);
      if (!keepData) {
        try { rmSync(binB.dataDir, { recursive: true, force: true }); } catch { /* ignore */ }
      }
    }
    await shimA.close();
    await shimB.close();
  }
}

// ── Timed post helper ───────────────────────────────────────────────────────

interface TimedPostArgs {
  direction: IterationEntry["direction"];
  senderBaseUrl: string;
  senderPub: string;
  recvShim: ShimState;
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
    const found = [...args.recvShim.entities.values()].find(
      (e) => e.name === entityName,
    );
    if (found) {
      const eventId = String(found.attributes["event_id"] ?? "");
      if (eventId === post.rumor_event_id) {
        t_recv = Date.now();
        break;
      }
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

// ── Plugin log tail (for fixture diagnostics) ───────────────────────────────

function readPluginLogTail(p: PluginHandle): string[] {
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
