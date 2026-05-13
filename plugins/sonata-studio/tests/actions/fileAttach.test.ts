import { afterEach, describe, expect, it } from "bun:test";
import { promises as fs } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createHash, randomBytes as nodeRandomBytes } from "node:crypto";

import { chacha20poly1305 } from "@noble/ciphers/chacha.js";
import { hexToBytes, bytesToHex } from "@noble/hashes/utils.js";
import { schnorr } from "@noble/curves/secp256k1.js";

import { fileAttach } from "../../src/actions";
import { HttpError } from "../../src/actions/util";
import { decrypt as nip44Decrypt } from "../../src/crypto/nip44";

import { makeCtx } from "./_helpers";
import { seedActiveRoom } from "./_room-fixture";

const DOWNLOADS = path.resolve(os.homedir(), "Downloads");

function sha256Hex(data: Uint8Array): string {
  return createHash("sha256").update(data).digest("hex");
}

async function writeTmpFile(name: string, data: Uint8Array): Promise<string> {
  await fs.mkdir(DOWNLOADS, { recursive: true });
  const p = path.join(DOWNLOADS, name);
  await fs.writeFile(p, data);
  return p;
}

async function rmIfExists(p: string): Promise<void> {
  try { await fs.unlink(p); } catch { /* ignore */ }
}

describe("studio_file_attach", () => {
  const tmpFiles: string[] = [];

  afterEach(async () => {
    for (const p of tmpFiles) await rmIfExists(p);
    tmpFiles.length = 0;
  });

  it("rejects symlinks", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const target = await writeTmpFile(
        `fileattach-target-${Date.now()}.bin`,
        new Uint8Array([1, 2, 3]),
      );
      tmpFiles.push(target);
      const link = path.join(DOWNLOADS, `fileattach-symlink-${Date.now()}.bin`);
      await fs.symlink(target, link);
      tmpFiles.push(link);

      let caught: unknown;
      try {
        await fileAttach.attach(
          { file_path: link, room_slug: "alpha" },
          seed.ctx,
        );
      } catch (err) {
        caught = err;
      }
      expect(caught).toBeInstanceOf(HttpError);
      expect((caught as HttpError).code).toBe("path_is_symlink");
    } finally {
      seed.restore();
    }
  });

  it("rejects files larger than the 256 MiB cap", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const big = path.join(DOWNLOADS, `fileattach-big-${Date.now()}.bin`);
      // Sparse 257 MiB file via truncate — actual blocks not allocated, so CI
      // doesn't burn disk. The size check reads stat.size, which honors the
      // sparse declared length.
      const fh = await fs.open(big, "w");
      await fh.truncate(257 * 1024 * 1024);
      await fh.close();
      tmpFiles.push(big);

      let caught: unknown;
      try {
        await fileAttach.attach(
          { file_path: big, room_slug: "alpha" },
          seed.ctx,
        );
      } catch (err) {
        caught = err;
      }
      expect(caught).toBeInstanceOf(HttpError);
      expect((caught as HttpError).code).toBe("file_too_big");
    } finally {
      seed.restore();
    }
  });

  it("encrypts a 1 MB blob with ChaCha20-Poly1305 (ciphertext = plaintext + 16-byte tag) and round-trips via the wrapped file_key", async () => {
    const { ctx, pluginPub } = makeCtx();

    const epochPriv = hexToBytes("00".repeat(31) + "01");
    const epochPub = bytesToHex(schnorr.getPublicKey(epochPriv));
    const slug = "fileroom";
    const env = installDirectFetchShim({
      slug,
      pluginPubLower: pluginPub.toLowerCase(),
      epochN: 5,
      epochPrivHex: bytesToHex(epochPriv),
      epochPubHex: epochPub,
      onUpload: (bytes) => ({
        status: 200,
        body: {
          sha256: sha256Hex(bytes),
          url: `https://blossom.test/${sha256Hex(bytes)}`,
          size: bytes.length,
          type: "application/octet-stream",
        },
      }),
    });

    const plaintext = nodeRandomBytes(1024 * 1024); // 1 MB random bytes
    const filePath = path.join(DOWNLOADS, `fileattach-1mb-${Date.now()}.bin`);
    await fs.writeFile(filePath, plaintext);
    tmpFiles.push(filePath);

    try {
      const res = await fileAttach.attach(
        { file_path: filePath, room_slug: slug, mime_type: "application/octet-stream" },
        ctx,
      );

      // Wire-shape assertions
      expect(res.type).toBe("file");
      expect(res.filename).toBe(path.basename(filePath));
      expect(res.mime_type).toBe("application/octet-stream");
      expect(res.size_bytes).toBe(plaintext.length);
      expect(res.sha256).toMatch(/^[0-9a-f]{64}$/);
      expect(res.blake3).toMatch(/^[0-9a-f]{64}$/);
      expect(res.mirrors).toEqual([`https://blossom.test/${res.sha256}`]);
      expect(res.decrypt_hint.kind).toBe("audience-epoch+file-key");
      expect(res.decrypt_hint.epoch_n).toBe(5);
      expect(typeof res.decrypt_hint.wrapped_key).toBe("string");

      // Inspect uploaded bytes.
      expect(env.uploads.length).toBe(1);
      const ciphertext = env.uploads[0]!.body;
      expect(sha256Hex(ciphertext)).toBe(res.sha256);

      // Ciphertext length is plaintext + 16-byte Poly1305 tag.
      expect(ciphertext.length).toBe(plaintext.length + 16);

      // Round-trip: unwrap (file_key || nonce) from decrypt_hint.wrapped_key
      // using (epochPriv, pluginPub), then ChaCha20-Poly1305-decrypt.
      const keyMaterial = nip44Decrypt(res.decrypt_hint.wrapped_key, epochPriv, pluginPub);
      expect(keyMaterial.length).toBe(32 + 12);
      const fileKey = keyMaterial.subarray(0, 32);
      const nonce = keyMaterial.subarray(32, 44);
      const recovered = chacha20poly1305(fileKey, nonce).decrypt(ciphertext);
      expect(recovered.length).toBe(plaintext.length);
      // Byte-equal via Buffer.compare for speed on 1 MB.
      expect(Buffer.from(recovered).equals(Buffer.from(plaintext))).toBe(true);
    } finally {
      env.restore();
    }
  });

  it("throws blossom_rejected when Blossom returns 413", async () => {
    const { ctx, pluginPub } = makeCtx();

    const epochPriv = hexToBytes("00".repeat(31) + "02");
    const epochPub = bytesToHex(schnorr.getPublicKey(epochPriv));
    const slug = "quota";
    const env = installDirectFetchShim({
      slug,
      pluginPubLower: pluginPub.toLowerCase(),
      epochN: 1,
      epochPrivHex: bytesToHex(epochPriv),
      epochPubHex: epochPub,
      onUpload: () => ({
        status: 413,
        body: { error: "quota_exceeded", message: "100 MB hosted limit reached" },
      }),
    });

    const filePath = path.join(DOWNLOADS, `fileattach-413-${Date.now()}.bin`);
    await fs.writeFile(filePath, new Uint8Array([1, 2, 3, 4, 5]));
    tmpFiles.push(filePath);

    try {
      let caught: unknown;
      try {
        await fileAttach.attach(
          { file_path: filePath, room_slug: slug },
          ctx,
        );
      } catch (err) {
        caught = err;
      }
      expect(caught).toBeInstanceOf(HttpError);
      expect((caught as HttpError).code).toBe("blossom_rejected");
    } finally {
      env.restore();
    }
  });
});

