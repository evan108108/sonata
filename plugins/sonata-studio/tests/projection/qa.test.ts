// Question + Answer projection — answered=true side effect + LWW.

import { describe, expect, test } from "bun:test";
import { projectToMemory } from "../../src/projection";
import { FakeMemoryClient } from "./fakes";
import {
  answerPayload,
  answerRumor,
  questionPayload,
  questionRumor,
} from "./builders";

describe("projectQuestion / projectAnswer", () => {
  test("Answer flips target Question.answered = true", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    const qEvtId = "1".repeat(64);
    const qRumor = questionRumor({
      pubkey: "a".repeat(64),
      dTag: "q-1",
      eventId: qEvtId,
    });
    await projectToMemory(qRumor, questionPayload(), client);

    const qAttrs = fake.attrs(`studio:question:studio-rt:${qRumor.pubkey}:q-1`);
    expect(qAttrs!["answered"]).toBe(false);

    const aRumor = answerRumor({ pubkey: "b".repeat(64), dTag: "a-1" });
    await projectToMemory(aRumor, answerPayload(qEvtId), client);

    const qAttrsAfter = fake.attrs(`studio:question:studio-rt:${qRumor.pubkey}:q-1`);
    expect(qAttrsAfter!["answered"]).toBe(true);

    // --targets--> relation created.
    const targets = fake.rels({ relation: "targets" });
    expect(targets.length).toBe(1);
  });

  test("Answer-before-Question: pending then resolved when Question arrives", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    const futureQEvtId = "2".repeat(64);
    const aRumor = answerRumor({
      pubkey: "b".repeat(64),
      dTag: "a-2",
    });
    await projectToMemory(aRumor, answerPayload(futureQEvtId), client);

    const aAttrs = fake.attrs(`studio:answer:studio-rt:${aRumor.pubkey}:a-2`);
    const pending = aAttrs!["_pending_relations"] as Array<{
      relation: string;
      target_event_id: string;
    }>;
    expect(pending).toHaveLength(1);
    expect(pending[0]!.target_event_id).toBe(futureQEvtId);

    // Question arrives.
    const qRumor = questionRumor({
      pubkey: "a".repeat(64),
      dTag: "q-2",
      eventId: futureQEvtId,
    });
    await projectToMemory(qRumor, questionPayload(), client);

    // Pending drained.
    const aAttrsAfter = fake.attrs(`studio:answer:studio-rt:${aRumor.pubkey}:a-2`);
    expect(aAttrsAfter!["_pending_relations"]).toEqual([]);
    expect(fake.rels({ relation: "targets" }).length).toBe(1);
    // NOTE: when Answer was projected first, the Question didn't exist yet,
    // so the answered=true flip is best-effort. The pending-drain path
    // creates the relation but doesn't retroactively flip answered. Renderers
    // can derive "answered" by checking whether any --targets--> relation
    // points at the question.
  });

  test("LWW on Question: later created_at replaces; earlier dropped", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    const r1 = questionRumor({
      pubkey: "a".repeat(64),
      dTag: "q-lww",
      createdAt: 1000,
      eventId: "1".repeat(64),
    });
    await projectToMemory(r1, questionPayload({ body: "first" }), client);

    const r2 = questionRumor({
      pubkey: r1.pubkey,
      dTag: "q-lww",
      createdAt: 2000,
      eventId: "2".repeat(64),
    });
    await projectToMemory(r2, questionPayload({ body: "second" }), client);

    const after = fake.attrs(`studio:question:studio-rt:${r1.pubkey}:q-lww`);
    expect(after!["body"]).toBe("second");
    expect(after!["created_at_seconds"]).toBe(2000);

    const r1Replay = questionRumor({
      pubkey: r1.pubkey,
      dTag: "q-lww",
      createdAt: 500,
    });
    await projectToMemory(r1Replay, questionPayload({ body: "earlier" }), client);
    const final = fake.attrs(`studio:question:studio-rt:${r1.pubkey}:q-lww`);
    expect(final!["body"]).toBe("second");
  });

  test("Question replay preserves answered=true even after body replacement", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    const qEvtId = "3".repeat(64);
    const r1 = questionRumor({
      pubkey: "a".repeat(64),
      dTag: "q-keep",
      createdAt: 1000,
      eventId: qEvtId,
    });
    await projectToMemory(r1, questionPayload({ body: "v1" }), client);

    // Answer flips it.
    await projectToMemory(
      answerRumor({ pubkey: "b".repeat(64), dTag: "a-keep" }),
      answerPayload(qEvtId),
      client,
    );
    expect(fake.attrs(`studio:question:studio-rt:${r1.pubkey}:q-keep`)!["answered"]).toBe(true);

    // Question republished — answered must be retained.
    const r2 = questionRumor({
      pubkey: r1.pubkey,
      dTag: "q-keep",
      createdAt: 2000,
      eventId: "4".repeat(64),
    });
    await projectToMemory(r2, questionPayload({ body: "v2" }), client);
    const after = fake.attrs(`studio:question:studio-rt:${r1.pubkey}:q-keep`);
    expect(after!["body"]).toBe("v2");
    expect(after!["answered"]).toBe(true);
  });
});
