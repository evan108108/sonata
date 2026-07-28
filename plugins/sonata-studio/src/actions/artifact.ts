// Studio public-artifact actions — publish / list / revoke against the 4a
// gateway's /v0/artifacts/* API (shipped 2026-07-28).
//
// Unlike room content there is no gift-wrap and no audience epoch here: the
// payload is AES-256-GCM ciphertext under a per-dTag key K that leaves this
// machine only inside the URL fragment (#k=...), which browsers never send
// to servers. The gateway stores ciphertext, serves ciphertext, and streams
// a viewer shell that decrypts client-side — 4a cannot read what it hosts.
//
// Key stability discipline (locked decision): K is minted once per dTag and
// reused for every republish of that dTag so previously shared latest-URLs
// keep decrypting. NEVER rotate K within a dTag — invalidation is kind:5
// revocation, which produces a proper 410, not decrypt-to-garbage.
//
// Persistence is entity+secret rows (this plugin has no sqlite):
//   entity  studio:artifact:<sha256>     type=studio_artifact, one per publish
//   secret  studio:artifact_key:<dTag>   value=base64url(K), one per slug
//
// An explicit `d_tag` in the request means "republish this artifact" (reuses
// the slug and its K). A derived d_tag (from title) is a NEW artifact — on
// collision with an existing slug it suffixes -2, -3, … instead of silently
// superseding.

import { promises as fs } from "node:fs";
import * as path from "node:path";
import { createHash } from "node:crypto";

import { base64urlnopad } from "@scure/base";

import { GatewayError } from "../a4-client";
import { entity, secret } from "../memory-client";
import { __signEvent } from "../crypto/nip17";
import { blake3ContentTag } from "../crypto/blake3-tag";
import { encryptArtifact, generateArtifactKey } from "../crypto/aes-gcm";
import { uploadCiphertext, StorageUploadError } from "../storage/upload";
import { FA_CONTEXT_V0, HttpError, ensureString, slugify } from "./util";
import type { ActionCtx } from "./room";

const ARTIFACT_MANIFEST_KIND = 30540;
const REVOCATION_KIND = 5;

// 4 MiB pre-network cap. The gateway accepts up to 256 MiB, but the browser
// viewer decrypts the whole blob in memory before rendering — 4 MiB is a UX
// ceiling for interactive artifacts, not a protocol limit.
const MAX_PAYLOAD_BYTES = 4 * 1024 * 1024;
const MAX_TITLE_CHARS = 200;
const MAX_REASON_CHARS = 500;

// Gateway D_TAG regex (artifact-manifest-validator.ts). Deliberately NOT
// util.ts's ensureSlug — that one is tighter ([A-Za-z0-9-]+, no underscore,
// no length cap) and would reject valid artifact slugs.
const D_TAG_RE = /^[A-Za-z0-9_-]{1,64}$/;
const HEX64 = /^[0-9a-f]{64}$/i;

// v1 content-type allowlist (locked decision). Everything else is 400 —
// pre-network, so no bytes are uploaded for a type the viewer can't render.
const ALLOWED_CONTENT_TYPES = new Set([
  "text/html",
  "text/plain",
  "application/json",
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
  "image/svg+xml",
]);

const ENTITY_TYPE = "studio_artifact";
const ENTITY_PREFIX = "studio:artifact:";
const KEY_SECRET_PREFIX = "studio:artifact_key:";

// ── Request / result shapes ─────────────────────────────────────────────────

interface ArtifactPublishRequest {
  file_path?: unknown;
  data?: unknown;
  data_encoding?: unknown;
  content_type?: unknown;
  title?: unknown;
  d_tag?: unknown;
  room_id?: unknown;
}

export interface ArtifactPublishResult {
  sha256: string;
  d_tag: string;
  frozen_url: string;
  latest_url: string;
  event_id: string;
  published_at_ms: number;
}

interface ArtifactListRequest {
  filter?: unknown;
  limit?: unknown;
  offset?: unknown;
  include_revoked?: unknown;
}

