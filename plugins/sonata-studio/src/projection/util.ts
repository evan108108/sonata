// Shared helpers for the projection layer.
//
// Centralizes attribute parsing, LWW comparison, audit-trail append, and the
// "studio_member first-sight" auto-create. Per-kind projectors stay terse
// and only describe what's specific to their kind.

import type {
  AuditEntry,
  MemoryClient,
  PendingRelation,
  ProjectionContext,
} from "./types";

const HEX64 = /^[0-9a-f]{64}$/i;

export function parseExistingAttributes(
  raw: string | null | undefined,
): Record<string, unknown> {
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
  } catch {
    // fall through — corrupt attributes are treated as absent.
  }
  return {};
}

export function nowMs(): number {
  return Date.now();
}

/**
 * Compare incoming rumor.created_at vs existing entity created_at.
 * @returns true iff the incoming event should overwrite the body.
 *
 * Per plan §7.3: "if incoming `rumor.created_at` ≤ stored, ignore."
 * The first projection (no existing record) always wins.
 */
export function shouldReplaceBody(
  incomingCreatedAt: number,
  existing: Record<string, unknown> | undefined,
): boolean {
  if (!existing) return true;
  const stored = existing["created_at_seconds"];
  if (typeof stored !== "number") return true;
  return incomingCreatedAt > stored;
}

export function appendAudit(
  existing: Record<string, unknown>,
  ctx: ProjectionContext,
): AuditEntry[] {
  const prior = existing["_studio_event_audit"];
  const arr: AuditEntry[] = Array.isArray(prior) ? (prior as AuditEntry[]) : [];
  // Cap audit at 64 entries — older events are kept on the relay anyway.
  const next: AuditEntry[] = [
    ...arr.slice(Math.max(0, arr.length - 63)),
    {
      event_id: ctx.rumor.id,
      created_at: ctx.rumor.created_at,
      projected_at_ms: nowMs(),
    },
  ];
  return next;
}

/**
 * Compose the per-entity tag set per §7.1 step 4.
 * `["sonata-studio", "room:<slug>", ...payload.tags]`.
 */
export function buildEntityTags(ctx: ProjectionContext): string[] {
  const tags = new Set<string>(["sonata-studio", `room:${ctx.roomSlug}`]);
  const payloadTags = ctx.payload["tags"];
  if (Array.isArray(payloadTags)) {
    for (const t of payloadTags) {
      if (typeof t === "string" && t.length > 0) tags.add(t);
    }
  }
  return Array.from(tags);
}

/**
 * Auto-create a studio_member stub for any pubkey we haven't seen.
 * Per §7.2.8: name `studio:member:${pubkey_hex}`, cross-room, nickname null.
 * Idempotent — early-return if the entity already exists.
 */
export async function ensureMember(
  client: MemoryClient,
  pubkey: string,
  firstSeenInRoom: string,
): Promise<string> {
  if (!HEX64.test(pubkey)) {
    throw new Error(`pubkey is not 32-byte hex: ${pubkey}`);
  }
  const lower = pubkey.toLowerCase();
  const name = `studio:member:${lower}`;
  const existing = await client.entity.byNameOrNull(name);
  if (existing) return existing.id;
  const res = await client.entity.upsert({
    name,
    type: "studio_member",
    description: `Studio member ${lower.slice(0, 8)}…`,
    attributes: {
      pubkey_hex: lower,
      nickname: null,
      first_seen_in_room: firstSeenInRoom,
      first_seen_at_ms: nowMs(),
      tags: ["sonata-studio", "studio-member"],
    },
  });
  return res.id;
}

/**
 * Try to extract a 64-hex event id from a Studio target.@id reference.
 * Accepts bare hex and `nostr:<hex>`. Bech32 nevent decoding is out of
 * scope for v0 — pending relations carrying nevent strings will resolve
 * once the consumer stores raw hex too. Returns null if no hex extractable.
 */
