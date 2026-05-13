// Per-room storage_config actions.
//
// A Studio room defaults to the hosted Blossom backend, but a room owner can
// switch to a custom Blossom URL or to BYO S3-compatible storage (R2, AWS S3,
// MinIO, Wasabi, Backblaze B2). Per-room because federation lives at the
// room level — every member of a room reads/writes through the same backend.
//
// Wire shape — persisted on the studio_room entity's `attributes.storage_config`:
//   { kind: "blossom", blossom_url: "..." }
//   { kind: "s3", s3_endpoint, s3_region, s3_bucket, s3_path_style,
//     s3_access_key_id_keychain_ref, s3_secret_access_key_keychain_ref }
//
// Secrets stay in macOS Keychain on the renderer side; the entity attrs only
// carry references. The plugin receives raw credentials per-call (as the
// `s3_credentials` body param on file/image-attach) — it never persists raw
// secrets.

import { entity } from "../memory-client";
import {
  parseS3Error,
  signDeleteObject,
  signGetObject,
  signPutObject,
  validateS3Credentials,
  validateStorageConfig,
  type StorageConfig,
} from "../storage/s3";

import {
  HttpError,
  ensureSlug,
  loadRoomCtx,
} from "./util";
import type { ActionCtx } from "./room";

// Singleton entity for plugin-wide settings (auto-run uses this same row).
const USER_PROFILE_NAME = "studio:user_profile";
const USER_PROFILE_TYPE = "studio_user_profile";

// ── Helpers ─────────────────────────────────────────────────────────────────

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

/**
 * Read the explicit per-room storage_config override. Returns null when the
 * room has no override (caller should fall back to the global default).
 * Throws HttpError(404) if the room slug is unknown.
 *
 * `validate` is true by default — corrupt configs are surfaced rather than
 * silently coerced. The fileAttach hot path can pass `validate: false` and
 * fall back to the default-resolution chain on bad data so an upload never
 * fails just because of a malformed config row.
 */
export async function readRoomStorageOverride(
  roomSlug: string,
  opts: { validate?: boolean } = {},
): Promise<StorageConfig | null> {
  const ent = await entity.byNameOrNull(`studio:room:${roomSlug}`);
  if (!ent) {
    throw new HttpError(404, "room_not_found", `no local studio_room for slug "${roomSlug}"`);
  }
  const attrs = parseAttrs(ent.attributes);
  const raw = attrs["storage_config"];
  if (raw == null) return null;
  const r = validateStorageConfig(raw);
  if (!r.ok) {
    if (opts.validate === false) return null;
    throw new HttpError(
      500,
      r.error.code,
      `room ${roomSlug} storage_config: ${r.error.field} ${r.error.reason}`,
    );
  }
  return r.config;
}

/**
 * Read the user-level default storage_config (singleton on studio:user_profile,
 * attribute `default_storage_config`). Returns null when no default has been
 * configured — caller falls back to the hosted Blossom URL.
 */
export async function readDefaultStorageConfig(
  opts: { validate?: boolean } = {},
): Promise<StorageConfig | null> {
  const ent = await entity.byNameOrNull(USER_PROFILE_NAME).catch(() => null);
  if (!ent) return null;
  const attrs = parseAttrs(ent.attributes);
  const raw = attrs["default_storage_config"];
  if (raw == null) return null;
  const r = validateStorageConfig(raw);
  if (!r.ok) {
    if (opts.validate === false) return null;
    throw new HttpError(500, r.error.code, `default_storage_config: ${r.error.field} ${r.error.reason}`);
  }
  return r.config;
}

/**
 * Resolve the effective storage config for a room: per-room override wins,
 * then user-default, then null (caller uses hosted Blossom). Never throws on
 * malformed config — the upload path can't fail just because settings rot.
 */
export async function resolveRoomStorageConfig(
  roomSlug: string,
): Promise<StorageConfig | null> {
  const override = await readRoomStorageOverride(roomSlug, { validate: false }).catch(() => null);
  if (override) return override;
  const def = await readDefaultStorageConfig({ validate: false }).catch(() => null);
  return def;
}

// ── Actions ─────────────────────────────────────────────────────────────────

interface SetRequest {
  room?: unknown;
  config?: unknown;
}

