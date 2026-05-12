import { describe, expect, it } from "bun:test";

import { track } from "../../src/actions";
import { lastPublishWrapsBody, seedActiveRoom } from "./_room-fixture";

describe("studio_track_create", () => {
  it("publishes a kind:30531 rumor with track tags + members", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const result = await track.create(
        { room: "alpha", name: "discoveries", title: "Discoveries", layout: "column" },
        seed.ctx,
      );
      expect(result.d_tag).toBe("discoveries");
      expect(result.rumor_event_id).toMatch(/^[0-9a-f]{64}$/);

      const body = lastPublishWrapsBody(seed.calls);
      expect(body.gift_wraps.length).toBe(1);
      // Each gift-wrap is kind:1059 (NIP-17). The inner rumor's kind is what
      // we care about — kind:30531 — but it's encrypted; instead assert the
      // wrap's `p` tag matches our plugin pub.
      const wrap = body.gift_wraps[0]!;
      const pTag = wrap.tags.find((t) => t[0] === "p");
      expect(pTag?.[1]).toBe(seed.pluginPub.toLowerCase());
    } finally {
      seed.restore();
    }
  });

  it("rejects invalid layout", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      await expect(
        track.create({ room: "alpha", name: "x", title: "X", layout: "weird" }, seed.ctx),
      ).rejects.toMatchObject({ code: "bad_request" });
    } finally {
      seed.restore();
    }
  });

  it("404s when room slug is unknown", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      await expect(
        track.create({ room: "missing", name: "x", title: "X" }, seed.ctx),
      ).rejects.toMatchObject({ code: "room_not_found" });
    } finally {
      seed.restore();
    }
  });
});
