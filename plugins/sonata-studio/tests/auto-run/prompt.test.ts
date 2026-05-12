// Snapshot-style assertions on the §7 prompt envelope. We don't strict-equal
// the whole string (the template will evolve) — we instead pin the structural
// anchors that the worker prompt parses against: header lines, the room/card
// section delimiters, the constraints block.

import { describe, expect, test } from "bun:test";
import { buildPrompt, type CardForPrompt, type RoomForPrompt } from "../../src/auto-run/prompt";

function fixtureCard(overrides: Partial<CardForPrompt> = {}): CardForPrompt {
  return {
    event_id: "e".repeat(64),
    d_tag: "card-abcdef",
    card_kind: "task",
    track_slug: "inbox",
    title: "List your home dir",
    body: "Run `ls ~` and post the result as a comment.",
    blocks: [],
    related_to: [],
    created_by_pubkey: "a".repeat(64),
    ...overrides,
  };
}

function fixtureRoom(overrides: Partial<RoomForPrompt> = {}): RoomForPrompt {
  return {
    slug: "two-sona-smoke",
    title: "Two-Sona Smoke",
    project: "smoke",
    audience_address: "30520:abcd:two-sona-smoke",
    ...overrides,
  };
}

describe("buildPrompt", () => {
  test("includes the canonical section anchors", () => {
    const prompt = buildPrompt({
      card: fixtureCard(),
      room: fixtureRoom(),
      selfPubkey: "b".repeat(64),
    });
    expect(prompt).toContain("══ ROOM ══");
    expect(prompt).toContain("══ CARD ══");
    expect(prompt).toContain("══ HOW TO RESPOND ══");
    expect(prompt).toContain("══ CONSTRAINTS ══");
  });

  test("renders the card title, body, and event_id inline", () => {
    const card = fixtureCard({
      title: "Diagnose 503s on /api/score",
      body: "Check Sentry between 14:00 and 16:00.",
      event_id: "1234567890abcdef".repeat(4),
    });
    const prompt = buildPrompt({
      card,
      room: fixtureRoom(),
      selfPubkey: "b".repeat(64),
    });
    expect(prompt).toContain("title: Diagnose 503s on /api/score");
    expect(prompt).toContain("Check Sentry between 14:00 and 16:00.");
    expect(prompt).toContain(`event_id: ${card.event_id}`);
  });

  test("renders blocks as pretty-printed JSON when non-empty", () => {
    const prompt = buildPrompt({
      card: fixtureCard({
        blocks: [{ type: "code", language: "ts", code: "console.log('hi')" }],
      }),
      room: fixtureRoom(),
      selfPubkey: "b".repeat(64),
    });
    expect(prompt).toContain("blocks:");
    expect(prompt).toContain('"type": "code"');
    expect(prompt).toContain('"language": "ts"');
  });

  test("omits the blocks block when empty", () => {
    const prompt = buildPrompt({
      card: fixtureCard({ blocks: [] }),
      room: fixtureRoom(),
      selfPubkey: "b".repeat(64),
    });
    expect(prompt).not.toContain("blocks:");
  });

  test("omits room.project line when null", () => {
    const prompt = buildPrompt({
      card: fixtureCard(),
      room: fixtureRoom({ project: null }),
      selfPubkey: "b".repeat(64),
    });
    expect(prompt).not.toContain("project: ");
  });

  test("calls out the comment-post MCP tool with the right room+target", () => {
    const room = fixtureRoom({ slug: "ops" });
    const card = fixtureCard({ event_id: "f".repeat(64) });
    const prompt = buildPrompt({
      card,
      room,
      selfPubkey: "b".repeat(64),
    });
    expect(prompt).toContain("mcp__memory__sonata-studio_studio_comment_post");
    expect(prompt).toContain(`room: "${room.slug}"`);
    expect(prompt).toContain(`target_event_id: "${card.event_id}"`);
  });

  test("instructs the worker to not self-assign new cards", () => {
    const prompt = buildPrompt({
      card: fixtureCard(),
      room: fixtureRoom(),
      selfPubkey: "b".repeat(64),
    });
    expect(prompt).toContain("DO NOT post new cards to this room with assignees that include your");
    expect(prompt).toContain("DO NOT change the card's lifecycle status from your worker.");
  });
});