interface GetRequest {
  room?: unknown;
}

interface TestRequest {
  config?: unknown;
  credentials?: unknown;
}

async function setStorageConfig(
  body: SetRequest,
  ctx: ActionCtx,
): Promise<{ ok: true; storage_config: StorageConfig | null }> {
  const roomSlug = ensureSlug(body.room, "room");

  // `null` clears the override → fall back to the plugin's global default.
  let cfg: StorageConfig | null = null;
  if (body.config !== null && body.config !== undefined) {
    const v = validateStorageConfig(body.config);
    if (!v.ok) {
      throw new HttpError(400, v.error.code, `${v.error.field}: ${v.error.reason}`);
    }
    cfg = v.config;
  }

  // Membership check — only members may rewrite the room's storage_config.
  // Per spec v0.1: any member can update; founder gating could come later
  // (mirrors how track creation is currently any-member).
  const room = await loadRoomCtx(roomSlug, ctx.cfg.pluginPub);

  const ent = await entity.byNameOrNull(`studio:room:${roomSlug}`);
  if (!ent) {
    throw new HttpError(404, "room_not_found", `studio_room ${roomSlug} disappeared mid-write`);
  }
  const attrs = parseAttrs(ent.attributes);
  if (cfg === null) {
    delete attrs["storage_config"];
  } else {
    attrs["storage_config"] = cfg;
  }
  await entity.patch({ id: ent.id, attributes: attrs });

  void room; // membership check side-effect only
  return { ok: true, storage_config: cfg };
}

async function getStorageConfig(
  body: GetRequest,
  _ctx: ActionCtx,
): Promise<{
  storage_config: StorageConfig | null;
  default_storage_config: StorageConfig | null;
  effective: StorageConfig | null;
  source: "room" | "default" | "hosted_blossom";
}> {
  const roomSlug = ensureSlug(body.room, "room");
  const override = await readRoomStorageOverride(roomSlug, { validate: false }).catch(() => null);
  const def = await readDefaultStorageConfig({ validate: false });
  const effective = override ?? def ?? null;
  const source: "room" | "default" | "hosted_blossom" = override
    ? "room"
    : def
    ? "default"
    : "hosted_blossom";
  return {
    storage_config: override,
    default_storage_config: def,
    effective,
    source,
  };
}

async function setDefaultStorageConfig(
  body: { config?: unknown },
  _ctx: ActionCtx,
): Promise<{ ok: true; default_storage_config: StorageConfig | null }> {
  let cfg: StorageConfig | null = null;
  if (body.config !== null && body.config !== undefined) {
    const v = validateStorageConfig(body.config);
    if (!v.ok) {
      throw new HttpError(400, v.error.code, `${v.error.field}: ${v.error.reason}`);
    }
    cfg = v.config;
  }

  const existing = await entity.byNameOrNull(USER_PROFILE_NAME).catch(() => null);
  const priorAttrs = parseAttrs(existing?.attributes);
  if (cfg === null) {
    delete priorAttrs["default_storage_config"];
  } else {
    priorAttrs["default_storage_config"] = cfg;
  }
  if (existing) {
    await entity.patch({ id: existing.id, attributes: priorAttrs });
  } else {
    await entity.upsert({
      name: USER_PROFILE_NAME,
      type: USER_PROFILE_TYPE,
      description: "Local default profile (machine-only, not federated directly)",
      attributes: priorAttrs,
    });
  }
  return { ok: true, default_storage_config: cfg };
}

async function getDefaultStorageConfig(
  _body: unknown,
  _ctx: ActionCtx,
): Promise<{ default_storage_config: StorageConfig | null }> {
  const cfg = await readDefaultStorageConfig({ validate: false });
  return { default_storage_config: cfg };
}

