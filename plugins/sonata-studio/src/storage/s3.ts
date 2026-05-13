// S3 SigV4 request signing — pure functions. No SDK.
//
// Used by BYO-S3 storage for Studio room attachments. Builds canonical
// request → string-to-sign → signature → Authorization header per
// https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-request-examples.html.
//
// HMAC primitive comes from @noble/hashes; payload sha256 from node:crypto.
//
// Path-style is the default (R2 requires it; AWS allows it on most regions).
// Virtual-hosted-style is opt-in via `pathStyle: false`.

import { hmac } from "@noble/hashes/hmac.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex } from "@noble/hashes/utils.js";

const SERVICE = "s3";
const ALGO = "AWS4-HMAC-SHA256";
const UNSIGNED_PAYLOAD = "UNSIGNED-PAYLOAD";

export interface S3SignArgs {
  endpoint: string;
  region: string;
  bucket: string;
  key: string;
  accessKeyId: string;
  secretAccessKey: string;
  /** Default true (R2). Set false for virtual-hosted-style URLs (AWS modern). */
  pathStyle?: boolean;
  /** Override the wall-clock time used for signing (ISO 8601 basic). Test hook. */
  nowIsoBasic?: string;
}

export interface S3PutArgs extends S3SignArgs {
  body: Uint8Array;
  contentType?: string;
  /** If true, hash the payload and sign with that hex; else use UNSIGNED-PAYLOAD. */
  signPayload?: boolean;
}

export interface S3GetArgs extends S3SignArgs {}
export interface S3HeadArgs extends S3SignArgs {}

export interface SignedRequest {
  url: string;
  headers: Record<string, string>;
}

// ── Public API ──────────────────────────────────────────────────────────────

export function signPutObject(args: S3PutArgs): SignedRequest {
  const payloadHash = args.signPayload === true ? sha256Hex(args.body) : UNSIGNED_PAYLOAD;
  return sign({
    ...args,
    method: "PUT",
    payloadHash,
    extraHeaders: args.contentType ? { "content-type": args.contentType } : {},
  });
}

export function signGetObject(args: S3GetArgs): SignedRequest {
  return sign({
    ...args,
    method: "GET",
    payloadHash: emptyBodySha256(),
    extraHeaders: {},
  });
}

export function signHeadObject(args: S3HeadArgs): SignedRequest {
  return sign({
    ...args,
    method: "HEAD",
    payloadHash: emptyBodySha256(),
    extraHeaders: {},
  });
}

// DELETE — used by the connection-test action to clean up the probe object.
export function signDeleteObject(args: S3SignArgs): SignedRequest {
  return sign({
    ...args,
    method: "DELETE",
    payloadHash: emptyBodySha256(),
    extraHeaders: {},
  });
}

// ── URL builders ────────────────────────────────────────────────────────────

/**
 * Build the request URL for `bucket/key` under `endpoint`. Path-style:
 *   https://<host>/<bucket>/<key>
 * Virtual-hosted-style:
 *   https://<bucket>.<host>/<key>
 *
 * `endpoint` may be passed with or without a scheme. If no scheme, defaults
 * to https.
 */
export function buildS3Url(args: {
  endpoint: string;
  bucket: string;
  key: string;
  pathStyle?: boolean;
}): { url: string; host: string; canonicalUri: string } {
  const { protocol, host } = parseEndpoint(args.endpoint);
  const encodedKey = encodeS3Key(args.key);
  if (args.pathStyle !== false) {
    return {
      url: `${protocol}//${host}/${encodeURIComponent(args.bucket)}/${encodedKey}`,
      host,
      canonicalUri: `/${encodeURIComponent(args.bucket)}/${encodedKey}`,
    };
  }
  return {
    url: `${protocol}//${args.bucket}.${host}/${encodedKey}`,
    host: `${args.bucket}.${host}`,
    canonicalUri: `/${encodedKey}`,
  };
}

// ── Core sign ───────────────────────────────────────────────────────────────

interface SignCore extends S3SignArgs {
  method: "GET" | "PUT" | "HEAD" | "DELETE";
  payloadHash: string;
  extraHeaders: Record<string, string>;
}

