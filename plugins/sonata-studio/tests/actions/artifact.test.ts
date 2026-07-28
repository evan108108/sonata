// studio_artifact_publish / list / revoke — plan §Verification scenarios 1-14.
//
// Same harness convention as the other action tests: global fetch is mocked
// (installMockFetch) so the handlers run with the REAL GatewayClient (NIP-98
// signing included) and the REAL memory-client. The mock backs both hosts
// with an in-memory simulator:
//   http://127.0.0.1:3211  — entity + secret rows (Sonata memory API)
//   https://gateway.test   — Blossom upload + /v0/artifacts/manifest + revoke
//
// Crypto is real @noble/webcrypto throughout — scenario 14 pins the
// cross-client interop contract (IV || AES-256-GCM ct+tag) against the exact
// WebCrypto calls the gateway's viewer shell makes.
//
// One deliberate deviation from the plan's scenario-10 wording: "identical
// bytes at a second dTag → blob_already_bound" cannot occur naturally from
// this client — a fresh dTag mints a fresh K, and AES-GCM's random IV makes
// even same-K ciphertexts unique, so two publishes never share a sha256. The
// scenario instead pins the plugin's HANDLING of a gateway 409: the sim
// returns blob_already_bound for a marked dTag and we assert the surfaced
// HttpError + that no local row was inserted.

import { describe, expect, it } from "bun:test";
import { webcrypto } from "node:crypto";

import { schnorr } from "@noble/curves/secp256k1.js";
import { hexToBytes } from "@noble/hashes/utils.js";
import { base64urlnopad } from "@scure/base";

import { artifact, HttpError } from "../../src/actions";
import { __getEventHash, type NostrEvent } from "../../src/crypto/nip17";
import { blake3ContentTag } from "../../src/crypto/blake3-tag";
import { encryptArtifact, generateArtifactKey } from "../../src/crypto/aes-gcm";
import {
  installMockFetch,
  makeCtx,
  type FetchCall,
  type FixtureCtx,
} from "./_helpers";

const MEM_HOST = "http://127.0.0.1:3211";
const GW_HOST = "https://gateway.test";

// ── In-memory Sonata + gateway simulator ────────────────────────────────────

interface SimEntityRow {
  _id: string;
  name: string;
  type: string;
  description: string;
  attributes: string;
  referenceCount: number;
  createdAt: number;
  updatedAt: number;
}

interface Sim {
  entities: Map<string, SimEntityRow>;
  secrets: Map<string, string>;
  manifestEvents: NostrEvent[];
  revokeEvents: NostrEvent[];
  secretSetCount: number;
  /** dTags whose manifest publish the sim rejects with 409 blob_already_bound. */
  reject409DTags: Set<string>;
}

interface Harness {
  sim: Sim;
  fx: FixtureCtx;
  calls: FetchCall[];
  restore: () => void;
  gatewayCalls: () => FetchCall[];
}

function findTag(tags: string[][], name: string): string | undefined {
  for (const t of tags) if (t[0] === name) return t[1];
  return undefined;
}

function attrsOf(row: SimEntityRow | undefined): Record<string, unknown> {
  return row ? (JSON.parse(row.attributes) as Record<string, unknown>) : {};
}

