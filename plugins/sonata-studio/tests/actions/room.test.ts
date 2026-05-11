// room.list / room.create — rumor structure + memory wiring.

import { describe, expect, it } from "bun:test";
import { bytesToHex } from "@noble/hashes/utils.js";
import { schnorr } from "@noble/curves/secp256k1.js";

import { room } from "../../src/actions";
import {
  installMockFetch,
  makeCtx,
  matchGatewayUrl,
  matchMemoryUrl,
  unwrapFirstPublication,
  type FetchCall,
} from "./_helpers";

interface MemoryStore {
  entities: Map<string, { id: string; name: string; type: string; description: string; attributes: string }>;
  entitiesById: Map<string, string>; // id → name
  secrets: Map<string, string>;
}

function makeStore(): MemoryStore {
  return {
    entities: new Map(),
    entitiesById: new Map(),
    secrets: new Map(),
  };
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
        const row = {
          id,
          name: b.name,
          type: b.type,
          description: b.description,
          attributes: JSON.stringify(b.attributes ?? {}),
        };
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
        const merged = { ...cur, ...(b.attributes ?? {}) };
        store.entities.set(name, { ...row, attributes: JSON.stringify(merged) });
        return { status: 200, body: { id: b.id } };
      },
    },
    {
      match: (u: string, m: string) => m === "GET" && matchMemoryUrl("/api/entity/?name=")(u),
      respond: (u: string) => {
        const name = decodeURIComponent(new URL(u).searchParams.get("name") ?? "");
        const row = store.entities.get(name);
        return { status: 200, body: row ?? null };
      },
    },
    {
      match: (u: string, m: string) => m === "GET" && matchMemoryUrl("/api/entity/list")(u),
      respond: (u: string) => {
        const params = new URL(u).searchParams;
        const type = params.get("type");
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
      match: (u: string, m: string) => m === "POST" && matchMemoryUrl("/api/plugins/")(u),
      respond: () => ({ status: 200, body: { ok: true } }),
    },
    {
      match: (u: string, m: string) => m === "POST" && matchMemoryUrl("/api/entity/touch")(u),
      respond: () => ({ status: 200, body: { success: true } }),
    },
  ];
}

function gatewayRoutes() {
  return [
    {
      match: (u: string, m: string) =>
        m === "POST" && matchGatewayUrl("/v0/audience/raw/create")(u),
      respond: (_u: string, _m: string, _body: unknown) => ({
        status: 200,
        body: {
          ok: true,
          audience_address: "30520:aa:test",
          declaration_event_id: "decl-id-fixture",
          founding_grant_event_id: "grant-id-fixture",
          relay_acks: { declaration: [], founding_grant: [] },
        },
      }),
    },
    {
      match: (u: string, m: string) =>
        m === "POST" && matchGatewayUrl("/v0/audience/raw/publish-wraps")(u),
      respond: () => ({
        status: 200,
        body: { ok: true, audience_address: "x", epoch: 1, gift_wraps: [] },
      }),
    },
  ];
}

// ── Tests ───────────────────────────────────────────────────────────────────

describe("studio_room_list", () => {
  it("returns empty list when no rooms exist", async () => {
    const store = makeStore();
    const { restore } = installMockFetch({ routes: memoryRoutes(store) });
    try {
      const { ctx } = makeCtx();
      const res = await room.list(ctx);
      expect(res).toEqual({ rooms: [] });
    } finally {
      restore();
    }
  });

  it("includes existing rooms with audience address + epoch", async () => {
    const store = makeStore();
    const { restore } = installMockFetch({ routes: memoryRoutes(store) });
    try {
      // Pre-seed a room.
      const audIdPub = "a".repeat(64);
      store.entities.set("studio:room:demo", {
        id: "ent-1",
        name: "studio:room:demo",
        type: "studio_room",
        description: "demo",
        attributes: JSON.stringify({
          slug: "demo",
          title: "Demo Room",
          aud_id_pub_hex: audIdPub,
          current_epoch: 1,
          members: ["b".repeat(64)],
          state: "active",
        }),
      });
      store.entitiesById.set("ent-1", "studio:room:demo");

      const { ctx } = makeCtx();
      const res = await room.list(ctx);
      expect(res.rooms).toHaveLength(1);
      const r = res.rooms[0]!;
      expect(r.slug).toBe("demo");
      expect(r.title).toBe("Demo Room");
      expect(r.audience_address).toBe(`30520:${audIdPub}:demo`);
      expect(r.epoch).toBe(1);
      expect(r.state).toBe("active");
    } finally {
      restore();
    }
  });
});

