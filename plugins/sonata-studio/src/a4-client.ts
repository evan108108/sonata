// 4A gateway client — typed HTTP wrapper that signs every call with NIP-98.
//
// Per plan §4.2, each method:
//   1. JSON-stringifies the body.
//   2. Calls signNip98({url, method, body}) — body=undefined for GET.
//   3. Sets Authorization: Nostr <base64-event>.
//   4. POSTs (or GETs) to `${gatewayBaseUrl}/v0/audience/raw/...`.
//   5. On 4xx → throws GatewayError(status, code, message) with no retry.
//   6. On 5xx (or network error) → exponential backoff retry: 250ms, 500ms,
//      1s, 2s; give up after 4 attempts.
//   7. On 2xx → JSON-parses, returns typed.
//
// SSE stream open: GET /v0/audience/:slug/stream — returns the raw Response;
// the caller (T6 SSEClient) consumes the body. No retry at this layer; the
// SSE manager handles reconnect with the last-seen cursor.

import { signNip98 } from "./crypto/nip98";
import type { PluginConfig } from "./config";

// ── Types ───────────────────────────────────────────────────────────────────

export interface NostrEventLike {
  id: string;
  pubkey: string;
  created_at: number;
  kind: number;
  tags: string[][];
  content: string;
  sig: string;
}

export interface RelayAck {
  relay: string;
  status: "accepted" | "rejected" | "failed";
  message?: string;
}

export interface RawCreateRequest {
  declaration: NostrEventLike;
  founding_grant: NostrEventLike;
}

export interface RawCreateResponse {
  ok: true;
  audience_address: string;
  declaration_event_id: string;
  founding_grant_event_id: string;
  relay_acks: { declaration: RelayAck[]; founding_grant: RelayAck[] };
}

export interface RawGrantRequest {
  audience_address: string;
  grant: NostrEventLike;
  updated_declaration?: NostrEventLike;
}

export interface RawGrantResponse {
  ok: true;
  grant_event_id: string;
  declaration_event_id: string | null;
  relay_acks: { grant: RelayAck[]; declaration: RelayAck[] };
}

export interface RawRotateRequest {
  audience_address: string;
  declaration: NostrEventLike;
  grants: NostrEventLike[];
}

export interface RawRotateResponse {
  ok: true;
  declaration_event_id: string;
  // `accepted` is an explicit per-grant boolean added by the gateway after
  // the silent-failure bug where empty `relay_acks` length-check passed.
  // Optional for backwards-compat with older gateway deploys.
  grants: {
    recipient: string;
    event_id: string;
    accepted?: boolean;
    relay_acks: RelayAck[];
  }[];
}

export interface RawInviteRequest {
  audience_address: string;
  declaration: NostrEventLike;
  invite_pub: string;
  invite_priv_4ainv: string;
}

export interface RawInviteResponse {
  ok: true;
  /**
   * Native-scheme URL emitted by the gateway. After the s4a:// rename the
   * gateway returns `s4a_url`; older gateway builds return `four_a_url`.
   * The plugin's `inviteToRoom` ignores both fields in favour of
   * constructing the URLs locally from the bech32-encoded priv it just
   * generated — keeping plugin behaviour stable across the gateway-deploy
   * window. The fields stay typed here so the renderer can read the
   * gateway's value if a future caller wants it.
   */
  s4a_url?: string;
  four_a_url?: string;
  https_url: string;
  invite_pub: string;
  invite_priv_4ainv: string;
  expires_at: number;
  declaration_event_id: string;
}

export interface RawClaimRequest {
  audience_address: string;
  claim: NostrEventLike;
}

export interface RawClaimResponse {
  ok: true;
  claim_event_id: string;
  relay_acks: RelayAck[];
}

export interface RawProcessClaimsRequest {
  audience_address: string;
}

export interface RawProcessClaimsResponse {
  ok: true;
  claimed: {
    invite_pub: string;
    claim_pubkey: string;
    claim_event_id: string;
    /**
     * Optional raw `content` field from the kind:30522 claim event. Gateway
     * implementations MAY include it so callers can parse the joiner's
     * volunteered profile preview (see `parseClaimProfile`). Older
     * gateways omit this field; callers must treat its absence as "no
     * preview available, fall back to pubkey-prefix only."
     */
    content?: string;
  }[];
}

export interface RawPublishWrapsRequest {
  audience_address: string;
  gift_wraps: NostrEventLike[];
}

export interface RawPublishWrapsResponse {
  ok: true;
  audience_address: string;
  epoch: number;
  gift_wraps: { recipient: string; event_id: string; relay_acks: RelayAck[] }[];
}

