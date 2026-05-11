// Test fakes for the projection layer.
//
// Provides an in-memory MemoryClient that records calls so assertions can
// inspect entity state, relation list, and call counts without an HTTP
// transport. Lives under tests/ so production code never imports it.

import type { MemoryClient } from "../../src/projection/types";
import type {
  EntityRow,
  EntityUpsertArgs,
  RelationCreateArgs,
} from "../../src/memory-client";

interface StoredEntity {
  id: string;
  name: string;
  type: string;
  description: string;
  attributes: Record<string, unknown>;
  createdAt: number;
  updatedAt: number;
  referenceCount: number;
}

interface StoredRelation {
  id: string;
  sourceId: string;
  sourceType: "memory" | "entity";
  targetId: string;
  targetType: "memory" | "entity";
  relation: string;
}

export class FakeMemoryClient {
  private entities = new Map<string, StoredEntity>(); // by name
  private byId = new Map<string, StoredEntity>();
  private relations: StoredRelation[] = [];
  private secrets = new Map<string, string>();
  private nextEntityId = 1;
  private nextRelationId = 1;
  upsertCalls: EntityUpsertArgs[] = [];
  patchCalls: { id: string; attributes: Record<string, unknown> }[] = [];
  relationCreateCalls: RelationCreateArgs[] = [];
  secretSetCalls: { name: string; value: string; description?: string }[] = [];

  asMemoryClient(): MemoryClient {
    return {
      entity: {
        upsert: async (args) => {
          this.upsertCalls.push(args);
          const existing = this.entities.get(args.name);
          const id = existing?.id ?? `ent-${this.nextEntityId++}`;
          const now = Date.now();
          const stored: StoredEntity = {
            id,
            name: args.name,
            type: args.type,
            description: args.description,
            attributes: args.attributes ?? {},
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            referenceCount: existing?.referenceCount ?? 0,
          };
          this.entities.set(args.name, stored);
          this.byId.set(id, stored);
          return { id };
        },
        byName: async (name) => {
          const e = this.entities.get(name);
          return e ? this.toRow(e) : null;
        },
        byNameOrNull: async (name) => {
          const e = this.entities.get(name);
          return e ? this.toRow(e) : null;
        },
        list: async (opts) => {
          const out: EntityRow[] = [];
          for (const e of this.entities.values()) {
            if (opts?.type && e.type !== opts.type) continue;
            out.push(this.toRow(e));
            if (opts?.limit !== undefined && out.length >= opts.limit) break;
          }
          return out;
        },
        patch: async (args) => {
          this.patchCalls.push(args);
          const e = this.byId.get(args.id);
          if (!e) throw new Error(`patch: id ${args.id} not found`);
          e.attributes = { ...e.attributes, ...args.attributes };
          e.updatedAt = Date.now();
          return { id: args.id };
        },
      },
      relation: {
        create: async (args) => {
          this.relationCreateCalls.push(args);
          // Idempotency: dedupe by (source, target, relation).
          const dup = this.relations.find(
            (r) =>
              r.sourceId === args.sourceId &&
              r.targetId === args.targetId &&
              r.relation === args.relation,
          );
          if (dup) return { id: dup.id };
          const id = `rel-${this.nextRelationId++}`;
          this.relations.push({ id, ...args });
          return { id };
        },
      },
      secret: {
        set: async (args) => {
          this.secretSetCalls.push(args);
          this.secrets.set(args.name, args.value);
          return { success: true, name: args.name };
        },
      },
    };
  }

  private toRow(e: StoredEntity): EntityRow {
    return {
      id: e.id,
      name: e.name,
      type: e.type,
      description: e.description,
      attributes: JSON.stringify(e.attributes),
      createdAt: e.createdAt,
      updatedAt: e.updatedAt,
      referenceCount: e.referenceCount,
    };
  }

  /** Snapshot the current attributes for an entity by name. */
  attrs(name: string): Record<string, unknown> | null {
    const e = this.entities.get(name);
    return e ? { ...e.attributes } : null;
  }

  /** All relations whose source or target matches a predicate. */
  rels(filter?: Partial<StoredRelation>): StoredRelation[] {
    const out: StoredRelation[] = [];
    for (const r of this.relations) {
      let match = true;
      for (const k of Object.keys(filter ?? {}) as (keyof StoredRelation)[]) {
        if (r[k] !== filter![k]) {
          match = false;
          break;
        }
      }
      if (match) out.push({ ...r });
    }
    return out;
  }

  allEntityNames(): string[] {
    return Array.from(this.entities.keys()).sort();
  }
}
