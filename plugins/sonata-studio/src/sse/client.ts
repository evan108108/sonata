// SSEClient — one connection per joined Studio room.
//
// Implements plan §6.2: open the gateway SSE stream for the room's audience,
// drive it through reconnect with `since_ts`, and route each parsed event:
//
//   hello              → reset retries, healthy connection
//   gift-wrap          → unwrap, decrypt, validate, project to memory
//   key-grant          → decrypt the per-epoch priv with our plugin key,
//                        store under epoch_keys (mem_secret), drain pending
//   declaration-updated → refresh members + current_epoch on the room entity
//   epoch-rotated      → log only; the actual key arrives via key-grant
//   error              → log warn, continue
//
// Cursor (last_seen_wrap_at_ms) persists to the studio_room entity, debounced
// at 5s (Pass C5). A 5s rolling wrap_event_id window dedupes replay overlap.
// A per-epoch pending-decrypt queue (Pass A11) buffers gift-wraps that arrive
// before their epoch key, drained when the matching key-grant lands.

import { hexToBytes, bytesToHex } from "@noble/hashes/utils.js";
import { schnorr } from "@noble/curves/secp256k1.js";
import { GatewayError, type GatewayClient, type NostrEventLike } from "../a4-client";
import { unwrap } from "../crypto/nip17";
import * as nip44 from "../crypto/nip44";
import { log } from "../logger";
import { projectToMemory } from "../projection";
import { projectDeclarationDiff, type DeclarationSnapshot } from "../projection/room-system-events";
import type { StudioRumor } from "../projection/types";
import { payloadValidatorFor, STUDIO_KINDS } from "../validators";
import { parseSSEStream } from "./parser";

const HEX64 = /^[0-9a-f]{64}$/i;
const DEFAULT_DEBOUNCE_MS = 5_000;
const DEDUP_WINDOW_MS = 5_000;
const MAX_BACKOFF_MS = 60_000;

export interface SSEEntityRow {
  id: string;
  name: string;
  type: string;
  description: string;
  attributes?: string | null;
  referenceCount: number;
  createdAt: number;
  updatedAt: number;
}

export interface SSEMemoryClient {
  entity: {
    byName(name: string): Promise<SSEEntityRow | null>;
    byNameOrNull(name: string): Promise<SSEEntityRow | null>;
    list(opts?: { type?: string; limit?: number }): Promise<SSEEntityRow[]>;
    patch(args: {
      id: string;
      attributes: Record<string, unknown>;
    }): Promise<{ id: string }>;
    upsert(args: {
      name: string;
      type: string;
      description: string;
      attributes: Record<string, unknown>;
    }): Promise<{ id: string }>;
  };
  secret: {
    get(name: string): Promise<{ name: string; value: string }>;
    getOrNull(name: string): Promise<{ name: string; value: string } | null>;
    set(args: {
      name: string;
      value: string;
      description?: string;
    }): Promise<{ success: boolean; name: string }>;
  };
}

export interface SSEClientOptions {
  /** Override for tests — defaults to projectToMemory. */
  project?: (
    rumor: StudioRumor,
    payload: Record<string, unknown>,
  ) => Promise<void>;
  /** Cursor write debounce. Tests pass 0 to flush every event. */
  cursorDebounceMs?: number;
  /** Override the backoff schedule (returns ms). Tests pass () => 0. */
  backoff?: (retries: number) => number;
  /** Disable retry loop after stream end (used by single-shot tests). */
  reconnect?: boolean;
}

interface RoomState {
  entityId: string;
  audIdPub: string;
  cursor: number;
  members: string[];
  currentEpoch: number;
  epochKeysSecretName: string;
  /**
   * Persisted room state ("active" | "pending-grant" | "left"). Tracked
   * locally so handleKeyGrant can flip pending-grant → active on the
   * first grant landing without re-reading from the entity store.
   */
  state: string;
  /**
   * Approximate join time (ms) for pending-grant rooms. Used on first
   * connect to set since_ts ≈ join_at - 60 so a key-grant published in
   * the gap between rawClaim returning and the SSE stream opening still
   * shows up in the gateway's replay window. Plan §7 Pass D3.
   */
  joinedAtMs: number | null;
}

/**
 * Replay window we ask for when first opening an SSE stream for a room
 * still in pending-grant. 60s covers the realistic gap between a claim
 * being posted and the founder's admit/rotate call landing — anything
 * longer is surfaced as a stuck-grant by Phase 5 hardening.
 */
const PENDING_GRANT_REPLAY_WINDOW_SEC = 60;

/**
 * Plan §12 Pass D race: the SSE handshake can return 403
 * `caller is not a current member of the audience` if a peer races us —
 * we open the stream after `joinRoom`'s claim succeeds but before the
 * founder admits us. The reconnect loop then needs to reach back across
 * the gap so the gateway's replay tail covers the key-grant + declaration
 * update that landed while we were in backoff. Window is in unix-ms to
 * match the gateway's `since_ts` contract (audience-stream.ts:163-170).
 *
 * Distinct from PENDING_GRANT_REPLAY_WINDOW_SEC: that window targets the
 * first-ever connect for rooms whose local state is still `pending-grant`;
 * this one fires on any 403 forbidden response, which can also occur if a
 * post-admit epoch rotation kicked us out and we haven't projected the
 * declaration update yet.
 */
