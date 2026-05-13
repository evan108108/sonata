// Studio file attach action — encrypt + upload an arbitrary file blob to a
// Blossom server using hybrid encryption (random ChaCha20-Poly1305 file_key,
// NIP-44-wrapped to the room's current audience-epoch key). Returns the
// file-block JSON the compose flow embeds in a card's `blocks` array.
//
// Sibling to imageAttach, but the wire shape differs: a file block carries
// `filename` + `size_bytes` + a `decrypt_hint.kind = "audience-epoch+file-key"`
// envelope. Hybrid encryption lets the same ciphertext be unwrapped by every
// member with the current epoch priv (one bulk encryption, one wrap), so a
// 256 MiB ciphertext doesn't have to be re-encrypted per recipient.
//
// Pipeline:
//   1. Resolve file_path; reject symlinks (same defense as imageAttach).
//   2. Size cap — 256 MiB hard limit, error code `file_too_big`.
//   3. Generate random 32-byte `file_key` + 12-byte nonce.
//   4. ChaCha20-Poly1305 encrypt plaintext with file_key + nonce. Ciphertext
//      length = plaintext.length + 16 (RFC 8439 Poly1305 tag).
//   5. Load room ctx + take a snapshot of `currentEpoch` (audit doc §5.3 — the
//      wrap is bound to the epoch at the moment we read the room, not at the
//      moment the upload returns).
//   6. NIP-44 wrap the 44-byte plaintext `(file_key || nonce)` from pluginPriv
//      → epochPub. The base64 wire string is the `decrypt_hint.wrapped_key`.
//   7. Compute sha256 + blake3 of CIPHERTEXT bytes (Blossom keys by sha256).
//   8. Sign a BUD-01 auth event (kind 24242, t=upload), PUT ciphertext.
//   9. Verify response sha256 matches; return file-block content.
//
// See plumbing audit /Users/evan/memory/claude/documents/evenflow/
//   sonata-studio-phase5-plumbing-audit.md for the crypto round-trip proof
//   and SPEC-v0.5 compatibility check — no spec edits required.

import { promises as fs } from "node:fs";
import * as path from "node:path";
import { createHash, randomBytes as nodeRandomBytes } from "node:crypto";

import { chacha20poly1305 } from "@noble/ciphers/chacha.js";
import { bytesToHex } from "@noble/hashes/utils.js";
import { blake3 } from "@noble/hashes/blake3.js";

import { encrypt as nip44Encrypt } from "../crypto/nip44";
import { __signEvent, type NostrEvent } from "../crypto/nip17";
import {
  HttpError,
  ensureSlug,
  ensureString,
  loadRoomCtx,
} from "./util";
import type { ActionCtx } from "./room";

// 256 MiB hard-cap across all backends — locked-decision 2026-05-13.
// Compose-sheet enforces the same cap at file-pick time; this is the
// server-side defense in depth.
const MAX_FILE_BYTES = 256 * 1024 * 1024;

// BUD-01 authorization event kind (same as imageAttach — Blossom protocol).
const BLOSSOM_AUTH_KIND = 24242;

// Default Blossom server; overridable via ctx.cfg.blossomBaseURL.
const DEFAULT_BLOSSOM_URL = "https://api.4a4.ai/blossom";

interface FileAttachRequest {
  file_path?: unknown;
  room_slug?: unknown;
  mime_type?: unknown;
}

interface FileBlockDecryptHint {
  kind: "audience-epoch+file-key";
  epoch_n: number;
  wrapped_key: string;
}

interface FileAttachResult {
  type: "file";
  filename: string;
  mime_type: string;
  size_bytes: number;
  sha256: string;
  blake3: string;
  mirrors: string[];
  decrypt_hint: FileBlockDecryptHint;
}

