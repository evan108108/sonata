// HTTP client for Sonata's memory API (SONATA_HOST, default :3211).
//
// Initial-connection retry: ping every 1s for up to 60s. After that, crash
// hard — the plugin can't operate without Sonata.

import { log } from "./logger";

const SONATA_HOST = (process.env["SONATA_HOST"] ?? "http://127.0.0.1:3211").replace(/\/$/, "");

export class MemoryClientError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "MemoryClientError";
  }
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const url = `${SONATA_HOST}${path}`;
  const init: RequestInit = {
    method,
    headers: body !== undefined ? { "Content-Type": "application/json" } : {},
  };
  if (body !== undefined) init.body = JSON.stringify(body);

  const res = await fetch(url, init);
  const text = await res.text();
  let parsed: unknown = null;
  if (text.length > 0) {
    try {
      parsed = JSON.parse(text);
    } catch {
      // non-JSON body — leave parsed as null, surface as code=non_json
    }
  }
  if (!res.ok) {
    const obj = (parsed ?? {}) as { error?: string; message?: string };
    throw new MemoryClientError(
      res.status,
      obj.error ?? "http_error",
      obj.message ?? `${method} ${path} → ${res.status}`,
    );
  }
  return parsed as T;
}

export async function waitForSonata(timeoutMs: number = 60_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let lastErr: unknown;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${SONATA_HOST}/api/ping`).catch(() => null);
      if (res && res.ok) {
        log.info("Sonata reachable", { host: SONATA_HOST });
        return;
      }
      lastErr = res ? `status=${res.status}` : "fetch failed";
    } catch (e) {
      lastErr = e instanceof Error ? e.message : String(e);
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  log.error("Sonata unreachable after 60s — crashing", { host: SONATA_HOST, lastErr: String(lastErr) });
  process.exit(1);
}

// ---- Entity API (/api/entity) ----

export interface EntityUpsertArgs {
  name: string;
  type: string;
  description: string;
  attributes?: Record<string, unknown>;
}

export interface StoreResponse {
  id: string;
}

export interface EntityRow {
  id: string;
  name: string;
  type: string;
  description: string;
  attributes?: string | null;
  referenceCount: number;
  createdAt: number;
  updatedAt: number;
}

/**
 * Sonata's entity API is asymmetric on the wire: writes return `{id, success}`
 * but reads (`GET /api/entity/?name=`, `GET /api/entity/list`) return rows
 * shaped like `{_id, name, type, ...}` — Convex-style, no `id` field. This
 * helper normalizes a read row by mirroring `_id` into `id` so callers can
 * always read `ent.id`. Without this, `entity.patch({id: ent.id, ...})` sends
 * `id: undefined`, JSON.stringify drops it, and Sonata returns 400 "Missing
 * required parameter: id" — which is exactly what every Scout SSE handler hit
 * in T8 before this fix landed. Pinned by tests/memory-client.response-shape.test.ts.
 */
function normalizeEntityRow<T extends { id?: string; _id?: string } | null | undefined>(
  row: T,
): T {
  if (!row) return row;
  if (row.id === undefined && typeof row._id === "string") {
    (row as { id: string })["id"] = row._id;
  }
  return row;
}

export const entity = {
  upsert: (args: EntityUpsertArgs) => request<StoreResponse>("POST", "/api/entity/", args),
  get: async (id: string) => {
    const row = await request<EntityRow | null>("POST", "/api/entity/get", { id });
    return normalizeEntityRow(row);
  },
  /**
   * Like get, but returns null on 404 instead of throwing. The `get` type
   * annotation says `EntityRow | null`, but `/api/entity/get` actually
   * returns 404 when the id doesn't exist (the `request` helper throws
   * MemoryClientError for non-OK responses), so the `| null` path is
   * unreachable in practice. Mirrors byNameOrNull for symmetry.
   */
  getOrNull: async (id: string): Promise<EntityRow | null> => {
    try {
      const row = await request<EntityRow | null>("POST", "/api/entity/get", { id });
      return normalizeEntityRow(row);
    } catch (err) {
      if (err instanceof MemoryClientError && err.status === 404) return null;
      throw err;
    }
  },
  byName: async (name: string) => {
    const row = await request<EntityRow | null>(
      "GET",
      `/api/entity/?name=${encodeURIComponent(name)}`,
    );
    return normalizeEntityRow(row);
  },
  /**
   * Like byName, but returns null on 404 instead of throwing. Sonata's
   * `/api/entity/?name=` returns HTTP 404 when the row doesn't exist, so
   * every caller that wants "fetch if present, fall through if absent" must
   * either wrap a try/catch around byName or use this helper. Use this for
   * any LWW projection or first-sight check; reserve byName for paths where
   * a missing row is genuinely an error.
   */
  byNameOrNull: async (name: string): Promise<EntityRow | null> => {
    try {
      const row = await request<EntityRow | null>(
        "GET",
        `/api/entity/?name=${encodeURIComponent(name)}`,
      );
      return normalizeEntityRow(row);
    } catch (err) {
      if (err instanceof MemoryClientError && err.status === 404) return null;
      throw err;
    }
  },
  list: async (opts?: { type?: string; limit?: number }) => {
    const q = new URLSearchParams();
    if (opts?.type) q.set("type", opts.type);
    if (opts?.limit !== undefined) q.set("limit", String(opts.limit));
    const qs = q.toString();
    const rows = await request<EntityRow[]>(
      "GET",
      `/api/entity/list${qs ? "?" + qs : ""}`,
    );
    return rows.map((r) => normalizeEntityRow(r));
  },
  /**
   * PATCH /api/entity/ — partial update by id. The Sonata API contract
   * (Sources/Actions/EntityActions.swift, mem_entity_patch) reads `id` from
   * the JSON body (NOT from the URL path) and accepts these optional fields:
   *   { id: string, name?, type?, description?, attributes?: object }
   * Anything else is ignored. Missing `id` → 400 "Missing required parameter: id".
   * Pinned by tests/memory-client.patch-shape.test.ts — do not change the
   * body shape without updating the test and the Swift handler in lockstep.
   */
  patch: (args: { id: string; attributes: Record<string, unknown> }) =>
    request<StoreResponse>("PATCH", "/api/entity/", args),
  delete: (id: string) => request<{ success: boolean }>("DELETE", `/api/entity/?id=${encodeURIComponent(id)}`),
  touch: (id: string) => request<{ success: boolean }>("POST", "/api/entity/touch", { id }),
};

// ---- Secret API (/api/secrets) ----

// Sonata's `/api/secrets/:name` route does NOT URL-decode the path parameter
// (Hummingbird passes the raw segment through). `secret.set` writes via JSON
// body — name is whatever bytes the caller sent. So if we URL-encode here,
// reads/deletes look up the literal `%3A` and miss every secret with `:` in
// the name. Studio's secret names are `studio:room:<slug>:<key>`, which is
// why createRoom's read-back failed with "epoch 1 key missing". We escape
// only the chars that would corrupt the URL itself (path separators, query
// markers, whitespace) and leave reserved-but-path-safe chars like `:`
// alone so the round-trip matches the writer.
function encodeSecretName(name: string): string {
  return name.replace(/[/?#% ]/g, (c) => encodeURIComponent(c));
}

export const secret = {
  get: (name: string) =>
    request<{ name: string; value: string }>("GET", `/api/secrets/${encodeSecretName(name)}`),
  /**
   * Like get, but returns null on 404 instead of throwing. Sonata's
   * `/api/secrets/:name` route returns HTTP 404 when the secret is absent,
   * so every caller that wants "fetch if present, fall through if absent"
   * has historically wrapped get in try/catch. Use this for first-write
   * paths (mergeEpochKeysSecret) and optional-secret lookups; reserve get
   * for paths where a missing secret is genuinely an error.
   */
  getOrNull: async (name: string): Promise<{ name: string; value: string } | null> => {
    try {
      return await request<{ name: string; value: string }>(
        "GET",
        `/api/secrets/${encodeSecretName(name)}`,
      );
    } catch (err) {
      if (err instanceof MemoryClientError && err.status === 404) return null;
      throw err;
    }
  },
  set: (args: { name: string; value: string; description?: string }) =>
    request<{ success: boolean; name: string }>("POST", "/api/secrets/", args),
  delete: (name: string) =>
    request<{ success: boolean }>("DELETE", `/api/secrets/${encodeSecretName(name)}`),
};

// ---- Relation API (/api/relation) ----

export interface RelationCreateArgs {
  sourceId: string;
  sourceType: "memory" | "entity";
  targetId: string;
  targetType: "memory" | "entity";
  relation: string;
}

export const relation = {
  create: (args: RelationCreateArgs) => request<StoreResponse>("POST", "/api/relation/", args),
  list: (limit?: number) =>
    request<unknown[]>("GET", `/api/relation/list${limit !== undefined ? "?limit=" + limit : ""}`),
  delete: (id: string) =>
    request<{ success: boolean }>("DELETE", `/api/relation/?id=${encodeURIComponent(id)}`),
};

// ---- Plugin config (/api/plugins/:name/config) ----

export async function setPluginConfig(
  pluginName: string,
  config: Record<string, unknown>,
): Promise<void> {
  await request<{ ok: boolean }>(
    "POST",
    `/api/plugins/${encodeURIComponent(pluginName)}/config`,
    { config },
  );
}
