// member.setNickname is local-only — never hits the gateway.

import { describe, expect, it } from "bun:test";

import { member } from "../../src/actions";
import { seedActiveRoom } from "./_room-fixture";

describe("studio_member_set_nickname", () => {
  it("upserts studio_member entity with the given nickname; no relay traffic", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const peer = "1".repeat(64);
      const before = seed.calls.length;
      const res = await member.setNickname(
        { pubkey_or_npub: peer, nickname: "Scout" },
        seed.ctx,
      );
      expect(res).toEqual({ ok: true });

      // No publish-wraps was issued.
      const after = seed.calls.slice(before);
      expect(after.some((c) => c.url.endsWith("/v0/audience/raw/publish-wraps"))).toBe(false);

      const ent = seed.store.entities.get(`studio:member:${peer}`);
      expect(ent).toBeDefined();
      expect(ent!.type).toBe("studio_member");
      const attrs = JSON.parse(ent!.attributes) as Record<string, unknown>;
      expect(attrs.nickname).toBe("Scout");
      expect(attrs.pubkey_hex).toBe(peer);
    } finally {
      seed.restore();
    }
  });

  it("preserves first_seen_in_room from a prior auto-create", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const peer = "2".repeat(64);
      // Pre-seed an auto-created stub with first_seen_in_room set.
      seed.store.entities.set(`studio:member:${peer}`, {
        id: "ent-pre",
        name: `studio:member:${peer}`,
        type: "studio_member",
        description: "stub",
        attributes: JSON.stringify({
          pubkey_hex: peer,
          nickname: null,
          first_seen_in_room: "alpha",
          first_seen_at_ms: 1234,
          tags: ["sonata-studio", "studio-member"],
        }),
      });
      seed.store.entitiesById.set("ent-pre", `studio:member:${peer}`);

      await member.setNickname({ pubkey_or_npub: peer, nickname: "Renamed" }, seed.ctx);
      const ent = seed.store.entities.get(`studio:member:${peer}`)!;
      const attrs = JSON.parse(ent.attributes) as Record<string, unknown>;
      expect(attrs.nickname).toBe("Renamed");
      expect(attrs.first_seen_in_room).toBe("alpha");
      expect(attrs.first_seen_at_ms).toBe(1234);
    } finally {
      seed.restore();
    }
  });

  it("rejects bad pubkey input", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      await expect(
        member.setNickname({ pubkey_or_npub: "not-hex", nickname: "x" }, seed.ctx),
      ).rejects.toMatchObject({ code: "bad_request" });
    } finally {
      seed.restore();
    }
  });
});
