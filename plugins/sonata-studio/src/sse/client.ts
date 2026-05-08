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
    list(opts?: { type?: string; limit?: number }): Promise<SSEEntityRow[]>;
    patch(args: {
      id: string;
      attributes: Record<string, unknown>;
    }): Promise<{ id: string }>;
  };
  secret: {
    get(name: string): Promise<{ name: string; value: string }>;
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
  private recentWrapIds = new Map<string, number>();
  private cursorDirty = false;
  private cursorTimer: ReturnType<typeof setTimeout> | null = null;
  private activeBody: ReadableStream<Uint8Array> | null = null;
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
        const resp = await this.gateway.openStream(args);
        // First successful connect clears the pre-admit flag so the next
        // reconnect uses normal cursor logic.
        this.pendingAdmitReconnect = false;
        if (!resp.body) {
          throw new Error("gateway response had no body");
        }
        this.activeBody = resp.body;
        await this.consume(resp.body);
      } catch (err) {
        if (isPreAdmitRejection(err)) {
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
      } finally {
        this.activeBody = null;
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
    if (this.activeBody) {
      this.activeBody.cancel().catch(() => {
        // best-effort
      });
    }
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

    if (this.isDuplicateWrap(wrap.id, receivedAtMs)) return;

    let unwrapped;
    try {
      unwrapped = unwrap(wrap as never, this.pluginPriv);
    } catch (e) {
      // Wraps for other recipients arrive on the same stream; failing to
      // decrypt the seal is the expected case for those.
      log.debug("[sse] unwrap failed (likely not for us)", {
        room: this.roomSlug,
        wrap_id: wrap.id,
      });
      this.advanceCursor(receivedAtMs);
      return;
    }
    const rumor = unwrapped.rumor;
    if (!(STUDIO_KINDS as readonly number[]).includes(rumor.kind)) {
      this.advanceCursor(receivedAtMs);
      return;
    }
    const aTag = findTag(rumor.tags, "a");
    const expectedAddr = `30520:${this.state.audIdPub}:${this.roomSlug}`;
    if (aTag !== expectedAddr) {
      this.advanceCursor(receivedAtMs);
      return;
    }
    const epochTag = findTag(rumor.tags, "fa:epoch");
    const epoch = epochTag !== undefined ? Number(epochTag) : NaN;
    if (!Number.isFinite(epoch)) {
      log.warn("[sse] gift-wrap rumor missing fa:epoch", {
        room: this.roomSlug,
        rumor_id: rumor.id,
      });
      this.advanceCursor(receivedAtMs);
      return;
    }

    const epochPriv = this.epochKeys.get(epoch);
    if (!epochPriv) {
      this.pushPending(epoch, rumor as StudioRumor, unwrapped.publisherPub);
      this.advanceCursor(receivedAtMs);
      return;
    }
    await this.decryptAndProject(rumor as StudioRumor, unwrapped.publisherPub, epochPriv);
    this.advanceCursor(receivedAtMs);
  }

  private isDuplicateWrap(id: string, nowMs: number): boolean {
    // GC entries older than the dedup window.
    for (const [k, t] of this.recentWrapIds) {
      if (nowMs - t > DEDUP_WINDOW_MS) this.recentWrapIds.delete(k);
    }
    if (this.recentWrapIds.has(id)) return true;
    this.recentWrapIds.set(id, nowMs);
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
    const payload = data as { grant_event?: NostrEventLike };
    const grant = payload.grant_event;
    if (!grant) return;
    if (!this.state) return;
    if (grant.kind !== KIND_KEY_GRANT) return;

    const epoch = this.parseEpochFromGrant(grant);
    if (epoch === null) {
      log.warn("[sse] could not parse epoch from key-grant", {
        room: this.roomSlug,
        event_id: grant.id,
      });
      return;
    }

    let epochPriv: Uint8Array;
    try {
      epochPriv = nip44.decrypt(grant.content, this.pluginPriv, grant.pubkey);
    } catch (e) {
      // Grants for other recipients land on the same stream; ignore.
      log.debug("[sse] key-grant decrypt failed (likely not for us)", {
        room: this.roomSlug,
        event_id: grant.id,
      });
      return;
    }
    if (epochPriv.length !== 32) {
      log.warn("[sse] decrypted key-grant payload is not 32 bytes", {
        room: this.roomSlug,
        event_id: grant.id,
        len: epochPriv.length,
      });
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
  }

  private async shouldPromoteToActive(): Promise<boolean> {
    if (!this.state) return false;
    if (this.state.state !== "pending-grant") return false;
    try {
      const fresh = await this.memory.entity.byName(`studio:room:${this.roomSlug}`);
      const freshAttrs = parseAttrs(fresh?.attributes);
      const cur = freshAttrs["state"];
      // Promote only if the on-disk state is still pending-grant. If the
      // attribute is missing entirely (older rows pre-Phase-3), trust our
      // in-memory pending-grant view.
      if (cur === undefined) return true;
      return cur === "pending-grant";
    } catch {
      return true;
    }
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
    const payload = data as { declaration_event?: NostrEventLike };
    const decl = payload.declaration_event;
    if (!decl) return;

    const tags = decl.tags;
    const members: string[] = [];
    let pendingPubs: string[] = [];
    let epoch: number | null = null;
    for (const t of tags) {
      if (t[0] === "p" && t[1] && HEX64.test(t[1])) {
        members.push(t[1].toLowerCase());
      } else if (t[0] === "fa:pending" && t[1]) {
        pendingPubs.push(t[1]);
      } else if (t[0] === "fa:epoch" && t[1]) {
        const n = Number(t[1]);
        if (Number.isFinite(n) && n >= 1) epoch = n;
      }
    }
    this.state.members = members;
    if (epoch !== null) this.state.currentEpoch = epoch;
    const attrs: Record<string, unknown> = {
      members,
      pending: pendingPubs,
    };
    if (epoch !== null) attrs["current_epoch"] = epoch;
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
  }

  // ── room state load + epoch keys persistence ─────────────────────────────

  private async loadRoomState(): Promise<void> {
    const name = `studio:room:${this.roomSlug}`;
    const ent = await this.memory.entity.byName(name);
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