const PRE_ADMIT_REPLAY_LOOKBACK_MS = 60_000;

interface PendingItem {
  rumor: StudioRumor;
  publisherPub: string;
}

const KIND_KEY_GRANT = 30521;

function defaultBackoff(retries: number): number {
  const base = Math.min(MAX_BACKOFF_MS, 500 * Math.pow(2, retries));
  // ±20% jitter — multiplier in [0.8, 1.2].
  const jitter = 0.8 + Math.random() * 0.4;
  return Math.floor(base * jitter);
}

interface AbortFlag {
  readonly aborted: boolean;
}

function sleep(ms: number, signal?: AbortFlag): Promise<void> {
  if (ms <= 0) return Promise.resolve();
  return new Promise((resolve) => {
    const t = setTimeout(resolve, ms);
    if (signal) {
      const tick = setInterval(() => {
        if (signal.aborted) {
          clearTimeout(t);
          clearInterval(tick);
          resolve();
        }
      }, Math.min(ms, 100));
      const orig = t as unknown as { unref?: () => void };
      orig.unref?.();
    }
  });
}

function parseAttrs(raw: string | null | undefined): Record<string, unknown> {
  if (!raw) return {};
  try {
    const v = JSON.parse(raw);
    return v && typeof v === "object" && !Array.isArray(v)
      ? (v as Record<string, unknown>)
      : {};
  } catch {
    return {};
  }
}

function findTag(tags: string[][], name: string): string | undefined {
  for (const t of tags) if (t[0] === name) return t[1];
  return undefined;
}

/**
 * Discriminator for "we tried to listen before the inviter admitted us."
 *
 * The gateway path that emits this is `audience-stream.ts:196`:
 *   `jsonError("forbidden", "caller is not a current member of the audience", 403)`.
 *
 * We match on `code === "forbidden"` (the stable hook) OR the literal
 * message phrase (defensive fallback if the gateway later splits the code
 * into more specific reasons). Other 403s — bad signature, expired NIP-98
 * window, malformed audience — fall through to normal reconnect without
 * the lookback override.
 */
function isPreAdmitRejection(err: unknown): boolean {
  if (!(err instanceof GatewayError)) return false;
  if (err.status !== 403) return false;
  return err.code === "forbidden" || /not a current member/i.test(err.message);
}

export class SSEClient implements AbortFlag {
  aborted = false;
  private retries = 0;
  private state: RoomState | null = null;
  private epochKeys = new Map<number, Uint8Array>();
  private pending = new Map<number, PendingItem[]>();
  /**
   * Snapshot of the last-projected kind:30520 so the room-system-events
   * projector can diff each new declaration against the previous one to
   * emit synthetic joined/removed/closed/reopened entries.
   */
  private previousDeclarationSnapshot: DeclarationSnapshot | null = null;
  /**
   * Per-event-id dedup window covering BOTH gift-wraps (kind:1059) and
   * key-grants (kind:30521). The gateway emits the same event under two
   * legitimate paths within one connection — the replay-before-hello batch
   * AND the first live-tail poll (which still sees events newer than
   * `now - OVERLAP_SECONDS`). Without this, every reconnect's replay
   * window also re-floods the handlers because key-grants don't advance
   * the gift-wrap cursor on their own.
   */
  private recentEventIds = new Map<string, number>();
  private cursorDirty = false;
  private cursorTimer: ReturnType<typeof setTimeout> | null = null;
  private abortController = new AbortController();
  /**
   * Set when the most recent connect attempt was rejected with 403
   * `caller is not a current member of the audience`. The next iteration
   * of the run loop overrides `since_ts` with a 60s lookback so the
   * gateway's replay tail catches a key-grant or declaration-update that
   * was published while we were waiting in backoff. Cleared on the first
   * successful connect.
   */
  private pendingAdmitReconnect = false;
  private readonly project: (
    rumor: StudioRumor,
    payload: Record<string, unknown>,
  ) => Promise<void>;
  private readonly cursorDebounceMs: number;
  private readonly backoff: (retries: number) => number;
  private readonly reconnect: boolean;

  constructor(
    private readonly roomSlug: string,
    private readonly pluginPriv: Uint8Array,
    private readonly gateway: GatewayClient,
    private readonly memory: SSEMemoryClient,
    opts: SSEClientOptions = {},
  ) {
    this.project = opts.project ?? projectToMemory;
    this.cursorDebounceMs = opts.cursorDebounceMs ?? DEFAULT_DEBOUNCE_MS;
    this.backoff = opts.backoff ?? defaultBackoff;
    this.reconnect = opts.reconnect ?? true;
  }

