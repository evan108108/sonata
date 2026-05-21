// Synthetic `studio_room_system_event` projector.
//
// Derives a feed-style log of membership / status transitions from observed
// kind:30520 republishes and kind:30522 status=left claims. The events are
// local-only — every member's renderer independently derives the same set
// from the same observable wire events, so no federation is needed.
//
// Dedup is keyed on `source_event_id`: replaying the same kind-30520 (or
// the same leave claim) on reconnect is a no-op.
//
// Per sonata-studio-room-lifecycle.md §6.4.

import type { MemoryEntityClient } from "./types";

type SystemEventKind = "joined" | "left" | "removed" | "closed" | "reopened";

export interface DeclarationSnapshot {
  members: string[];          // lowercase hex
  status: "active" | "closed";
  createdAt: number;          // unix seconds
  eventId: string;
  audIdPub: string;
  slug: string;
}

/**
 * Diff a new kind:30520 declaration against the previously-projected one
 * and emit synthetic studio_room_system_event entities for each transition.
 *
 * Caller is expected to maintain the "previous snapshot" externally
 * (typically the SSE client). The first time a member-event arrives there's
 * no previous snapshot — we emit nothing rather than re-listing the entire
 * roster as joined, since renderer expects "joined" to mean "joined since
 * we last saw the room."
 */
export async function projectDeclarationDiff(args: {
  prev: DeclarationSnapshot | null;
  next: DeclarationSnapshot;
  roomSlug: string;
  founderPubkey: string;
  entity: MemoryEntityClient;
}): Promise<void> {
  const { prev, next, roomSlug, founderPubkey, entity } = args;
  if (!prev) return;

  const prevSet = new Set(prev.members.map((m) => m.toLowerCase()));
  const nextSet = new Set(next.members.map((m) => m.toLowerCase()));

  const added: string[] = [];
  for (const m of nextSet) if (!prevSet.has(m)) added.push(m);
  const removed: string[] = [];
  for (const m of prevSet) if (!nextSet.has(m)) removed.push(m);

  for (const pub of added) {
    await upsertSystemEvent({
      entity,
      roomSlug,
      kind: "joined",
      subject: pub,
      actor: founderPubkey,
      atSeconds: next.createdAt,
      sourceEventId: next.eventId,
      suffix: `joined:${pub}`,
    });
  }
  for (const pub of removed) {
    await upsertSystemEvent({
      entity,
      roomSlug,
      kind: "removed",
      subject: pub,
      actor: founderPubkey,
      atSeconds: next.createdAt,
      sourceEventId: next.eventId,
      suffix: `removed:${pub}`,
    });
  }

  if (prev.status !== next.status) {
    const kind: SystemEventKind = next.status === "closed" ? "closed" : "reopened";
    await upsertSystemEvent({
      entity,
      roomSlug,
      kind,
      actor: founderPubkey,
      atSeconds: next.createdAt,
      sourceEventId: next.eventId,
      suffix: `status:${kind}`,
    });
  }
}

/**
 * Emit a `left` system event for a kind:30522 status=left claim.
 */
export async function projectLeaveClaim(args: {
  claimEventId: string;
  claimPubkey: string;
  createdAt: number;
  roomSlug: string;
  entity: MemoryEntityClient;
}): Promise<void> {
  const { claimEventId, claimPubkey, createdAt, roomSlug, entity } = args;
  await upsertSystemEvent({
    entity,
    roomSlug,
    kind: "left",
    subject: claimPubkey,
    atSeconds: createdAt,
    sourceEventId: claimEventId,
    suffix: `left:${claimPubkey}`,
  });
}

async function upsertSystemEvent(args: {
  entity: MemoryEntityClient;
  roomSlug: string;
  kind: SystemEventKind;
  subject?: string;
  actor?: string;
  atSeconds: number;
  sourceEventId: string;
  /** Stable id-suffix so replays land at the same entity row. */
  suffix: string;
}): Promise<void> {
  const {
    entity,
    roomSlug,
    kind,
    subject,
    actor,
    atSeconds,
    sourceEventId,
    suffix,
  } = args;
  const name = `studio:room:${roomSlug}:sysevent:${suffix}`;
  // Dedup on source_event_id — if an entity already exists for this exact
  // event we're replaying and there's nothing to update.
  const existing = await entity.byNameOrNull(name);
  if (existing) {
    try {
      const attrsRaw = (existing as { attributes?: string | null }).attributes;
      if (typeof attrsRaw === "string") {
        const parsed = JSON.parse(attrsRaw) as Record<string, unknown>;
        if (parsed.source_event_id === sourceEventId) return;
      }
    } catch {
      // fall through to upsert
    }
  }
  const attrs: Record<string, unknown> = {
    room_slug: roomSlug,
    kind,
    at: atSeconds,
    source_event_id: sourceEventId,
    tags: ["sonata-studio", `room:${roomSlug}`, "system-event"],
  };
  if (subject) attrs.subject = subject.toLowerCase();
  if (actor) attrs.actor = actor.toLowerCase();
  try {
    await entity.upsert({
      name,
      type: "studio_room_system_event",
      description: `Studio room ${roomSlug} system event: ${kind}`,
      attributes: attrs,
    });
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error(
      `[room-system-events] upsert "${name}" failed: ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
  }
}
