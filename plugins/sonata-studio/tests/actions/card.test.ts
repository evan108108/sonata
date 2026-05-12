import { describe, expect, it } from "bun:test";
import { unwrap } from "../../src/crypto/nip17";
import { decryptString } from "../../src/crypto/nip44";

import { card } from "../../src/actions";
import { lastPublishWrapsBody, seedActiveRoom } from "./_room-fixture";

describe("studio_card_post", () => {
  it("publishes a kind:30530 rumor with @type=Card payload", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const res = await card.post(
        {
          room: "alpha",
          track: "discoveries",
          kind: "lead",
          title: "First Card",
          summary: "Quick summary",
          blocks: [{ type: "text", body: "hello world" }],
          tags: ["urgent"],
        },
        seed.ctx,
      );

      expect(res.audience_address).toMatch(/^30520:[0-9a-f]{64}:alpha$/);
      expect(res.d_tag).toMatch(/^first-card-[0-9a-f]{8}$/);

      const body = lastPublishWrapsBody(seed.calls);
      expect(body.gift_wraps.length).toBe(1);

      // Unwrap the wrap → seal → rumor and verify kind + decrypted payload.
      const giftWrap = body.gift_wraps[0]!;
      const { rumor } = unwrap(
        {
          ...giftWrap,
          id: (giftWrap as unknown as { id: string }).id,
          pubkey: (giftWrap as unknown as { pubkey: string }).pubkey,
          sig: (giftWrap as unknown as { sig: string }).sig,
          created_at: (giftWrap as unknown as { created_at: number }).created_at,
        },
        seed.pluginPriv,
      );
      expect(rumor.kind).toBe(30530);
      // Required tags per spec.
      const tagNames = rumor.tags.map((t) => t[0]);
      expect(tagNames).toContain("d");
      expect(tagNames).toContain("a");
      expect(tagNames).toContain("fa:context");
      expect(tagNames).toContain("fa:epoch");
      expect(tagNames).toContain("alt");
      expect(tagNames).toContain("blake3");
      expect(tagNames).toContain("p");

      const plaintext = decryptString(rumor.content, seed.epochPriv, rumor.pubkey);
      const payload = JSON.parse(plaintext);
      expect(payload["@type"]).toBe("Card");
      expect(payload.kind).toBe("lead");
      expect(payload.track).toBe("discoveries");
      expect(payload.title).toBe("First Card");
      expect(payload.tags).toEqual(["urgent"]);
    } finally {
      seed.restore();
    }
  });

  it("rejects payloads that exceed the 10000-char body cap", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const longBody = "x".repeat(10001);
      await expect(
        card.post(
          { room: "alpha", track: "t", kind: "note", title: "T", body: longBody },
          seed.ctx,
        ),
      ).rejects.toMatchObject({ code: "bad_request" });
    } finally {
      seed.restore();
    }
  });

  it("legacy `summary` input still publishes (back-compat alias)", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const res = await card.post(
        {
          room: "alpha",
          track: "t",
          kind: "note",
          title: "Legacy summary input",
          summary: "old-shape input",
        },
        seed.ctx,
      );
      const body = lastPublishWrapsBody(seed.calls);
      const giftWrap = body.gift_wraps[0]!;
      const { rumor } = unwrap(
        {
          ...giftWrap,
          id: (giftWrap as unknown as { id: string }).id,
          pubkey: (giftWrap as unknown as { pubkey: string }).pubkey,
          sig: (giftWrap as unknown as { sig: string }).sig,
          created_at: (giftWrap as unknown as { created_at: number }).created_at,
        },
        seed.pluginPriv,
      );
      const plaintext = decryptString(rumor.content, seed.epochPriv, rumor.pubkey);
      const payload = JSON.parse(plaintext) as Record<string, unknown>;
      expect(payload.body).toBe("old-shape input");
      expect(payload.summary).toBeUndefined();
      expect(res.d_tag).toMatch(/^legacy-summary-input-[0-9a-f]{8}$/);
    } finally {
      seed.restore();
    }
  });

  it("rejects when both `body` and `summary` are present with different content", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      await expect(
        card.post(
          {
            room: "alpha",
            track: "t",
            kind: "note",
            title: "Conflict",
            body: "a",
            summary: "b",
          },
          seed.ctx,
        ),
      ).rejects.toMatchObject({ code: "bad_request" });
    } finally {
      seed.restore();
    }
  });
});

describe("studio_card_list", () => {
  it("returns empty list when no cards exist", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const res = await card.list({ room: "alpha" }, seed.ctx);
      expect(res).toEqual({ cards: [] });
    } finally {
      seed.restore();
    }
  });
});
