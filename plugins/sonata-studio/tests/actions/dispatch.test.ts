import { describe, expect, it } from "bun:test";
import { unwrap } from "../../src/crypto/nip17";
import { decryptString } from "../../src/crypto/nip44";

import { dispatch } from "../../src/actions";
import { lastPublishWrapsBody, seedActiveRoom } from "./_room-fixture";

describe("studio_dispatch_intent_post", () => {
  it("publishes a kind:30532 rumor carrying eventId, candidates, chosen, reason", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const res = await dispatch.post(
        {
          room: "alpha",
          event_id: "bus-event-42",
          candidates: ["worker-a", "worker-b", "worker-c"],
          chosen: "worker-b",
          reason: "lowest backlog",
          signals: { backlog: 3, idle: true, region: "us-west" },
        },
        seed.ctx,
      );
      expect(res.d_tag).toBe("bus-event-42");

      const wrap = lastPublishWrapsBody(seed.calls).gift_wraps[0]!;
      const { rumor } = unwrap(wrap as never, seed.pluginPriv);
      expect(rumor.kind).toBe(30532);
      const payload = JSON.parse(decryptString(rumor.content, seed.epochPriv, rumor.pubkey));
      expect(payload["@type"]).toBe("DispatchIntent");
      expect(payload.eventId).toBe("bus-event-42");
      expect(payload.chosen).toBe("worker-b");
      expect(payload.candidates).toEqual(["worker-a", "worker-b", "worker-c"]);
      expect(payload.signals.backlog).toBe(3);
    } finally {
      seed.restore();
    }
  });

  it("rejects when chosen is not in candidates", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      await expect(
        dispatch.post(
          {
            room: "alpha",
            event_id: "x",
            candidates: ["a"],
            chosen: "b",
            reason: "r",
          },
          seed.ctx,
        ),
      ).rejects.toMatchObject({ code: "bad_request" });
    } finally {
      seed.restore();
    }
  });
});