  /** Run the connect → consume → reconnect loop until aborted. */
  async run(): Promise<void> {
    await this.loadRoomState();
    if (!this.state) {
      log.warn("[sse] room not found, aborting client", {
        room: this.roomSlug,
      });
      return;
    }
    while (!this.aborted) {
      try {
        const args: {
          audience_slug: string;
          aud_id_pub: string;
          since_ts?: number;
        } = {
          audience_slug: this.roomSlug,
          aud_id_pub: this.state.audIdPub,
        };
        if (this.pendingAdmitReconnect) {
          // Plan §12 Pass D: previous connect was rejected with 403
          // `caller is not a current member`. Ask for the last 60s in
          // unix-ms so the gateway replays the grant + declaration-update
          // that landed in the gap. Overrides cursor and pending-grant
          // logic — the gap can straddle either case.
          args.since_ts = Math.max(0, Date.now() - PRE_ADMIT_REPLAY_LOOKBACK_MS);
        } else if (this.state.cursor > 0) {
          args.since_ts = this.state.cursor;
        } else if (this.state.state === "pending-grant") {
          // Plan §7 Pass D3: a pending-grant room may already have a
          // key-grant sitting in the gateway's replay window because the
          // founder's admit/rotate raced ahead of our SSE connect. Ask for
          // the past 60s — anchored at joined_at_ms when we have one,
          // otherwise wall-clock-now-60s.
          const nowSec = Math.floor(Date.now() / 1000);
          const joinedSec = this.state.joinedAtMs !== null
            ? Math.floor(this.state.joinedAtMs / 1000)
            : nowSec;
          args.since_ts = Math.max(0, Math.min(joinedSec, nowSec) - PENDING_GRANT_REPLAY_WINDOW_SEC);
        }
        const resp = await this.gateway.openStream(args, this.abortController.signal);
        // First successful connect clears the pre-admit flag so the next
        // reconnect uses normal cursor logic.
        this.pendingAdmitReconnect = false;
        if (!resp.body) {
          throw new Error("gateway response had no body");
        }
        await this.consume(resp.body);
      } catch (err) {
        if (this.aborted) {
          // Expected during shutdown — fetch was aborted via the signal,
          // surfacing as AbortError out of openStream or reader.read().
        } else if (isPreAdmitRejection(err)) {
          this.pendingAdmitReconnect = true;
          log.info("[sse] pre-admit 403, will reconnect with 60s lookback", {
            room: this.roomSlug,
          });
        } else {
          const msg = err instanceof Error ? err.message : String(err);
          log.warn("[sse] stream error, will reconnect", {
            room: this.roomSlug,
            err: msg,
          });
        }
      }
      // Persist cursor before sleeping so a crash mid-backoff doesn't lose
      // progress. flushCursor() is a no-op if nothing's dirty.
      await this.flushCursor();
      if (!this.reconnect || this.aborted) break;
      this.retries++;
      const delay = this.backoff(this.retries);
      await sleep(delay, this);
    }
    await this.flushCursor();
  }

  abort(): void {
    if (this.aborted) return;
    this.aborted = true;
    // Abort the in-flight fetch (and its response body). Cancelling the
    // body directly is not viable here: `parseSSEStream` calls
    // `body.getReader()`, which locks the stream, and `ReadableStream.cancel`
    // on a locked stream throws TypeError — that's the root cause of the
    // `close()` hang. Aborting the fetch propagates through the runtime and
    // errors `reader.read()` out of the parser loop on the next iteration.
    this.abortController.abort();
  }

  /** Force a cursor write right now (test hook + graceful shutdown). */
  async flushCursor(): Promise<void> {
    if (this.cursorTimer) {
      clearTimeout(this.cursorTimer);
      this.cursorTimer = null;
    }
    if (!this.cursorDirty || !this.state) return;
    this.cursorDirty = false;
    try {
      await this.memory.entity.patch({
        id: this.state.entityId,
        attributes: { last_seen_wrap_at_ms: this.state.cursor },
      });
    } catch (err) {
      log.warn("[sse] persistCursor failed", {
        room: this.roomSlug,
        err: err instanceof Error ? err.message : String(err),
      });
    }
  }

  // ── stream consumption ────────────────────────────────────────────────────

  private async consume(body: ReadableStream<Uint8Array>): Promise<void> {
    for await (const evt of parseSSEStream(body)) {
      if (this.aborted) return;
      try {
        await this.handleEvent(evt.event, evt.data);
      } catch (err) {
        log.warn("[sse] handler threw, continuing", {
          room: this.roomSlug,
          event: evt.event,
          err: err instanceof Error ? err.message : String(err),
        });
      }
    }
  }

  private async handleEvent(name: string, data: unknown): Promise<void> {
    switch (name) {
      case "hello":
        this.retries = 0;
        return;
      case "gift-wrap":
        return this.handleGiftWrap(data);
      case "key-grant":
        return this.handleKeyGrant(data);
      case "declaration-updated":
        return this.handleDeclarationUpdated(data);
      case "epoch-rotated":
        log.info("[sse] epoch-rotated hint", {
          room: this.roomSlug,
          data,
        });
        return;
      case "error":
        log.warn("[sse] gateway error event", { data });
        return;
      case "keepalive":
      case "message":
        return;
      default:
        log.debug("[sse] unknown event type", { event: name });
    }
  }

