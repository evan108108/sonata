// Dispatcher-level smoke tests — bad rumors, kind routing.

import { describe, expect, test } from "bun:test";
import { projectToMemory } from "../../src/projection";
import { FakeMemoryClient } from "./fakes";
import { cardRumor, cardPayload } from "./builders";

describe("projectToMemory dispatcher", () => {
  test("throws on rumor missing 'a' tag", async () => {
    const fake = new FakeMemoryClient();
    const r = cardRumor({});
    r.tags = r.tags.filter((t) => t[0] !== "a");
    await expect(projectToMemory(r, cardPayload(), fake.asMemoryClient())).rejects.toThrow(
      /missing required 'a'/,
    );
  });

  test("throws on rumor with malformed 'a' tag", async () => {
    const fake = new FakeMemoryClient();
    const r = cardRumor({});
    r.tags = r.tags.map((t) => (t[0] === "a" ? ["a", "not-a-4a-address"] : t));
    await expect(projectToMemory(r, cardPayload(), fake.asMemoryClient())).rejects.toThrow(
      /not a valid 4A audience address/,
    );
  });

  test("throws on rumor missing 'd' tag", async () => {
    const fake = new FakeMemoryClient();
    const r = cardRumor({});
    r.tags = r.tags.filter((t) => t[0] !== "d");
    await expect(projectToMemory(r, cardPayload(), fake.asMemoryClient())).rejects.toThrow(
      /missing required 'd'/,
    );
  });

  test("throws on unsupported kind", async () => {
    const fake = new FakeMemoryClient();
    const r = cardRumor({});
    r.kind = 99999;
    await expect(projectToMemory(r, cardPayload(), fake.asMemoryClient())).rejects.toThrow(
      /unsupported Studio kind/,
    );
  });
});
