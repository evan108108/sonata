// Comment projection — pending-relations + ordering.

import { describe, expect, test } from "bun:test";
import { projectToMemory } from "../../src/projection";
import { FakeMemoryClient } from "./fakes";
import {
  cardPayload,
  cardRumor,
  commentPayload,
  commentRumor,
} from "./builders";

describe("projectComment", () => {
  test("creates studio_comment with target_ref + relates --targets--> when card exists", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    const cardEvtId = "c".repeat(64);
    const cRumor = cardRumor({
      pubkey: "1".repeat(64),
      dTag: "card-001",
      eventId: cardEvtId,
    });
    await projectToMemory(cRumor, cardPayload(), client);

    const cmtRumor = commentRumor({
      pubkey: "2".repeat(64),
      dTag: "cmt-001",
    });
    await projectToMemory(cmtRumor, commentPayload(cardEvtId), client);

    const cmtAttrs = fake.attrs(
      `studio:comment:studio-rt:${cmtRumor.pubkey}:cmt-001`,
    );
    expect(cmtAttrs).not.toBeNull();
    expect(cmtAttrs!["target_ref"]).toBe(cardEvtId);
    expect(cmtAttrs!["body"]).toBe("looks good");

    const targetsRels = fake.rels({ relation: "targets" });
    expect(targetsRels.length).toBe(1);
    // No pending relations.
    expect(cmtAttrs!["_pending_relations"] ?? []).toEqual([]);
  });

  test("out-of-order: comment-before-card stashes pending; later card resolves it", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    const futureCardEvtId = "f".repeat(64);
    const cmtRumor = commentRumor({
      pubkey: "2".repeat(64),
      dTag: "cmt-pending",
    });
    await projectToMemory(cmtRumor, commentPayload(futureCardEvtId), client);

    const cmtAttrs = fake.attrs(
      `studio:comment:studio-rt:${cmtRumor.pubkey}:cmt-pending`,
    );
    expect(cmtAttrs).not.toBeNull();
    const pending = cmtAttrs!["_pending_relations"] as Array<{
      relation: string;
      target_event_id: string;
    }>;
    expect(pending).toHaveLength(1);
    expect(pending[0]!.relation).toBe("targets");
    expect(pending[0]!.target_event_id).toBe(futureCardEvtId);
    // No `targets` relation yet.
    expect(fake.rels({ relation: "targets" })).toHaveLength(0);

    // Card arrives with that event_id.
    const cRumor = cardRumor({
      pubkey: "1".repeat(64),
      dTag: "card-late",
      eventId: futureCardEvtId,
    });
    await projectToMemory(cRumor, cardPayload(), client);

    // Pending should be drained → relation created → entity body cleared.
    expect(fake.rels({ relation: "targets" }).length).toBe(1);
    const cmtAttrsAfter = fake.attrs(
      `studio:comment:studio-rt:${cmtRumor.pubkey}:cmt-pending`,
    );
    expect(cmtAttrsAfter!["_pending_relations"]).toEqual([]);
  });

  test("nostr: URI target ref resolves the same way as bare hex", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    const cardEvtId = "9".repeat(64);
    await projectToMemory(
      cardRumor({ pubkey: "1".repeat(64), dTag: "c-nostr", eventId: cardEvtId }),
      cardPayload(),
      client,
    );
    await projectToMemory(
      commentRumor({ pubkey: "2".repeat(64), dTag: "cmt-nostr" }),
      commentPayload(`nostr:${cardEvtId}`),
      client,
    );
    expect(fake.rels({ relation: "targets" }).length).toBe(1);
  });
});
