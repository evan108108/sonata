// Persistent SSE cursor — `lastSeenReceivedAtMs` in `<data-dir>/cursor.json`.
//
// Contract (plan invariant 5): the cursor advances ONLY after Sonata's
// POST /api/webhook/deliver returns 2xx for a wrap (or the wrap is
// definitively garbage — undecryptable / not a hook). On reconnect it is
// passed as `since=<unixSeconds>` (floor of the ms value), so a wrap in the
// same second may replay; Sonata's `wrapEventId UNIQUE` + INSERT OR IGNORE
// dedup absorbs that — the path is at-least-once by design.

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { log } from "./logger";

const CURSOR_FILE = "cursor.json";

export class Cursor {
  private readonly path: string;
  private valueMs = 0;

  constructor(pluginDataDir: string) {
    this.path = join(pluginDataDir, CURSOR_FILE);
    this.load();
  }

  /** Current cursor in unix ms (0 = never delivered anything). */
  get ms(): number {
    return this.valueMs;
  }

  /** Cursor as whole unix seconds for the stream's `since` query param. */
  get sinceSeconds(): number {
    return Math.floor(this.valueMs / 1000);
  }

  /**
   * Advance to `receivedAtMs` (monotonic — earlier values are ignored) and
   * persist synchronously. Called after every successful forward, so a crash
   * never replays more than the in-flight wrap.
   */
  advance(receivedAtMs: number): void {
    if (receivedAtMs <= this.valueMs) return;
    this.valueMs = receivedAtMs;
    try {
      mkdirSync(dirname(this.path), { recursive: true });
      const tmp = this.path + ".tmp";
      writeFileSync(tmp, JSON.stringify({ lastSeenReceivedAtMs: this.valueMs }) + "\n");
      renameSync(tmp, this.path);
    } catch (err) {
      // Non-fatal: worst case the next boot replays from the older cursor
      // and Sonata's dedup absorbs the duplicates.
      log.warn("cursor persist failed", {
        path: this.path,
        err: err instanceof Error ? err.message : String(err),
      });
    }
  }

  private load(): void {
    if (!existsSync(this.path)) return;
    try {
      const parsed = JSON.parse(readFileSync(this.path, "utf8")) as {
        lastSeenReceivedAtMs?: unknown;
      };
      if (typeof parsed.lastSeenReceivedAtMs === "number" && parsed.lastSeenReceivedAtMs > 0) {
        this.valueMs = parsed.lastSeenReceivedAtMs;
      }
    } catch (err) {
      log.warn("cursor file unreadable — starting from 0", {
        path: this.path,
        err: err instanceof Error ? err.message : String(err),
      });
    }
  }
}
