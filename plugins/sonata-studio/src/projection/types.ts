// Shared types for the projection layer (T7, plan §7).
//
// Projectors take a Studio rumor + decrypted payload and write the result
// into Sonata memory as entities + relations. The MemoryClient interface
// here is a structural subset of memory-client.ts so tests can pass an
// in-memory fake without touching the HTTP transport.

import type {
  EntityRow,
  EntityUpsertArgs,
  RelationCreateArgs,
  StoreResponse,
} from "../memory-client";

export interface MemoryEntityClient {
  upsert(args: EntityUpsertArgs): Promise<StoreResponse>;
  byName(name: string): Promise<EntityRow | null>;
  byNameOrNull(name: string): Promise<EntityRow | null>;
  list(opts?: { type?: string; limit?: number }): Promise<EntityRow[]>;
  patch(args: { id: string; attributes: Record<string, unknown> }): Promise<StoreResponse>;
}

export interface MemoryRelationClient {
  create(args: RelationCreateArgs): Promise<StoreResponse>;
}

export interface MemorySecretClient {
  set(args: { name: string; value: string; description?: string }): Promise<{ success: boolean; name: string }>;
}

export interface MemoryClient {
  entity: MemoryEntityClient;
  relation: MemoryRelationClient;
  secret: MemorySecretClient;
}

export interface StudioRumor {
  id: string;
  pubkey: string;
  kind: number;
  created_at: number;
  tags: string[][];
  content: string;
}

export interface ProjectionContext {
  rumor: StudioRumor;
  /** Decrypted JSON-LD payload — already validated by validators.ts. */
  payload: Record<string, unknown>;
  client: MemoryClient;
  /** Audience slug parsed from the rumor's `a` tag. */
  roomSlug: string;
  /** rumor `d` tag value. */
  dTag: string;
  /** Hex pubkey of the original publisher (rumor.pubkey). */
  createdByPubkey: string;
}

export interface AuditEntry {
  event_id: string;
  created_at: number;
  projected_at_ms: number;
}

export interface PendingRelation {
  /** Sonata relation verb to create when the target appears. */
  relation: string;
  /** The target rumor's event_id to match against. */
  target_event_id: string;
}