function setup(): Harness {
  const sim: Sim = {
    entities: new Map(),
    secrets: new Map(),
    manifestEvents: [],
    revokeEvents: [],
    secretSetCount: 0,
    reject409DTags: new Set(),
  };
  let nextId = 1;
  // Routes read the just-captured call (for the Blossom auth header); the
  // holder is filled right after installMockFetch returns, before any fetch.
  const holder: { calls: FetchCall[] } = { calls: [] };

  const mock = installMockFetch({
    routes: [
      {
        match: (url, method) => method === "GET" && url.startsWith(`${MEM_HOST}/api/entity/list`),
        respond: (url) => {
          const type = new URL(url).searchParams.get("type");
          const rows = [...sim.entities.values()].filter((r) => !type || r.type === type);
          return { status: 200, body: rows };
        },
      },
      {
        match: (url, method) => method === "GET" && url.startsWith(`${MEM_HOST}/api/entity/?name=`),
        respond: (url) => {
          const name = new URL(url).searchParams.get("name") ?? "";
          const row = sim.entities.get(name);
          return row
            ? { status: 200, body: row }
            : { status: 404, body: { error: "not_found", message: name } };
        },
      },
      {
        match: (url, method) => method === "POST" && url === `${MEM_HOST}/api/entity/`,
        respond: (_u, _m, body) => {
          const b = body as {
            name: string;
            type: string;
            description: string;
            attributes?: Record<string, unknown>;
          };
          const prev = sim.entities.get(b.name);
          const row: SimEntityRow = {
            _id: prev?._id ?? `ent-${nextId++}`,
            name: b.name,
            type: b.type,
            description: b.description,
            attributes: JSON.stringify(b.attributes ?? {}),
            referenceCount: 0,
            createdAt: prev?.createdAt ?? Date.now(),
            updatedAt: Date.now(),
          };
          sim.entities.set(b.name, row);
          return { status: 200, body: { id: row._id } };
        },
      },
      {
        match: (url, method) => method === "PATCH" && url.startsWith(`${MEM_HOST}/api/entity/`),
        respond: (_u, _m, body) => {
          const b = body as { id: string; attributes: Record<string, unknown> };
          for (const row of sim.entities.values()) {
            if (row._id === b.id) {
              row.attributes = JSON.stringify(b.attributes);
              row.updatedAt = Date.now();
              return { status: 200, body: { id: row._id } };
            }
          }
          return { status: 404, body: { error: "not_found", message: b.id } };
        },
      },
      {
        match: (url, method) => method === "POST" && url === `${MEM_HOST}/api/secrets/`,
        respond: (_u, _m, body) => {
          const b = body as { name: string; value: string };
          sim.secrets.set(b.name, b.value);
          sim.secretSetCount++;
          return { status: 200, body: { success: true, name: b.name } };
        },
      },
      {
        match: (url, method) => method === "GET" && url.startsWith(`${MEM_HOST}/api/secrets/`),
        respond: (url) => {
          const name = url.slice(`${MEM_HOST}/api/secrets/`.length);
          const value = sim.secrets.get(name);
          return value !== undefined
            ? { status: 200, body: { name, value } }
            : { status: 404, body: { error: "not_found", message: name } };
        },
      },
      {
        match: (url, method) => method === "PUT" && url === `${GW_HOST}/blossom/upload`,
        respond: () => {
          // Echo back the sha the uploader declared in its BUD-01 auth event
          // (the binary body is not JSON-recoverable from the capture).
          const call = holder.calls[holder.calls.length - 1]!;
          const auth = call.headers["authorization"] ?? "";
          const evt = JSON.parse(atob(auth.slice("Nostr ".length))) as NostrEvent;
          const sha = findTag(evt.tags, "x") ?? "";
          return {
            status: 200,
            body: {
              sha256: sha,
              url: `${GW_HOST}/blossom/${sha}`,
              mirrors: [`${GW_HOST}/blossom/${sha}`],
              size: 0,
              uploaded: Math.floor(Date.now() / 1000),
              type: "application/octet-stream",
            },
          };
        },
      },
      {
        match: (url, method) => method === "POST" && url === `${GW_HOST}/v0/artifacts/manifest`,
        respond: (_u, _m, body) => {
          const event = (body as { event: NostrEvent }).event;
          sim.manifestEvents.push(event);
          const d = findTag(event.tags, "d") ?? "";
          const blob = findTag(event.tags, "blob") ?? "";
          if (sim.reject409DTags.has(d)) {
            return {
              status: 409,
              body: {
                error: "blob_already_bound",
                message: "this blob's frozen URL is already bound to another manifest address",
                latest_url: `${GW_HOST}/v0/artifacts/${event.pubkey}/${d}`,
              },
            };
          }
          return {
            status: 200,
            body: {
              ok: true,
              superseded: false,
              frozen_url: `${GW_HOST}/v0/artifacts/${blob}`,
              latest_url: `${GW_HOST}/v0/artifacts/${event.pubkey}/${d}`,
            },
          };
        },
      },
      {
        match: (url, method) => method === "POST" && url === `${GW_HOST}/v0/artifacts/revoke`,
        respond: (_u, _m, body) => {
          const event = (body as { event: NostrEvent }).event;
          sim.revokeEvents.push(event);
          const revoked = event.tags.filter((t) => t[0] === "e" || t[0] === "a");
          return { status: 200, body: { revoked, skipped: [] } };
        },
      },
    ],
  });
  holder.calls = mock.calls;

  const fx = makeCtx();
  return {
    sim,
    fx,
    calls: mock.calls,
    restore: mock.restore,
    gatewayCalls: () => mock.calls.filter((c) => c.url.startsWith(GW_HOST)),
  };
}

