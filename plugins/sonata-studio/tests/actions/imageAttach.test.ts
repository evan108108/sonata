import { afterEach, describe, expect, it } from "bun:test";
import { promises as fs } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createHash } from "node:crypto";

import { imageAttach } from "../../src/actions";
import { HttpError } from "../../src/actions/util";
import { decrypt as nip44Decrypt } from "../../src/crypto/nip44";
import { base64 } from "@scure/base";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils.js";
import { blake3 } from "@noble/hashes/blake3.js";
import { schnorr } from "@noble/curves/secp256k1.js";

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
  try {
    await fs.unlink(p);
  } catch {
    // ignore
  }
}

describe("studio_image_attach", () => {
  const tmpFiles: string[] = [];

  afterEach(async () => {
    for (const p of tmpFiles) await rmIfExists(p);
    tmpFiles.length = 0;
  });

  it("rejects symlinks", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const target = await writeTmpFile(
        `imgattach-target-${Date.now()}.bin`,
        new Uint8Array([1, 2, 3]),
      );
      tmpFiles.push(target);
      const link = path.join(DOWNLOADS, `imgattach-symlink-${Date.now()}.bin`);
      await fs.symlink(target, link);
      tmpFiles.push(link);

      let caught: unknown;
      try {
        await imageAttach.attach(
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

  it("rejects files larger than the 20 MiB cap", async () => {
    const seed = seedActiveRoom("alpha");
    try {
      const big = path.join(DOWNLOADS, `imgattach-big-${Date.now()}.bin`);
      // Use truncate to allocate 20 MiB + 1 sparsely so we don't actually
      // allocate that much disk in CI. fs.truncate creates a sparse file.
      const fh = await fs.open(big, "w");
      await fh.truncate(20 * 1024 * 1024 + 1);
      await fh.close();
      tmpFiles.push(big);

      let caught: unknown;
      try {
        await imageAttach.attach(
          { file_path: big, room_slug: "alpha" },
          seed.ctx,
        );
      } catch (err) {
        caught = err;
      }
      expect(caught).toBeInstanceOf(HttpError);
      expect((caught as HttpError).code).toBe("file_too_large");
    } finally {
      seed.restore();
    }
  });

  it("encrypts, uploads ciphertext, and returns block content matching server sha256", async () => {
    const { ctx, pluginPub } = makeCtx();

    // Deterministic epoch keypair so we can decrypt the uploaded ciphertext.
    const epochPriv = hexToBytes("00".repeat(31) + "01");
    const epochPub = bytesToHex(schnorr.getPublicKey(epochPriv));
    const slug = "imgroom";
    const env = installDirectFetchShim({
      slug,
      pluginPubLower: pluginPub.toLowerCase(),
      epochN: 7,
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

    const plaintext = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4, 5]);
    const filePath = path.join(DOWNLOADS, `imgattach-happy-${Date.now()}.png`);
    await fs.writeFile(filePath, plaintext);
    tmpFiles.push(filePath);

    try {
      const res = await imageAttach.attach(
        { file_path: filePath, room_slug: slug },
        ctx,
      );

      expect(res.mime_type).toBe("image/png");
      expect(res.decrypt_hint).toEqual({ kind: "audience-epoch", epoch_n: 7 });
      expect(res.sha256).toMatch(/^[0-9a-f]{64}$/);
      expect(res.blake3).toMatch(/^[0-9a-f]{64}$/);
      expect(res.mirrors).toEqual([`https://blossom.test/${res.sha256}`]);

      // Inspect what we actually sent up.
      expect(env.uploads.length).toBe(1);
      const sent = env.uploads[0]!.body;
      expect(sha256Hex(sent)).toBe(res.sha256);
      expect(bytesToHex(blake3(sent))).toBe(res.blake3);
      expect(sent[0]).toBe(0x02); // NIP-44 v2 version byte.

      // Round-trip decrypt under the epoch priv (recipient) from plugin pub.
      const decrypted = nip44Decrypt(base64.encode(sent), epochPriv, pluginPub);
      expect(Array.from(decrypted)).toEqual(Array.from(plaintext));

      // Authorization header: kind 24242 with t=upload, x=<sha256>, exp ≤ +60s.
      const authHeader = env.uploads[0]!.headers["authorization"];
      expect(authHeader?.startsWith("Nostr ")).toBe(true);
      const authJson = JSON.parse(atob(authHeader!.slice("Nostr ".length))) as {
        kind: number;
        tags: string[][];
        pubkey: string;
      };
      expect(authJson.kind).toBe(24242);
      expect(authJson.pubkey).toBe(pluginPub.toLowerCase());
      const tagMap = new Map(authJson.tags.map((t) => [t[0]!, t[1]!] as const));
      expect(tagMap.get("t")).toBe("upload");
      expect(tagMap.get("x")).toBe(res.sha256);
      const expiration = Number(tagMap.get("expiration"));
      const nowSec = Math.floor(Date.now() / 1000);
      expect(expiration).toBeGreaterThan(nowSec);
      expect(expiration).toBeLessThanOrEqual(nowSec + 60);
    } finally {
      env.restore();
    }
  });

  it("throws when Blossom returns a mismatched sha256", async () => {
    const { ctx, pluginPub } = makeCtx();

    const epochPriv = hexToBytes("00".repeat(31) + "02");
    const epochPub = bytesToHex(schnorr.getPublicKey(epochPriv));
    const slug = "mismatch";
    const env = installDirectFetchShim({
      slug,
      pluginPubLower: pluginPub.toLowerCase(),
      epochN: 1,
      epochPrivHex: bytesToHex(epochPriv),
      epochPubHex: epochPub,
      onUpload: () => ({
        status: 200,
        body: {
          sha256: "f".repeat(64), // deliberately wrong
          url: "https://blossom.test/bogus",
          size: 0,
          type: "application/octet-stream",
        },
      }),
    });

    const filePath = path.join(DOWNLOADS, `imgattach-mismatch-${Date.now()}.png`);
    await fs.writeFile(filePath, new Uint8Array([1, 2, 3, 4, 5]));
    tmpFiles.push(filePath);

    try {
      let caught: unknown;
      try {
        await imageAttach.attach(
          { file_path: filePath, room_slug: slug },
          ctx,
        );
      } catch (err) {
        caught = err;
      }
      expect(caught).toBeInstanceOf(HttpError);
      expect((caught as HttpError).code).toBe("blossom_response_invalid");
    } finally {
      env.restore();
    }
  });
});

// ── Direct fetch shim ─────────────────────────────────────────────────────
// installMockFetch in _helpers.ts utf8-decodes Uint8Array bodies, which
// corrupts the binary ciphertext we want to assert on. This helper installs
// a direct globalThis.fetch override that preserves raw bytes for the
// Blossom upload path.

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
