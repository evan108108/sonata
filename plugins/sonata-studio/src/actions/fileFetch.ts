// Studio file fetch action — receive-side symmetric to fileAttach.
//
// A card block (produced by fileAttach on a peer) carries:
//   {sha256, blake3, mirrors[], decrypt_hint:{epoch_n, wrapped_key}, filename?}
// plus the author's plugin pubkey on the containing card event.
//
// This action takes those fields and returns a decrypted plaintext file on
// local disk that the caller (a worker session) can then read/process.
//
// Pipeline (mirror image of fileAttach):
//   1. Validate inputs; resolve the epoch's PRIVATE key for room_slug from
//      the epoch_keys secret (either shape — verbose or flat).
//   2. NIP-44 decrypt wrapped_key using (epochPriv, author_pubkey) → 44
//      bytes → (file_key || nonce). Fails distinctly on wrong epoch, wrong
//      author, or MAC mismatch.
//   3. HTTP GET mirror_url. Enforce the same 256 MiB cap fileAttach does so
//      a hostile peer can't drop 100 GiB into ~/.sonata.
//   4. Verify sha256(ciphertext) == sha256; verify blake3(ciphertext) == blake3
//      when the caller supplied one. Distinct error codes so operators can
//      tell a mirror/proxy tamper from a wrong-key decrypt failure.
//   5. ChaCha20-Poly1305 decrypt ciphertext with (file_key, nonce) → plaintext.
//   6. Write plaintext to `~/.sonata/plugins/sonata-studio/scratch/<sha256>/`
//      using the caller's filename (or `blob.bin` fallback). Path is stable
//      across calls — same ciphertext → same on-disk path — so callers can
//      dedupe and workers can re-fetch after a crash without spamming disk.
//   7. Return {file_path, size_bytes, mime_type, sha256_verified,
//      blake3_verified}.
//
// Motivation and the "why was this missing" story: the studio plugin's
// crypto path for inbound blobs lived only inside sse/client.ts, wired into
// automatic gift-wrap unwrapping. No handler exposed it as a call. Scout
// receiving a file-block in the sona-scout-shared-work-space room had no
// tool it could invoke to turn the block into a local file — cost most of a
// day of DM back-and-forth before we realised the plugin literally lacked
// the receive-side action. See project-sonata/bugs card and the 2026-07-09
// AE II DM (message_id d42d643be8594174940afa00db6ec779) for the incident.

import { promises as fs } from "node:fs";
import * as path from "node:path";
import { createHash } from "node:crypto";
import { homedir } from "node:os";

import { chacha20poly1305 } from "@noble/ciphers/chacha.js";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils.js";
import { blake3 } from "@noble/hashes/blake3.js";

import { decrypt as nip44Decrypt } from "../crypto/nip44";
import { secret } from "../memory-client";
import {
  HttpError,
  ensureSlug,
  ensureString,
  loadRoomCtx,
} from "./util";
import type { ActionCtx } from "./room";

// Same hard cap as fileAttach — a peer can only have uploaded at most this
// much, so the fetch side just mirrors the constraint as defense in depth
// against tampered/oversized mirror responses.
const MAX_FILE_BYTES = 256 * 1024 * 1024;
const HEX64_RE = /^[0-9a-f]{64}$/i;

interface FileFetchRequest {
  sha256?: unknown;
  blake3?: unknown;
  wrapped_key?: unknown;
  epoch_n?: unknown;
  room_slug?: unknown;
  mirror_url?: unknown;
  author_pubkey?: unknown;
  filename?: unknown;
  mime_type?: unknown;
}

interface FileFetchResult {
  file_path: string;
  size_bytes: number;
  mime_type: string;
  sha256_verified: boolean;
  blake3_verified: boolean;
}

