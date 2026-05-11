// Logger — JSON-per-line file log with single-rotation at 50MB; stdout
// mirrors with `[sonata-studio]` prefix per plan §3.6.

import { existsSync, mkdirSync, renameSync, statSync, appendFileSync } from "node:fs";
import { join } from "node:path";

const MAX_LOG_BYTES = 50 * 1024 * 1024;
const PLUGIN_DATA_DIR = process.env["SONATA_PLUGIN_DATA_DIR"] ?? process.cwd();
const LOG_DIR = join(PLUGIN_DATA_DIR, "logs");
const LOG_FILE = join(LOG_DIR, "sonata-studio.log");
const ROTATED = LOG_FILE + ".1";

mkdirSync(LOG_DIR, { recursive: true });

type Level = "debug" | "info" | "warn" | "error";

function rotateIfNeeded(): void {
  try {
    if (!existsSync(LOG_FILE)) return;
    const size = statSync(LOG_FILE).size;
    if (size < MAX_LOG_BYTES) return;
    renameSync(LOG_FILE, ROTATED);
  } catch {
    // best-effort: don't crash logging on rotation failure
  }
}

function write(level: Level, msg: string, fields?: Record<string, unknown>): void {
  const ts = new Date().toISOString();
  const entry: Record<string, unknown> = { ts, level, msg };
  if (fields) for (const [k, v] of Object.entries(fields)) entry[k] = v;
  const line = JSON.stringify(entry) + "\n";

  rotateIfNeeded();
  try {
    appendFileSync(LOG_FILE, line);
  } catch {
    // swallow file errors — stdout still receives the line below
  }

  const prefix = `[sonata-studio ${ts}]`;
  const summary = fields ? `${msg} ${JSON.stringify(fields)}` : msg;
  if (level === "error") console.error(`${prefix} ERROR: ${summary}`);
  else if (level === "warn") console.warn(`${prefix} WARN: ${summary}`);
  else if (level === "debug") console.log(`${prefix} DEBUG: ${summary}`);
  else console.log(`${prefix} ${summary}`);
}

export const log = {
  debug: (msg: string, fields?: Record<string, unknown>) => write("debug", msg, fields),
  info: (msg: string, fields?: Record<string, unknown>) => write("info", msg, fields),
  warn: (msg: string, fields?: Record<string, unknown>) => write("warn", msg, fields),
  error: (msg: string, fields?: Record<string, unknown>) => write("error", msg, fields),
};