export interface ArtifactListEntry {
  id: string;
  sha256: string;
  d_tag: string;
  /** Publisher pubkey (lowercase hex) — the viewer's "signed by" attribution. */
  pubkey: string;
  title: string | null;
  content_type: string;
  frozen_url: string | null;
  latest_url: string | null;
  event_id: string;
  published_at_ms: number;
  room_id: string | null;
  revoked: boolean;
  revoked_at_ms: number | null;
  revoked_reason?: string | null;
  key_missing?: boolean;
}

export interface ArtifactListResult {
  artifacts: ArtifactListEntry[];
  v2_marker?: string;
}

interface ArtifactRevokeRequest {
  sha256?: unknown;
  d_tag?: unknown;
  reason?: unknown;
}

export interface ArtifactRevokeResult {
  revoked: string[][];
  skipped: { tag: string[]; reason: string }[];
}

// ── Small helpers ───────────────────────────────────────────────────────────

function parseAttrs(raw: string | null | undefined): Record<string, unknown> {
  if (!raw) return {};
  try {
    const v = JSON.parse(raw);
    if (v && typeof v === "object" && !Array.isArray(v)) return v as Record<string, unknown>;
  } catch {
    // fall through
  }
  return {};
}

function ensureDTag(v: unknown, field: string): string {
  const s = ensureString(v, field);
  if (!D_TAG_RE.test(s)) {
    throw new HttpError(400, "bad_d_tag", `"${field}" must match ^[A-Za-z0-9_-]{1,64}$`);
  }
  return s;
}

function keySecretName(dTag: string): string {
  return `${KEY_SECRET_PREFIX}${dTag}`;
}

function entityName(sha256: string): string {
  return `${ENTITY_PREFIX}${sha256}`;
}

function sha256Hex(data: Uint8Array): string {
  return createHash("sha256").update(data).digest("hex");
}

function fragmentFor(key: Uint8Array): string {
  return `#k=${base64urlnopad.encode(key)}`;
}

function randomSlugSuffix(): string {
  return sha256Hex(generateArtifactKey()).slice(0, 8);
}

/** Map a GatewayError onto the handler's HttpError contract. Network-level
 *  failures (status 0) become 502 — the caller can retry; 4xx/5xx pass
 *  through with the gateway's own machine code (superseded,
 *  blob_already_bound, not_uploader, …). */
function rethrowGateway(err: unknown): never {
  if (err instanceof GatewayError) {
    const status = err.status >= 400 && err.status < 600 ? err.status : 502;
    throw new HttpError(status, err.code, err.message);
  }
  throw err as Error;
}

/** Read K for a dTag from the secret store. `strict` controls what a corrupt
 *  or wrongly-sized stored value does: publish must never silently mint a
 *  replacement (rotating K breaks every shared URL), list just degrades the
 *  row to key_missing. */
async function loadKeyOrNull(dTag: string, strict: boolean): Promise<Uint8Array | null> {
  const row = await secret.getOrNull(keySecretName(dTag));
  if (!row) return null;
  try {
    const key = base64urlnopad.decode(row.value);
    if (key.length === 32) return key;
  } catch {
    // fall through
  }
  if (strict) {
    throw new HttpError(
      500,
      "internal_error",
      `stored key for dTag "${dTag}" is corrupt (not 32 base64url bytes); refusing to mint a replacement`,
    );
  }
  return null;
}

// Per-dTag serialization of load-or-mint. Two concurrent publishes to the
// same fresh slug would otherwise both see "no key", mint different Ks, and
// last-write-wins the secret store — leaving the loser's ciphertext (and its
// returned #k= fragment) keyed by a K that no longer exists anywhere. This
// process is the secret store's only writer for these names, so an
// in-process queue fully closes the race; read-back-after-set would only
// narrow it (A can set+read K1 before B's set lands).
const keyMintLocks = new Map<string, Promise<Uint8Array>>();