export async function fetchFile(
  body: FileFetchRequest,
  ctx: ActionCtx,
): Promise<FileFetchResult> {
  // 1. Validate inputs.
  const sha256Hex = ensureLowerHex64(body.sha256, "sha256");
  const wrappedKey = ensureString(body.wrapped_key, "wrapped_key");
  const roomSlug = ensureSlug(body.room_slug, "room_slug");
  const mirrorUrl = ensureString(body.mirror_url, "mirror_url");
  const authorPub = ensureLowerHex64(body.author_pubkey, "author_pubkey");
  const epochN = ensureInteger(body.epoch_n, "epoch_n");
  const blake3ExpectedHex =
    body.blake3 !== undefined && body.blake3 !== null
      ? ensureLowerHex64(body.blake3, "blake3")
      : null;
  const filename = filenameFromBody(body.filename);
  const mimeOverride =
    body.mime_type !== undefined && body.mime_type !== null
      ? ensureString(body.mime_type, "mime_type")
      : null;

  if (!/^https?:\/\//i.test(mirrorUrl)) {
    throw new HttpError(400, "bad_mirror_url", "mirror_url must be an http(s) URL");
  }

  // 2. Load the room + resolve the epoch's private key. We deliberately do
  //    NOT call loadRoomCtx's currentEpoch requirement — file blocks are
  //    often bound to prior epochs (author sent the file before a rotation
  //    landed on the receiver). Load epoch_keys directly for the requested
  //    epoch instead.
  const room = await loadRoomCtx(roomSlug, ctx.cfg.pluginPub);
  const epochPrivHex = await loadEpochPrivHex(room.attributes, roomSlug, epochN);
  if (!epochPrivHex) {
    throw new HttpError(
      404,
      "epoch_key_missing",
      `no local priv for room "${roomSlug}" epoch ${epochN} — receiver was not admitted at that epoch, or key-grant projection hasn't landed yet`,
    );
  }
  const epochPriv = hexToBytes(epochPrivHex);

  // 3. NIP-44 unwrap the wrapped_key. Sender was the author's plugin key;
  //    receiver is us with the epoch's priv. NIP-44 ECDH is symmetric so
  //    (epochPriv, authorPub) recovers the shared secret the author used.
  let keyMaterial: Uint8Array;
  try {
    keyMaterial = nip44Decrypt(wrappedKey, epochPriv, authorPub);
  } catch (err) {
    throw new HttpError(
      400,
      "wrapped_key_decrypt_failed",
      `NIP-44 unwrap failed: ${err instanceof Error ? err.message : String(err)}. Check epoch_n and author_pubkey.`,
    );
  }
  if (keyMaterial.length !== 32 + 12) {
    throw new HttpError(
      400,
      "wrapped_key_shape",
      `unwrapped key material must be 44 bytes (32 file_key + 12 nonce); got ${keyMaterial.length}`,
    );
  }
  const fileKey = keyMaterial.slice(0, 32);
  const nonce = keyMaterial.slice(32, 44);

  // 4. Download ciphertext, enforcing size cap.
  const ciphertext = await downloadWithCap(mirrorUrl, MAX_FILE_BYTES);

  // 5. Verify sha256 (Blossom's key + integrity). Then optional blake3.
  const actualSha256 = createHash("sha256").update(ciphertext).digest("hex");
  if (actualSha256.toLowerCase() !== sha256Hex.toLowerCase()) {
    throw new HttpError(
      502,
      "sha256_mismatch",
      `mirror returned bytes whose sha256 (${actualSha256}) does not match requested sha256 (${sha256Hex}) — mirror or proxy tampered with the ciphertext`,
    );
  }
  let blake3Verified = false;
  if (blake3ExpectedHex) {
    const actualBlake3 = bytesToHex(blake3(ciphertext));
    if (actualBlake3.toLowerCase() !== blake3ExpectedHex.toLowerCase()) {
      throw new HttpError(
        502,
        "blake3_mismatch",
        `ciphertext blake3 (${actualBlake3}) does not match expected (${blake3ExpectedHex})`,
      );
    }
    blake3Verified = true;
  }

  // 6. Decrypt.
  let plaintext: Uint8Array;
  try {
    const cipher = chacha20poly1305(fileKey, nonce);
    plaintext = cipher.decrypt(ciphertext);
  } catch (err) {
    throw new HttpError(
      400,
      "chacha_decrypt_failed",
      `ChaCha20-Poly1305 decrypt failed: ${err instanceof Error ? err.message : String(err)}. wrapped_key unwrapped cleanly but tag verification failed on the ciphertext — the file body was likely modified in transit.`,
    );
  }

  // 7. Write to scoped scratch dir. Path is deterministic on sha256 so a
  //    repeated fetch of the same block goes back to the same path (callers
  //    can dedupe; a worker retrying after a crash doesn't fan disk out).
  const scratchDir = path.join(
    homedir(),
    ".sonata",
    "plugins",
    "sonata-studio",
    "scratch",
    sha256Hex,
  );
  await fs.mkdir(scratchDir, { recursive: true, mode: 0o700 });
  const outPath = path.join(scratchDir, filename);
  await fs.writeFile(outPath, plaintext, { mode: 0o600 });

  return {
    file_path: outPath,
    size_bytes: plaintext.length,
    mime_type: mimeOverride ?? inferMime(filename),
    sha256_verified: true,
    blake3_verified: blake3Verified,
  };
}

// MARK: - Helpers

function ensureLowerHex64(v: unknown, field: string): string {
  const s = ensureString(v, field);
  if (!HEX64_RE.test(s)) {
    throw new HttpError(400, "bad_request", `${field} must be 64 lowercase hex characters`);
  }
  return s.toLowerCase();
}

function ensureInteger(v: unknown, field: string): number {
  if (typeof v !== "number" || !Number.isInteger(v) || v < 1) {
    throw new HttpError(400, "bad_request", `${field} must be a positive integer`);
  }
  return v;
}

