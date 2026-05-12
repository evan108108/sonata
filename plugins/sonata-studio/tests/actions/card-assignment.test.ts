import { describe, expect, it } from "bun:test";

import { unwrap } from "../../src/crypto/nip17";
import { decryptString } from "../../src/crypto/nip44";
import { card } from "../../src/actions";
import { lastPublishWrapsBody, seedActiveRoom } from "./_room-fixture";

const HEX64 = "0".repeat(64);
const HEX64_B = "1".repeat(64);

function decryptPayload(seed: ReturnType<typeof seedActiveRoom>) {
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
  return JSON.parse(plaintext) as Record<string, unknown>;
}

describe("studio_card_post: assignees + status", () => {
  it("round-trips a single-assignee + default status on the wire", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      await card.post(
        {
          room: "alpha",
          track: "engineering",
          kind: "task",
          title: "Triage backlog",
          body: "do the thing",
          assignees: [HEX64],
        },
        seed.ctx,
      );
      const payload = decryptPayload(seed);
      expect(payload.assignees).toEqual([HEX64]);
      expect(payload.status).toBe("open");
    } finally {
      seed.restore();
    }
  });

  it("accepts an explicit status on create", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      await card.post(
        {
          room: "alpha",
          track: "engineering",
          kind: "task",
          title: "Already in progress",
          body: "I started on this earlier",
          status: "in_progress",
        },
        seed.ctx,
      );
      const payload = decryptPayload(seed);
      expect(payload.status).toBe("in_progress");
      expect(payload.assignees).toEqual([]);
    } finally {
      seed.restore();
    }
  });

  it("rejects assignees cardinality > 1 with too_many_assignees", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      await expect(
        card.post(
          {
            room: "alpha",
            track: "engineering",
            kind: "task",
            title: "Multi-assign attempt",
            body: "nope",
            assignees: [HEX64, HEX64_B],
          },
          seed.ctx,
        ),
      ).rejects.toMatchObject({ code: "too_many_assignees" });
    } finally {
      seed.restore();
    }
  });

  it("rejects non-hex assignee with bad_request", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      await expect(
        card.post(
          {
            room: "alpha",
            track: "engineering",
            kind: "task",
            title: "Bad hex",
            body: "nope",
            assignees: ["not-hex"],
          },
          seed.ctx,
        ),
      ).rejects.toMatchObject({ code: "bad_request" });
    } finally {
      seed.restore();
    }
  });

  it("rejects unknown status value with invalid_status", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      await expect(
        card.post(
          {
            room: "alpha",
            track: "engineering",
            kind: "task",
            title: "Bad status",
            body: "nope",
            status: "foo",
          },
          seed.ctx,
        ),
      ).rejects.toMatchObject({ code: "invalid_status" });
    } finally {
      seed.restore();
    }
  });

  it("update preserves status when omitted, accepts new assignees", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const posted = await card.post(
        {
          room: "alpha",
          track: "engineering",
          kind: "task",
          title: "Assign later",
          body: "starts unassigned",
          status: "in_progress",
        },
        seed.ctx,
      );
      await card.update(
        { room: "alpha", d_tag: posted.d_tag, assignees: [HEX64] },
        seed.ctx,
      );
      const payload = decryptPayload(seed);
      expect(payload.assignees).toEqual([HEX64]);
      expect(payload.status).toBe("in_progress");
    } finally {
      seed.restore();
    }
  });

  it("update rejects invalid status", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const posted = await card.post(
        {
          room: "alpha",
          track: "engineering",
          kind: "task",
          title: "Bad status update",
          body: "x",
        },
        seed.ctx,
      );
      await expect(
        card.update(
          { room: "alpha", d_tag: posted.d_tag, status: "wat" },
          seed.ctx,
        ),
      ).rejects.toMatchObject({ code: "invalid_status" });
    } finally {
      seed.restore();
    }
  });
});
