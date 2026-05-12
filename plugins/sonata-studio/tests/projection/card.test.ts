// Card projection — shape + relations + LWW.

import { describe, expect, test } from "bun:test";
import { projectToMemory } from "../../src/projection";
import { FakeMemoryClient } from "./fakes";
import {
  cardPayload,
  cardRumor,
  roomPayload,
  roomRumor,
  trackPayload,
  trackRumor,
} from "./builders";

describe("projectCard", () => {
  test("creates studio_card entity with correct shape", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    const rumor = cardRumor({
      pubkey: "1".repeat(64),
      dTag: "card-001",
      eventId: "e".repeat(64),
    });
    await projectToMemory(rumor, cardPayload(), client);

    const expectedName = `studio:card:studio-rt:${rumor.pubkey}:card-001`;
    const attrs = fake.attrs(expectedName);
    expect(attrs).not.toBeNull();
    expect(attrs!["_studio_kind"]).toBe(30530);
    expect(attrs!["title"]).toBe("hello");
    expect(attrs!["body"]).toBe("world");
    // Cutover alias — readers that still look at `summary` keep working.
    expect(attrs!["summary"]).toBe("world");
    expect(attrs!["track_slug"]).toBe("inbox");
    expect(attrs!["created_by_pubkey"]).toBe(rumor.pubkey);
    expect(attrs!["event_id"]).toBe(rumor.id);
    expect(attrs!["d_tag"]).toBe("card-001");
    const tags = attrs!["tags"] as string[];
    expect(tags).toContain("sonata-studio");
    expect(tags).toContain("room:studio-rt");
    const audit = attrs!["_studio_event_audit"] as Array<{ event_id: string }>;
    expect(audit).toHaveLength(1);
    expect(audit[0]!.event_id).toBe(rumor.id);
  });

  test("legacy `summary` payload maps to body (regression)", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    // Pre-cutover wire shape: only `summary`, no `body`.
    const legacy = cardPayload({ body: undefined, summary: "legacy text" });
    delete legacy["body"];
    const rumor = cardRumor({ dTag: "legacy-001" });
    await projectToMemory(rumor, legacy, client);

    const attrs = fake.attrs(`studio:card:studio-rt:${rumor.pubkey}:legacy-001`);
    expect(attrs).not.toBeNull();
    expect(attrs!["body"]).toBe("legacy text");
    expect(attrs!["summary"]).toBe("legacy text");
  });

  test("auto-creates studio_track stub and relates --in_track-->", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    const rumor = cardRumor({ dTag: "c1" });
    await projectToMemory(rumor, cardPayload({ track: "decisions" }), client);

    const track = fake.attrs("studio:track:studio-rt:decisions");
    expect(track).not.toBeNull();
    expect(track!["auto_created"]).toBe(true);

    // Verify the relation card --in_track--> track exists.
    const rels = fake.rels({ relation: "in_track" });
    expect(rels.length).toBe(1);
  });

  test("relates --in_room--> when room exists", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    // Seed the room first.
    const rRumor = roomRumor({});
    await projectToMemory(rRumor, roomPayload(), client);

    const cRumor = cardRumor({ dTag: "c2" });
    await projectToMemory(cRumor, cardPayload(), client);

    const inRoom = fake.rels({ relation: "in_room" });
    // Card → room. (Track was auto-created without a room; stub→room may
    // also exist depending on order. Just assert at least one in_room.)
    expect(inRoom.length).toBeGreaterThan(0);
  });

  test("LWW: later created_at replaces; earlier is dropped", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    // First projection at t=1000.
    const r1 = cardRumor({
      pubkey: "5".repeat(64),
      dTag: "c-lww",
      createdAt: 1000,
      eventId: "1".repeat(64),
    });
    await projectToMemory(r1, cardPayload({ title: "first" }), client);

    // Same (pubkey, kind, d) at t=2000 — must replace.
    const r2 = cardRumor({
      pubkey: r1.pubkey,
      dTag: "c-lww",
      createdAt: 2000,
      eventId: "2".repeat(64),
    });
    await projectToMemory(r2, cardPayload({ title: "second" }), client);

    const after2 = fake.attrs(`studio:card:studio-rt:${r1.pubkey}:c-lww`);
    expect(after2!["title"]).toBe("second");
    expect(after2!["created_at_seconds"]).toBe(2000);
    expect(after2!["event_id"]).toBe(r2.id);

    // Replay r1 (earlier created_at) — must be dropped (still title="second").
    const r1Replay = cardRumor({
      pubkey: r1.pubkey,
      dTag: "c-lww",
      createdAt: 500,
      eventId: "3".repeat(64),
    });
    await projectToMemory(r1Replay, cardPayload({ title: "earlier" }), client);

    const after3 = fake.attrs(`studio:card:studio-rt:${r1.pubkey}:c-lww`);
    expect(after3!["title"]).toBe("second");
    expect(after3!["created_at_seconds"]).toBe(2000);
  });

  test("_profile card upserts the per-room studio_member with nickname", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    const authorPub = "a".repeat(64);
    const rumor = cardRumor({
      pubkey: authorPub,
      dTag: `profile:${authorPub}`,
      eventId: "f".repeat(64),
    });
    const payload = cardPayload({
      kind: "_profile",
      title: "  Evan  ",
      body: "(hidden — nickname carrier)",
    });
    await projectToMemory(rumor, payload, client);

    // The card itself is still projected — wire still round-trips.
    const cardAttrs = fake.attrs(`studio:card:studio-rt:${authorPub}:profile:${authorPub}`);
    expect(cardAttrs).not.toBeNull();
    expect(cardAttrs!["card_kind"]).toBe("_profile");

    // Per-room member entity carries the trimmed nickname.
    const memberAttrs = fake.attrs(`studio:member:studio-rt:${authorPub}`);
    expect(memberAttrs).not.toBeNull();
    expect(memberAttrs!["nickname"]).toBe("Evan");
    expect(memberAttrs!["pubkey_hex"]).toBe(authorPub);
    expect(memberAttrs!["room_slug"]).toBe("studio-rt");
  });

  test("_profile card with image block populates studio_member.avatar_image_block", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    const authorPub = "b".repeat(64);
    const rumor = cardRumor({
      pubkey: authorPub,
      dTag: `profile:${authorPub}`,
      eventId: "a".repeat(64),
    });
    const imageBlock = {
      type: "image",
      sha256: "c".repeat(64),
      mirrors: ["https://example.test/c.bin"],
      decrypt_hint: { kind: "nip44-v2", epoch_n: 0 },
      mime_type: "image/jpeg",
      blake3: "",
    };
    const payload = cardPayload({
      kind: "_profile",
      title: "Sona",
      body: "(hidden)",
      blocks: [imageBlock],
    });
    await projectToMemory(rumor, payload, client);

    const memberAttrs = fake.attrs(`studio:member:studio-rt:${authorPub}`);
    expect(memberAttrs).not.toBeNull();
    expect(memberAttrs!["nickname"]).toBe("Sona");
    const stored = memberAttrs!["avatar_image_block"] as Record<string, unknown>;
    expect(stored).not.toBeNull();
    expect(stored["sha256"]).toBe(imageBlock.sha256);
    expect(stored["mime_type"]).toBe("image/jpeg");
    expect((stored["decrypt_hint"] as { epoch_n: number }).epoch_n).toBe(0);

    // Republish without blocks clears the avatar.
    const rumor2 = cardRumor({
      pubkey: authorPub,
      dTag: `profile:${authorPub}`,
      createdAt: rumor.created_at + 10,
      eventId: "d".repeat(64),
    });
    await projectToMemory(
      rumor2,
      cardPayload({ kind: "_profile", title: "Sona", body: "(hidden)" }),
      client,
    );
    const after = fake.attrs(`studio:member:studio-rt:${authorPub}`);
    expect(after!["avatar_image_block"]).toBeNull();
  });

  test("Track event clears the auto_created flag from a stub", async () => {
    const fake = new FakeMemoryClient();
    const client = fake.asMemoryClient();

    // Card creates a stub track first.
    await projectToMemory(cardRumor({ dTag: "c1" }), cardPayload({ track: "ideas" }), client);
    expect(fake.attrs("studio:track:studio-rt:ideas")!["auto_created"]).toBe(true);

    // Real Track event arrives.
    await projectToMemory(
      trackRumor({}),
      trackPayload({ name: "ideas", title: "Ideas", description: "where ideas land" }),
      client,
    );
    const after = fake.attrs("studio:track:studio-rt:ideas");
    expect(after!["auto_created"]).toBe(false);
    expect(after!["title"]).toBe("Ideas");
    expect(after!["description"]).toBe("where ideas land");
  });
});