function sign(args: SignCore): SignedRequest {
  const { url, host, canonicalUri } = buildS3Url({
    endpoint: args.endpoint,
    bucket: args.bucket,
    key: args.key,
    pathStyle: args.pathStyle,
  });

  const isoBasic = args.nowIsoBasic ?? toIsoBasic(new Date());
  const dateStamp = isoBasic.slice(0, 8); // YYYYMMDD

  const headers: Record<string, string> = {
    host,
    "x-amz-content-sha256": args.payloadHash,
    "x-amz-date": isoBasic,
    ...args.extraHeaders,
  };

  // Canonical request
  const signedHeaderNames = Object.keys(headers)
    .map((h) => h.toLowerCase())
    .sort();
  const signedHeaders = signedHeaderNames.join(";");
  const canonicalHeaders =
    signedHeaderNames
      .map((h) => `${h}:${String(headers[h] ?? headersByLowerKey(headers, h)).trim()}`)
      .join("\n") + "\n";
  const canonicalQuery = ""; // No query in v0; presigned URLs are a future card.
  const canonicalRequest = [
    args.method,
    canonicalUri,
    canonicalQuery,
    canonicalHeaders,
    signedHeaders,
    args.payloadHash,
  ].join("\n");

  // String-to-sign
  const credentialScope = `${dateStamp}/${args.region}/${SERVICE}/aws4_request`;
  const stringToSign = [
    ALGO,
    isoBasic,
    credentialScope,
    sha256Hex(textEncode(canonicalRequest)),
  ].join("\n");

  // Signing key derivation
  const kDate = hmacBytes(textEncode(`AWS4${args.secretAccessKey}`), dateStamp);
  const kRegion = hmacBytes(kDate, args.region);
  const kService = hmacBytes(kRegion, SERVICE);
  const kSigning = hmacBytes(kService, "aws4_request");
  const signature = bytesToHex(hmacBytes(kSigning, stringToSign));

  const authorization =
    `${ALGO} Credential=${args.accessKeyId}/${credentialScope}` +
    `, SignedHeaders=${signedHeaders}` +
    `, Signature=${signature}`;

  return {
    url,
    headers: { ...headers, Authorization: authorization },
  };
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function parseEndpoint(endpoint: string): { protocol: string; host: string } {
  const trimmed = endpoint.replace(/\/+$/, "");
  const withScheme = /^[a-z]+:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
  const m = /^([a-z]+:)\/\/([^/]+)/i.exec(withScheme);
  if (!m) throw new Error(`invalid s3 endpoint: ${endpoint}`);
  return { protocol: m[1]!, host: m[2]! };
}

/**
 * Encode an S3 object key for use in a URL path. Per SigV4, RFC 3986
 * unreserved chars stay; `/` stays (S3 treats it as path); everything else
 * percent-encoded. encodeURIComponent is closer but encodes `/`; we splice.
 */
export function encodeS3Key(key: string): string {
  return key
    .split("/")
    .map((seg) =>
      encodeURIComponent(seg)
        .replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`),
    )
    .join("/");
}

function toIsoBasic(d: Date): string {
  // YYYYMMDDTHHMMSSZ
  const pad = (n: number) => String(n).padStart(2, "0");
  return (
    d.getUTCFullYear().toString() +
    pad(d.getUTCMonth() + 1) +
    pad(d.getUTCDate()) +
    "T" +
    pad(d.getUTCHours()) +
    pad(d.getUTCMinutes()) +
    pad(d.getUTCSeconds()) +
    "Z"
  );
}

function sha256Hex(data: Uint8Array): string {
  return bytesToHex(sha256(data));
}

function emptyBodySha256(): string {
  // sha256("")
  return "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
}

function textEncode(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

function hmacBytes(key: Uint8Array, msg: string | Uint8Array): Uint8Array {
  const m = typeof msg === "string" ? textEncode(msg) : msg;
  return hmac(sha256, key, m);
}

// Headers lookup is case-insensitive — but our `headers` map is built with
// lowercase keys already, so this is a defensive fallback.
function headersByLowerKey(h: Record<string, string>, lower: string): string {
  for (const k of Object.keys(h)) {
    if (k.toLowerCase() === lower) return h[k] ?? "";
  }
  return "";
}

// ── Typed errors ────────────────────────────────────────────────────────────

export class S3UploadError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "S3UploadError";
  }
}

/**
 * Parse an S3 XML error body and return a typed error. Falls back to the
 * raw text if no `<Code>` is present.
 */
export function parseS3Error(status: number, body: string): S3UploadError {
  const codeMatch = /<Code>([^<]+)<\/Code>/i.exec(body);
  const msgMatch = /<Message>([^<]+)<\/Message>/i.exec(body);
  const code = codeMatch ? codeMatch[1]! : "s3_http_error";
  const msg = msgMatch ? msgMatch[1]! : body.slice(0, 200);
  return new S3UploadError(status, code, `S3 ${status} ${code}: ${msg}`);
}

// ── Config types + validation ───────────────────────────────────────────────

export type StorageKind = "blossom" | "s3";

export interface BlossomStorageConfig {
  kind: "blossom";
  blossom_url: string;
}

export interface S3StorageConfig {
  kind: "s3";
  s3_endpoint: string;
  s3_region: string;
  s3_bucket: string;
  s3_path_style: boolean;
  s3_access_key_id_keychain_ref: string;
  s3_secret_access_key_keychain_ref: string;
  /**
   * Optional public URL base — the prefix used to construct the mirror URL
   * the *renderer* uses to fetch the ciphertext (no auth). Without it, the
   * mirror URL is the signed PUT URL on the S3 API endpoint, which requires
   * SigV4 auth on GET even when the bucket is public.
   *
   * R2: bucket public access → e.g. https://pub-<hash>.r2.dev
   * AWS S3 with public-read: https://<bucket>.s3.<region>.amazonaws.com
   * (Set if the bucket allows public reads. If unset we fall back to the
   * signed S3 API URL — works only when readers also have credentials.)
   */
  s3_public_url_base?: string;
}

export type StorageConfig = BlossomStorageConfig | S3StorageConfig;

export interface StorageConfigValidationError {
  code: "invalid_storage_config";
  field: string;
  reason: string;
}

/**
 * Validate a storage_config object. Returns the validated, narrowed config
 * on success or an error describing the first failing field.
 */
export function validateStorageConfig(
  raw: unknown,
):
  | { ok: true; config: StorageConfig }
  | { ok: false; error: StorageConfigValidationError } {
  if (raw === null || typeof raw !== "object") {
    return {
      ok: false,
      error: { code: "invalid_storage_config", field: "(root)", reason: "must be an object" },
    };
  }
  const obj = raw as Record<string, unknown>;
  const kind = obj["kind"];
  if (kind === "blossom") {
    const url = obj["blossom_url"];
    if (typeof url !== "string" || url.length === 0) {
      return {
        ok: false,
        error: { code: "invalid_storage_config", field: "blossom_url", reason: "must be a non-empty string" },
      };
    }
    return { ok: true, config: { kind: "blossom", blossom_url: url } };
  }
  if (kind === "s3") {
    const endpoint = obj["s3_endpoint"];
    const region = obj["s3_region"];
    const bucket = obj["s3_bucket"];
    const pathStyle = obj["s3_path_style"];
    const keyRef = obj["s3_access_key_id_keychain_ref"];
    const secRef = obj["s3_secret_access_key_keychain_ref"];
    if (typeof endpoint !== "string" || endpoint.length === 0) {
      return {
        ok: false,
        error: { code: "invalid_storage_config", field: "s3_endpoint", reason: "must be a non-empty string" },
      };
    }
    if (typeof region !== "string" || region.length === 0) {
      return {
        ok: false,
        error: { code: "invalid_storage_config", field: "s3_region", reason: "must be a non-empty string" },
      };
    }
    if (typeof bucket !== "string" || bucket.length === 0) {
      return {
        ok: false,
        error: { code: "invalid_storage_config", field: "s3_bucket", reason: "must be a non-empty string" },
      };
    }
    if (typeof pathStyle !== "boolean") {
      return {
        ok: false,
        error: { code: "invalid_storage_config", field: "s3_path_style", reason: "must be a boolean" },
      };
    }
    if (typeof keyRef !== "string" || keyRef.length === 0) {
      return {
        ok: false,
        error: {
          code: "invalid_storage_config",
          field: "s3_access_key_id_keychain_ref",
          reason: "must be a non-empty string",
        },
      };
    }
    if (typeof secRef !== "string" || secRef.length === 0) {
      return {
        ok: false,
        error: {
          code: "invalid_storage_config",
          field: "s3_secret_access_key_keychain_ref",
          reason: "must be a non-empty string",
        },
      };
    }
    const publicBaseRaw = obj["s3_public_url_base"];
    let publicBase: string | undefined;
    if (publicBaseRaw !== undefined && publicBaseRaw !== null && publicBaseRaw !== "") {
      if (typeof publicBaseRaw !== "string") {
        return {
          ok: false,
          error: {
            code: "invalid_storage_config",
            field: "s3_public_url_base",
            reason: "must be a string when provided",
          },
        };
      }
      publicBase = publicBaseRaw.replace(/\/+$/, "");
    }
    return {
      ok: true,
      config: {
        kind: "s3",
        s3_endpoint: endpoint,
        s3_region: region,
        s3_bucket: bucket,
        s3_path_style: pathStyle,
        s3_access_key_id_keychain_ref: keyRef,
        s3_secret_access_key_keychain_ref: secRef,
        ...(publicBase !== undefined ? { s3_public_url_base: publicBase } : {}),
      },
    };
  }
  return {
    ok: false,
    error: {
      code: "invalid_storage_config",
      field: "kind",
      reason: 'must be "blossom" or "s3"',
    },
  };
}

export interface S3Credentials {
  access_key_id: string;
  secret_access_key: string;
}

export function validateS3Credentials(
  raw: unknown,
): { ok: true; credentials: S3Credentials } | { ok: false; error: string } {
  if (raw === null || typeof raw !== "object") {
    return { ok: false, error: "s3_credentials must be an object" };
  }
  const obj = raw as Record<string, unknown>;
  const id = obj["access_key_id"];
  const sec = obj["secret_access_key"];
  if (typeof id !== "string" || id.length === 0) {
    return { ok: false, error: "s3_credentials.access_key_id must be a non-empty string" };
  }
  if (typeof sec !== "string" || sec.length === 0) {
    return { ok: false, error: "s3_credentials.secret_access_key must be a non-empty string" };
  }
  return { ok: true, credentials: { access_key_id: id, secret_access_key: sec } };
}