  // ── gift-wrap ─────────────────────────────────────────────────────────────

  private async handleGiftWrap(data: unknown): Promise<void> {
    if (!data || typeof data !== "object") return;
    const payload = data as { wrap_event?: NostrEventLike; received_at_ms?: number };
    const wrap = payload.wrap_event;
    const receivedAtMs = payload.received_at_ms;
    if (!wrap || typeof receivedAtMs !== "number") return;
    if (!this.state) return;

    if (this.isDuplicateEvent(wrap.id, receivedAtMs)) {
      log.info("[sse-trace] gift-wrap duplicate-skip", { room: this.roomSlug, wrap_id: wrap.id });
      return;
    }

    let unwrapped;
    try {
      unwrapped = unwrap(wrap as never, this.pluginPriv);
    } catch (e) {
      log.info("[sse-trace] gift-wrap unwrap-failed", {
        room: this.roomSlug,
        wrap_id: wrap.id,
        err: e instanceof Error ? e.message : String(e),
      });
      this.advanceCursor(receivedAtMs);
      return;
    }
    const rumor = unwrapped.rumor;
    log.info("[sse-trace] gift-wrap unwrapped", {
      room: this.roomSlug,
      wrap_id: wrap.id,
      rumor_id: rumor.id,
      rumor_kind: rumor.kind,
    });
    if (!(STUDIO_KINDS as readonly number[]).includes(rumor.kind)) {
      log.info("[sse-trace] gift-wrap non-studio-kind-skip", { room: this.roomSlug, rumor_kind: rumor.kind });
      this.advanceCursor(receivedAtMs);
      return;
    }
    const aTag = findTag(rumor.tags, "a");
    const expectedAddr = `30520:${this.state.audIdPub}:${this.roomSlug}`;
    if (aTag !== expectedAddr) {
      log.info("[sse-trace] gift-wrap a-tag-mismatch", {
        room: this.roomSlug,
        a_tag: aTag,
        expected: expectedAddr,
      });
      this.advanceCursor(receivedAtMs);
      return;
    }
    const epochTag = findTag(rumor.tags, "fa:epoch");
    const epoch = epochTag !== undefined ? Number(epochTag) : NaN;
    if (!Number.isFinite(epoch)) {
      log.info("[sse-trace] gift-wrap missing-epoch", { room: this.roomSlug, rumor_id: rumor.id });
      this.advanceCursor(receivedAtMs);
      return;
    }

    const epochPriv = this.epochKeys.get(epoch);
    if (!epochPriv) {
      log.info("[sse-trace] gift-wrap pending-no-epoch-key", {
        room: this.roomSlug,
        rumor_id: rumor.id,
        epoch,
        available_epochs: Array.from(this.epochKeys.keys()),
      });
      this.pushPending(epoch, rumor as StudioRumor, unwrapped.publisherPub);
      this.advanceCursor(receivedAtMs);
      return;
    }
    log.info("[sse-trace] gift-wrap decrypting-and-projecting", {
      room: this.roomSlug,
      rumor_id: rumor.id,
      epoch,
    });
    try {
      await this.decryptAndProject(rumor as StudioRumor, unwrapped.publisherPub, epochPriv);
      log.info("[sse-trace] gift-wrap projected-ok", { room: this.roomSlug, rumor_id: rumor.id });
    } catch (e) {
      log.info("[sse-trace] gift-wrap decrypt-or-project-failed", {
        room: this.roomSlug,
        rumor_id: rumor.id,
        err: e instanceof Error ? e.message : String(e),
      });
    }
    this.advanceCursor(receivedAtMs);
  }

  private isDuplicateEvent(id: string, nowMs: number): boolean {
    // GC entries older than the dedup window.
    for (const [k, t] of this.recentEventIds) {
      if (nowMs - t > DEDUP_WINDOW_MS) this.recentEventIds.delete(k);
    }
    if (this.recentEventIds.has(id)) return true;
    this.recentEventIds.set(id, nowMs);
    return false;
  }

  private pushPending(
    epoch: number,
    rumor: StudioRumor,
    publisherPub: string,
  ): void {
    let q = this.pending.get(epoch);
    if (!q) {
      q = [];
      this.pending.set(epoch, q);
    }
    q.push({ rumor, publisherPub });
    log.debug("[sse] gift-wrap queued (no epoch key yet)", {
      room: this.roomSlug,
      epoch,
      rumor_id: rumor.id,
      depth: q.length,
    });
  }