async function expectHttpError(
  p: Promise<unknown>,
  status: number,
  code: string,
): Promise<HttpError> {
  let caught: unknown;
  try {
    await p;
  } catch (e) {
    caught = e;
  }
  expect(caught).toBeInstanceOf(HttpError);
  const err = caught as HttpError;
  expect(err.status).toBe(status);
  expect(err.code).toBe(code);
  return err;
}

function seedRow(
  sim: Sim,
  fx: FixtureCtx,
  args: {
    sha: string;
    dTag: string;
    title: string;
    publishedAtMs: number;
    revoked?: boolean;
    eventId?: string;
  },
): void {
  sim.entities.set(`studio:artifact:${args.sha}`, {
    _id: `seed-${args.sha.slice(0, 8)}`,
    name: `studio:artifact:${args.sha}`,
    type: "studio_artifact",
    description: args.title,
    attributes: JSON.stringify({
      dTag: args.dTag,
      title: args.title,
      contentType: "text/html",
      pubkey: fx.pluginPub,
      eventId: args.eventId ?? "e".repeat(64),
      publishedAtMs: args.publishedAtMs,
      roomId: null,
      revoked: args.revoked ?? false,
      revokedAtMs: args.revoked ? args.publishedAtMs + 1 : null,
      revokedReason: null,
    }),
    referenceCount: 0,
    createdAt: args.publishedAtMs,
    updatedAt: args.publishedAtMs,
  });
  if (!sim.secrets.has(`studio:artifact_key:${args.dTag}`)) {
    sim.secrets.set(
      `studio:artifact_key:${args.dTag}`,
      base64urlnopad.encode(generateArtifactKey()),
    );
  }
}

// ── Scenario 1: round-trip publish ──────────────────────────────────────────

