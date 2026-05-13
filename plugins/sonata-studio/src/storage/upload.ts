// Storage backend dispatch — given a room's storage_config + a ciphertext
// blob (already encrypted under the room's audience epoch), upload it to
// either Blossom or BYO S3 and return a stable mirror URL.
//
// Shared by both fileAttach.ts and imageAttach.ts.

import { __signEvent, type NostrEvent } from "../crypto/nip17";

import {
  parseS3Error,
  signPutObject,
  validateS3Credentials,
  type S3Credentials,
  type StorageConfig,
} from "./s3";

const BLOSSOM_AUTH_KIND = 24242;

export interface UploadArgs {
  /** Resolved storage config; null → DEFAULT_BLOSSOM_URL. */
  config: StorageConfig | null;
  /** Default Blossom URL when config === null OR kind === "blossom" without url. */
  defaultBlossomURL: string;
  /** Bytes to PUT (ciphertext). */
  ciphertext: Uint8Array;
  /** sha256 hex of the ciphertext — used as the object key and Blossom hash. */
  ciphertextSha256Hex: string;
  /** Plugin signing keypair (used to sign Blossom BUD-01 auth events). */
  pluginPriv: Uint8Array;
  pluginPub: string;
  /** Room slug — used as a key prefix on S3 to keep multiple rooms organized. */
  roomSlug: string;
  /**
   * Caller-provided S3 creds (rendered passes them in the action body). Required
   * when config.kind === "s3"; rejected with `missing_s3_credentials` otherwise.
   */
  s3Credentials?: unknown;
}

export interface UploadResult {
  /** Final mirror URL the file/image block should record. */
  mirror_url: string;
  /** "blossom" | "s3" */
  backend: "blossom" | "s3";
}

export class StorageUploadError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "StorageUploadError";
  }
}

/**
 * Upload an already-encrypted blob to whichever backend the room is
 * configured for. Returns the mirror URL the caller should record on the
 * file/image block.
 */
export async function uploadCiphertext(args: UploadArgs): Promise<UploadResult> {
  const kind = args.config?.kind ?? "blossom";

  if (kind === "s3") {
    if (!args.config || args.config.kind !== "s3") {
      throw new StorageUploadError(500, "internal_error", "kind mismatch (unreachable)");
    }
    return uploadToS3(args, args.config);
  }

  // Blossom path. Use config's URL when provided; else fall back to default.
  const blossomURL =
    args.config && args.config.kind === "blossom"
      ? args.config.blossom_url
      : args.defaultBlossomURL;
  return uploadToBlossom(args, blossomURL);
}

// ── Blossom ─────────────────────────────────────────────────────────────────

async function uploadToBlossom(args: UploadArgs, blossomURL: string): Promise<UploadResult> {
  const authEvent = signBlossomAuthEvent({
    pluginPriv: args.pluginPriv,
    pluginPub: args.pluginPub,
    sha256: args.ciphertextSha256Hex,
    action: "upload",
  });
  const authB64 = btoa(JSON.stringify(authEvent));

  const uploadURL = `${blossomURL.replace(/\/+$/, "")}/upload`;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 5 * 60 * 1000);

  let response: Response;
  try {
    response = await fetch(uploadURL, {
      method: "PUT",
      headers: {
        "Content-Type": "application/octet-stream",
        Authorization: `Nostr ${authB64}`,
      },
      body: args.ciphertext,
      signal: controller.signal,
    });
  } catch (err) {
    clearTimeout(timeout);
    throw new StorageUploadError(
      502,
      "blossom_unreachable",
      `failed to PUT ${uploadURL}: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
  clearTimeout(timeout);

  if (!response.ok) {
    const text = await response.text().catch(() => "<no body>");
    throw new StorageUploadError(
      response.status >= 500 ? 502 : 400,
      "blossom_rejected",
      `Blossom ${response.status}: ${text}`,
    );
  }

  const respJson = (await response.json()) as { sha256?: string; url?: string };
  if (
    typeof respJson.sha256 !== "string" ||
    respJson.sha256.toLowerCase() !== args.ciphertextSha256Hex
  ) {
    throw new StorageUploadError(
      502,
      "blossom_response_invalid",
      `Blossom returned sha256=${respJson.sha256} but we sent sha256=${args.ciphertextSha256Hex}`,
    );
  }

  const mirrorURL =
    typeof respJson.url === "string" && respJson.url.length > 0
      ? respJson.url
      : `${blossomURL.replace(/\/+$/, "")}/${args.ciphertextSha256Hex}`;

  return { mirror_url: mirrorURL, backend: "blossom" };
}

interface BlossomAuthArgs {
  pluginPriv: Uint8Array;
  pluginPub: string;
  sha256: string;
  action: "upload" | "get" | "list" | "delete";
}

function signBlossomAuthEvent(args: BlossomAuthArgs): NostrEvent {
  const createdAt = Math.floor(Date.now() / 1000);
  const tags: string[][] = [
    ["t", args.action],
    ["x", args.sha256],
    ["expiration", String(createdAt + 60)],
  ];
  return __signEvent(
    {
      pubkey: args.pluginPub.toLowerCase(),
      kind: BLOSSOM_AUTH_KIND,
      created_at: createdAt,
      tags,
      content: `Sonata Studio ${args.action}`,
    },
    args.pluginPriv,
  );
}

// ── S3 ──────────────────────────────────────────────────────────────────────

async function uploadToS3(
  args: UploadArgs,
  cfg: Extract<StorageConfig, { kind: "s3" }>,
): Promise<UploadResult> {
  const credsResult = validateS3Credentials(args.s3Credentials);
  if (!credsResult.ok) {
    throw new StorageUploadError(400, "missing_s3_credentials", credsResult.error);
  }
  const creds: S3Credentials = credsResult.credentials;

  // Object key: studio/<roomSlug>/<sha256>. Single bucket can host many rooms.
  const objectKey = `studio/${args.roomSlug}/${args.ciphertextSha256Hex}`;

  const signed = signPutObject({
    endpoint: cfg.s3_endpoint,
    region: cfg.s3_region,
    bucket: cfg.s3_bucket,
    key: objectKey,
    body: args.ciphertext,
    pathStyle: cfg.s3_path_style,
    accessKeyId: creds.access_key_id,
    secretAccessKey: creds.secret_access_key,
    contentType: "application/octet-stream",
  });

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 5 * 60 * 1000);

  let response: Response;
  try {
    response = await fetch(signed.url, {
      method: "PUT",
      headers: signed.headers,
      body: args.ciphertext,
      signal: controller.signal,
    });
  } catch (err) {
    clearTimeout(timeout);
    throw new StorageUploadError(
      502,
      "s3_unreachable",
      `failed to PUT ${signed.url}: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
  clearTimeout(timeout);

  if (!response.ok) {
    const text = await response.text().catch(() => "");
    const err = parseS3Error(response.status, text);
    throw new StorageUploadError(
      response.status >= 500 ? 502 : 400,
      err.code,
      err.message,
    );
  }

  // If the bucket has a public-read URL configured, use that as the mirror —
  // it's what room members hit on download (no SigV4 auth). The signed URL
  // is the API endpoint and requires auth on GET even with a public bucket.
  const publicBase = cfg.s3_public_url_base;
  const mirrorURL = publicBase
    ? `${publicBase}/${objectKey}`
    : signed.url;
  return { mirror_url: mirrorURL, backend: "s3" };
}