export interface RawPublishDeclarationRequest {
  audience_address: string;
  declaration: NostrEventLike;
}

export interface RawPublishDeclarationResponse {
  ok: true;
  audience_address: string;
  declaration_event_id: string;
  relay_acks: RelayAck[];
}

export interface DeclarationResponse {
  ok: true;
  declaration: NostrEventLike;
}

export interface DeclarationByInvitePubResponse {
  ok: true;
  audience_address: string;
  aud_id_pub: string;
  slug: string;
  declaration: NostrEventLike;
}

export interface OpenStreamArgs {
  audience_slug: string;
  /** Required by the gateway to disambiguate slug → declaration. */
  aud_id_pub: string;
  since_ts?: number;
  replay_limit?: number;
}

// ── Errors ──────────────────────────────────────────────────────────────────

export class GatewayError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "GatewayError";
  }
}

// ── Retry policy ────────────────────────────────────────────────────────────

const RETRY_DELAYS_MS = [250, 500, 1_000, 2_000] as const;
const MAX_ATTEMPTS = RETRY_DELAYS_MS.length;

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

// ── Client ──────────────────────────────────────────────────────────────────

export interface GatewayClientOptions {
  /** Inject a fetch-compatible function (tests pass a mock). */
  fetcher?: typeof fetch;
  /** Override retry delays (tests use [0,0,0,0] to skip waits). */
  retryDelaysMs?: readonly number[];
}

export class GatewayClient {
  private readonly fetcher: typeof fetch;
  private readonly retryDelaysMs: readonly number[];

  constructor(
    private readonly cfg: Pick<PluginConfig, "pluginPriv" | "gatewayBaseUrl">,
    opts: GatewayClientOptions = {},
  ) {
    this.fetcher = opts.fetcher ?? fetch.bind(globalThis);
    this.retryDelaysMs = opts.retryDelaysMs ?? RETRY_DELAYS_MS;
  }

  // ── Raw audience routes ──────────────────────────────────────────────────

  rawCreate(req: RawCreateRequest): Promise<RawCreateResponse> {
    return this.post("/v0/audience/raw/create", req);
  }

  rawGrant(req: RawGrantRequest): Promise<RawGrantResponse> {
    return this.post("/v0/audience/raw/grant", req);
  }

  rawRotate(req: RawRotateRequest): Promise<RawRotateResponse> {
    return this.post("/v0/audience/raw/rotate", req);
  }

  rawInvite(req: RawInviteRequest): Promise<RawInviteResponse> {
    return this.post("/v0/audience/raw/invite", req);
  }

  rawClaim(req: RawClaimRequest): Promise<RawClaimResponse> {
    return this.post("/v0/audience/raw/claim", req);
  }

  rawProcessClaims(
    req: RawProcessClaimsRequest,
  ): Promise<RawProcessClaimsResponse> {
    return this.post("/v0/audience/raw/process-claims", req);
  }

  rawPublishWraps(
    req: RawPublishWrapsRequest,
  ): Promise<RawPublishWrapsResponse> {
    return this.post("/v0/audience/raw/publish-wraps", req);
  }

  /**
   * Publish a re-signed kind:30520 declaration (close / reopen / boot).
   * The gateway only mints epoch keys or grants when those routes are
   * invoked; this route is for declaration-only state changes that don't
   * rotate the epoch.
   */
  rawPublishDeclaration(
    req: RawPublishDeclarationRequest,
  ): Promise<RawPublishDeclarationResponse> {
    return this.post("/v0/audience/raw/publish-declaration", req);
  }

  /** Public read — no NIP-98 auth needed; declarations are public. */
  async getDeclaration(args: {
    slug: string;
    aud_id_pub: string;
  }): Promise<DeclarationResponse> {
    const url = `${this.cfg.gatewayBaseUrl}/v0/audience/${encodeURIComponent(
      args.slug,
    )}/declaration?aud_id_pub=${encodeURIComponent(args.aud_id_pub)}`;
    const res = await this.fetchWithRetry(url, { method: "GET" });
    return this.parseJson(res);
  }

