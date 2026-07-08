// Eligibility + idempotency + rate-limit gating for auto-run.
//
// Called from `projectCard()` immediately after the entity upsert lands.
// Decides whether the card should fire a worker, and either dispatches it
// (via dispatcher.ts) or surfaces a pending-consent / skipped-comment side
// effect.
//
// Decision tree (§6.4 + §15):
//   - master switch off + no room override "on"           → return early silently
//   - card not assigned to self                            → return early silently
//   - card not in "open" status                            → return early silently
//   - sentinel auto_run_dispatched_event_id is set         → return early (idempotent)
//   - assigner == self                                     → skip + "recursion" comment
//   - room override == "off"                               → skip + "room disabled" comment
//   - founder not allow-listed + no decision               → write pending_consent
//   - founder decision == "never"                          → skip (no comment — already declined)
//   - daily quota exhausted                                → skip + "daily cap" comment
//   - per-room bucket empty                                → skip + "rate limit" comment
//   - otherwise                                            → dispatch

import { entity } from "../memory-client";
import { log } from "../logger";
import { dispatchCard, postSkippedComment } from "./dispatcher";
import { buildPrompt, type CardForPrompt, type RoomForPrompt } from "./prompt";
import { resolveTrust } from "./trusted-rooms";
import {
  consentDecision,
  consumeOnceDecision,
  loadProfile,
  loadRoomOverride,
  markDispatched,
  saveProfile,
  tryConsumeRoomToken,
  tryReserveDailyQuota,
  writePendingConsent,
} from "./state";
import { getSelfPubkey } from "./context";

export type EligibilityOutcome =
  | "dispatched"
  | "auto_run_off"
  | "not_assigned_to_self"
  | "not_open"
  | "already_dispatched"
  | "recursion_blocked"
  | "room_disabled"
  | "needs_consent"
  | "founder_blocked"
  | "daily_cap"
  | "rate_limited"
  | "missing_context";