export async function attachFile(
  body: FileAttachRequest,
  ctx: ActionCtx,
): Promise<FileAttachResult> {
  const filePathRaw = ensureString(body.file_path, "file_path");
  const roomSlug = ensureSlug(body.room_slug, "room_slug");
  const mimeOverride =
    body.mime_type !== undefined
      ? ensureString(body.mime_type, "mime_type")
      : undefined;

  // 1. Resolve + symlink reject. Same posture as imageAttach: plugin runs as
  //    the user, so any readable path is allowed; symlinks are still rejected
  //    so we don't surprise the user by following a link off to elsewhere.
  const resolved = path.resolve(filePathRaw);
  let stat;
  try {
    const lstat = await fs.lstat(resolved);
    if (lstat.isSymbolicLink()) {
      throw new HttpError(400, "path_is_symlink", `file_path must not be a symlink`);
    }
    stat = await fs.stat(resolved);
  } catch (err) {
    if (err instanceof HttpError) throw err;
    throw new HttpError(404, "file_not_found", `file_path does not exist`);
  }
  if (!stat.isFile()) {
    throw new HttpError(400, "not_a_file", `file_path is not a regular file`);
  }

  // 2. Size cap.
  if (stat.size > MAX_FILE_BYTES) {
    throw new HttpError(
      413,
      "file_too_big",
      `file is ${stat.size} bytes; max is ${MAX_FILE_BYTES} bytes (256 MiB)`,
    );
  }

  const plaintext = await fs.readFile(resolved);

  // 3. Random per-file ChaCha20-Poly1305 key + nonce. Pull from node:crypto
  //    rather than @noble/hashes/utils — see audit §2.1 caveat (the noble
  //    WebCrypto-backed randomBytes caps at 65 536 bytes; node:crypto has no
  //    such cap, and we want large-file paths to never trip a random-source
  //    limit).
  const fileKey = nodeRandomBytes(32);
  const nonce = nodeRandomBytes(12);

  // 4. Bulk-encrypt plaintext under file_key. ChaCha20-Poly1305 appends a
  //    16-byte Poly1305 tag, so ciphertext.length === plaintext.length + 16.
  const cipher = chacha20poly1305(fileKey, nonce);
  const ciphertextBytes = cipher.encrypt(plaintext);

  // 5. Snapshot the room's current epoch BEFORE the upload begins. Bound by
  //    the audit doc §5.3 recommendation: if epoch rotation lands mid-upload,
  //    the wrap stays addressed to the epoch in force when fileAttach started.
  const room = await loadRoomCtx(roomSlug, ctx.cfg.pluginPub);
  const epochAtStart = {
    n: room.currentEpoch,
    pub: room.currentEpochPubHex,
  };

  // 6. NIP-44 wrap the 44-byte (file_key || nonce) plaintext to the
  //    audience-epoch pubkey. The wrapped_key is the base64 wire string the
  //    renderer will hand to NIP44.decrypt to recover both file_key and nonce.
  const keyMaterial = new Uint8Array(32 + 12);
  keyMaterial.set(fileKey, 0);
  keyMaterial.set(nonce, 32);
  const wrappedKey = nip44Encrypt(keyMaterial, ctx.cfg.pluginPriv, epochAtStart.pub);

  // 7. Hashes over CIPHERTEXT bytes (Blossom keys by sha256; blake3 is the
  //    renderer-side integrity check tracked alongside imageAttach).
  const ciphertextSha = sha256Hex(ciphertextBytes);
  const ciphertextBlake = bytesToHex(blake3(ciphertextBytes));

  // 8. BUD-01 auth + PUT.
  const blossomURL = blossomBaseURL(ctx);
  const authEvent = signBlossomAuthEvent({
    pluginPriv: ctx.cfg.pluginPriv,
    pluginPub: ctx.cfg.pluginPub,
    sha256: ciphertextSha,
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
        "Authorization": `Nostr ${authB64}`,
      },
      body: ciphertextBytes,
      signal: controller.signal,
    });
  } catch (err) {
    clearTimeout(timeout);
    throw new HttpError(
      502,
      "blossom_unreachable",
      `failed to PUT ${uploadURL}: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
  clearTimeout(timeout);

  if (!response.ok) {
    const text = await response.text().catch(() => "<no body>");
    throw new HttpError(
      response.status >= 500 ? 502 : 400,
      "upload_failed",
      `Blossom ${response.status}: ${text}`,
    );
  }

  // 9. Verify server-reported sha256.
  const respJson = (await response.json()) as { sha256?: string; url?: string };
  if (
    typeof respJson.sha256 !== "string" ||
    respJson.sha256.toLowerCase() !== ciphertextSha
  ) {
    throw new HttpError(
      502,
      "blossom_response_invalid",
      `Blossom returned sha256=${respJson.sha256} but we sent sha256=${ciphertextSha}`,
    );
  }

  const mirrorURL =
    typeof respJson.url === "string" && respJson.url.length > 0
      ? respJson.url
      : `${blossomURL.replace(/\/+$/, "")}/${ciphertextSha}`;

  return {
    type: "file",
    filename: path.basename(resolved),
    mime_type: mimeOverride ?? inferMime(resolved),
    size_bytes: plaintext.length,
    sha256: ciphertextSha,
    blake3: ciphertextBlake,
    mirrors: [mirrorURL],
    decrypt_hint: {
      kind: "audience-epoch+file-key",
      epoch_n: epochAtStart.n,
      wrapped_key: wrappedKey,
    },
  };
}

// MARK: - Helpers

function sha256Hex(data: Buffer | Uint8Array): string {
  return createHash("sha256").update(data).digest("hex");
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

function blossomBaseURL(ctx: ActionCtx): string {
  const cfgUrl = (ctx.cfg as unknown as { blossomBaseURL?: string }).blossomBaseURL;
  if (typeof cfgUrl === "string" && cfgUrl.length > 0) return cfgUrl;
  return DEFAULT_BLOSSOM_URL;
}

function inferMime(filePath: string): string {
  const ext = path.extname(filePath).toLowerCase();
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

export const fileAttach = {
  attach(body: unknown, ctx: ActionCtx): Promise<FileAttachResult> {
    return attachFile((body ?? {}) as FileAttachRequest, ctx);
  },
};