export function extractTargetEventId(targetRef: string): string | null {
  const trimmed = targetRef.trim();
  if (HEX64.test(trimmed)) return trimmed.toLowerCase();
  if (trimmed.startsWith("nostr:")) {
    const rest = trimmed.slice("nostr:".length);
    if (HEX64.test(rest)) return rest.toLowerCase();
  }
  return null;
}

export function getPendingRelations(
  attributes: Record<string, unknown>,
): PendingRelation[] {
  const raw = attributes["_pending_relations"];
  if (!Array.isArray(raw)) return [];
  const out: PendingRelation[] = [];
  for (const e of raw) {
    if (typeof e !== "object" || e === null) continue;
    const rec = e as Record<string, unknown>;
    const rel = rec["relation"];
    const tid = rec["target_event_id"];
    if (typeof rel === "string" && typeof tid === "string") {
      out.push({ relation: rel, target_event_id: tid });
    }
  }
  return out;
}

/**
 * Scan all comment + answer entities; for any that has a pending relation
 * matching `targetEventId`, create the resolved relation and remove the
 * entry from `_pending_relations`. Idempotent — duplicate relation creates
 * are server-side no-ops per memory.ts contract.
 *
 * Called after upserting a Card, Question, or Answer (anything that can be
 * the target of a Comment/Answer).
 */
export async function resolvePendingRelations(
  client: MemoryClient,
  targetEventId: string,
  targetEntityId: string,
): Promise<void> {
  const candidates = await collectCandidatesWithPending(client);
  for (const ent of candidates) {
    const attrs = parseExistingAttributes(ent.attributes);
    const pending = getPendingRelations(attrs);
    if (pending.length === 0) continue;
    const remaining: PendingRelation[] = [];
    let resolved = false;
    for (const p of pending) {
      if (p.target_event_id.toLowerCase() === targetEventId.toLowerCase()) {
        await client.relation.create({
          sourceId: ent.id,
          sourceType: "entity",
          targetId: targetEntityId,
          targetType: "entity",
          relation: p.relation,
        });
        resolved = true;
      } else {
        remaining.push(p);
      }
    }
    if (resolved) {
      await client.entity.patch({
        id: ent.id,
        attributes: { ...attrs, _pending_relations: remaining },
      });
    }
  }
}

async function collectCandidatesWithPending(
  client: MemoryClient,
): Promise<Array<{ id: string; attributes?: string | null }>> {
  const out: Array<{ id: string; attributes?: string | null }> = [];
  for (const type of ["studio_comment", "studio_answer"]) {
    const list = await client.entity.list({ type });
    for (const e of list) {
      out.push({ id: e.id, attributes: e.attributes });
    }
  }
  return out;
}

export interface UpsertEntityOptions {
  name: string;
  type: string;
  description: string;
  attributes: Record<string, unknown>;
  /** Local-only fields preserved from the existing entity (additive merge). */
  preserveKeys?: string[];
}

/**
 * Read existing entity (if any), merge `preserveKeys` from existing into the
 * new attributes, and upsert. This makes upsert behavior agnostic to whether
 * the server's POST /api/entity is replace-style or merge-style: we always
 * send the full desired state of attributes.
 *
 * Returns `{ id, existing }` so callers can branch on first-sight vs update.
 */
export async function upsertWithMerge(
  client: MemoryClient,
  opts: UpsertEntityOptions,
): Promise<{ id: string; existing: Record<string, unknown> | undefined }> {
  const found = await client.entity.byNameOrNull(opts.name);
  let merged: Record<string, unknown> = { ...opts.attributes };
  let existingAttrs: Record<string, unknown> | undefined;
  if (found) {
    existingAttrs = parseExistingAttributes(found.attributes);
    if (opts.preserveKeys && opts.preserveKeys.length > 0) {
      for (const k of opts.preserveKeys) {
        if (k in existingAttrs) merged[k] = existingAttrs[k];
      }
    }
  }
  const res = await client.entity.upsert({
    name: opts.name,
    type: opts.type,
    description: opts.description,
    attributes: merged,
  });
  return { id: res.id, existing: existingAttrs };
}