describe("studio_artifact_publish", () => {
  it("scenario 1 — encrypts, uploads, signs a valid kind:30540 manifest, persists row + key", async () => {
    const h = setup();
    try {
      const res = await artifact.publish(
        {
          data: "<h1>hi</h1>",
          data_encoding: "utf8",
          content_type: "text/html",
          title: "Q3 Report",
        },
        h.fx.ctx,
      );

      expect(res.d_tag).toBe("q3-report");
      expect(res.sha256).toMatch(/^[0-9a-f]{64}$/);

      // Exactly one Blossom upload, addressed to the gateway host.
      const uploads = h.calls.filter((c) => c.url === `${GW_HOST}/blossom/upload`);
      expect(uploads).toHaveLength(1);

      // Manifest event: canonical id, valid schnorr sig, required tags.
      expect(h.sim.manifestEvents).toHaveLength(1);
      const evt = h.sim.manifestEvents[0]!;
      expect(evt.kind).toBe(30540);
      expect(evt.pubkey).toBe(h.fx.pluginPub.toLowerCase());
      expect(__getEventHash(evt)).toBe(evt.id);
      expect(
        schnorr.verify(hexToBytes(evt.sig), hexToBytes(evt.id), hexToBytes(evt.pubkey)),
      ).toBe(true);
      expect(findTag(evt.tags, "d")).toBe("q3-report");
      expect(findTag(evt.tags, "blob")).toBe(res.sha256);
      expect(findTag(evt.tags, "type")).toBe("text/html");
      expect(findTag(evt.tags, "title")).toBe("Q3 Report");
      expect(findTag(evt.tags, "alt")).toBe("Public artifact: Q3 Report (text/html)");
      expect(findTag(evt.tags, "blake3")).toBe(blake3ContentTag(evt.content));
      expect(findTag(evt.tags, "fa:context")).toBe("https://4a4.ai/ns/v0");
      expect(res.event_id).toBe(evt.id);

      // Row + key persisted.
      const row = h.sim.entities.get(`studio:artifact:${res.sha256}`);
      expect(row).toBeTruthy();
      expect(attrsOf(row)["dTag"]).toBe("q3-report");
      const keyB64 = h.sim.secrets.get("studio:artifact_key:q3-report");
      expect(keyB64).toBeTruthy();
      expect(base64urlnopad.decode(keyB64!)).toHaveLength(32);

      // URLs carry the fragment key (32 bytes → 43 unpadded base64url chars).
      expect(res.frozen_url).toBe(`${GW_HOST}/v0/artifacts/${res.sha256}#k=${keyB64}`);
      expect(res.latest_url).toBe(
        `${GW_HOST}/v0/artifacts/${h.fx.pluginPub.toLowerCase()}/q3-report#k=${keyB64}`,
      );
      expect(keyB64!).toMatch(/^[A-Za-z0-9_-]{43}$/);
    } finally {
      h.restore();
    }
  });

  it("scenario 2 — explicit-d_tag republish reuses K, new sha + eventId, second row", async () => {
    const h = setup();
    try {
      const first = await artifact.publish(
        { data: "<h1>v1</h1>", content_type: "text/html", title: "Q3 Report" },
        h.fx.ctx,
      );
      const second = await artifact.publish(
        {
          data: "<h1>v2 — different bytes</h1>",
          content_type: "text/html",
          title: "Q3 Report",
          d_tag: "q3-report",
        },
        h.fx.ctx,
      );

      expect(h.sim.secretSetCount).toBe(1); // K minted once, reused
      expect(second.d_tag).toBe(first.d_tag);
      expect(second.sha256).not.toBe(first.sha256);
      expect(second.event_id).not.toBe(first.event_id);
      expect(h.sim.entities.has(`studio:artifact:${first.sha256}`)).toBe(true);
      expect(h.sim.entities.has(`studio:artifact:${second.sha256}`)).toBe(true);
      // Same K → same fragment on both URLs.
      expect(second.latest_url.split("#k=")[1]).toBe(first.latest_url.split("#k=")[1]);
    } finally {
      h.restore();
    }
  });

  it("scenario 7 — content_type outside the v1 allowlist rejects pre-network", async () => {
    const h = setup();
    try {
      await expectHttpError(
        artifact.publish(
          { data: "x", content_type: "application/octet-stream" },
          h.fx.ctx,
        ),
        400,
        "unsupported_content_type",
      );
      expect(h.gatewayCalls()).toHaveLength(0);
    } finally {
      h.restore();
    }
  });

  it("scenario 8 — payloads over 4 MiB reject pre-network with 413", async () => {
    const h = setup();
    try {
      await expectHttpError(
        artifact.publish(
          { data: "x".repeat(5 * 1024 * 1024), content_type: "text/plain" },
          h.fx.ctx,
        ),
        413,
        "payload_too_large",
      );
      expect(h.gatewayCalls()).toHaveLength(0);
    } finally {
      h.restore();
    }
  });

  it("scenario 9 — room_id is rejected with 400 roomId_v2 (personal-only v1)", async () => {
    const h = setup();
    try {
      await expectHttpError(
        artifact.publish(
          { data: "x", content_type: "text/plain", room_id: "foo" },
          h.fx.ctx,
        ),
        400,
        "roomId_v2",
      );
      expect(h.gatewayCalls()).toHaveLength(0);
    } finally {
      h.restore();
    }
  });

  it("scenario 10 — gateway 409 blob_already_bound surfaces and inserts no row", async () => {
    const h = setup();
    try {
      const a = await artifact.publish(
        { data: "<p>same</p>", content_type: "text/html", d_tag: "x" },
        h.fx.ctx,
      );
      const rowsBefore = h.sim.entities.size;

      h.sim.reject409DTags.add("y");
      await expectHttpError(
        artifact.publish(
          { data: "<p>same</p>", content_type: "text/html", d_tag: "y" },
          h.fx.ctx,
        ),
        409,
        "blob_already_bound",
      );

      expect(h.sim.entities.size).toBe(rowsBefore);
      expect(attrsOf(h.sim.entities.get(`studio:artifact:${a.sha256}`))["dTag"]).toBe("x");
    } finally {
      h.restore();
    }
  });

  it("scenario 11 — d_tag derivation: empty/unicode titles fall back, long titles truncate, collisions suffix", async () => {
    const h = setup();
    try {
      const noTitle = await artifact.publish(
        { data: "a", content_type: "text/plain" },
        h.fx.ctx,
      );
      expect(noTitle.d_tag).toMatch(/^artifact-[0-9a-f]{8}$/);

      const unicode = await artifact.publish(
        { data: "b", content_type: "text/plain", title: "你好" },
        h.fx.ctx,
      );
      expect(unicode.d_tag).toMatch(/^artifact-[0-9a-f]{8}$/);

      const long = await artifact.publish(
        { data: "c", content_type: "text/plain", title: "x".repeat(200) },
        h.fx.ctx,
      );
      expect(long.d_tag).toBe("x".repeat(64));

      const collide1 = await artifact.publish(
        { data: "d1", content_type: "text/plain", title: "Q3 Report" },
        h.fx.ctx,
      );
      const collide2 = await artifact.publish(
        { data: "d2", content_type: "text/plain", title: "Q3 Report" },
        h.fx.ctx,
      );
      expect(collide1.d_tag).toBe("q3-report");
      expect(collide2.d_tag).toBe("q3-report-2");
      // Fresh dTag → fresh K (two distinct key secrets).
      expect(h.sim.secrets.get("studio:artifact_key:q3-report")).not.toBe(
        h.sim.secrets.get("studio:artifact_key:q3-report-2"),
      );
    } finally {
      h.restore();
    }
  });

  it("TS-H1 regression — two publishes racing the same fresh d_tag mint exactly one K", async () => {
    const h = setup();
    try {
      const [a, b] = await Promise.all([
        artifact.publish({ data: "left", content_type: "text/plain", d_tag: "race" }, h.fx.ctx),
        artifact.publish({ data: "right", content_type: "text/plain", d_tag: "race" }, h.fx.ctx),
      ]);
      // Without per-dTag serialization both mints run, last secret.set wins,
      // and the loser's returned fragment decrypts nothing.
      expect(h.sim.secretSetCount).toBe(1);
      const stored = h.sim.secrets.get("studio:artifact_key:race");
      expect(a.latest_url.split("#k=")[1]).toBe(stored);
      expect(b.latest_url.split("#k=")[1]).toBe(stored);
      expect(a.sha256).not.toBe(b.sha256);
    } finally {
      h.restore();
    }
  });

  it("scenario 12 — user-supplied d_tag failing the gateway regex rejects with 400", async () => {
    const h = setup();
    try {
      await expectHttpError(
        artifact.publish(
          { data: "x", content_type: "text/plain", d_tag: "foo bar" },
          h.fx.ctx,
        ),
        400,
        "bad_d_tag",
      );
      await expectHttpError(
        artifact.publish(
          { data: "x", content_type: "text/plain", d_tag: "a".repeat(65) },
          h.fx.ctx,
        ),
        400,
        "bad_d_tag",
      );
      expect(h.gatewayCalls()).toHaveLength(0);
    } finally {
      h.restore();
    }
  });
});

