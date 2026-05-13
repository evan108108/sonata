// Studio image attach action — encrypt + upload an image to a Blossom server,
// returning the image-block JSON the compose flow embeds in a card's
// `blocks` array. Per parent spec §6 + plan §11 D4 (image is a new block
// type, deferred-blob storage via Blossom).
//
// Pipeline:
//   1. Resolve file_path and reject symlinks. The plugin runs under the
//      user's UID with full home-dir read access; no allowlist guard.
//   2. Read file bytes; reject > 20 MiB (blossom.band free-tier hard limit).
//   3. Compute plaintext sha256 (diagnostic only — NOT the storage key).
//   4. Load the room's current epoch via loadRoomCtx (gives pluginPub +
//      epoch priv/pub material).
//   5. NIP-44 v2 encrypt plaintext bytes from (pluginPriv → epochPub).
//      Decode the standard base64 wire string back to raw bytes — Blossom
//      stores opaque bytes, not a base64 string. The renderer's
//      StudioImageFetcher reverses this (raw bytes → NIP44.decryptRaw).
//   6. Compute sha256 + blake3 of the CIPHERTEXT bytes. sha256 is Blossom's
//      content key; blake3 is a renderer-side integrity check.
//   7. Sign a BUD-01 auth event (kind 24242) — t=upload, x=sha256,
//      expiration < 60s in the future. Base64-encode the signed event into
//      `Authorization: Nostr <b64>`.
//   8. PUT ciphertext to `${blossomURL}/upload` with Content-Type:
//      application/octet-stream and Content-Length implied.
//   9. Verify response.sha256 matches our computed sha256; reject if not.
//  10. Return image-block content: { sha256, mirrors, decrypt_hint,
//      mime_type, blake3 }. The compose flow prepends `"type": "image"`
//      when slotting it into the card's blocks[] array.

import { promises as fs } from "node:fs";
import * as path from "node:path";
import { createHash } from "node:crypto";

import { bytesToHex } from "@noble/hashes/utils.js";
import { blake3 } from "@noble/hashes/blake3.js";
import { base64 } from "@scure/base";

import { encrypt as nip44Encrypt } from "../crypto/nip44";
import { uploadCiphertext, StorageUploadError } from "../storage/upload";
import { resolveRoomStorageConfig } from "./storage";
import {
  HttpError,
  ensureSlug,
  ensureString,
  loadRoomCtx,
} from "./util";
import type { ActionCtx } from "./room";

// 20 MiB cap — blossom.band free tier hard limit. Validated client-side at
// file-pick time and again here for defense in depth.
const MAX_FILE_BYTES = 20 * 1024 * 1024;

// Default Blossom server. Overridable via ctx.cfg.blossomBaseURL (renderer
// Settings → Blossom server URL).
const DEFAULT_BLOSSOM_URL = "https://api.4a4.ai/blossom";

interface ImageAttachRequest {
  file_path?: unknown;
  room_slug?: unknown;
  mime_type?: unknown;
  s3_credentials?: unknown;
}

interface ImageAttachResult {
  sha256: string;
  mirrors: string[];
  decrypt_hint: { kind: "audience-epoch"; epoch_n: number };
  mime_type: string;
  blake3: string;
}

export async function attachImage(
  body: ImageAttachRequest,
  ctx: ActionCtx,
): Promise<ImageAttachResult> {
  const filePathRaw = ensureString(body.file_path, "file_path");
  const roomSlug = ensureSlug(body.room_slug, "room_slug");
  const mimeOverride =
    body.mime_type !== undefined
      ? ensureString(body.mime_type, "mime_type")
      : undefined;

  // 1. Resolve path + reject symlinks. The plugin runs under the user's own
  //    UID with full home-dir access, so an allowlist of "approved roots"
  //    was security theatre — the user already has read access to anything
  //    they can point us at. Symlink rejection stays because the bytes are
  //    going to be uploaded to a remote Blossom server and we'd rather not
  //    surprise the user by silently following a link to elsewhere.
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
      "file_too_large",
      `file is ${stat.size} bytes; blossom.band free tier rejects > ${MAX_FILE_BYTES}`,
    );
  }

  const plaintext = await fs.readFile(resolved);

  // 3. Plaintext sha256 — diagnostic only; never returned or stored in the
  //    block. Plumbed through the logger so an operator can join "I attached
  //    file X" with "ciphertext sha256 Y" in plugin logs.
  const plaintextSha = sha256Hex(plaintext);

  // 4. Load room ctx — validates plugin membership and resolves the current
  //    epoch keypair from the secret store.
  const room = await loadRoomCtx(roomSlug, ctx.cfg.pluginPub);
  const epochPub = room.currentEpochPubHex;

  // 5. Encrypt plaintext → epochPub. Symmetric ECDH: (pluginPriv, epochPub)
  //    derives the same conversation key as (epochPriv, pluginPub), which is
  //    what the renderer uses to decrypt.
  const wireBase64 = nip44Encrypt(plaintext, ctx.cfg.pluginPriv, epochPub);
  // Decode the base64 wire string back to raw bytes — Blossom stores opaque
  // bytes, not a base64 string. First byte is 0x02 (NIP-44 v2 version).
  const ciphertextBytes = base64.decode(wireBase64);

  // 6. Hashes over CIPHERTEXT bytes.
  const ciphertextSha = sha256Hex(ciphertextBytes);
  const ciphertextBlake = bytesToHex(blake3(ciphertextBytes));

  // 7. Resolve storage backend: per-room override > user default > hosted Blossom.
  const storageConfig = await resolveRoomStorageConfig(roomSlug);

  // 8. Dispatch upload (Blossom or BYO-S3).
  let uploadResult;
  try {
    uploadResult = await uploadCiphertext({
      config: storageConfig,
      defaultBlossomURL: blossomBaseURL(ctx),
      ciphertext: ciphertextBytes,
      ciphertextSha256Hex: ciphertextSha,
      pluginPriv: ctx.cfg.pluginPriv,
      pluginPub: ctx.cfg.pluginPub,
      roomSlug,
      s3Credentials: body.s3_credentials,
    });
  } catch (err) {
    if (err instanceof StorageUploadError) {
      throw new HttpError(err.status, err.code, err.message);
    }
    throw err;
  }

  void plaintextSha; // currently diagnostic-only; reserved for future log line.

  // 9. Image-block content.
  return {
    sha256: ciphertextSha,
    mirrors: [uploadResult.mirror_url],
    decrypt_hint: { kind: "audience-epoch", epoch_n: room.currentEpoch },
    mime_type: mimeOverride ?? inferMime(resolved),
    blake3: ciphertextBlake,
  };
}

// MARK: - Helpers

function sha256Hex(data: Buffer | Uint8Array): string {
  return createHash("sha256").update(data).digest("hex");
}

function blossomBaseURL(ctx: ActionCtx): string {
  const cfgUrl = (ctx.cfg as unknown as { blossomBaseURL?: string }).blossomBaseURL;
  if (typeof cfgUrl === "string" && cfgUrl.length > 0) return cfgUrl;
  return DEFAULT_BLOSSOM_URL;
}

function inferMime(filePath: string): string {
  const ext = path.extname(filePath).toLowerCase();
  switch (ext) {
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

export const imageAttach = {
  attach(body: unknown, ctx: ActionCtx): Promise<ImageAttachResult> {
    return attachImage((body ?? {}) as ImageAttachRequest, ctx);
  },
};
