// Test fakes shared by the SSE manager + client tests.

import type {
  SSEEntityRow,
  SSEMemoryClient,
} from "../../src/sse/client";

interface StoredEntity {
  id: string;
  name: string;
  type: string;
  description: string;
  attributes: Record<string, unknown>;
  referenceCount: number;
  createdAt: number;
  updatedAt: number;
}

export class FakeSSEMemory {
  private entities = new Map<string, StoredEntity>();
  private secrets = new Map<string, string>();
  private nextId = 1;
  patchCalls: { id: string; attributes: Record<string, unknown> }[] = [];
  secretSetCalls: { name: string; value: string }[] = [];

  upsertRoom(slug: string, attrs: Record<string, unknown>): string {
    const name = `studio:room:${slug}`;
    const existing = this.entities.get(name);
    const id = existing?.id ?? `ent-${this.nextId++}`;
    const now = Date.now();
    this.entities.set(name, {
      id,
      name,
      type: "studio_room",
      description: "test room",
      attributes: { ...(existing?.attributes ?? {}), ...attrs },
      referenceCount: 0,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    });
    return id;
  }

  setSecret(name: string, value: string): void {
    this.secrets.set(name, value);
  }

  getSecret(name: string): string | undefined {
    return this.secrets.get(name);
  }

  attrs(slug: string): Record<string, unknown> | null {
    const e = this.entities.get(`studio:room:${slug}`);
    return e ? { ...e.attributes } : null;
  }

  asClient(): SSEMemoryClient {
    return {
      entity: {
        byName: async (name) => {
          const e = this.entities.get(name);
          return e ? this.toRow(e) : null;
        },
        byNameOrNull: async (name) => {
          const e = this.entities.get(name);
          return e ? this.toRow(e) : null;
        },
        list: async (opts) => {
          const out: SSEEntityRow[] = [];
          for (const e of this.entities.values()) {
            if (opts?.type && e.type !== opts.type) continue;
            out.push(this.toRow(e));
            if (opts?.limit !== undefined && out.length >= opts.limit) break;
          }
          return out;
        },
        patch: async (args) => {
          this.patchCalls.push(args);
          for (const e of this.entities.values()) {
            if (e.id === args.id) {
              e.attributes = { ...e.attributes, ...args.attributes };
              e.updatedAt = Date.now();
              break;
            }
          }
          return { id: args.id };
        },
      },
      secret: {
        get: async (name) => {
          const v = this.secrets.get(name);
          if (v === undefined) {
            const err = new Error(`secret ${name} not found`) as Error & {
              status: number;
            };
            err.status = 404;
            throw err;
          }
          return { name, value: v };
        },
        getOrNull: async (name) => {
          const v = this.secrets.get(name);
          return v === undefined ? null : { name, value: v };
        },
        set: async (args) => {
          this.secretSetCalls.push({ name: args.name, value: args.value });
          this.secrets.set(args.name, args.value);
          return { success: true, name: args.name };
        },
      },
    };
  }

  private toRow(e: StoredEntity): SSEEntityRow {
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
}

// ─── SSE response helpers ─────────────────────────────────────────────────────

export interface SSEEvent {
  event: string;
  data: unknown;
  id?: string;
}

/** Build a ReadableStream that emits the given events then closes. */
export function sseStream(events: SSEEvent[]): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  return new ReadableStream<Uint8Array>({
    start(controller): void {
      for (const e of events) {
        if (e.id !== undefined) {
          controller.enqueue(encoder.encode(`id: ${e.id}\n`));
        }
        controller.enqueue(encoder.encode(`event: ${e.event}\n`));
        controller.enqueue(
          encoder.encode(`data: ${JSON.stringify(e.data)}\n\n`),
        );
      }
      controller.close();
    },
  });
}

export function sseResponse(events: SSEEvent[]): Response {
  return new Response(sseStream(events), {
    status: 200,
    headers: { "content-type": "text/event-stream" },
  });
}
