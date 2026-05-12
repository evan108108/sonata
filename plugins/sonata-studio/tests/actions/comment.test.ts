import { describe, expect, it } from "bun:test";
import { unwrap } from "../../src/crypto/nip17";
import { decryptString } from "../../src/crypto/nip44";

import { comment } from "../../src/actions";
import { lastPublishWrapsBody, seedActiveRoom } from "./_room-fixture";

describe("studio_comment_post", () => {
  it("publishes a kind:30533 rumor with target.@id pointing to the input target", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const targetEventId = "f".repeat(64);
      const res = await comment.post(
        { room: "alpha", target: targetEventId, body: "I agree", intent: "agree" },
        seed.ctx,
      );
      expect(res.d_tag.startsWith(targetEventId + ":")).toBe(true);

      const body = lastPublishWrapsBody(seed.calls);
      const wrap = body.gift_wraps[0]!;
      const { rumor } = unwrap(wrap as never, seed.pluginPriv);
      expect(rumor.kind).toBe(30533);
      const payload = JSON.parse(decryptString(rumor.content, seed.epochPriv, rumor.pubkey));
      expect(payload["@type"]).toBe("Comment");
      expect((payload.target as { "@id": string })["@id"]).toBe(targetEventId);
      expect(payload.intent).toBe("agree");
    } finally {
      seed.restore();
    }
  });

  it("rejects empty body", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      await expect(
        comment.post({ room: "alpha", target: "f".repeat(64), body: "" }, seed.ctx),
      ).rejects.toMatchObject({ code: "bad_request" });
    } finally {
      seed.restore();
    }
  });
});