// ── Direct fetch shim ─────────────────────────────────────────────────────
// Mirrors imageAttach.test.ts's shim — Bun's installMockFetch utf8-decodes
// Uint8Array bodies and corrupts binary ciphertext we want to assert on.

interface DirectFetchOpts {
  slug: string;
  pluginPubLower: string;
  epochN: number;
  epochPrivHex: string;
  epochPubHex: string;
  onUpload: (body: Uint8Array) => { status: number; body: unknown };
}

interface UploadCapture {
  url: string;
  body: Uint8Array;
  headers: Record<string, string>;
}

function installDirectFetchShim(opts: DirectFetchOpts): {
  uploads: UploadCapture[];
  restore: () => void;
} {
  const uploads: UploadCapture[] = [];
  const orig = globalThis.fetch;

  const entityAttrs = JSON.stringify({
    slug: opts.slug,
    title: opts.slug,
    aud_id_pub_hex: "a".repeat(64),
    aud_id_priv_secret_name: null,
    epoch_keys_secret_name: `studio:room:${opts.slug}:epoch_keys`,
    current_epoch: opts.epochN,
    members: [opts.pluginPubLower],
    state: "active",
  });
  const entityRow = {
    id: "ent-room",
    name: `studio:room:${opts.slug}`,
    type: "studio_room",
    description: opts.slug,
    attributes: entityAttrs,
  };
  const epochSecretValue = JSON.stringify({
    epochs: {
      [String(opts.epochN)]: {
        epoch: opts.epochN,
        priv_hex: opts.epochPrivHex,
        pub_hex: opts.epochPubHex,
      },
    },
  });

  function json(status: number, body: unknown): Response {
    return new Response(JSON.stringify(body), {
      status,
      headers: { "Content-Type": "application/json" },
    });
  }

  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    const method = (init?.method ?? "GET").toUpperCase();

    if (method === "GET" && url.startsWith("http://127.0.0.1:3211/api/ping")) {
      return json(200, { ok: true });
    }
    if (method === "GET" && url.startsWith("http://127.0.0.1:3211/api/entity/?name=")) {
      const name = decodeURIComponent(new URL(url).searchParams.get("name") ?? "");
      return json(200, name === entityRow.name ? entityRow : null);
    }
    if (method === "GET" && url.startsWith("http://127.0.0.1:3211/api/secrets/")) {
      const name = decodeURIComponent(url.split("/api/secrets/")[1]!);
      if (name === `studio:room:${opts.slug}:epoch_keys`) {
        return json(200, { name, value: epochSecretValue });
      }
      return json(404, { error: "not_found" });
    }
    if (method === "PUT" && url.endsWith("/upload")) {
      const raw = init?.body;
      let bytes: Uint8Array;
      if (raw instanceof Uint8Array) {
        bytes = raw;
      } else if (raw instanceof ArrayBuffer) {
        bytes = new Uint8Array(raw);
      } else {
        bytes = new TextEncoder().encode(String(raw));
      }
      const headers: Record<string, string> = {};
      if (init?.headers) {
        const hh = init.headers as Record<string, string>;
        for (const k of Object.keys(hh)) headers[k.toLowerCase()] = hh[k]!;
      }
      uploads.push({ url, body: bytes, headers });
      const resp = opts.onUpload(bytes);
      return json(resp.status, resp.body);
    }
    return json(404, { error: "no_route", url, method });
  }) as typeof fetch;

  return {
    uploads,
    restore: () => {
      globalThis.fetch = orig;
    },
  };
}