  private async decryptAndProject(
    rumor: StudioRumor,
    publisherPub: string,
    epochPriv: Uint8Array,
  ): Promise<void> {
    let plaintext: string;
    try {
      plaintext = nip44.decryptString(rumor.content, epochPriv, publisherPub);
    } catch (e) {
      log.warn("[sse] decrypt failed", {
        room: this.roomSlug,
        rumor_id: rumor.id,
      });
      return;
    }
    let payload: unknown;
    try {
      payload = JSON.parse(plaintext);
    } catch {
      log.warn("[sse] payload not JSON", {
        room: this.roomSlug,
        rumor_id: rumor.id,
      });
      return;
    }
    const validator = payloadValidatorFor(rumor.kind);
    if (!validator) return;
    const v = validator(payload);
    if (!v.ok) {
      log.warn("[sse] payload validator failed", {
        room: this.roomSlug,
        rumor_id: rumor.id,
        error: v.error,
      });
      return;
    }
    await this.project(rumor, payload as Record<string, unknown>);
  }

  // ── key-grant ─────────────────────────────────────────────────────────────

  private async handleKeyGrant(data: unknown): Promise<void> {
    if (!data || typeof data !== "object") return;
    const payload = data as { grant_event?: NostrEventLike; received_at_ms?: number };
    const grant = payload.grant_event;
    if (!grant) return;
    if (!this.state) return;
    if (grant.kind !== KIND_KEY_GRANT) return;

    // `received_at_ms` is `grant.created_at * 1000` from the gateway
    // (audience-stream.ts:381). Falling back to `created_at` for older
    // gateway builds or test fixtures that omit it.
    const receivedAtMs =
      typeof payload.received_at_ms === "number"
        ? payload.received_at_ms
        : grant.created_at * 1000;

    // Bug A root cause: the gateway emits the same key-grant on every
    // SSE connect (replay window includes anything since the last
    // gift-wrap cursor) AND once again on the first live-tail poll. Before
    // this dedup, the loop re-processed each replay/live overlap pair,
    // logging "[sse] key-grant landed" hundreds of times for the same
    // event id at the same epoch. The cursor advance below closes the
    // loop across reconnects; this catches within-connection duplicates.
    if (this.isDuplicateEvent(grant.id, receivedAtMs)) {
      log.info("[sse-trace] key-grant duplicate-skip", {
        room: this.roomSlug,
        event_id: grant.id,
      });
      this.advanceCursor(receivedAtMs);
      return;
    }

    const epoch = this.parseEpochFromGrant(grant);
    if (epoch === null) {
      log.warn("[sse] could not parse epoch from key-grant", {
        room: this.roomSlug,
        event_id: grant.id,
      });
      this.advanceCursor(receivedAtMs);
      return;
    }

    let epochPriv: Uint8Array;
    try {
      epochPriv = nip44.decrypt(grant.content, this.pluginPriv, grant.pubkey);
    } catch (e) {
      // Grants for other recipients land on the same stream; ignore.
      // Still advance the cursor so the gateway stops replaying it.
      log.debug("[sse] key-grant decrypt failed (likely not for us)", {
        room: this.roomSlug,
        event_id: grant.id,
      });
      this.advanceCursor(receivedAtMs);
      return;
    }
    if (epochPriv.length !== 32) {
      log.warn("[sse] decrypted key-grant payload is not 32 bytes", {
        room: this.roomSlug,
        event_id: grant.id,
        len: epochPriv.length,
      });
      this.advanceCursor(receivedAtMs);
      return;
    }

    this.epochKeys.set(epoch, epochPriv);
    if (epoch > this.state.currentEpoch) {
      this.state.currentEpoch = epoch;
    }
    await this.persistEpochKeys();

    // Plan §1 Gap 3 + §7 Pass B8: a pending-grant room becomes active the
    // instant its first key-grant lands. Re-read the entity before patching
    // so we never clobber a state the operator changed in the meantime
    // (e.g. "left"). If the fresh read fails, fall back to the in-memory
    // value — same race posture handleDeclarationUpdated runs with.
    const patch: Record<string, unknown> = { current_epoch: this.state.currentEpoch };
    const promote = await this.shouldPromoteToActive();
    if (promote) {
      patch["state"] = "active";
      this.state.state = "active";
    }
    await this.memory.entity.patch({
      id: this.state.entityId,
      attributes: patch,
    });
    log.info("[sse] key-grant landed", {
      room: this.roomSlug,
      epoch,
      promoted: promote,
    });

    await this.drainPending(epoch);
    // Move the cursor PAST this grant so the gateway's next-connect replay
    // window excludes it (`g.created_at > sinceUnix` in audience-stream.ts).
    // Before this, the cursor only advanced on gift-wraps, so a room that
    // had received only key-grants kept replaying them forever.
    this.advanceCursor(receivedAtMs);
  }

  private async shouldPromoteToActive(): Promise<boolean> {
    if (!this.state) return false;
    if (this.state.state !== "pending-grant") return false;
    const fresh = await this.memory.entity.byNameOrNull(`studio:room:${this.roomSlug}`);
    const freshAttrs = parseAttrs(fresh?.attributes);
    const cur = freshAttrs["state"];
    // Promote only if the on-disk state is still pending-grant. If the row
    // is missing entirely (older rows pre-Phase-3) or the attribute is
    // absent, trust our in-memory pending-grant view.
    if (cur === undefined) return true;
    return cur === "pending-grant";
  }

