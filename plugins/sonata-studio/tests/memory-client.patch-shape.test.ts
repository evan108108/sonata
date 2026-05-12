// Pin the wire shape of entity.patch — Sonata's PATCH /api/entity/ handler
// reads `id` from the JSON body. If a future refactor moves `id` to the URL
// path or wraps the body in a different envelope, every Scout SSE handler
// 400s in production (the round-trip and federated tests use an in-process
// memory shim, so they don't catch this regression). Keep this test green.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { entity } from "../src/memory-client";

interface CapturedCall {
  url: string;
  method: string;
  contentType: string | null;
  body: unknown;
}

const SONATA_HOST = "http://127.0.0.1:3211";

function installFetchCapture(): {
  calls: CapturedCall[];
  restore: () => void;
} {
  const calls: CapturedCall[] = [];
  const orig = globalThis.fetch;
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    const method = (init?.method ?? "GET").toUpperCase();
    const headers = (init?.headers ?? {}) as Record<string, string>;
    const ctKey = Object.keys(headers).find((k) => k.toLowerCase() === "content-type");
    const contentType = ctKey ? headers[ctKey] ?? null : null;
    let body: unknown = null;
    if (init?.body !== undefined && init?.body !== null) {
      const raw = typeof init.body === "string"
        ? init.body
        : init.body instanceof Uint8Array
          ? new TextDecoder().decode(init.body)
          : String(init.body);
      try { body = JSON.parse(raw); } catch { body = raw; }
    }
    calls.push({ url, method, contentType, body });
    return new Response(JSON.stringify({ id: "fake-id", success: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }) as typeof fetch;
  return { calls, restore: () => { globalThis.fetch = orig; } };
}

describe("entity.patch wire shape", () => {
  let capture: ReturnType<typeof installFetchCapture>;

  beforeEach(() => { capture = installFetchCapture(); });
  afterEach(() => { capture.restore(); });

  test("sends PATCH to /api/entity/ with {id, attributes} body", async () => {
    await entity.patch({
      id: "ent-123",
      attributes: { state: "active", current_epoch: 7 },
    });

    expect(capture.calls).toHaveLength(1);
    const call = capture.calls[0]!;
    expect(call.method).toBe("PATCH");
    expect(call.url).toBe(`${SONATA_HOST}/api/entity/`);
    expect(call.contentType).toBe("application/json");
    // Body MUST be a JSON object with id (string) at the top level — the
    // Swift handler reads it from bodyDict["id"]. Anything else → 400.
    expect(call.body).toEqual({
      id: "ent-123",
      attributes: { state: "active", current_epoch: 7 },
    });
    const body = call.body as Record<string, unknown>;
    expect(typeof body["id"]).toBe("string");
    expect(typeof body["attributes"]).toBe("object");
  });

  test("does not put id in the URL path", async () => {
    await entity.patch({ id: "ent-xyz", attributes: {} });
    const call = capture.calls[0]!;
    expect(call.url).not.toContain("ent-xyz");
    expect(call.url.endsWith("/api/entity/")).toBe(true);
  });

  test("preserves nested attribute objects verbatim (no flattening)", async () => {
    const attrs = {
      members: ["abc", "def"],
      nested: { a: 1, b: [2, 3] },
      _pending_relations: [{ relation: "targets", target_event_id: "deadbeef" }],
    };
    await entity.patch({ id: "ent-1", attributes: attrs });
    const body = capture.calls[0]!.body as { attributes: unknown };
    expect(body.attributes).toEqual(attrs);
  });
});
