// Pin the response normalization for entity reads — Sonata's API is
// asymmetric (writes return `{id, success}`, reads return Convex-style
// `{_id, name, ...}`). The helper must mirror `_id` → `id` so plugin
// callers (sse/client.ts, projection/util.ts) can read `ent.id` without
// hitting `undefined`. T8 surfaced this: undefined id → entity.patch
// JSON.stringify drops it → Sonata 400 "Missing required parameter: id".
//
// This is the parallel to tests/memory-client.patch-shape.test.ts.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { entity } from "../src/memory-client";

interface CapturedCall {
  url: string;
  method: string;
}

function installFetchStub(responder: (url: string, method: string) => unknown): {
  calls: CapturedCall[];
  restore: () => void;
} {
  const calls: CapturedCall[] = [];
  const orig = globalThis.fetch;
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    const method = (init?.method ?? "GET").toUpperCase();
    calls.push({ url, method });
    const body = responder(url, method);
    return new Response(JSON.stringify(body), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }) as typeof fetch;
  return { calls, restore: () => { globalThis.fetch = orig; } };
}

const SAMPLE_ROW = {
  _id: "abc123",
  _creationTime: 1700000000000,
  name: "studio:room:test",
  type: "studio_room",
  description: "test row",
  attributes: '{"state":"active"}',
  referenceCount: 0,
  createdAt: 1700000000000,
  updatedAt: 1700000000000,
};

describe("entity read response normalization", () => {
  let stub: ReturnType<typeof installFetchStub>;
  afterEach(() => { stub?.restore(); });

  test("byName mirrors _id → id", async () => {
    stub = installFetchStub(() => SAMPLE_ROW);
    const row = await entity.byName("studio:room:test");
    expect(row).not.toBeNull();
    expect(row!.id).toBe("abc123");
    expect(row!.name).toBe("studio:room:test");
  });

  test("byName returns null verbatim when API returns null", async () => {
    stub = installFetchStub(() => null);
    const row = await entity.byName("studio:room:missing");
    expect(row).toBeNull();
  });

  test("list mirrors _id → id on every row", async () => {
    const rows = [
      { ...SAMPLE_ROW, _id: "row-1" },
      { ...SAMPLE_ROW, _id: "row-2", name: "studio:room:other" },
    ];
    stub = installFetchStub(() => rows);
    const result = await entity.list({ type: "studio_room" });
    expect(result).toHaveLength(2);
    expect(result[0]!.id).toBe("row-1");
    expect(result[1]!.id).toBe("row-2");
  });

  test("list of zero rows returns empty array", async () => {
    stub = installFetchStub(() => []);
    const result = await entity.list();
    expect(result).toEqual([]);
  });

  test("preserves an existing id field if the server ever sends one", async () => {
    // Defensive: if the API later returns both `id` and `_id`, prefer the
    // explicit `id` rather than overwriting it.
    stub = installFetchStub(() => ({ ...SAMPLE_ROW, id: "explicit-id" }));
    const row = await entity.byName("studio:room:test");
    expect(row!.id).toBe("explicit-id");
  });
});