  private parseEpochFromGrant(grant: NostrEventLike): number | null {
    const epochTag = findTag(grant.tags, "fa:epoch");
    if (epochTag !== undefined) {
      const n = Number(epochTag);
      if (Number.isFinite(n) && n >= 1) return n;
    }
    // Per E22, kind:30521 grants carry d=`<slug>:<epoch>:<plugin_pub>`.
    const dTag = findTag(grant.tags, "d");
    if (dTag !== undefined) {
      const parts = dTag.split(":");
      if (parts.length >= 2) {
        const n = Number(parts[1]);
        if (Number.isFinite(n) && n >= 1) return n;
      }
    }
    return null;
  }

  private async drainPending(epoch: number): Promise<void> {
    const q = this.pending.get(epoch);
    if (!q || q.length === 0) return;
    this.pending.delete(epoch);
    const epochPriv = this.epochKeys.get(epoch);
    if (!epochPriv) return;
    log.info("[sse] draining pending decrypt queue", {
      room: this.roomSlug,
      epoch,
      count: q.length,
    });
    for (const item of q) {
      await this.decryptAndProject(item.rumor, item.publisherPub, epochPriv);
    }
  }

  // ── declaration-updated ───────────────────────────────────────────────────

  private async handleDeclarationUpdated(data: unknown): Promise<void> {
    if (!data || typeof data !== "object") return;
    if (!this.state) return;
    const payload = data as { declaration_event?: NostrEventLike; received_at_ms?: number };
    const decl = payload.declaration_event;
    if (!decl) return;
    const receivedAtMs =
      typeof payload.received_at_ms === "number"
        ? payload.received_at_ms
        : decl.created_at * 1000;
    if (this.isDuplicateEvent(decl.id, receivedAtMs)) {
      log.info("[sse-trace] declaration-updated duplicate-skip", {
        room: this.roomSlug,
        event_id: decl.id,
      });
      this.advanceCursor(receivedAtMs);
      return;
    }

    const tags = decl.tags;
    const members: string[] = [];
    let pendingPubs: string[] = [];
    let epoch: number | null = null;
    // Room-lifecycle status tags (sonata-studio-room-lifecycle.md §4.1).
    // Absence ≡ active; unknown values fall back to active.
    let status: "active" | "closed" = "active";
    let closedAt: number | null = null;
    for (const t of tags) {
      if (t[0] === "p" && t[1] && HEX64.test(t[1])) {
        members.push(t[1].toLowerCase());
      } else if (t[0] === "fa:pending" && t[1]) {
        pendingPubs.push(t[1]);
      } else if (t[0] === "fa:epoch" && t[1]) {
        const n = Number(t[1]);
        if (Number.isFinite(n) && n >= 1) epoch = n;
      } else if (t[0] === "fa:status") {
        if (t[1] === "closed") status = "closed";
      } else if (t[0] === "fa:closed-at" && t[1]) {
        const n = Number(t[1]);
        if (Number.isFinite(n) && n > 0) closedAt = n;
      }
    }
    const previousEpoch = this.state.currentEpoch;
    this.state.members = members;
    if (epoch !== null) this.state.currentEpoch = epoch;
    const attrs: Record<string, unknown> = {
      members,
      pending: pendingPubs,
    };
    if (epoch !== null) attrs["current_epoch"] = epoch;
    // Room-lifecycle status. The kind-30520 carries the authoritative room
    // state; we only flip the local `state` field for active↔closed
    // transitions and leave pending-grant / left untouched.
    //   - status=closed → state=closed (always; close beats anything except
    //     a separate self-initiated "left" which the leaveRoom action handles).
    //   - status=active AND current state is "closed" → state=active (reopen).
    //   - status=active otherwise → preserve existing state (pending-grant
    //     stays until the key-grant arrives; "left" sticks until a fresh
    //     re-join).
    const priorState =
      typeof this.state.state === "string" ? this.state.state : "active";
    if (status === "closed") {
      attrs["state"] = "closed";
      attrs["closed_at_seconds"] = closedAt;
      this.state.state = "closed";
    } else if (priorState === "closed") {
      attrs["state"] = "active";
      attrs["closed_at_seconds"] = null;
      this.state.state = "active";
    }
    try {
      await this.memory.entity.patch({
        id: this.state.entityId,
        attributes: attrs,
      });
    } catch (err) {
      log.warn("[sse] declaration-updated patch failed", {
        room: this.roomSlug,
        err: err instanceof Error ? err.message : String(err),
      });
    }
    // T4b root cause #2: when the founder rotates the audience, A's plugin
    // generates the new epoch_(n+1) priv locally inside admit.ts and persists
    // it to the secret store, but A's SSEClient.this.epochKeys map only holds
    // what was loaded at startup (epoch_1). A doesn't receive a key-grant
    // SSE event for itself (A is the publisher), so without an explicit
    // reload here, B's cards encrypted to epoch_2 hit `epochKeys.get(2) =
    // undefined` and get queued forever in this.pending. Solution: when
    // declaration-updated reports a new epoch, re-read the secret store
    // and drain any pending items for the new epoch.
    if (epoch !== null && epoch > previousEpoch) {
      const loaded = await this.reloadEpochKeysFromSecret();
      if (loaded > 0) {
        log.info("[sse] declaration-updated reloaded epoch keys", {
          room: this.roomSlug,
          new_epoch: epoch,
          loaded_count: loaded,
        });
      }
      if (this.epochKeys.has(epoch)) {
        await this.drainPending(epoch);
      }
    }
    // Project synthetic system events (joined / removed / closed /
    // reopened) by diffing against the previous declaration we observed
    // on this connection. The first declaration on a fresh connect has
    // no `prev`, so projectDeclarationDiff emits nothing — we don't want
    // a reconnect to re-emit "joined" for every member.
    const nextSnapshot: DeclarationSnapshot = {
      members,
      status,
      createdAt: decl.created_at,
      eventId: decl.id,
      audIdPub: this.state.audIdPub,
      slug: this.roomSlug,
    };
    try {
      await projectDeclarationDiff({
        prev: this.previousDeclarationSnapshot,
        next: nextSnapshot,
        roomSlug: this.roomSlug,
        founderPubkey: decl.pubkey,
        entity: this.memory.entity,
      });
    } catch (err) {
      log.warn("[sse] room-system-events projector failed", {
        room: this.roomSlug,
        err: err instanceof Error ? err.message : String(err),
      });
    }
    this.previousDeclarationSnapshot = nextSnapshot;

    // Advance the cursor past this declaration so the gateway's replay
    // path (`cur.created_at > sinceUnix`, audience-stream.ts:286) stops
    // re-emitting it on every reconnect.
    this.advanceCursor(receivedAtMs);
  }