// ── Revocation ──────────────────────────────────────────────────────────────

describe("studio_artifact_revoke", () => {
  it("scenario 3 — revoke by d_tag posts an a-tag kind:5 and flips local rows", async () => {
    const h = setup();
    try {
      const pub = await artifact.publish(
        { data: "<h1>hi</h1>", content_type: "text/html", title: "Q3 Report" },
        h.fx.ctx,
      );
      const res = await artifact.revoke({ d_tag: "q3-report", reason: "stale" }, h.fx.ctx);

      expect(h.sim.revokeEvents).toHaveLength(1);
      const evt = h.sim.revokeEvents[0]!;
      expect(evt.kind).toBe(5);
      expect(__getEventHash(evt)).toBe(evt.id);
      const addr = `30540:${h.fx.pluginPub.toLowerCase()}:q3-report`;
      expect(evt.tags).toContainEqual(["a", addr]);
      expect(res.revoked).toContainEqual(["a", addr]);

      const attrs = attrsOf(h.sim.entities.get(`studio:artifact:${pub.sha256}`));
      expect(attrs["revoked"]).toBe(true);
      expect(typeof attrs["revokedAtMs"]).toBe("number");
      expect(attrs["revokedReason"]).toBe("stale");
    } finally {
      h.restore();
    }
  });

  it("scenario 4 — revoke by sha256 posts an e-tag kind:5 with the row's eventId", async () => {
    const h = setup();
    try {
      const pub = await artifact.publish(
        { data: "<h1>hi</h1>", content_type: "text/html", title: "Frozen One" },
        h.fx.ctx,
      );
      const res = await artifact.revoke({ sha256: pub.sha256 }, h.fx.ctx);

      const evt = h.sim.revokeEvents[0]!;
      expect(evt.tags).toContainEqual(["e", pub.event_id]);
      expect(res.revoked).toContainEqual(["e", pub.event_id]);
      const attrs = attrsOf(h.sim.entities.get(`studio:artifact:${pub.sha256}`));
      expect(attrs["revoked"]).toBe(true);
    } finally {
      h.restore();
    }
  });

  it("404s on a sha256 with no local row and 400s when neither selector is given", async () => {
    const h = setup();
    try {
      await expectHttpError(
        artifact.revoke({ sha256: "f".repeat(64) }, h.fx.ctx),
        404,
        "unknown_sha",
      );
      await expectHttpError(artifact.revoke({}, h.fx.ctx), 400, "bad_request");
    } finally {
      h.restore();
    }
  });
});