function loadOrMintKey(dTag: string): Promise<Uint8Array> {
  const prev = keyMintLocks.get(dTag);
  const run = prev
    ? prev.then(
        () => doLoadOrMintKey(dTag),
        () => doLoadOrMintKey(dTag),
      )
    : doLoadOrMintKey(dTag);
  keyMintLocks.set(dTag, run);
  const cleanup = () => {
    if (keyMintLocks.get(dTag) === run) keyMintLocks.delete(dTag);
  };
  run.then(cleanup, cleanup);
  return run;
}

async function doLoadOrMintKey(dTag: string): Promise<Uint8Array> {
  let key = await loadKeyOrNull(dTag, true);
  if (!key) {
    key = generateArtifactKey();
    await secret.set({
      name: keySecretName(dTag),
      value: base64urlnopad.encode(key),
      description: `AES-256-GCM key for artifact dTag ${dTag}`,
    });
  }
  return key;
}

// ── studio_artifact_publish ─────────────────────────────────────────────────

async function publishArtifact(
  body: ArtifactPublishRequest,
  ctx: ActionCtx,
): Promise<ArtifactPublishResult> {
  // v1 schema guard — the field exists for forward-compat, any value is v2.
  if (body.room_id !== undefined && body.room_id !== null) {
    throw new HttpError(400, "roomId_v2", "room-qualified artifacts are v2; omit room_id");
  }

  const contentType = ensureString(body.content_type, "content_type");
  if (!ALLOWED_CONTENT_TYPES.has(contentType)) {
    throw new HttpError(
      400,
      "unsupported_content_type",
      `content_type "${contentType}" is not in the v1 allowlist: ${[...ALLOWED_CONTENT_TYPES].join(", ")}`,
    );
  }

  let title: string | null = null;
  if (body.title !== undefined) {
    title = ensureString(body.title, "title");
    if (title.length > MAX_TITLE_CHARS) {
      throw new HttpError(400, "bad_title", `"title" exceeds ${MAX_TITLE_CHARS} chars`);
    }
  }

  const plaintext = await loadPayload(body);
  if (plaintext.byteLength > MAX_PAYLOAD_BYTES) {
    throw new HttpError(
      413,
      "payload_too_large",
      `payload is ${plaintext.byteLength} bytes; max is ${MAX_PAYLOAD_BYTES} (4 MiB)`,
    );
  }

  const dTag =
    body.d_tag !== undefined
      ? ensureDTag(body.d_tag, "d_tag")
      : await deriveDTag(title);

  // Look up or mint K (serialized per dTag — see loadOrMintKey). Reuse-per-
  // dTag is the whole key-stability story.
  const key = await loadOrMintKey(dTag);

  const ciphertext = await encryptArtifact(plaintext, key);
  const sha = sha256Hex(ciphertext);

  try {
    await uploadCiphertext({
      config: null,
      defaultBlossomURL: `${ctx.cfg.gatewayBaseUrl}/blossom`,
      ciphertext,
      ciphertextSha256Hex: sha,
      pluginPriv: ctx.cfg.pluginPriv,
      pluginPub: ctx.cfg.pluginPub,
      roomSlug: "artifacts",
    });
  } catch (err) {
    if (err instanceof StorageUploadError) {
      throw new HttpError(err.status, err.code, err.message);
    }
    throw err;
  }

  const content = JSON.stringify({
    "@context": FA_CONTEXT_V0,
    "@type": "ArtifactManifest",
    contentType,
    encryption: "aes-256-gcm",
  });
  const tags: string[][] = [
    ["d", dTag],
    ["blob", sha],
    ["type", contentType],
  ];
  if (title !== null) tags.push(["title", title]);
  tags.push(
    ["alt", `Public artifact: ${title ?? dTag} (${contentType})`],
    ["blake3", blake3ContentTag(content)],
    ["fa:context", FA_CONTEXT_V0],
  );
  const event = __signEvent(
    {
      pubkey: ctx.cfg.pluginPub.toLowerCase(),
      kind: ARTIFACT_MANIFEST_KIND,
      created_at: Math.floor(Date.now() / 1000),
      tags,
      content,
    },
    ctx.cfg.pluginPriv,
  );

  let resp;
  try {
    resp = await ctx.gateway.publishArtifactManifest({ event });
  } catch (err) {
    // 409 blob_already_bound / superseded: the row we'd insert is a dup or
    // stale by definition — surface the gateway's code, insert nothing.
    rethrowGateway(err);
  }

  const publishedAtMs = Date.now();
  // Ops breadcrumb: if the upsert below fails, the manifest is already live
  // on the gateway but locally invisible — this line is the hand-recovery key.
  console.log(`[DEBUG] artifact publish success sha=${sha} eventId=${event.id} dTag=${dTag} pubkey=${ctx.cfg.pluginPub.toLowerCase()} — pending local upsert`);
  await entity.upsert({
    name: entityName(sha),
    type: ENTITY_TYPE,
    description: title ?? dTag,
    attributes: {
      dTag,
      title,
      contentType,
      pubkey: ctx.cfg.pluginPub.toLowerCase(),
      eventId: event.id,
      publishedAtMs,
      roomId: null,
      revoked: false,
      revokedAtMs: null,
      revokedReason: null,
    },
  });

  const fragment = fragmentFor(key);
  return {
    sha256: sha,
    d_tag: dTag,
    frozen_url: `${resp.frozen_url}${fragment}`,
    latest_url: `${resp.latest_url}${fragment}`,
    event_id: event.id,
    published_at_ms: publishedAtMs,
  };
}

