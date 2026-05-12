// Track + DispatchIntent + Member projection.

import { describe, expect, test } from "bun:test";
import { projectToMemory } from "../../src/projection";
import { FakeMemoryClient } from "./fakes";
import {
  dispatchPayload,
  dispatchRumor,
  trackPayload,
  trackRumor,
} from "./builders";

describe("projectTrack", () => {
  test("creates studio_track entity + auto-creates studio_member for first-sight pubkey", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    const r = trackRumor({ pubkey: "a".repeat(64), dTag: "t-1" });
    await projectToMemory(r, trackPayload({ name: "scout" }), client);

    expect(fake.attrs("studio:track:studio-rt:scout")).not.toBeNull();
    // Auto-created member entity.
    const member = fake.attrs(`studio:member:${r.pubkey}`);
    expect(member).not.toBeNull();
    expect(member!["pubkey_hex"]).toBe(r.pubkey);
    expect(member!["nickname"]).toBeNull();
  });
});

describe("projectDispatchIntent", () => {
  test("creates studio_dispatch_intent entity with bus_event_id name", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    const r = dispatchRumor({ pubkey: "a".repeat(64), dTag: "d-1" });
    await projectToMemory(r, dispatchPayload({ eventId: "bus-evt-7" }), client);

    const attrs = fake.attrs("studio:dispatch:studio-rt:bus-evt-7");
    expect(attrs).not.toBeNull();
    expect(attrs!["bus_event_id"]).toBe("bus-evt-7");
    expect(attrs!["chosen"]).toBe("scout");
    expect(attrs!["candidates"]).toEqual(["scout", "supervisor"]);
    expect(attrs!["reason"]).toBe("matches scout-search trigger");
  });
});

describe("studio_member first-sight idempotency", () => {
  test("repeat events for same pubkey do not duplicate the member entity", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    const pk = "f".repeat(64);
    await projectToMemory(trackRumor({ pubkey: pk, dTag: "t-x" }), trackPayload({ name: "x" }), client);
    await projectToMemory(trackRumor({ pubkey: pk, dTag: "t-y" }), trackPayload({ name: "y" }), client);

    const memberCount = fake
      .allEntityNames()
      .filter((n) => n.startsWith("studio:member:")).length;
    expect(memberCount).toBe(1);
  });
});
