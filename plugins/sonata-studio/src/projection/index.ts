// Projection dispatcher (T7, plan §7).
//
// Takes a Sonata Studio rumor (kinds 30530-30536) plus its decrypted JSON-LD
// payload, derives a stable entity name, and writes the result to memory
// via mem_entity_upsert + mem_relation_create. All operations are
// idempotent — replaying the same event is a no-op; replaying with a
// later created_at LWW-replaces the body.
//
// This module is the only entry point for projecting events. T6 (SSE
// manager) calls `projectToMemory(rumor, payload)` for each gift-wrap
// it unwraps. The function is independent of T6 — it's just a function
// that accepts a rumor + payload + (optional) client.

import * as memory from "../memory-client";
import type {
  MemoryClient,
  ProjectionContext,
  StudioRumor,
} from "./types";
import { projectCard } from "./card";
import { projectComment } from "./comment";
import { projectDispatchIntent } from "./dispatch";
import { projectAnswer, projectQuestion } from "./qa";
import { projectRoom } from "./room";
import { projectTrack } from "./track";

const KIND_CARD = 30530;
const KIND_TRACK = 30531;
const KIND_DISPATCH = 30532;
const KIND_COMMENT = 30533;
const KIND_QUESTION = 30534;
const KIND_ANSWER = 30535;
const KIND_ROOM = 30536;

const ADDR_RE = /^30520:([0-9a-f]{64}):([A-Za-z0-9-]+)$/i;

function defaultClient(): MemoryClient {
  return {
    entity: memory.entity,
    relation: memory.relation,
    secret: memory.secret,
  };
}

function findTag(tags: string[][], name: string): string | undefined {
  for (const t of tags) if (t[0] === name) return t[1];
  return undefined;
}

/**
 * Project a Studio rumor + its decrypted payload into memory.
 *
 * Throws on malformed rumors (missing `a` / `d` tags, unknown kind). The
 * payload is assumed already validated by `validators.payloadValidatorFor(kind)`
 * — callers must check that before invoking.
 */
export async function projectToMemory(
  rumor: StudioRumor,
  payload: Record<string, unknown>,
  client: MemoryClient = defaultClient(),
): Promise<void> {
  const aTag = findTag(rumor.tags, "a");
  if (!aTag) {
    throw new Error("rumor missing required 'a' tag (audience address)");
  }
  const m = ADDR_RE.exec(aTag);
  if (!m) {
    throw new Error(`'a' tag ${aTag} is not a valid 4A audience address`);
  }
  const roomSlug = m[2]!;

  const dTag = findTag(rumor.tags, "d");
  if (!dTag) {
    throw new Error("rumor missing required 'd' tag");
  }

  const ctx: ProjectionContext = {
    rumor,
    payload,
    client,
    roomSlug,
    dTag,
    createdByPubkey: rumor.pubkey.toLowerCase(),
  };

  switch (rumor.kind) {
    case KIND_CARD:
      return projectCard(ctx);
    case KIND_TRACK:
      return projectTrack(ctx);
    case KIND_DISPATCH:
      return projectDispatchIntent(ctx);
    case KIND_COMMENT:
      return projectComment(ctx);
    case KIND_QUESTION:
      return projectQuestion(ctx);
    case KIND_ANSWER:
      return projectAnswer(ctx);
    case KIND_ROOM:
      return projectRoom(ctx);
    default:
      throw new Error(`unsupported Studio kind ${rumor.kind}`);
  }
}

export type { MemoryClient, StudioRumor } from "./types";
