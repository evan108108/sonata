// studio_room_admit handler — Phase 3 §1 Gap 2.
//
// Mocks the gateway's raw/process-claims + raw/rotate endpoints and the
// Sonata memory entity/secret routes. Exercises:
//   - Founder gate (loadRoomCtx surfaces audIdPrivHex=null → 403).
//   - Zero claims → 200 with admitted:[] and no rotate call.
//   - One fresh claim → rawRotate called once with epoch+1 declaration,
//     N+1 grants (every member of the new epoch), and entity patched.
//   - Already-admitted claim_pubkey → skipped, no rotate call.
//   - Partial grant fan-out failure → 207-equivalent shape.

import { describe, expect, it } from "bun:test";
import { schnorr } from "@noble/curves/secp256k1.js";
import { bytesToHex, hexToBytes, randomBytes } from "@noble/hashes/utils.js";

import { room_admit } from "../../src/actions";
import {
  installMockFetch,
  makeCtx,
  matchGatewayUrl,
  matchMemoryUrl,
  type FetchCall,
} from "./_helpers";

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
  ];
}

interface Seeded {
  store: MemoryStore;
  audIdPriv: Uint8Array;
  audIdPub: string;
  pluginPub: string;
  founderRoom: (slug: string) => void;
  joinerRoom: (slug: string) => void;
}

