// Regression test for the founder-doesn't-subscribe bug fixed in 8915a67.
//
// createRoom must call ctx.sseManager.open(slug) before returning so the
// founder's SSEManager has a client listening on the audience's gift-wrap
// firehose. Without this, B's cards land on the gateway but A's session
// never sees them.
//
// Pure-unit: mocks the gateway + memory layer (same pattern as
// tests/actions/room.test.ts) and injects a recording SSE opener. No live
// gateway dependency, runs in CI.

import { describe, expect, it } from "bun:test";

import { room } from "../src/actions";
import {
  installMockFetch,
  makeCtx,
  matchGatewayUrl,
  matchMemoryUrl,
} from "./actions/_helpers";

interface MemoryStore {
  entities: Map<string, { id: string; name: string; type: string; description: string; attributes: string }>;
  entitiesById: Map<string, string>;
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
      match: (u: string, m: string) =>
        m === "POST" && matchMemoryUrl("/api/entity/")(u) && !u.includes("?"),
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
      respond: () => ({
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

describe("studio_room_create — sseManager.open() regression", () => {
  it("calls ctx.sseManager.open(slug) exactly once with the new room's slug", async () => {
    const store = makeStore();
    const { restore } = installMockFetch({
      routes: [...gatewayRoutes(), ...memoryRoutes(store)],
    });
    try {
      const { ctx } = makeCtx();

      // Recording SSE opener — captures every open() call so we can verify
      // createRoom subscribes the founder to the audience's firehose. The
      // founder-doesn't-subscribe bug (commit 8915a67) was that this call
      // was missing entirely; this assertion is what stops it from coming
      // back.
      const opens: string[] = [];
      ctx.sseManager = {
        async open(roomSlug: string): Promise<void> {
          opens.push(roomSlug);
        },
      };

      const slug = `regression-test-${Math.random().toString(36).slice(2, 10)}`;
      await room.create({ slug, title: "x" }, ctx);

      expect(opens).toEqual([slug]);
    } finally {
      restore();
    }
  });
});