  /**
   * Public read — resolve a (declaration, aud_id_pub, slug) triple from an
   * invite pubkey alone. Used by `studio_room_join` to look up the audience
   * when the gateway-emitted URL omits `aud_id_pub`.
   *
   * 404 → invite_pub never seen as pending.
   * 410 → invite_pub was once pending but has been claimed or rotated out.
   * Both surface as `GatewayError` and the caller maps them to a single
   * `invite_not_found` user-facing error.
   */
  async getDeclarationByInvitePub(args: {
    invite_pub: string;
  }): Promise<DeclarationByInvitePubResponse> {
    const url = `${this.cfg.gatewayBaseUrl}/v0/audience/by-invite-pub/${encodeURIComponent(
      args.invite_pub,
    )}`;
    const res = await this.fetchWithRetry(url, { method: "GET" });
    return this.parseJson(res);
  }

  /**
   * Open the SSE stream. Returns the raw Response; caller pipes the body.
   * No retry at this layer — the SSE manager owns reconnect logic.
   *
   * `signal` is forwarded to the underlying fetch so the caller can abort
   * both the pending request and the response body stream in one shot —
   * the body's ReadableStream errors out of any in-flight `reader.read()`
   * when the signal fires, which is the only way to unblock an SSE pump
   * that's idling on the wire.
   */
  async openStream(args: OpenStreamArgs, signal?: AbortSignal): Promise<Response> {
    const params = new URLSearchParams({
      aud_id_pub: args.aud_id_pub,
    });
    if (args.since_ts !== undefined) params.set("since_ts", String(args.since_ts));
    if (args.replay_limit !== undefined) {
      params.set("replay_limit", String(args.replay_limit));
    }
    const url = `${this.cfg.gatewayBaseUrl}/v0/audience/${encodeURIComponent(
      args.audience_slug,
    )}/stream?${params.toString()}`;
    const auth = await signNip98({
      url,
      method: "GET",
      pluginPriv: this.cfg.pluginPriv,
    });
    const res = await this.fetcher(url, {
      method: "GET",
      headers: {
        Authorization: auth,
        Accept: "text/event-stream",
      },
      signal,
    });
    if (!res.ok) {
      const { code, message } = await this.readErrorPayload(res);
      throw new GatewayError(res.status, code, message);
    }
    return res;
  }

  // ── Internals ────────────────────────────────────────────────────────────

  private async post<T>(path: string, body: unknown): Promise<T> {
    const url = `${this.cfg.gatewayBaseUrl}${path}`;
    const bodyBytes = new TextEncoder().encode(JSON.stringify(body));
    // Sign once; retries reuse the same auth (the gateway's ±60s window
    // covers the worst-case retry tail).
    const auth = await signNip98({
      url,
      method: "POST",
      body: bodyBytes,
      pluginPriv: this.cfg.pluginPriv,
    });
    const res = await this.fetchWithRetry(url, {
      method: "POST",
      headers: {
        Authorization: auth,
        "Content-Type": "application/json",
      },
      body: bodyBytes,
    });
    return this.parseJson(res);
  }

  private async fetchWithRetry(
    url: string,
    init: RequestInit,
  ): Promise<Response> {
    let lastError: Error | null = null;
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      try {
        const res = await this.fetcher(url, init);
        if (res.ok) return res;
        if (res.status >= 400 && res.status < 500) {
          // 4xx → no retry, surface as GatewayError to caller.
          const { code, message } = await this.readErrorPayload(res);
          throw new GatewayError(res.status, code, message);
        }
        // 5xx → fall through to retry.
        const { code, message } = await this.readErrorPayload(res);
        lastError = new GatewayError(res.status, code, message);
      } catch (err) {
        if (err instanceof GatewayError && err.status >= 400 && err.status < 500) {
          throw err;
        }
        lastError =
          err instanceof Error ? err : new Error(String(err));
      }

      if (attempt < MAX_ATTEMPTS - 1) {
        await sleep(this.retryDelaysMs[attempt] ?? 0);
      }
    }
    if (lastError instanceof GatewayError) throw lastError;
    throw new GatewayError(
      0,
      "network_error",
      lastError?.message ?? "request failed after retries",
    );
  }

  private async parseJson<T>(res: Response): Promise<T> {
    try {
      return (await res.json()) as T;
    } catch (err) {
      throw new GatewayError(
        res.status,
        "invalid_response",
        `gateway returned non-JSON: ${(err as Error).message}`,
      );
    }
  }

  private async readErrorPayload(
    res: Response,
  ): Promise<{ code: string; message: string }> {
    try {
      const body = (await res.json()) as Record<string, unknown>;
      const code = typeof body.error === "string" ? body.error : `http_${res.status}`;
      const message =
        typeof body.message === "string" ? body.message : res.statusText;
      return { code, message };
    } catch {
      return { code: `http_${res.status}`, message: res.statusText };
    }
  }
}