  /**
   * Re-read the audience's epoch keys secret and merge any new entries into
   * this.epochKeys. Used by handleDeclarationUpdated to pick up keys the
   * founder generated locally (admit.ts → mergeEpochKeysSecret) without
   * waiting for a non-existent key-grant SSE event addressed to self.
   * Returns the number of new epoch privs added (existing entries unchanged).
   */
  private async reloadEpochKeysFromSecret(): Promise<number> {
    if (!this.state) return 0;
    let added = 0;
    try {
      const sec = await this.memory.secret.get(this.state.epochKeysSecretName);
      const parsed = JSON.parse(sec.value) as Record<string, unknown>;
      const verbose = parsed["epochs"];
      if (verbose && typeof verbose === "object" && !Array.isArray(verbose)) {
        for (const [k, v] of Object.entries(verbose as Record<string, unknown>)) {
          const epoch = Number(k);
          if (!Number.isFinite(epoch)) continue;
          if (this.epochKeys.has(epoch)) continue;
          if (!v || typeof v !== "object") continue;
          const priv = (v as Record<string, unknown>)["priv_hex"];
          if (typeof priv !== "string" || !HEX64.test(priv)) continue;
          this.epochKeys.set(epoch, hexToBytes(priv));
          added++;
        }
      }
      for (const [k, v] of Object.entries(parsed)) {
        if (k === "epochs") continue;
        const epoch = Number(k);
        if (!Number.isFinite(epoch) || typeof v !== "string") continue;
        if (!HEX64.test(v)) continue;
        if (this.epochKeys.has(epoch)) continue;
        this.epochKeys.set(epoch, hexToBytes(v));
        added++;
      }
    } catch {
      // secret missing — nothing to reload
    }
    return added;
  }

  // ── room state load + epoch keys persistence ─────────────────────────────

