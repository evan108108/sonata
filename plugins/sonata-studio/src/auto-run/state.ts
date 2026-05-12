// Persistent state for auto-run: settings + token-bucket + daily quota +
// founder decisions + pending-consent surfacing.
//
// Storage lives on the existing singleton entity `studio:user_profile` so
// the renderer's Settings pane and the plugin can share one source of
// truth. Last-write-wins via PATCH — the Settings UI writes its keys, the
// plugin writes its bucket counters, and both reads + merges atomically
// per request (no field collision in v0).
//
// Per-room overrides live on the existing `studio:room:<slug>` entity
// (attribute `auto_run_override` = "on" | "off" | "default").
//
// Decisions are §15 of the design doc:
//   - Daily cap: default 50, range 0-500.
//   - Per-room bucket: capacity 10, refill 1 token / 6 minutes.
//   - Founder allow-list + once/always/never per founder.
//   - Re-run on manual reopen: sentinel reset is handled by cardStatus.ts.

import { entity, MemoryClientError } from "../memory-client";
import { log } from "../logger";

const USER_PROFILE_NAME = "studio:user_profile";

export const BUCKET_CAPACITY = 10;
export const BUCKET_REFILL_MS = 6 * 60 * 1000; // 1 token / 6 minutes
export const DEFAULT_DAILY_CAP = 50;

export type FounderDecision = "once" | "always" | "never";
export type RoomOverride = "on" | "off" | "default";

export interface RoomBucket {
  tokens: number;
  refill_at_ms: number;
}

export interface AutoRunProfile {
  enabled: boolean;
  max_per_day: number;
  today_count: number;
  today_date: string; // YYYY-MM-DD (local)
  allowed_founders: string[]; // lower hex
  founder_decisions: Record<string, FounderDecision>;
  room_buckets: Record<string, RoomBucket>;
  // Echo so Settings UI persistence stays compatible.
  default_nickname?: string;
  default_avatar_local_path?: string;
}

function safeParse(raw: string | null | undefined): Record<string, unknown> {
  if (!raw) return {};
  try {
    const v = JSON.parse(raw);
    if (v && typeof v === "object" && !Array.isArray(v)) return v as Record<string, unknown>;
  } catch {
    /* ignore */
  }
  return {};
}