async function loadPayload(body: ArtifactPublishRequest): Promise<Uint8Array> {
  const hasFile = body.file_path !== undefined;
  const hasData = body.data !== undefined;
  if (hasFile === hasData) {
    throw new HttpError(400, "bad_request", "exactly one of file_path or data is required");
  }

  if (hasFile) {
    const filePathRaw = ensureString(body.file_path, "file_path");
    const resolved = path.resolve(filePathRaw);
    let stat;
    try {
      const lstat = await fs.lstat(resolved);
      if (lstat.isSymbolicLink()) {
        throw new HttpError(400, "path_is_symlink", "file_path must not be a symlink");
      }
      stat = await fs.stat(resolved);
    } catch (err) {
      if (err instanceof HttpError) throw err;
      throw new HttpError(404, "file_not_found", "file_path does not exist");
    }
    if (!stat.isFile()) {
      throw new HttpError(400, "not_a_file", "file_path is not a regular file");
    }
    if (stat.size > MAX_PAYLOAD_BYTES) {
      throw new HttpError(
        413,
        "payload_too_large",
        `payload is ${stat.size} bytes; max is ${MAX_PAYLOAD_BYTES} (4 MiB)`,
      );
    }
    return new Uint8Array(await fs.readFile(resolved));
  }

  const data = ensureString(body.data, "data", { allowEmpty: true });
  const encoding =
    body.data_encoding === undefined ? "utf8" : ensureString(body.data_encoding, "data_encoding");
  if (encoding === "utf8") {
    return new TextEncoder().encode(data);
  }
  if (encoding === "base64") {
    return new Uint8Array(Buffer.from(data, "base64"));
  }
  throw new HttpError(400, "bad_request", '"data_encoding" must be "utf8" or "base64"');
}

/** Derive a fresh d_tag from the title. Derived slugs never silently reuse an
 *  existing artifact's slug — collisions suffix -2, -3, … (an EXPLICIT d_tag
 *  is how callers say "republish"). */
async function deriveDTag(title: string | null): Promise<string> {
  const base = slugify(title ?? "");
  if (base.length === 0) {
    return `artifact-${randomSlugSuffix()}`;
  }
  const rows = await entity.list({ type: ENTITY_TYPE, limit: 1000 });
  if (rows.length === 1000) console.warn("[DEBUG] studio_artifact list hit limit=1000 in deriveDTag — pagination not yet implemented");
  const taken = new Set<string>();
  for (const row of rows) {
    const dTag = parseAttrs(row.attributes)["dTag"];
    if (typeof dTag === "string") taken.add(dTag);
  }
  const first = base.slice(0, 64);
  if (!taken.has(first)) return first;
  for (let n = 2; ; n++) {
    const suffix = `-${n}`;
    const candidate = `${base.slice(0, 64 - suffix.length)}${suffix}`;
    if (!taken.has(candidate)) return candidate;
  }
}