// Path-traversal-safe filename: strip any directory components and reject
// empty/reserved names. Fallback to blob.bin. Caller can override mime.
function filenameFromBody(v: unknown): string {
  if (v === undefined || v === null || v === "") return "blob.bin";
  if (typeof v !== "string") return "blob.bin";
  const base = path.basename(v);
  if (base === "" || base === "." || base === "..") return "blob.bin";
  // Belt-and-suspenders: reject anything that still contains a separator
  // after basename (shouldn't happen but cheap guard against surprise).
  if (base.includes("/") || base.includes("\\")) return "blob.bin";
  return base;
}

// Look up a specific epoch's priv from the epoch_keys secret. Honours both
// on-disk shapes (see util.ts:loadRoomCtx comments) so this works whether the
// room was joined via key-grant (flat shape from SSEClient.persistEpochKeys)
// or founded/admitted locally (verbose shape from admit.ts). Returns null if
// the requested epoch isn't present.
async function loadEpochPrivHex(
  attrs: Record<string, unknown>,
  slug: string,
  epochN: number,
): Promise<string | null> {
  const epochSecretName =
    typeof attrs["epoch_keys_secret_name"] === "string"
      ? (attrs["epoch_keys_secret_name"] as string)
      : `studio:room:${slug}:epoch_keys`;
  const got = await secret.getOrNull(epochSecretName);
  if (!got) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(got.value);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  const p = parsed as Record<string, unknown>;
  const key = String(epochN);
  // Verbose form: {epochs: {"<n>": {priv_hex, pub_hex}}}.
  const epochsBlock = p["epochs"];
  if (epochsBlock && typeof epochsBlock === "object" && !Array.isArray(epochsBlock)) {
    const rec = (epochsBlock as Record<string, unknown>)[key];
    if (rec && typeof rec === "object") {
      const priv = (rec as Record<string, unknown>)["priv_hex"];
      if (typeof priv === "string" && HEX64_RE.test(priv)) return priv.toLowerCase();
    }
  }
  // Flat form: {"<n>": "<priv_hex>"}.
  const flat = p[key];
  if (typeof flat === "string" && HEX64_RE.test(flat)) return flat.toLowerCase();
  return null;
}

// Download with a hard byte cap. Aborts the response body as soon as it
// crosses the cap so a hostile mirror can't stream us out of disk.
async function downloadWithCap(url: string, maxBytes: number): Promise<Uint8Array> {
  let res: Response;
  try {
    res = await fetch(url);
  } catch (err) {
    throw new HttpError(
      502,
      "mirror_unreachable",
      `GET ${url} failed: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
  if (!res.ok) {
    throw new HttpError(
      res.status === 404 ? 404 : 502,
      "mirror_error",
      `GET ${url} returned HTTP ${res.status}`,
    );
  }
  // Prefer Content-Length as an early-fail hint before streaming.
  const cl = res.headers.get("content-length");
  if (cl) {
    const n = Number(cl);
    if (Number.isFinite(n) && n > maxBytes) {
      throw new HttpError(
        413,
        "file_too_big",
        `mirror reports Content-Length ${n} > ${maxBytes} byte cap`,
      );
    }
  }
  if (!res.body) {
    // Some polyfills expose only .arrayBuffer(). Fall back with a
    // post-hoc size check.
    const buf = new Uint8Array(await res.arrayBuffer());
    if (buf.length > maxBytes) {
      throw new HttpError(413, "file_too_big", `mirror returned ${buf.length} bytes > ${maxBytes} cap`);
    }
    return buf;
  }
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    if (!value) continue;
    total += value.byteLength;
    if (total > maxBytes) {
      try {
        await reader.cancel();
      } catch {
        /* ignore */
      }
      throw new HttpError(
        413,
        "file_too_big",
        `mirror streaming crossed the ${maxBytes} byte cap`,
      );
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

// Same table fileAttach uses for the outbound path. Kept in sync manually —
// the two live in the same crypto handshake so identical MIME inference is
// a soft consistency guarantee for round-tripped filenames.
function inferMime(filename: string): string {
  const ext = path.extname(filename).toLowerCase();
  switch (ext) {
    case ".pdf":  return "application/pdf";
    case ".zip":  return "application/zip";
    case ".gz":   return "application/gzip";
    case ".tar":  return "application/x-tar";
    case ".json": return "application/json";
    case ".txt":  return "text/plain";
    case ".md":   return "text/markdown";
    case ".csv":  return "text/csv";
    case ".html": return "text/html";
    case ".mp3":  return "audio/mpeg";
    case ".wav":  return "audio/wav";
    case ".mp4":  return "video/mp4";
    case ".mov":  return "video/quicktime";
    case ".png":  return "image/png";
    case ".jpg":
    case ".jpeg": return "image/jpeg";
    case ".gif":  return "image/gif";
    case ".webp": return "image/webp";
    case ".heic": return "image/heic";
    case ".heif": return "image/heif";
    default:      return "application/octet-stream";
  }
}

export const fileFetch = {
  fetch(body: unknown, ctx: ActionCtx): Promise<FileFetchResult> {
    return fetchFile((body ?? {}) as FileFetchRequest, ctx);
  },
};
