// Studio image attach action — encrypt + upload an image to a Blossom server,
// returning the image-block JSON the compose flow embeds in a card's
// `blocks` array. Per parent spec §6 + plan §11 D4 (image is a new block
// type, deferred-blob storage via Blossom).
//
// Pipeline:
//   1. Validate file_path is under ~/Library/Caches/com.sonata/ or ~/Downloads/
//      (Plan §12 Pass A9 — path-traversal guard). Reject symlinks so a
//      symlink inside an allowed root cannot escape to /etc, etc.
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
import * as os from "node:os";
import { createHash } from "node:crypto";

import { bytesToHex } from "@noble/hashes/utils.js";
import { blake3 } from "@noble/hashes/blake3.js";
import { base64 } from "@scure/base";

import { encrypt as nip44Encrypt } from "../crypto/nip44";
import { __signEvent, type NostrEvent } from "../crypto/nip17";
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

// BUD-01 authorization event kind. NIP-98 defines kind 27235 for generic
// HTTP-auth; BUD-01 specializes to 24242 with a `t` tag of
// "upload"|"get"|"list"|"delete". See
// https://github.com/hzrd149/blossom/blob/master/buds/01.md.
const BLOSSOM_AUTH_KIND = 24242;

// Default Blossom server. Overridable via ctx.cfg.blossomBaseURL (renderer
// Settings → Blossom server URL).
const DEFAULT_BLOSSOM_URL = "https://blossom.primal.net";

function allowedRoots(): string[] {
  return [
    path.resolve(os.homedir(), "Library/Caches/com.sonata"),
    path.resolve(os.homedir(), "Downloads"),
  ];
}

interface ImageAttachRequest {
  file_path?: unknown;
  room_slug?: unknown;
  mime_type?: unknown;
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

  // 1. Path-traversal guard. Resolve first, then check against allowlist;
  //    reject symlinks (a symlink inside an allowed root could point out).
  const resolved = path.resolve(filePathRaw);
  const roots = allowedRoots();
  const inRoot = roots.some(
    (r) => resolved === r || resolved.startsWith(r + path.sep),
  );
  if (!inRoot) {
    throw new HttpError(
      400,
      "path_outside_allowed_roots",
      `file_path must be under ~/Library/Caches/com.sonata/ or ~/Downloads/`,
    );
  }
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

  // 7. BUD-01 auth event.
  const blossomURL = blossomBaseURL(ctx);
  const authEvent = signBlossomAuthEvent({
    pluginPriv: ctx.cfg.pluginPriv,
    pluginPub: ctx.cfg.pluginPub,
    sha256: ciphertextSha,
    action: "upload",
  });
  const authB64 = base64Encode(JSON.stringify(authEvent));

  // 8. PUT ciphertext to /upload.
  const uploadURL = `${blossomURL.replace(/\/+$/, "")}/upload`;
  // Parent §12 E16 — 5-min timeout (system sleep tolerance).
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
      "blossom_rejected",
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

  void plaintextSha; // currently diagnostic-only; reserved for future log line.

  // 10. Image-block content.
  return {
    sha256: ciphertextSha,
    mirrors: [mirrorURL],
    decrypt_hint: { kind: "audience-epoch", epoch_n: room.currentEpoch },
    mime_type: mimeOverride ?? inferMime(resolved),
    blake3: ciphertextBlake,
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
  // BUD-01 "Authorization Event": kind 24242, tags include `t`, `x` (sha256),
  // and `expiration` (unix-seconds, ≤ 60s ahead). `content` is human-readable.
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

function base64Encode(s: string): string {
  // Bun exposes globalThis.btoa; the encoded JSON is ASCII so it round-trips
  // through atob on the verifier side.
  return btoa(s);
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