// ── studio_artifact_list ────────────────────────────────────────────────────

async function listArtifacts(
  req: ArtifactListRequest,
  ctx: ActionCtx,
): Promise<ArtifactListResult> {
  const filter = req.filter === undefined ? "personal" : ensureString(req.filter, "filter");
  if (filter === "room") {
    return { artifacts: [], v2_marker: "room-filter-v2" };
  }
  if (filter !== "personal") {
    throw new HttpError(400, "bad_request", '"filter" must be "personal" or "room"');
  }
  const limitRaw = req.limit !== undefined ? Number(req.limit) : 50;
  const limit = Math.max(1, Math.min(200, Math.floor(Number.isFinite(limitRaw) ? limitRaw : 50)));
  const offsetRaw = req.offset !== undefined ? Number(req.offset) : 0;
  const offset = Math.max(0, Math.floor(Number.isFinite(offsetRaw) ? offsetRaw : 0));
  const includeRevoked = !(req.include_revoked === false || req.include_revoked === "false");

  const rows = await entity.list({ type: ENTITY_TYPE, limit: 1000 });
  if (rows.length === 1000) console.warn("[DEBUG] studio_artifact list hit limit=1000 in listArtifacts — pagination not yet implemented");
  const keyCache = new Map<string, Uint8Array | null>();
  const out: ArtifactListEntry[] = [];

  for (const row of rows) {
    if (!row.name.startsWith(ENTITY_PREFIX)) continue;
    const sha = row.name.slice(ENTITY_PREFIX.length);
    const attrs = parseAttrs(row.attributes);
    const dTag = typeof attrs["dTag"] === "string" ? (attrs["dTag"] as string) : null;
    if (!dTag || !HEX64.test(sha)) continue;

    const revoked = attrs["revoked"] === true;
    if (revoked && !includeRevoked) continue;

    if (!keyCache.has(dTag)) {
      keyCache.set(dTag, await loadKeyOrNull(dTag, false));
    }
    const key = keyCache.get(dTag) ?? null;
    const pubkey =
      typeof attrs["pubkey"] === "string"
        ? (attrs["pubkey"] as string)
        : ctx.cfg.pluginPub.toLowerCase();

    const entry: ArtifactListEntry = {
      id: row.id,
      sha256: sha,
      d_tag: dTag,
      pubkey,
      title: typeof attrs["title"] === "string" ? (attrs["title"] as string) : null,
      content_type:
        typeof attrs["contentType"] === "string"
          ? (attrs["contentType"] as string)
          : "application/octet-stream",
      frozen_url: null,
      latest_url: null,
      event_id: typeof attrs["eventId"] === "string" ? (attrs["eventId"] as string) : "",
      published_at_ms: typeof attrs["publishedAtMs"] === "number" ? (attrs["publishedAtMs"] as number) : 0,
      room_id: null,
      revoked,
      revoked_at_ms:
        typeof attrs["revokedAtMs"] === "number" ? (attrs["revokedAtMs"] as number) : null,
      revoked_reason:
        typeof attrs["revokedReason"] === "string" ? (attrs["revokedReason"] as string) : null,
    };
    if (key) {
      const fragment = fragmentFor(key);
      entry.frozen_url = `${ctx.cfg.gatewayBaseUrl}/v0/artifacts/${sha}${fragment}`;
      entry.latest_url = `${ctx.cfg.gatewayBaseUrl}/v0/artifacts/${pubkey}/${dTag}${fragment}`;
    } else {
      // Key secret lost — URLs can't be composed. Existing recipients still
      // hold working URLs; republish under the same dTag is impossible (a
      // fresh K would orphan them), so the UI renders a recovery hint.
      entry.key_missing = true;
    }
    out.push(entry);
  }

  out.sort((a, b) => b.published_at_ms - a.published_at_ms);
  return { artifacts: out.slice(offset, offset + limit) };
}