function todayString(now: number = Date.now()): string {
  const d = new Date(now);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${dd}`;
}

function readStringArray(v: unknown): string[] {
  if (!Array.isArray(v)) return [];
  return v.filter((x): x is string => typeof x === "string").map((s) => s.toLowerCase());
}

function readFounderDecisions(v: unknown): Record<string, FounderDecision> {
  if (!v || typeof v !== "object" || Array.isArray(v)) return {};
  const out: Record<string, FounderDecision> = {};
  for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
    if (val === "once" || val === "always" || val === "never") {
      out[k.toLowerCase()] = val;
    }
  }
  return out;
}

function readRoomBuckets(v: unknown): Record<string, RoomBucket> {
  if (!v || typeof v !== "object" || Array.isArray(v)) return {};
  const out: Record<string, RoomBucket> = {};
  for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
    if (val && typeof val === "object" && !Array.isArray(val)) {
      const obj = val as Record<string, unknown>;
      const tokens = typeof obj["tokens"] === "number" ? obj["tokens"] : BUCKET_CAPACITY;
      const refillAtMs = typeof obj["refill_at_ms"] === "number" ? obj["refill_at_ms"] : Date.now();
      out[k] = { tokens, refill_at_ms: refillAtMs };
    }
  }
  return out;
}

function profileFromAttrs(attrs: Record<string, unknown>): AutoRunProfile {
  const max = typeof attrs["auto_run_max_per_day"] === "number"
    ? attrs["auto_run_max_per_day"] as number
    : DEFAULT_DAILY_CAP;
  return {
    enabled: attrs["auto_run_enabled"] === true,
    max_per_day: Math.max(0, Math.min(500, max)),
    today_count: typeof attrs["auto_run_today_count"] === "number"
      ? (attrs["auto_run_today_count"] as number)
      : 0,
    today_date: typeof attrs["auto_run_today_date"] === "string"
      ? (attrs["auto_run_today_date"] as string)
      : todayString(),
    allowed_founders: readStringArray(attrs["auto_run_allowed_founders"]),
    founder_decisions: readFounderDecisions(attrs["auto_run_founder_decisions"]),
    room_buckets: readRoomBuckets(attrs["auto_run_room_buckets"]),
    default_nickname: typeof attrs["default_nickname"] === "string"
      ? (attrs["default_nickname"] as string)
      : undefined,
    default_avatar_local_path: typeof attrs["default_avatar_local_path"] === "string"
      ? (attrs["default_avatar_local_path"] as string)
      : undefined,
  };
}

function attrsFromProfile(p: AutoRunProfile, prior: Record<string, unknown>): Record<string, unknown> {
  // Preserve unknown keys (Settings UI may add fields we don't know about).
  return {
    ...prior,
    auto_run_enabled: p.enabled,
    auto_run_max_per_day: p.max_per_day,
    auto_run_today_count: p.today_count,
    auto_run_today_date: p.today_date,
    auto_run_allowed_founders: p.allowed_founders,
    auto_run_founder_decisions: p.founder_decisions,
    auto_run_room_buckets: p.room_buckets,
  };
}

export async function loadProfile(): Promise<{
  profile: AutoRunProfile;
  rawAttrs: Record<string, unknown>;
  entityId: string | null;
}> {
  const existing = await entity.byNameOrNull(USER_PROFILE_NAME).catch(() => null);
  const rawAttrs = safeParse(existing?.attributes);
  const profile = profileFromAttrs(rawAttrs);
  return { profile, rawAttrs, entityId: existing?.id ?? null };
}

export async function saveProfile(
  next: AutoRunProfile,
  priorAttrs: Record<string, unknown>,
  entityId: string | null,
): Promise<void> {
  const attributes = attrsFromProfile(next, priorAttrs);
  try {
    if (entityId) {
      await entity.patch({ id: entityId, attributes });
    } else {
      await entity.upsert({
        name: USER_PROFILE_NAME,
        type: "studio_user_profile",
        description: "Local default profile (machine-only, not federated directly)",
        attributes,
      });
    }
  } catch (err) {
    log.warn("[auto-run] saveProfile failed", { err: errMsg(err) });
  }
}

export interface BucketResult {
  ok: boolean;
  remaining: number;
  next_refill_ms: number;
}

/**
 * Apply token-bucket logic to a single room.
 *
 * Bucket starts full at first touch. Tokens refill at 1 per BUCKET_REFILL_MS,
 * capped at BUCKET_CAPACITY. Each consume attempt deducts 1 and returns ok=true,
 * or returns ok=false when the bucket is empty.
 *
 * Caller must persist the updated profile after calling this if `ok` is true.
 */
export function tryConsumeRoomToken(
  profile: AutoRunProfile,
  roomSlug: string,
  now: number = Date.now(),
): BucketResult {
  const bucket = profile.room_buckets[roomSlug] ?? {
    tokens: BUCKET_CAPACITY,
    refill_at_ms: now + BUCKET_REFILL_MS,
  };
  // Refill: floor((now - last) / refill_ms) tokens, capped at capacity.
  if (now >= bucket.refill_at_ms && bucket.tokens < BUCKET_CAPACITY) {
    const elapsed = now - bucket.refill_at_ms;
    const refill = 1 + Math.floor(elapsed / BUCKET_REFILL_MS);
    bucket.tokens = Math.min(BUCKET_CAPACITY, bucket.tokens + refill);
    bucket.refill_at_ms = now + BUCKET_REFILL_MS;
  }
  if (bucket.tokens <= 0) {
    profile.room_buckets[roomSlug] = bucket;
    return { ok: false, remaining: 0, next_refill_ms: bucket.refill_at_ms };
  }
  bucket.tokens -= 1;
  if (bucket.tokens < BUCKET_CAPACITY && bucket.refill_at_ms < now + BUCKET_REFILL_MS) {
    bucket.refill_at_ms = now + BUCKET_REFILL_MS;
  }
  profile.room_buckets[roomSlug] = bucket;
  return { ok: true, remaining: bucket.tokens, next_refill_ms: bucket.refill_at_ms };
}

/**
 * Daily-quota check + increment. Rolls over to a fresh count on local date
 * change. Returns ok=false when the daily cap is hit; in either case the
 * profile object is mutated in place and the caller must persist it.
 */
export function tryReserveDailyQuota(
  profile: AutoRunProfile,
  now: number = Date.now(),
): { ok: boolean; remaining: number } {
  const today = todayString(now);
  if (profile.today_date !== today) {
    profile.today_date = today;
    profile.today_count = 0;
  }
  if (profile.today_count >= profile.max_per_day) {
    return { ok: false, remaining: 0 };
  }
  profile.today_count += 1;
  return { ok: true, remaining: profile.max_per_day - profile.today_count };
}

export async function loadRoomOverride(roomSlug: string): Promise<RoomOverride> {
  try {
    const row = await entity.byNameOrNull(`studio:room:${roomSlug}`);
    if (!row) return "default";
    const attrs = safeParse(row.attributes);
    const o = attrs["auto_run_override"];
    if (o === "on" || o === "off") return o;
    return "default";
  } catch {
    return "default";
  }
}

/**
 * Whether dispatch is allowed for a given (room, founder) pair according to
 * the room override + founder allow-list + per-founder decision settings.
 *
 * Returns:
 *   "allowed"          — proceed
 *   "needs_consent"    — surface consent banner; do not dispatch
 *   "blocked"          — founder=never or room=off; do not dispatch
 *   "auto_run_off"     — master switch off; do not dispatch
 */
export function consentDecision(
  profile: AutoRunProfile,
  roomOverride: RoomOverride,
  founderPub: string,
): "allowed" | "needs_consent" | "blocked" | "auto_run_off" {
  if (roomOverride === "off") return "blocked";
  if (!profile.enabled && roomOverride !== "on") return "auto_run_off";
  const founder = founderPub.toLowerCase();
  const decision = profile.founder_decisions[founder];
  if (decision === "never") return "blocked";
  if (profile.allowed_founders.includes(founder)) return "allowed";
  if (decision === "always") return "allowed";
  if (decision === "once") return "allowed"; // consumed by caller after dispatch
  return "needs_consent";
}

/**
 * Consume a `once` decision: clear it after a successful dispatch so the
 * next card from the same founder re-prompts. No-op for `always`.
 */
export function consumeOnceDecision(
  profile: AutoRunProfile,
  founderPub: string,
): void {
  const founder = founderPub.toLowerCase();
  if (profile.founder_decisions[founder] === "once") {
    delete profile.founder_decisions[founder];
  }
}

export async function writePendingConsent(
  roomSlug: string,
  founderPub: string,
  cardEventId: string,
  cardTitle: string,
): Promise<void> {
  const founder = founderPub.toLowerCase();
  const name = `studio:pending_consent:${roomSlug}:${founder}`;
  try {
    await entity.upsert({
      name,
      type: "studio_pending_consent",
      description: `Auto-run consent prompt: ${cardTitle}`,
      attributes: {
        room_slug: roomSlug,
        founder_pubkey: founder,
        card_event_id: cardEventId,
        card_title: cardTitle,
        created_at_ms: Date.now(),
        tags: ["sonata-studio", "auto-run-consent", `room:${roomSlug}`],
      },
    });
  } catch (err) {
    log.warn("[auto-run] writePendingConsent failed", {
      room: roomSlug,
      err: errMsg(err),
    });
  }
}

export async function markDispatched(
  cardEntityId: string,
  priorCardAttrs: Record<string, unknown>,
  triggerEventId: string,
  taskId: string,
): Promise<void> {
  await entity.patch({
    id: cardEntityId,
    attributes: {
      ...priorCardAttrs,
      auto_run_dispatched_event_id: triggerEventId,
      auto_run_task_id: taskId,
      auto_run_dispatched_at_ms: Date.now(),
    },
  });
}

export async function markCompletion(
  cardEntityId: string,
  priorCardAttrs: Record<string, unknown>,
  status: "completed" | "failed",
): Promise<void> {
  try {
    await entity.patch({
      id: cardEntityId,
      attributes: {
        ...priorCardAttrs,
        auto_run_completion_status: status,
        auto_run_completion_at_ms: Date.now(),
      },
    });
  } catch (err) {
    log.warn("[auto-run] markCompletion failed", { err: errMsg(err) });
  }
}

function errMsg(err: unknown): string {
  if (err instanceof MemoryClientError) return `${err.code}: ${err.message}`;
  return err instanceof Error ? err.message : String(err);
}