// ── Listing ─────────────────────────────────────────────────────────────────

describe("studio_artifact_list", () => {
  it("surfaces revoked_reason after a revoke with a reason", async () => {
    const h = setup();
    try {
      const pub = await artifact.publish(
        { data: "<h1>hi</h1>", content_type: "text/html", title: "Reasoned" },
        h.fx.ctx,
      );
      await artifact.revoke({ d_tag: "reasoned", reason: "superseded by v2" }, h.fx.ctx);

      const res = await artifact.list({ filter: "personal" }, h.fx.ctx);
      const entry = res.artifacts.find((a) => a.sha256 === pub.sha256);
      expect(entry).toBeDefined();
      expect(entry!.revoked).toBe(true);
      expect(entry!.revoked_reason).toBe("superseded by v2");
    } finally {
      h.restore();
    }
  });

  it("scenario 5 — personal filter returns seeded rows newest-first with composed #k= URLs", async () => {
    const h = setup();
    try {
      seedRow(h.sim, h.fx, { sha: "a".repeat(64), dTag: "one", title: "One", publishedAtMs: 1000 });
      seedRow(h.sim, h.fx, { sha: "b".repeat(64), dTag: "two", title: "Two", publishedAtMs: 3000 });
      seedRow(h.sim, h.fx, {
        sha: "c".repeat(64),
        dTag: "three",
        title: "Three",
        publishedAtMs: 2000,
        revoked: true,
      });

      const res = await artifact.list({ filter: "personal" }, h.fx.ctx);
      expect(res.artifacts).toHaveLength(3);
      expect(res.v2_marker).toBeUndefined();
      expect(res.artifacts.map((a) => a.d_tag)).toEqual(["two", "three", "one"]);
      expect(res.artifacts.map((a) => a.revoked)).toEqual([false, true, false]);
      for (const a of res.artifacts) {
        expect(a.pubkey).toBe(h.fx.pluginPub.toLowerCase());
        expect(a.frozen_url).toMatch(
          new RegExp(`^https://gateway\\.test/v0/artifacts/${a.sha256}#k=[A-Za-z0-9_-]{43}$`),
        );
        expect(a.latest_url).toContain(`/v0/artifacts/${h.fx.pluginPub}/${a.d_tag}#k=`);
      }

      const noRevoked = await artifact.list({ include_revoked: "false" }, h.fx.ctx);
      expect(noRevoked.artifacts.map((a) => a.d_tag)).toEqual(["two", "one"]);
    } finally {
      h.restore();
    }
  });

  it("scenario 6 — room filter returns the v2 marker with no rows", async () => {
    const h = setup();
    try {
      const res = await artifact.list({ filter: "room" }, h.fx.ctx);
      expect(res).toEqual({ artifacts: [], v2_marker: "room-filter-v2" });
    } finally {
      h.restore();
    }
  });

  it("scenario 13 — a missing key secret degrades the row to key_missing instead of throwing", async () => {
    const h = setup();
    try {
      seedRow(h.sim, h.fx, { sha: "d".repeat(64), dTag: "lost", title: "Lost", publishedAtMs: 500 });
      h.sim.secrets.delete("studio:artifact_key:lost");

      const res = await artifact.list({}, h.fx.ctx);
      expect(res.artifacts).toHaveLength(1);
      const row = res.artifacts[0]!;
      expect(row.key_missing).toBe(true);
      expect(row.frozen_url).toBeNull();
      expect(row.latest_url).toBeNull();
    } finally {
      h.restore();
    }
  });
});

// ── Crypto interop ──────────────────────────────────────────────────────────

describe("artifact crypto interop", () => {
  it("scenario 14 — encryptArtifact round-trips through the viewer shell's exact WebCrypto calls", async () => {
    const key = generateArtifactKey();
    const plaintext = new TextEncoder().encode(
      "<html><body><script>document.title='hi'</script>interop</body></html>",
    );
    const blob = await encryptArtifact(plaintext, key);

    // IV(12) || ct+tag(len+16) — the shell's split and decrypt, verbatim.
    expect(blob.length).toBe(12 + plaintext.length + 16);
    const iv = new Uint8Array(blob.buffer, blob.byteOffset, 12);
    const ct = new Uint8Array(blob.buffer, blob.byteOffset + 12, blob.length - 12);
    const cryptoKey = await webcrypto.subtle.importKey("raw", key, "AES-GCM", false, ["decrypt"]);
    const plain = new Uint8Array(
      await webcrypto.subtle.decrypt({ name: "AES-GCM", iv }, cryptoKey, ct),
    );
    expect(plain).toEqual(plaintext);
  });
});
