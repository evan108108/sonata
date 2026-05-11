// Room projection — additive semantics + local-only key preservation.

import { describe, expect, test } from "bun:test";
import { projectToMemory } from "../../src/projection";
import { FakeMemoryClient } from "./fakes";
import { roomPayload, roomRumor } from "./builders";

describe("projectRoom", () => {
  test("creates studio_room entity with public fields", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    await projectToMemory(roomRumor({}), roomPayload(), client);
    const attrs = fake.attrs("studio:room:studio-rt");
    expect(attrs).not.toBeNull();
    expect(attrs!["slug"]).toBe("studio-rt");
    expect(attrs!["title"]).toBe("Studio round-trip");
    expect(attrs!["default_tracks"]).toEqual(["inbox", "decisions"]);
  });

  test("local-only fields (e.g. aud_id_priv_secret_name) are not overwritten", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    // Pretend the action handler created the room locally with a secret reference.
    await client.entity.upsert({
      name: "studio:room:studio-rt",
      type: "studio_room",
      description: "local create",
      attributes: {
        aud_id_priv_secret_name: "studio-rt:aud-id-priv",
        epoch_keys_secret_name: "studio-rt:epoch-keys",
        current_epoch: 1,
        members: ["pubA", "pubB"],
        last_seen_wrap_at_ms: 0,
        state: "active",
        created_at_seconds: 1000,
      },
    });

    // A Room event arrives later (newer created_at).
    await projectToMemory(
      roomRumor({ createdAt: 2000 }),
      roomPayload({ title: "Updated", description: "newer" }),
      client,
    );

    const attrs = fake.attrs("studio:room:studio-rt");
    expect(attrs!["title"]).toBe("Updated");
    expect(attrs!["description"]).toBe("newer");
    // Locals preserved.
    expect(attrs!["aud_id_priv_secret_name"]).toBe("studio-rt:aud-id-priv");
    expect(attrs!["epoch_keys_secret_name"]).toBe("studio-rt:epoch-keys");
    expect(attrs!["current_epoch"]).toBe(1);
    expect(attrs!["members"]).toEqual(["pubA", "pubB"]);
    expect(attrs!["state"]).toBe("active");
  });

  test("LWW: older Room event is dropped", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    await projectToMemory(roomRumor({ createdAt: 5000 }), roomPayload({ title: "v1" }), client);
    expect(fake.attrs("studio:room:studio-rt")!["title"]).toBe("v1");

    await projectToMemory(
      roomRumor({ createdAt: 3000 }),
      roomPayload({ title: "older" }),
      client,
    );
    expect(fake.attrs("studio:room:studio-rt")!["title"]).toBe("v1");
  });
});