function seedHelpers(pluginPub: string): Seeded {
  const store = makeStore();
  const audIdPriv = randomBytes(32);
  const audIdPub = bytesToHex(schnorr.getPublicKey(audIdPriv));
  const epochPriv = "1".repeat(64);
  const epochPub = bytesToHex(schnorr.getPublicKey(hexToBytes(epochPriv)));

  return {
    store,
    audIdPriv,
    audIdPub,
    pluginPub,
    founderRoom(slug: string): void {
      store.secrets.set(`studio:room:${slug}:aud_id_priv`, bytesToHex(audIdPriv));
      store.secrets.set(`studio:room:${slug}:epoch_keys`, JSON.stringify({
        epochs: { "1": { epoch: 1, priv_hex: epochPriv, pub_hex: epochPub } },
      }));
      store.entities.set(`studio:room:${slug}`, {
        id: `ent-${slug}`,
        name: `studio:room:${slug}`,
        type: "studio_room",
        description: slug,
        attributes: JSON.stringify({
          slug,
          title: slug,
          aud_id_pub_hex: audIdPub,
          aud_id_priv_secret_name: `studio:room:${slug}:aud_id_priv`,
          epoch_keys_secret_name: `studio:room:${slug}:epoch_keys`,
          current_epoch: 1,
          members: [pluginPub.toLowerCase()],
          state: "active",
          pending_invites: [],
        }),
      });
      store.entitiesById.set(`ent-${slug}`, `studio:room:${slug}`);
    },
    joinerRoom(slug: string): void {
      store.secrets.set(`studio:room:${slug}:epoch_keys`, JSON.stringify({
        epochs: { "1": { epoch: 1, priv_hex: epochPriv, pub_hex: epochPub } },
      }));
      store.entities.set(`studio:room:${slug}`, {
        id: `ent-${slug}`,
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
      store.entitiesById.set(`ent-${slug}`, `studio:room:${slug}`);
    },
  };
}

function processClaimsRoute(claimed: { invite_pub: string; claim_pubkey: string; claim_event_id: string }[]) {
  return {
    match: (u: string, m: string) =>
      m === "POST" && matchGatewayUrl("/v0/audience/raw/process-claims")(u),
    respond: () => ({ status: 200, body: { ok: true, claimed } }),
  };
}

interface RotateRespOpts {
  failures?: Set<string>; // recipients whose grants get all-rejected acks
}

function rotateRoute(opts: RotateRespOpts = {}) {
  return {
    match: (u: string, m: string) =>
      m === "POST" && matchGatewayUrl("/v0/audience/raw/rotate")(u),
    respond: (_u: string, _m: string, body: unknown) => {
      const b = body as { grants: { tags: string[][] }[] };
      const failures = opts.failures ?? new Set<string>();
      const grants = b.grants.map((g, i) => {
        const recipient = g.tags.find((t) => t[0] === "p")?.[1] ?? "";
        const failed = failures.has(recipient);
        return {
          recipient,
          event_id: `grant-${i}`,
          relay_acks: failed
            ? [{ relay: "wss://test", status: "rejected" as const, message: "test" }]
            : [{ relay: "wss://test", status: "accepted" as const }],
        };
      });
      return {
        status: 200,
        body: {
          ok: true,
          declaration_event_id: "decl-rotated",
          grants,
        },
      };
    },
  };
}

// ── Tests ───────────────────────────────────────────────────────────────────

describe("studio_room_admit", () => {
  it("rejects non-founders with 403", async () => {
    const { ctx, pluginPub } = makeCtx();
    const seeded = seedHelpers(pluginPub);
    seeded.joinerRoom("foo");
    const { restore } = installMockFetch({
      routes: [processClaimsRoute([]), rotateRoute(), ...memoryRoutes(seeded.store)],
    });
    try {
      await expect(room_admit.admit({ room_slug: "foo" }, ctx)).rejects.toMatchObject({
        code: "not_founder",
      });
    } finally {
      restore();
    }
  });

  it("returns admitted:[] and skips rotate when no fresh claims", async () => {
    const { ctx, pluginPub } = makeCtx();
    const seeded = seedHelpers(pluginPub);
    seeded.founderRoom("foo");
    const { calls, restore } = installMockFetch({
      routes: [processClaimsRoute([]), rotateRoute(), ...memoryRoutes(seeded.store)],
    });
    try {
      const res = await room_admit.admit({ room_slug: "foo" }, ctx);
      expect(res.ok).toBe(true);
      expect(res.admitted).toEqual([]);
      expect(res.new_epoch).toBe(1);
      expect(res.declaration_event_id).toBeNull();
      expect(calls.find((c) => c.url.endsWith("/v0/audience/raw/rotate"))).toBeUndefined();
    } finally {
      restore();
    }
  });

  it("rotates with epoch+1, adds claimer, and grants every member of the new epoch", async () => {
    const { ctx, pluginPub } = makeCtx();
    const seeded = seedHelpers(pluginPub);
    seeded.founderRoom("foo");
    const claimerPriv = randomBytes(32);
    const claimerPub = bytesToHex(schnorr.getPublicKey(claimerPriv));
    const invitePriv = randomBytes(32);
    const invitePub = bytesToHex(schnorr.getPublicKey(invitePriv));
    const { calls, restore } = installMockFetch({
      routes: [
        processClaimsRoute([
          { invite_pub: invitePub, claim_pubkey: claimerPub, claim_event_id: "claim-1" },
        ]),
        rotateRoute(),
        ...memoryRoutes(seeded.store),
      ],
    });
    try {
      const res = await room_admit.admit({ room_slug: "foo" }, ctx);
      expect(res.ok).toBe(true);
      expect(res.new_epoch).toBe(2);
      expect(res.declaration_event_id).toBe("decl-rotated");
      expect(res.admitted).toHaveLength(1);
      expect(res.admitted[0]!.claim_pubkey).toBe(claimerPub);

      // Inspect the rotate POST.
      const rotateCall = calls.find((c) => c.url.endsWith("/v0/audience/raw/rotate"));
      expect(rotateCall).toBeDefined();
      const body = rotateCall!.body as {
        declaration: { tags: string[][] };
        grants: { tags: string[][] }[];
      };
      const declEpoch = body.declaration.tags.find((t) => t[0] === "fa:epoch")?.[1];
      expect(declEpoch).toBe("2");
      const declMembers = body.declaration.tags.filter((t) => t[0] === "p").map((t) => t[1]);
      expect(declMembers).toContain(pluginPub.toLowerCase());
      expect(declMembers).toContain(claimerPub);
      expect(declMembers).toHaveLength(2);
      // One grant per member of the new epoch.
      expect(body.grants).toHaveLength(2);
      const grantRecipients = body.grants.map(
        (g) => g.tags.find((t) => t[0] === "p")?.[1] ?? "",
      );
      expect(new Set(grantRecipients)).toEqual(new Set([pluginPub.toLowerCase(), claimerPub]));

      // Local entity patched: members + current_epoch.
      const ent = seeded.store.entities.get("studio:room:foo")!;
      const attrs = JSON.parse(ent.attributes) as Record<string, unknown>;
      expect(attrs["current_epoch"]).toBe(2);
      expect(attrs["members"]).toEqual(expect.arrayContaining([pluginPub.toLowerCase(), claimerPub]));

      // Epoch_2 priv landed in the secret in BOTH the verbose and flat formats.
      const sec = seeded.store.secrets.get("studio:room:foo:epoch_keys")!;
      const parsed = JSON.parse(sec) as { epochs?: Record<string, { priv_hex: string }>; [k: string]: unknown };
      expect(parsed.epochs?.["2"]?.priv_hex).toMatch(/^[0-9a-f]{64}$/i);
      expect(typeof parsed["2"]).toBe("string");
      expect((parsed["2"] as string).length).toBe(64);
    } finally {
      restore();
    }
  });

  it("skips a claim whose claim_pubkey is already a member (no rotate)", async () => {
    const { ctx, pluginPub } = makeCtx();
    const seeded = seedHelpers(pluginPub);
    seeded.founderRoom("foo");
    const invitePriv = randomBytes(32);
    const invitePub = bytesToHex(schnorr.getPublicKey(invitePriv));
    // The claimed pubkey is pluginPub itself, which is already a member.
    const { calls, restore } = installMockFetch({
      routes: [
        processClaimsRoute([
          { invite_pub: invitePub, claim_pubkey: pluginPub.toLowerCase(), claim_event_id: "claim-1" },
        ]),
        rotateRoute(),
        ...memoryRoutes(seeded.store),
      ],
    });
    try {
      const res = await room_admit.admit({ room_slug: "foo" }, ctx);
      expect(res.ok).toBe(true);
      expect(res.admitted).toEqual([]);
      expect(calls.find((c) => c.url.endsWith("/v0/audience/raw/rotate"))).toBeUndefined();
    } finally {
      restore();
    }
  });

  it("returns 207-equivalent shape on partial grant failure", async () => {
    const { ctx, pluginPub } = makeCtx();
    const seeded = seedHelpers(pluginPub);
    seeded.founderRoom("foo");
    const claimerPriv = randomBytes(32);
    const claimerPub = bytesToHex(schnorr.getPublicKey(claimerPriv));
    const invitePriv = randomBytes(32);
    const invitePub = bytesToHex(schnorr.getPublicKey(invitePriv));
    const { restore } = installMockFetch({
      routes: [
        processClaimsRoute([
          { invite_pub: invitePub, claim_pubkey: claimerPub, claim_event_id: "claim-1" },
        ]),
        // Mark the claimer's grant as all-rejected.
        rotateRoute({ failures: new Set([claimerPub]) }),
        ...memoryRoutes(seeded.store),
      ],
    });
    try {
      const res = await room_admit.admit({ room_slug: "foo" }, ctx);
      expect(res.ok).toBe(false);
      expect(res.error).toBe("partial_rotate");
      expect(res.failed).toBeDefined();
      expect(res.failed!.map((f) => f.recipient)).toContain(claimerPub);
      // Founder's own grant succeeded → not in admitted (founder is already a member).
      // Claimer failed → not in admitted.
      expect(res.admitted.find((a) => a.claim_pubkey === claimerPub)).toBeUndefined();
    } finally {
      restore();
    }
  });

  it("respects max_admit by capping the number of fresh claims rotated in one batch", async () => {
    const { ctx, pluginPub } = makeCtx();
    const seeded = seedHelpers(pluginPub);
    seeded.founderRoom("foo");
    const claims: { invite_pub: string; claim_pubkey: string; claim_event_id: string }[] = [];
    for (let i = 0; i < 3; i++) {
      const cp = bytesToHex(schnorr.getPublicKey(randomBytes(32)));
      const ip = bytesToHex(schnorr.getPublicKey(randomBytes(32)));
      claims.push({ invite_pub: ip, claim_pubkey: cp, claim_event_id: `claim-${i}` });
    }
    const { calls, restore } = installMockFetch({
      routes: [processClaimsRoute(claims), rotateRoute(), ...memoryRoutes(seeded.store)],
    });
    try {
      const res = await room_admit.admit({ room_slug: "foo", max_admit: 2 }, ctx);
      expect(res.ok).toBe(true);
      expect(res.admitted).toHaveLength(2);
      const rotateCall = calls.find((c) => c.url.endsWith("/v0/audience/raw/rotate"));
      const body = rotateCall!.body as { declaration: { tags: string[][] } };
      const memberTags = body.declaration.tags.filter((t) => t[0] === "p").map((t) => t[1]);
      // founder + 2 admitted = 3
      expect(memberTags).toHaveLength(3);
    } finally {
      restore();
    }
  });
});

// Avoid unused warning on FetchCall type re-export.
void (null as unknown as FetchCall);