async function testStorageConfig(
  body: TestRequest,
  _ctx: ActionCtx,
): Promise<{
  ok: boolean;
  kind: "blossom" | "s3";
  detail: string;
  upload_url?: string;
}> {
  const v = validateStorageConfig(body.config);
  if (!v.ok) {
    throw new HttpError(400, v.error.code, `${v.error.field}: ${v.error.reason}`);
  }
  const cfg = v.config;

  if (cfg.kind === "blossom") {
    // Blossom doesn't have a standardized HEAD; ping the base URL.
    const url = cfg.blossom_url.replace(/\/+$/, "");
    try {
      const r = await fetch(url, { method: "GET" });
      if (r.status >= 500) {
        return { ok: false, kind: "blossom", detail: `${url} → ${r.status}` };
      }
      return { ok: true, kind: "blossom", detail: `${url} reachable (${r.status})` };
    } catch (err) {
      return {
        ok: false,
        kind: "blossom",
        detail: `${url} unreachable: ${err instanceof Error ? err.message : String(err)}`,
      };
    }
  }

  // S3: upload a probe object, GET it, delete it.
  const cred = validateS3Credentials(body.credentials);
  if (!cred.ok) {
    throw new HttpError(400, "missing_credentials", cred.error);
  }

  const probeKey = `studio/.connection-test/${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  const probeBody = new TextEncoder().encode("sonata-studio probe");

  const putReq = signPutObject({
    endpoint: cfg.s3_endpoint,
    region: cfg.s3_region,
    bucket: cfg.s3_bucket,
    key: probeKey,
    body: probeBody,
    pathStyle: cfg.s3_path_style,
    accessKeyId: cred.credentials.access_key_id,
    secretAccessKey: cred.credentials.secret_access_key,
    contentType: "text/plain",
  });

  let putResp: Response;
  try {
    putResp = await fetch(putReq.url, {
      method: "PUT",
      headers: putReq.headers,
      body: probeBody,
    });
  } catch (err) {
    return {
      ok: false,
      kind: "s3",
      detail: `PUT ${putReq.url} unreachable: ${err instanceof Error ? err.message : String(err)}`,
    };
  }
  if (!putResp.ok) {
    const text = await putResp.text().catch(() => "");
    const err = parseS3Error(putResp.status, text);
    return { ok: false, kind: "s3", detail: err.message };
  }

  // GET to confirm round-trip.
  const getReq = signGetObject({
    endpoint: cfg.s3_endpoint,
    region: cfg.s3_region,
    bucket: cfg.s3_bucket,
    key: probeKey,
    pathStyle: cfg.s3_path_style,
    accessKeyId: cred.credentials.access_key_id,
    secretAccessKey: cred.credentials.secret_access_key,
  });
  let getOk = false;
  try {
    const r = await fetch(getReq.url, { method: "GET", headers: getReq.headers });
    getOk = r.ok;
    if (!r.ok) {
      const text = await r.text().catch(() => "");
      const err = parseS3Error(r.status, text);
      // Try to clean up regardless of GET status.
      void cleanupProbe(cfg, cred.credentials, probeKey);
      return { ok: false, kind: "s3", detail: `GET failed: ${err.message}` };
    }
  } catch (err) {
    void cleanupProbe(cfg, cred.credentials, probeKey);
    return {
      ok: false,
      kind: "s3",
      detail: `GET unreachable: ${err instanceof Error ? err.message : String(err)}`,
    };
  }

  // Delete the probe. Don't fail the overall test if delete fails — the
  // PUT+GET round-trip is what matters; cleanup is best-effort.
  void cleanupProbe(cfg, cred.credentials, probeKey);

  return {
    ok: getOk,
    kind: "s3",
    detail: `PUT + GET round-trip succeeded for ${cfg.s3_bucket}`,
    upload_url: putReq.url,
  };
}

async function cleanupProbe(
  cfg: { s3_endpoint: string; s3_region: string; s3_bucket: string; s3_path_style: boolean },
  creds: { access_key_id: string; secret_access_key: string },
  probeKey: string,
): Promise<void> {
  try {
    const delReq = signDeleteObject({
      endpoint: cfg.s3_endpoint,
      region: cfg.s3_region,
      bucket: cfg.s3_bucket,
      key: probeKey,
      pathStyle: cfg.s3_path_style,
      accessKeyId: creds.access_key_id,
      secretAccessKey: creds.secret_access_key,
    });
    await fetch(delReq.url, { method: "DELETE", headers: delReq.headers });
  } catch {
    // best-effort cleanup
  }
}

export const storage = {
  set: setStorageConfig,
  get: getStorageConfig,
  test: testStorageConfig,
  setDefault: setDefaultStorageConfig,
  getDefault: getDefaultStorageConfig,
};