export interface EligibilityResult {
  outcome: EligibilityOutcome;
  task_id?: string;
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

/**
 * Compute room context for the prompt envelope. Returns a minimal record
 * even if the room entity is missing (so the prompt still has a slug).
 */
async function loadRoomForPrompt(roomSlug: string): Promise<RoomForPrompt> {
  try {
    const row = await entity.byNameOrNull(`studio:room:${roomSlug}`);
    const attrs = parseAttrs(row?.attributes);
    const members = Array.isArray(attrs["members"])
      ? (attrs["members"] as unknown[]).filter((x): x is string => typeof x === "string")
      : [];
    return {
      slug: roomSlug,
      title: typeof attrs["title"] === "string" ? (attrs["title"] as string) : roomSlug,
      project: typeof attrs["project"] === "string" ? (attrs["project"] as string) : null,
      audience_address:
        typeof attrs["audience_address"] === "string"
          ? (attrs["audience_address"] as string)
          : typeof attrs["aud_id_pub"] === "string"
            ? (attrs["aud_id_pub"] as string)
            : null,
      members,
    };
  } catch {
    return { slug: roomSlug, title: roomSlug, project: null, audience_address: null, members: [] };
  }
}

export interface HookContext {
  cardEntityId: string;
  cardAttrs: Record<string, unknown>;
  roomSlug: string;
  /** The card's d_tag from rumor. */
  cardDTag: string;
}

/**
 * The projection-layer hook. Wrap calls in try/catch — projection must
 * not fail because dispatch did.
 */
export async function maybeDispatch(ctx: HookContext): Promise<EligibilityResult> {
  const self = getSelfPubkey();
  if (!self) return { outcome: "missing_context" };

  const status = ctx.cardAttrs["status"];
  if (status !== "open") return { outcome: "not_open" };

  const rawAssignees = ctx.cardAttrs["assignees"];
  const assignees: string[] = Array.isArray(rawAssignees)
    ? (rawAssignees as unknown[])
        .filter((v): v is string => typeof v === "string")
        .map((s) => s.toLowerCase())
    : [];
  if (assignees[0] !== self) return { outcome: "not_assigned_to_self" };

  // Idempotency sentinel — set BEFORE dispatch. If a duplicate SSE delivery
  // re-fires projectCard, this short-circuits even before we touch quota.
  if (typeof ctx.cardAttrs["auto_run_dispatched_event_id"] === "string") {
    return { outcome: "already_dispatched" };
  }

  const assignerPub = String(ctx.cardAttrs["created_by_pubkey"] ?? "").toLowerCase();
  // §8.1 #4 — recursion guard. If the auto-worker auto-assigned a card to
  // itself (and somehow bypassed the action-layer cycle-break), the projector
  // refuses to dispatch.
  if (assignerPub === self) {
    await postSkippedComment(
      ctx.roomSlug,
      String(ctx.cardAttrs["event_id"] ?? ""),
      "recursion guard: auto-worker may not run cards it assigned to itself",
    );
    return { outcome: "recursion_blocked" };
  }

  const roomOverride = await loadRoomOverride(ctx.roomSlug);
  const loaded = await loadProfile();
  const profile = loaded.profile;
  const decision = consentDecision(profile, roomOverride, assignerPub);

  switch (decision) {
    case "auto_run_off":
      return { outcome: "auto_run_off" };
    case "blocked": {
      // If the user explicitly chose "never" on this founder, stay silent —
      // posting a comment every time they retry would be noisy. Only surface
      // the "room disabled" message because that's an actionable mistake.
      if (roomOverride === "off") {
        await postSkippedComment(
          ctx.roomSlug,
          String(ctx.cardAttrs["event_id"] ?? ""),
          "auto-run is disabled for this room",
        );
        return { outcome: "room_disabled" };
      }
      return { outcome: "founder_blocked" };
    }
    case "needs_consent": {
      await writePendingConsent(
        ctx.roomSlug,
        assignerPub,
        String(ctx.cardAttrs["event_id"] ?? ""),
        String(ctx.cardAttrs["title"] ?? "(untitled)"),
      );
      return { outcome: "needs_consent" };
    }
    case "allowed":
      break;
    default: {
      // Defensive: an unexpected decision value would otherwise fall through
      // to the dispatch path. Treat unknown values as needs_consent so the
      // safety rail never opens by accident.
      log.warn("[auto-run] unexpected consent decision — treating as needs_consent", {
        room: ctx.roomSlug,
        decision: String(decision),
      });
      await writePendingConsent(
        ctx.roomSlug,
        assignerPub,
        String(ctx.cardAttrs["event_id"] ?? ""),
        String(ctx.cardAttrs["title"] ?? "(untitled)"),
      );
      return { outcome: "needs_consent" };
    }
  }

  const daily = tryReserveDailyQuota(profile);
  if (!daily.ok) {
    await saveProfile(profile, loaded.rawAttrs, loaded.entityId);
    await postSkippedComment(
      ctx.roomSlug,
      String(ctx.cardAttrs["event_id"] ?? ""),
      `daily cap reached (${profile.max_per_day}/day)`,
    );
    return { outcome: "daily_cap" };
  }

  const bucket = tryConsumeRoomToken(profile, ctx.roomSlug);
  if (!bucket.ok) {
    // Roll the daily count back — we charged it before checking the bucket.
    if (profile.today_count > 0) profile.today_count -= 1;
    await saveProfile(profile, loaded.rawAttrs, loaded.entityId);
    await postSkippedComment(
      ctx.roomSlug,
      String(ctx.cardAttrs["event_id"] ?? ""),
      "rate limit reached (10 cards/hour per room)",
    );
    return { outcome: "rate_limited" };
  }

  // Defense in depth: re-read the profile and re-check consent right before
  // we touch the dispatcher. The outer switch above bails on `needs_consent`,
  // but profile state could in principle have moved between then and now —
  // e.g., a concurrent projection saving the profile, a settings write from
  // the renderer, or a stale-attribute read on the first load. The bug
  // observed on 2026-05-12 was a second card slipping through despite an
  // empty allow-list; even though static analysis couldn't pin the upstream
  // path, this re-check makes the safety rail TOCTOU-proof: the dispatch
  // call is gated by a fresh read.
  const freshLoaded = await loadProfile();
  const freshOverride = await loadRoomOverride(ctx.roomSlug);
  const freshDecision = consentDecision(freshLoaded.profile, freshOverride, assignerPub);
  if (freshDecision !== "allowed") {
    // Roll the daily count back — we charged it under the first (now-stale)
    // decision. Leave the bucket consumption; it self-refills.
    if (profile.today_count > 0) profile.today_count -= 1;
    await saveProfile(profile, loaded.rawAttrs, loaded.entityId);
    log.warn("[auto-run] consent re-check changed verdict — aborting dispatch", {
      room: ctx.roomSlug,
      first_decision: "allowed",
      fresh_decision: freshDecision,
      assigner: assignerPub.slice(0, 16),
    });
    if (freshDecision === "needs_consent") {
      await writePendingConsent(
        ctx.roomSlug,
        assignerPub,
        String(ctx.cardAttrs["event_id"] ?? ""),
        String(ctx.cardAttrs["title"] ?? "(untitled)"),
      );
      return { outcome: "needs_consent" };
    }
    if (freshDecision === "blocked") {
      return freshOverride === "off"
        ? { outcome: "room_disabled" }
        : { outcome: "founder_blocked" };
    }
    return { outcome: "auto_run_off" };
  }

  // Consume the "once" decision after we've decided to dispatch — the next
  // card from this founder will re-prompt unless they pick "always".
  consumeOnceDecision(profile, assignerPub);
  await saveProfile(profile, loaded.rawAttrs, loaded.entityId);

  const room = await loadRoomForPrompt(ctx.roomSlug);
  const cardForPrompt: CardForPrompt = {
    event_id: String(ctx.cardAttrs["event_id"] ?? ""),
    d_tag: ctx.cardDTag,
    card_kind: typeof ctx.cardAttrs["card_kind"] === "string"
      ? (ctx.cardAttrs["card_kind"] as string)
      : null,
    track_slug: String(ctx.cardAttrs["track_slug"] ?? ""),
    title: String(ctx.cardAttrs["title"] ?? ""),
    body: String(ctx.cardAttrs["body"] ?? ""),
    blocks: Array.isArray(ctx.cardAttrs["blocks"]) ? (ctx.cardAttrs["blocks"] as unknown[]) : [],
    related_to: Array.isArray(ctx.cardAttrs["related_to"])
      ? (ctx.cardAttrs["related_to"] as unknown[]).filter((v): v is string => typeof v === "string")
      : [],
    created_by_pubkey: assignerPub,
  };
  // Trust resolution — decides whether the worker gets the default sandbox
  // prompt or the full-tool prompt. Default is sandbox unless the room is
  // explicitly listed in `~/.sonata/plugins/sonata-studio/config/trusted-rooms.json`
  // AND the current membership matches what was acknowledged. See
  // trusted-rooms.ts.
  const trust = resolveTrust(ctx.roomSlug, room.members);
  if (trust.level === "full") {
    log.warn("[auto-run] full-trust dispatch", {
      room: ctx.roomSlug,
      card: ctx.cardDTag,
      assigner: assignerPub,
      members: room.members.length,
      reason: trust.reason,
    });
  } else if (trust.entry) {
    log.warn("[auto-run] trusted-room fell back to sandbox", {
      room: ctx.roomSlug,
      reason: trust.reason,
    });
  }
  const prompt = buildPrompt({ card: cardForPrompt, room, selfPubkey: self, trustLevel: trust.level });

  // §6.4 — set the sentinel BEFORE the actual dispatch. Even if the task
  // POST fails or the in_progress transition fails, the sentinel prevents
  // duplicate dispatch on the next SSE delivery. A manual reopen clears it
  // (see cardStatus.ts).
  const triggerEventId = cardForPrompt.event_id;
  try {
    await markDispatched(ctx.cardEntityId, ctx.cardAttrs, triggerEventId, "pending");
  } catch (err) {
    log.warn("[auto-run] sentinel write failed (proceeding anyway)", {
      room: ctx.roomSlug,
      err: err instanceof Error ? err.message : String(err),
    });
  }

  try {
    const result = await dispatchCard({
      roomSlug: ctx.roomSlug,
      cardDTag: ctx.cardDTag,
      cardEventId: triggerEventId,
      cardTitle: cardForPrompt.title,
      prompt,
      trackSlug: cardForPrompt.track_slug,
      assignerPubkey: assignerPub,
      audienceAddress: room.audience_address,
      roomProject: room.project,
    });
    // Update the sentinel with the real task id so the watcher can correlate.
    await markDispatched(ctx.cardEntityId, ctx.cardAttrs, triggerEventId, result.task_id).catch(
      (err) => {
        log.warn("[auto-run] sentinel task_id update failed", {
          err: err instanceof Error ? err.message : String(err),
        });
      },
    );
    return { outcome: "dispatched", task_id: result.task_id };
  } catch (err) {
    log.error("[auto-run] dispatch failed", {
      room: ctx.roomSlug,
      err: err instanceof Error ? err.message : String(err),
    });
    await postSkippedComment(
      ctx.roomSlug,
      triggerEventId,
      `dispatch failed: ${err instanceof Error ? err.message : String(err)}`,
    );
    return { outcome: "missing_context" };
  }
}
