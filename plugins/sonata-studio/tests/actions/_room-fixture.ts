// Pre-seeded studio_room fixture for content-bearing handler tests.
//
// Covers the loadRoomCtx happy-path: aud_id_pub stamped, secrets populated,
// plugin pubkey in member set. Tests using this fixture can immediately call
// card/track/comment/etc handlers and assert on the publish-wraps body.

import { schnorr } from "@noble/curves/secp256k1.js";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils.js";

import { installMockFetch, makeCtx, matchGatewayUrl, matchMemoryUrl, type FetchCall } from "./_helpers";

interface MemoryStore {
  entities: Map<string, { id: string; name: string; type: string; description: string; attributes: string }>;
  entitiesById: Map<string, string>;
  secrets: Map<string, string>;
}

function makeStore(): MemoryStore {
  return { entities: new Map(), entitiesById: new Map(), secrets: new Map() };
}

function memoryRoutes(store: MemoryStore) {
  return [
    {
      match: (u: string, m: string) => m === "GET" && matchMemoryUrl("/api/ping")(u),
      respond: () => ({ status: 200, body: { ok: true } }),
    },
    {
      match: (u: string, m: string) => m === "POST" && matchMemoryUrl("/api/entity/")(u) && !u.includes("?"),
      respond: (_u: string, _m: string, body: unknown) => {
        const b = body as { name: string; type: string; description: string; attributes?: Record<string, unknown> };
        const existing = store.entities.get(b.name);
        const id = existing?.id ?? `ent-${store.entities.size + 1}`;
        const row = { id, name: b.name, type: b.type, description: b.description, attributes: JSON.stringify(b.attributes ?? {}) };
        store.entities.set(b.name, row);
        store.entitiesById.set(id, b.name);
        return { status: 200, body: { id } };
      },
    },
    {
      match: (u: string, m: string) => m === "PATCH" && matchMemoryUrl("/api/entity/")(u),
      respond: (_u: string, _m: string, body: unknown) => {
        const b = body as { id: string; attributes?: Record<string, unknown> };
        const name = store.entitiesById.get(b.id);
        if (!name) return { status: 404, body: { error: "not_found" } };
        const row = store.entities.get(name)!;
        const cur = JSON.parse(row.attributes || "{}") as Record<string, unknown>;
        store.entities.set(name, { ...row, attributes: JSON.stringify({ ...cur, ...(b.attributes ?? {}) }) });
        return { status: 200, body: { id: b.id } };
      },
    },
    {
      match: (u: string, m: string) => m === "GET" && matchMemoryUrl("/api/entity/?name=")(u),
      respond: (u: string) => {
        const name = decodeURIComponent(new URL(u).searchParams.get("name") ?? "");
        return { status: 200, body: store.entities.get(name) ?? null };
      },
    },
    {
      match: (u: string, m: string) => m === "GET" && matchMemoryUrl("/api/entity/list")(u),
      respond: (u: string) => {
        const type = new URL(u).searchParams.get("type");
        const out = [...store.entities.values()].filter((r) => !type || r.type === type);
        return { status: 200, body: out };
      },
    },
    {
      match: (u: string, m: string) => m === "POST" && matchMemoryUrl("/api/entity/get")(u),
      respond: (_u: string, _m: string, body: unknown) => {
        const id = (body as { id: string }).id;
        const name = store.entitiesById.get(id);
        return { status: 200, body: name ? store.entities.get(name) : null };
      },
    },
    {
      match: (u: string, m: string) => m === "POST" && matchMemoryUrl("/api/relation/")(u),
      respond: () => ({ status: 200, body: { id: `rel-${Math.random().toString(36).slice(2, 8)}` } }),
    },
    {
      match: (u: string, m: string) => m === "POST" && matchMemoryUrl("/api/secrets/")(u),
      respond: (_u: string, _m: string, body: unknown) => {
        const b = body as { name: string; value: string };
        store.secrets.set(b.name, b.value);
        return { status: 200, body: { success: true, name: b.name } };
      },
    },
    {
      match: (u: string, m: string) => m === "GET" && matchMemoryUrl("/api/secrets/")(u),
      respond: (u: string) => {
        const name = decodeURIComponent(u.split("/api/secrets/")[1]!);
        const value = store.secrets.get(name);
        return value === undefined
          ? { status: 404, body: { error: "not_found" } }
          : { status: 200, body: { name, value } };
      },
    },
    {
      match: (u: string, m: string) => m === "POST" && matchMemoryUrl("/api/entity/touch")(u),
      respond: () => ({ status: 200, body: { success: true } }),
    },
  ];
}

function gatewayPublishRoute() {
  return {
    match: (u: string, m: string) => m === "POST" && matchGatewayUrl("/v0/audience/raw/publish-wraps")(u),
    respond: () => ({
      status: 200,
      body: { ok: true, audience_address: "x", epoch: 1, gift_wraps: [] },
    }),
  };
}

export interface SeededRoom {
  ctx: ReturnType<typeof makeCtx>["ctx"];
  cfg: ReturnType<typeof makeCtx>["cfg"];
  pluginPriv: Uint8Array;
  pluginPub: string;
  audIdPub: string;
  epochPriv: Uint8Array;
  epochPub: string;
  store: MemoryStore;
  calls: FetchCall[];
  restore: () => void;
}

const HEX = (n: number) => Array.from({ length: n }, (_, i) => (i % 16).toString(16)).join("");

/**
 * Seed a fully-active studio_room with the plugin as the sole member.
 * Returns a context the tests can use without further setup.
 */
export function seedActiveRoom(slug: string): SeededRoom {
  const store = makeStore();
  const { ctx, cfg, pluginPriv, pluginPub } = makeCtx();
  const audIdPub = HEX(64);
  // Generate epoch keypair deterministically (seeds the epoch secret store).
  const epochPriv = hexToBytes(HEX(64));
  const epochPub = bytesToHex(schnorr.getPublicKey(epochPriv));
  store.secrets.set(`studio:room:${slug}:epoch_keys`, JSON.stringify({
    epochs: { "1": { epoch: 1, priv_hex: HEX(64), pub_hex: epochPub } },
  }));
  store.entities.set(`studio:room:${slug}`, {
    id: "ent-room",
    name: `studio:room:${slug}`,
    type: "studio_room",
    description: slug,
    attributes: JSON.stringify({
      slug,
      title: slug,
      aud_id_pub_hex: audIdPub,
      aud_id_priv_secret_name: null,
      epoch_keys_secret_name: `studio:room:${slug}:epoch_keys`,
      current_epoch: 1,
      members: [pluginPub.toLowerCase()],
      state: "active",
    }),
  });
  store.entitiesById.set("ent-room", `studio:room:${slug}`);

  const { calls, restore } = installMockFetch({
    routes: [gatewayPublishRoute(), ...memoryRoutes(store)],
  });

  return { ctx, cfg, pluginPriv, pluginPub, audIdPub, epochPriv, epochPub, store, calls, restore };
}

/** Locate the most recent publish-wraps POST and return its body. */
export function lastPublishWrapsBody(calls: FetchCall[]): { gift_wraps: { kind: number; tags: string[][]; content: string }[] } {
  for (let i = calls.length - 1; i >= 0; i--) {
    const c = calls[i]!;
    if (c.url.endsWith("/v0/audience/raw/publish-wraps")) {
      return c.body as { gift_wraps: { kind: number; tags: string[][]; content: string }[] };
    }
  }
  throw new Error("no publish-wraps call captured");
}