  private async loadRoomState(): Promise<void> {
    const name = `studio:room:${this.roomSlug}`;
    const ent = await this.memory.entity.byNameOrNull(name);
    if (!ent) {
      this.state = null;
      return;
    }
    const attrs = parseAttrs(ent.attributes);
    const audIdPub =
      typeof attrs["aud_id_pub_hex"] === "string"
        ? (attrs["aud_id_pub_hex"] as string)
        : null;
    if (!audIdPub || !HEX64.test(audIdPub)) {
      log.warn("[sse] room missing aud_id_pub_hex", { room: this.roomSlug });
      this.state = null;
      return;
    }
    const cursor =
      typeof attrs["last_seen_wrap_at_ms"] === "number"
        ? (attrs["last_seen_wrap_at_ms"] as number)
        : 0;
    const members = Array.isArray(attrs["members"])
      ? (attrs["members"] as unknown[]).filter(
          (x): x is string => typeof x === "string",
        )
      : [];
    const currentEpoch =
      typeof attrs["current_epoch"] === "number"
        ? (attrs["current_epoch"] as number)
        : 0;
    const epochKeysSecretName =
      typeof attrs["epoch_keys_secret_name"] === "string"
        ? (attrs["epoch_keys_secret_name"] as string)
        : `studio:room:${this.roomSlug}:epoch_keys`;

    // Load epoch keys from the secret store. Missing secret = empty map
    // (a pending-grant room before the founding grant lands).
    //
    // Two on-disk shapes are honored: the verbose
    //   { epochs: { "<n>": { epoch, priv_hex, pub_hex } } }
    // form `createRoom` and `admitRoom` write, and the flat
    //   { "<n>": "<hex>" }
    // form `persistEpochKeys` writes. Both can coexist on the same secret
    // (admitRoom intentionally mirrors both); reading either is fine.
    this.epochKeys = new Map();
    try {
      const sec = await this.memory.secret.get(epochKeysSecretName);
      const parsed = JSON.parse(sec.value) as Record<string, unknown>;
      // Verbose form first — entries inside `parsed.epochs`.
      const verbose = parsed["epochs"];
      if (verbose && typeof verbose === "object" && !Array.isArray(verbose)) {
        for (const [k, v] of Object.entries(verbose as Record<string, unknown>)) {
          const epoch = Number(k);
          if (!Number.isFinite(epoch)) continue;
          if (!v || typeof v !== "object") continue;
          const priv = (v as Record<string, unknown>)["priv_hex"];
          if (typeof priv !== "string" || !HEX64.test(priv)) continue;
          this.epochKeys.set(epoch, hexToBytes(priv));
        }
      }
      // Flat form — top-level keys that parse as epoch numbers + hex strings.
      for (const [k, v] of Object.entries(parsed)) {
        if (k === "epochs") continue;
        const epoch = Number(k);
        if (!Number.isFinite(epoch) || typeof v !== "string") continue;
        if (!HEX64.test(v)) continue;
        if (!this.epochKeys.has(epoch)) {
          this.epochKeys.set(epoch, hexToBytes(v));
        }
      }
    } catch {
      // first-run / pending-grant — no keys yet
    }

    const state =
      typeof attrs["state"] === "string" ? (attrs["state"] as string) : "active";
    const joinedAtMs =
      typeof attrs["joined_at_ms"] === "number"
        ? (attrs["joined_at_ms"] as number)
        : null;
    this.state = {
      entityId: ent.id,
      audIdPub: audIdPub.toLowerCase(),
      cursor,
      members,
      currentEpoch,
      epochKeysSecretName,
      state,
      joinedAtMs,
    };
  }

  private async persistEpochKeys(): Promise<void> {
    if (!this.state) return;
    // Write BOTH shapes:
    //   - Flat `{<n>: <priv_hex>}` for any consumer that just needs priv.
    //   - Verbose `{epochs: {<n>: {priv_hex, pub_hex}}}` — the shape
    //     loadRoomCtx (src/actions/util.ts) expects so non-founder members
    //     can post cards. Without the verbose mirror, B's card-post fails
    //     with "studio_room <slug> epoch <n> key missing" even though SSE
    //     delivered the priv correctly.
    const flat: Record<string, string> = {};
    const epochs: Record<string, { priv_hex: string; pub_hex: string }> = {};
    for (const [epoch, priv] of this.epochKeys) {
      const privHex = bytesToHex(priv);
      const pubHex = bytesToHex(schnorr.getPublicKey(priv));
      flat[String(epoch)] = privHex;
      epochs[String(epoch)] = { priv_hex: privHex, pub_hex: pubHex };
    }
    const out = { ...flat, epochs };
    try {
      await this.memory.secret.set({
        name: this.state.epochKeysSecretName,
        value: JSON.stringify(out),
        description: `Sonata Studio epoch keys for ${this.roomSlug}`,
      });
    } catch (err) {
      log.warn("[sse] failed to persist epoch keys", {
        room: this.roomSlug,
        err: err instanceof Error ? err.message : String(err),
      });
    }
  }

  // ── cursor ────────────────────────────────────────────────────────────────

  private advanceCursor(receivedAtMs: number): void {
    if (!this.state) return;
    if (receivedAtMs > this.state.cursor) {
      this.state.cursor = receivedAtMs;
      this.cursorDirty = true;
      this.scheduleCursorWrite();
    }
  }

  private scheduleCursorWrite(): void {
    if (this.cursorDebounceMs <= 0) {
      // Synchronous write — fire and forget so handlers don't block.
      void this.flushCursor();
      return;
    }
    if (this.cursorTimer) return;
    this.cursorTimer = setTimeout(() => {
      this.cursorTimer = null;
      void this.flushCursor();
    }, this.cursorDebounceMs);
  }

  // ── test hooks ────────────────────────────────────────────────────────────

  /** Test-only: peek pending depth for a given epoch. */
  pendingDepth(epoch: number): number {
    return this.pending.get(epoch)?.length ?? 0;
  }

  /** Test-only: snapshot the current cursor. */
  currentCursor(): number {
    return this.state?.cursor ?? 0;
  }

  /** Test-only: number of epoch keys currently loaded. */
  epochKeyCount(): number {
    return this.epochKeys.size;
  }
}
