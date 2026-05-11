import { describe, expect, it } from "bun:test";
import { unwrap } from "../../src/crypto/nip17";
import { decryptString } from "../../src/crypto/nip44";

import { qa } from "../../src/actions";
import { lastPublishWrapsBody, seedActiveRoom } from "./_room-fixture";

describe("studio_question_post", () => {
  it("publishes a kind:30534 rumor with @type=Question", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const res = await qa.question(
        { room: "alpha", body: "Is the build green?", track: "ops", tags: ["build"] },
        seed.ctx,
      );
      expect(res.rumor_event_id).toMatch(/^[0-9a-f]{64}$/);

      const wrap = lastPublishWrapsBody(seed.calls).gift_wraps[0]!;
      const { rumor } = unwrap(wrap as never, seed.pluginPriv);
      expect(rumor.kind).toBe(30534);
      const payload = JSON.parse(decryptString(rumor.content, seed.epochPriv, rumor.pubkey));
      expect(payload["@type"]).toBe("Question");
      expect(payload.body).toBe("Is the build green?");
      expect(payload.track).toBe("ops");
    } finally {
      seed.restore();
    }
  });
});

describe("studio_answer_post", () => {
  it("publishes a kind:30535 rumor with target.@id = question_id", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const questionId = "a".repeat(64);
      const res = await qa.answer(
        { room: "alpha", question_id: questionId, body: "Yes." },
        seed.ctx,
      );
      expect(res.d_tag.startsWith(questionId + ":")).toBe(true);

      const wrap = lastPublishWrapsBody(seed.calls).gift_wraps[0]!;
      const { rumor } = unwrap(wrap as never, seed.pluginPriv);
      expect(rumor.kind).toBe(30535);
      const payload = JSON.parse(decryptString(rumor.content, seed.epochPriv, rumor.pubkey));
      expect(payload["@type"]).toBe("Answer");
      expect((payload.target as { "@id": string })["@id"]).toBe(questionId);
    } finally {
      seed.restore();
    }
  });

  it("rejects non-hex question_id", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      await expect(
        qa.answer({ room: "alpha", question_id: "not-hex", body: "x" }, seed.ctx),
      ).rejects.toMatchObject({ code: "bad_request" });
    } finally {
      seed.restore();
    }
  });
});