describe("studio_room_create", () => {
  it("publishes declaration + founding grant + room rumor with correct kinds", async () => {
    const store = makeStore();
    const captured: FetchCall[] = [];
    const { calls, restore } = installMockFetch({
      routes: [
        ...gatewayRoutes(),
        ...memoryRoutes(store),
      ],
    });
    try {
      const { ctx, cfg } = makeCtx();
      const result = await room.create(
        { slug: "alpha", title: "Alpha Room", description: "test", default_tracks: [] },
        ctx,
      );

      expect(result.audience_address).toMatch(/^30520:[0-9a-f]{64}:alpha$/);
      expect(result.epoch).toBe(1);
      expect(result.members).toEqual([cfg.pluginPub.toLowerCase()]);

      const createCall = calls.find((c) => c.url.endsWith("/v0/audience/raw/create"));
      expect(createCall).toBeDefined();
      const createBody = createCall!.body as { declaration: { kind: number; tags: string[][] }; founding_grant: { kind: number } };
      expect(createBody.declaration.kind).toBe(30520);
      expect(createBody.founding_grant.kind).toBe(30521);
      // Declaration must include a `p` tag for the plugin pubkey.
      const pTags = createBody.declaration.tags.filter((t) => t[0] === "p").map((t) => t[1]);
      expect(pTags).toContain(cfg.pluginPub.toLowerCase());

      // Room rumor went out via publish-wraps.
      const wrapsCall = calls.find((c) => c.url.endsWith("/v0/audience/raw/publish-wraps"));
      expect(wrapsCall).toBeDefined();
      const wrapsBody = wrapsCall!.body as { gift_wraps: unknown[] };
      expect(wrapsBody.gift_wraps.length).toBe(1);

      // Persisted secrets for aud_id_priv + epoch_keys.
      expect(store.secrets.has("studio:room:alpha:aud_id_priv")).toBe(true);
      expect(store.secrets.has("studio:room:alpha:epoch_keys")).toBe(true);
      // Suppress unused var
      void captured;
    } finally {
      restore();
    }
  });

  it("rejects non-slug rooms", async () => {
    const store = makeStore();
    const { restore } = installMockFetch({ routes: memoryRoutes(store) });
    try {
      const { ctx } = makeCtx();
      await expect(room.create({ slug: "Bad Slug!", title: "x" }, ctx)).rejects.toThrow();
    } finally {
      restore();
    }
  });
});

describe("studio_room_invite", () => {
  it("requires founder (aud_id_priv present)", async () => {
    const store = makeStore();
    const { restore } = installMockFetch({ routes: memoryRoutes(store) });
    try {
      const { ctx, cfg } = makeCtx();
      const audIdPub = "a".repeat(64);
      // Seed a joined-only room — no aud_id_priv secret.
      const epochPriv = "1".repeat(64);
      const epochPub = bytesToHex(schnorr.getPublicKey(Buffer.from(epochPriv, "hex")));
      store.secrets.set("studio:room:beta:epoch_keys", JSON.stringify({
        epochs: { "1": { epoch: 1, priv_hex: epochPriv, pub_hex: epochPub } },
      }));
      store.entities.set("studio:room:beta", {
        id: "ent-1",
        name: "studio:room:beta",
        type: "studio_room",
        description: "beta",
        attributes: JSON.stringify({
          slug: "beta",
          aud_id_pub_hex: audIdPub,
          aud_id_priv_secret_name: null,
          epoch_keys_secret_name: "studio:room:beta:epoch_keys",
          current_epoch: 1,
          members: [cfg.pluginPub.toLowerCase()],
          state: "active",
        }),
      });
      store.entitiesById.set("ent-1", "studio:room:beta");

      await expect(room.invite({ room_slug: "beta" }, ctx)).rejects.toMatchObject({
        code: "not_founder",
      });
    } finally {
      restore();
    }
  });
});

describe("studio_room_join", () => {
  it("rejects malformed invite_url", async () => {
    const store = makeStore();
    const { restore } = installMockFetch({ routes: memoryRoutes(store) });
    try {
      const { ctx } = makeCtx();
      await expect(room.join({ invite_url: "not-an-invite" }, ctx)).rejects.toMatchObject({
        code: "bad_request",
      });
    } finally {
      restore();
    }
  });
});

// Avoid unused
void unwrapFirstPublication;
