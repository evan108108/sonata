import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Cursor } from "../src/cursor";

const dirs: string[] = [];

function tempDir(): string {
  const d = mkdtempSync(join(tmpdir(), "4a-webhook-relay-cursor-"));
  dirs.push(d);
  return d;
}

afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});

describe("Cursor", () => {
  test("starts at 0 with no file", () => {
    const c = new Cursor(tempDir());
    expect(c.ms).toBe(0);
    expect(c.sinceSeconds).toBe(0);
  });

  test("advance persists and reloads", () => {
    const dir = tempDir();
    const c = new Cursor(dir);
    c.advance(1_753_000_000_123);
    const reloaded = new Cursor(dir);
    expect(reloaded.ms).toBe(1_753_000_000_123);
    expect(reloaded.sinceSeconds).toBe(1_753_000_000);
  });

  test("advance is monotonic", () => {
    const c = new Cursor(tempDir());
    c.advance(2_000);
    c.advance(1_000);
    expect(c.ms).toBe(2_000);
  });

  test("malformed cursor file falls back to 0", () => {
    const dir = tempDir();
    writeFileSync(join(dir, "cursor.json"), "not json");
    const c = new Cursor(dir);
    expect(c.ms).toBe(0);
  });
});