// ── studio_artifact_revoke ──────────────────────────────────────────────────

async function revokeArtifact(
  body: ArtifactRevokeRequest,
  ctx: ActionCtx,
): Promise<ArtifactRevokeResult> {
  if (body.sha256 === undefined && body.d_tag === undefined) {
    throw new HttpError(400, "bad_request", "at least one of sha256 or d_tag is required");
  }
  let reason: string | null = null;
  if (body.reason !== undefined) {
    reason = ensureString(body.reason, "reason");
    if (reason.length > MAX_REASON_CHARS) {
      throw new HttpError(400, "bad_reason", `"reason" exceeds ${MAX_REASON_CHARS} chars`);
    }
  }
  const pluginPub = ctx.cfg.pluginPub.toLowerCase();

  const tags: string[][] = [];
  if (body.sha256 !== undefined) {
    const sha = ensureString(body.sha256, "sha256").toLowerCase();
    if (!HEX64.test(sha)) {
      throw new HttpError(400, "bad_request", '"sha256" must be 64 hex chars');
    }
    const row = await entity.byNameOrNull(entityName(sha));
    if (!row) {
      throw new HttpError(404, "unknown_sha", `no local artifact row for sha256 ${sha}`);
    }
    const eventId = parseAttrs(row.attributes)["eventId"];
    if (typeof eventId !== "string" || !HEX64.test(eventId)) {
      throw new HttpError(500, "internal_error", `artifact row for ${sha} carries no eventId`);
    }
    tags.push(["e", eventId.toLowerCase()]);
  }
  if (body.d_tag !== undefined) {
    const dTag = ensureDTag(body.d_tag, "d_tag");
    tags.push(["a", `${ARTIFACT_MANIFEST_KIND}:${pluginPub}:${dTag}`]);
  }

  const event = __signEvent(
    {
      pubkey: pluginPub,
      kind: REVOCATION_KIND,
      created_at: Math.floor(Date.now() / 1000),
      tags,
      content: reason ?? "revoked by studio_artifact_revoke",
    },
    ctx.cfg.pluginPriv,
  );

  let resp;
  try {
    resp = await ctx.gateway.revokeArtifact({ event });
  } catch (err) {
    rethrowGateway(err);
  }

  // Flip local rows for every tag the gateway accepted.
  const accepted = resp.revoked ?? [];
  if (accepted.length > 0) {
    const rows = await entity.list({ type: ENTITY_TYPE, limit: 1000 });
    if (rows.length === 1000) console.warn("[DEBUG] studio_artifact list hit limit=1000 in revokeArtifact — pagination not yet implemented");
    const nowMs = Date.now();
    for (const tag of accepted) {
      for (const row of rows) {
        const attrs = parseAttrs(row.attributes);
        const matches =
          tag[0] === "e"
            ? attrs["eventId"] === tag[1]
            : tag[0] === "a" && typeof tag[1] === "string" && attrs["dTag"] === tag[1].split(":")[2];
        if (!matches) continue;
        await entity.patch({
          id: row.id,
          attributes: {
            ...attrs,
            revoked: true,
            revokedAtMs: nowMs,
            revokedReason: reason,
          },
        });
      }
    }
  }

  return { revoked: accepted, skipped: resp.skipped ?? [] };
}

// ── Exported namespace (mirrors card.ts / fileAttach.ts) ────────────────────

export const artifact = {
  publish(body: unknown, ctx: ActionCtx): Promise<ArtifactPublishResult> {
    return publishArtifact((body ?? {}) as ArtifactPublishRequest, ctx);
  },
  list(req: unknown, ctx: ActionCtx): Promise<ArtifactListResult> {
    return listArtifacts((req ?? {}) as ArtifactListRequest, ctx);
  },
  revoke(body: unknown, ctx: ActionCtx): Promise<ArtifactRevokeResult> {
    return revokeArtifact((body ?? {}) as ArtifactRevokeRequest, ctx);
  },
};
