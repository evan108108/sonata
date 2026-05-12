// Periodic poll of Sonata's task table for our dispatched auto-run jobs.
//
// Sonata exposes /api/task/list (filter by project + status) and /api/task/get
// (by id). We chose the project filter for v0 — every auto-run task lands in
// project="studio-auto-run". Polling every 10s scans completed + failed task
// rows; for each previously-unhandled row, we transition the card and post
// the result/error as a kind-30533 comment.
//
// "Unhandled" tracking lives on the card entity itself
// (auto_run_completion_at_ms is set after we've reacted). This survives
// plugin restarts without needing a separate persistence layer.

import { entity } from "../memory-client";
import { log } from "../logger";
import { markCompletion } from "./state";
import { reportTaskComplete, reportTaskFailed } from "./dispatcher";
import { getAutoRunContext } from "./context";

const SONATA_HOST = (process.env["SONATA_HOST"] ?? "http://127.0.0.1:3211").replace(/\/$/, "");
const DEFAULT_POLL_MS = 10_000;

interface TaskListEntry {
  id: string;
  status: string;
  result?: string | null;
  metadata?: string | null;
  tags?: string | null;
}

interface TaskListResponse {
  ok?: boolean;
  result?: TaskListEntry[];
}

function parseMetadata(raw: string | null | undefined): {
  card_event_id?: string;
  card_d_tag?: string;
  room_slug?: string;
} {
  if (!raw) return {};
  try {
    const v = JSON.parse(raw);
    if (!v || typeof v !== "object" || Array.isArray(v)) return {};
    const obj = v as Record<string, unknown>;
    return {
      card_event_id: typeof obj["studio_card_event_id"] === "string" ? (obj["studio_card_event_id"] as string) : undefined,
      card_d_tag: typeof obj["studio_card_d_tag"] === "string" ? (obj["studio_card_d_tag"] as string) : undefined,
      room_slug: typeof obj["studio_room_slug"] === "string" ? (obj["studio_room_slug"] as string) : undefined,
    };
  } catch {
    return {};
  }
}

function parseAttrs(raw: string | null | undefined): Record<string, unknown> {
  if (!raw) return {};
  try {
    const v = JSON.parse(raw);
    if (v && typeof v === "object" && !Array.isArray(v)) return v as Record<string, unknown>;
  } catch {
    /* ignore */
  }
  return {};
}

async function listTasksByStatus(status: "completed" | "failed"): Promise<TaskListEntry[]> {
  const qs = new URLSearchParams({
    project: "studio-auto-run",
    status,
    limit: "200",
  });
  const res = await fetch(`${SONATA_HOST}/api/task/list?${qs.toString()}`).catch((err) => {
    log.warn("[auto-run] task/list fetch failed", { err: String(err) });
    return null;
  });
  if (!res || !res.ok) return [];
  try {
    const body = (await res.json()) as TaskListResponse;
    return Array.isArray(body.result) ? body.result : [];
  } catch {
    return [];
  }
}

async function findCardByEventId(
  eventId: string,
): Promise<{ id: string; attributes: Record<string, unknown> } | null> {
  // We can't index lookup by event_id, so we list studio_card and scan.
  // Auto-run dispatch volume is bounded by the per-room rate limit (10/h),
  // so the list size stays manageable at v0. Replace with a server-side
  // attribute index when volume warrants.
  const rows = await entity.list({ type: "studio_card", limit: 1000 }).catch(() => []);
  const target = eventId.toLowerCase();
  for (const row of rows) {
    const attrs = parseAttrs(row.attributes);
    const stored = typeof attrs["event_id"] === "string" ? (attrs["event_id"] as string).toLowerCase() : "";
    if (stored === target) {
      return { id: row.id, attributes: attrs };
    }
  }
  return null;
}

async function handleCompletedTask(task: TaskListEntry): Promise<void> {
  const meta = parseMetadata(task.metadata ?? null);
  if (!meta.card_event_id || !meta.card_d_tag || !meta.room_slug) return;
  const card = await findCardByEventId(meta.card_event_id);
  if (!card) return;
  // Already handled? Skip.
  if (typeof card.attributes["auto_run_completion_at_ms"] === "number") return;
  const resultBody = typeof task.result === "string" ? task.result : "";
  if (task.status === "completed") {
    await reportTaskComplete(meta.room_slug, meta.card_d_tag, meta.card_event_id, resultBody, task.id);
  } else {
    await reportTaskFailed(meta.room_slug, meta.card_d_tag, meta.card_event_id, resultBody, task.id);
  }
  await markCompletion(card.id, card.attributes, task.status === "completed" ? "completed" : "failed");
}

async function pollOnce(): Promise<void> {
  // Guard: don't run if the plugin context isn't initialized (boot race).
  if (!getAutoRunContext()) return;
  const [completed, failed] = await Promise.all([
    listTasksByStatus("completed"),
    listTasksByStatus("failed"),
  ]);
  for (const t of [...completed, ...failed]) {
    try {
      await handleCompletedTask(t);
    } catch (err) {
      log.warn("[auto-run] watcher.handleCompletedTask error", {
        task_id: t.id,
        err: err instanceof Error ? err.message : String(err),
      });
    }
  }
}

export class AutoRunWatcher {
  private timer: ReturnType<typeof setTimeout> | null = null;
  private aborted = false;
  private readonly pollMs: number;

  constructor(pollMs: number = DEFAULT_POLL_MS) {
    this.pollMs = pollMs;
  }

  start(): void {
    if (this.timer || this.aborted) return;
    const loop = async (): Promise<void> => {
      try {
        await pollOnce();
      } catch (err) {
        log.warn("[auto-run] watcher.pollOnce threw", {
          err: err instanceof Error ? err.message : String(err),
        });
      }
      if (this.aborted) return;
      this.timer = setTimeout(loop, this.pollMs);
    };
    this.timer = setTimeout(loop, this.pollMs);
    log.info("[auto-run] watcher started", { poll_ms: this.pollMs });
  }

  stop(): void {
    this.aborted = true;
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  }
}
