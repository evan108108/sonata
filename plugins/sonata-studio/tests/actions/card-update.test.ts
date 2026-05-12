import { describe, expect, it } from "bun:test";
import { unwrap } from "../../src/crypto/nip17";
import { decryptString } from "../../src/crypto/nip44";

import { card } from "../../src/actions";
import { lastPublishWrapsBody, seedActiveRoom } from "./_room-fixture";

describe("studio_card_update", () => {
  it("renames title while preserving track / kind / blocks / tags", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const posted = await card.post(
        {
          room: "alpha",
          track: "discoveries",
          kind: "lead",
          title: "Original title",
          summary: "first summary",
          blocks: [{ type: "text", body: "preserve me" }],
          tags: ["urgent", "deep-dive"],
        },
        seed.ctx,
      );

      const upd = await card.update(
        { room: "alpha", d_tag: posted.d_tag, title: "Renamed title" },
        seed.ctx,
      );
      expect(upd.d_tag).toBe(posted.d_tag);
      expect(upd.rumor_event_id).toMatch(/^[0-9a-f]{64}$/);

      // The last publish carries the new payload — verify merge semantics.
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

      // alt tag reflects the new title.
      const altTag = rumor.tags.find((t) => t[0] === "alt");
      expect(altTag?.[1]).toBe("Studio card: Renamed title");
      // d-tag is stable across the update.
      const dTag = rumor.tags.find((t) => t[0] === "d");
      expect(dTag?.[1]).toBe(posted.d_tag);

      const plaintext = decryptString(rumor.content, seed.epochPriv, rumor.pubkey);
      const payload = JSON.parse(plaintext) as Record<string, unknown>;
      expect(payload["@type"]).toBe("Card");
      expect(payload.title).toBe("Renamed title");
      // Preserved fields carry through from the original.
      expect(payload.kind).toBe("lead");
      expect(payload.track).toBe("discoveries");
      // Wire field renamed from `summary` to `body` (2026-05-12); `summary`
      // input on `card.post` above is the legacy alias path.
      expect(payload.body).toBe("first summary");
      expect(payload.summary).toBeUndefined();
      expect(payload.blocks).toEqual([{ type: "text", body: "preserve me" }]);
      expect(payload.tags).toEqual(["urgent", "deep-dive"]);
    } finally {
      seed.restore();
    }
  });

  it("track-only update moves the projected card between cardsByRoomTrack groups", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const posted = await card.post(
        {
          room: "alpha",
          track: "discoveries",
          kind: "note",
          title: "Roaming card",
          summary: "moves between tracks",
        },
        seed.ctx,
      );

      // Pre-move: card is filed under "discoveries".
      const beforeListed = await card.list({ room: "alpha", track: "discoveries" }, seed.ctx);
      expect(beforeListed.cards.map((c) => c.d_tag)).toContain(posted.d_tag);
      const beforeOther = await card.list({ room: "alpha", track: "review" }, seed.ctx);
      expect(beforeOther.cards.map((c) => c.d_tag)).not.toContain(posted.d_tag);

      // The projection's LWW guard ignores same-second replays — both publishes
      // land in the same wall-second under bun:test. Backdate the entity's
      // created_at_seconds so the update's projection actually overwrites,
      // mirroring what happens in production where the SSE relay delivers a
      // strictly-later event.
      const entityName = `studio:card:alpha:${seed.pluginPub.toLowerCase()}:${posted.d_tag}`;
      const row = seed.store.entities.get(entityName);
      if (!row) throw new Error(`fixture entity ${entityName} missing`);
      const attrs = JSON.parse(row.attributes) as Record<string, unknown>;
      attrs["created_at_seconds"] = Math.floor(Date.now() / 1000) - 60;
      seed.store.entities.set(entityName, { ...row, attributes: JSON.stringify(attrs) });

      // Move it.
      await card.update(
        { room: "alpha", d_tag: posted.d_tag, track: "review" },
        seed.ctx,
      );

      // Post-move: the same d_tag now appears only under "review".
      const afterDiscoveries = await card.list({ room: "alpha", track: "discoveries" }, seed.ctx);
      expect(afterDiscoveries.cards.map((c) => c.d_tag)).not.toContain(posted.d_tag);
      const afterReview = await card.list({ room: "alpha", track: "review" }, seed.ctx);
      expect(afterReview.cards.map((c) => c.d_tag)).toContain(posted.d_tag);
    } finally {
      seed.restore();
    }
  });

  it("404 card_not_found when the d_tag is unknown", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      await expect(
        card.update({ room: "alpha", d_tag: "ghost-00000000", title: "X" }, seed.ctx),
      ).rejects.toMatchObject({ code: "card_not_found", status: 404 });
    } finally {
      seed.restore();
    }
  });

  it("403 not_author when a different pubkey owns the card", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const posted = await card.post(
        {
          room: "alpha",
          track: "discoveries",
          kind: "note",
          title: "Someone else's card",
          summary: "you can't edit me",
        },
        seed.ctx,
      );

      // Rewrite the projected entity's created_by_pubkey to a foreign hex —
      // the lookup keys by the plugin's own pubkey, but the author check
      // compares to whatever the entity claims.
      const entityName = `studio:card:alpha:${seed.pluginPub.toLowerCase()}:${posted.d_tag}`;
      const row = seed.store.entities.get(entityName);
      if (!row) throw new Error(`fixture entity ${entityName} missing`);
      const attrs = JSON.parse(row.attributes) as Record<string, unknown>;
      attrs["created_by_pubkey"] = "f".repeat(64);
      seed.store.entities.set(entityName, { ...row, attributes: JSON.stringify(attrs) });

      await expect(
        card.update({ room: "alpha", d_tag: posted.d_tag, title: "Hijacked" }, seed.ctx),
      ).rejects.toMatchObject({ code: "not_author", status: 403 });
    } finally {
      seed.restore();
    }
  });
});
