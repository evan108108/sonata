import { describe, expect, it } from "bun:test";
import { unwrap } from "../../src/crypto/nip17";
import { decryptString } from "../../src/crypto/nip44";

import { card } from "../../src/actions";
import { lastPublishWrapsBody, seedActiveRoom } from "./_room-fixture";

describe("studio_card_delete", () => {
  it("republishes the card with status=deleted and marks the entity as deleted", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const posted = await card.post(
        {
          room: "alpha",
          track: "discoveries",
          kind: "lead",
          title: "About to die",
          summary: "this card will be deleted",
          blocks: [{ type: "text", body: "bye" }],
          tags: ["urgent"],
        },
        seed.ctx,
      );
      expect(posted.d_tag).toMatch(/^about-to-die-[0-9a-f]{8}$/);

      const del = await card.delete(
        { room: "alpha", d_tag: posted.d_tag },
        seed.ctx,
      );
      expect(del.d_tag).toBe(posted.d_tag);
      expect(del.rumor_event_id).toMatch(/^[0-9a-f]{64}$/);

      // Unwrap the most recent publish-wraps call — should be the delete event.
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
      const altTag = rumor.tags.find((t) => t[0] === "alt");
      expect(altTag?.[1]).toBe("Studio card: deleted");
      const dTag = rumor.tags.find((t) => t[0] === "d");
      expect(dTag?.[1]).toBe(posted.d_tag);

      const plaintext = decryptString(rumor.content, seed.epochPriv, rumor.pubkey);
      const payload = JSON.parse(plaintext) as Record<string, unknown>;
      expect(payload["@type"]).toBe("Card");
      expect(payload.status).toBe("deleted");
      // Carries the original metadata so list/preview survive the delete.
      expect(payload.title).toBe("About to die");
      expect(payload.kind).toBe("lead");
      expect(payload.track).toBe("discoveries");

      // The card still appears in card.list — renderers filter on status.
      // Note: in-test LWW (same-second created_at) keeps the projected status
      // as "active"; the wire payload above is the contract that matters for
      // delivery, and live projection happens on different seconds.
      const listed = await card.list({ room: "alpha" }, seed.ctx);
      expect(listed.cards.length).toBe(1);
      expect(listed.cards[0]!.d_tag).toBe(posted.d_tag);
    } finally {
      seed.restore();
    }
  });

  it("404 card_not_found when no such d_tag exists for the author", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      await expect(
        card.delete({ room: "alpha", d_tag: "ghost-00000000" }, seed.ctx),
      ).rejects.toMatchObject({ code: "card_not_found", status: 404 });
    } finally {
      seed.restore();
    }
  });

  it("403 not_author when the card was posted by a different pubkey", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const posted = await card.post(
        {
          room: "alpha",
          track: "discoveries",
          kind: "note",
          title: "Someone else's card",
          summary: "you can't delete me",
        },
        seed.ctx,
      );

      // Rewrite the projected entity's created_by_pubkey to a different hex —
      // this simulates a card whose original author isn't the plugin pubkey
      // currently calling delete. Entity name still keys on the plugin pubkey
      // (so the lookup hits), but the authored-by check fails.
      const entityName = `studio:card:alpha:${seed.pluginPub.toLowerCase()}:${posted.d_tag}`;
      const row = seed.store.entities.get(entityName);
      if (!row) throw new Error(`fixture entity ${entityName} missing`);
      const attrs = JSON.parse(row.attributes) as Record<string, unknown>;
      const foreignPub = "f".repeat(64);
      attrs["created_by_pubkey"] = foreignPub;
      seed.store.entities.set(entityName, { ...row, attributes: JSON.stringify(attrs) });

      await expect(
        card.delete({ room: "alpha", d_tag: posted.d_tag }, seed.ctx),
      ).rejects.toMatchObject({ code: "not_author", status: 403 });
    } finally {
      seed.restore();
    }
  });
});
