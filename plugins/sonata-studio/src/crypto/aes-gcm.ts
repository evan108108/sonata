// AES-256-GCM for public artifacts — the ONLY consumer is actions/artifact.ts.
//
// Blob layout is the gateway viewer's normative interop contract:
//   12-byte random IV || AES-256-GCM ciphertext+tag (single shot, no chunking)
//
// Deliberately no decrypt export: decryption happens exclusively in the
// gateway's browser viewer shell (the #k= fragment never reaches this
// process again). Keys/IVs come from node:crypto randomBytes — the noble
// WebCrypto-backed randomBytes caps at 65 536 bytes; node's doesn't.

import { randomBytes as nodeRandomBytes, webcrypto } from "node:crypto";

export function generateArtifactKey(): Uint8Array {
  return new Uint8Array(nodeRandomBytes(32));
}

// WebCrypto's BufferSource wants Uint8Array<ArrayBuffer>; callers may hand us
// views over ArrayBufferLike (Buffer pools, noble outputs). Copy into a fresh
// ArrayBuffer-backed view — payloads are ≤4 MiB, the copy is noise.
function toArrayBufferView(view: Uint8Array): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(view.length);
  out.set(view);
  return out;
}

export async function encryptArtifact(
  plaintext: Uint8Array,
  key: Uint8Array,
): Promise<Uint8Array> {
  const iv = new Uint8Array(nodeRandomBytes(12));
  const cryptoKey = await webcrypto.subtle.importKey(
    "raw",
    toArrayBufferView(key),
    { name: "AES-GCM" },
    false,
    ["encrypt"],
  );
  const ct = new Uint8Array(
    await webcrypto.subtle.encrypt({ name: "AES-GCM", iv }, cryptoKey, toArrayBufferView(plaintext)),
  );
  const out = new Uint8Array(iv.length + ct.length);
  out.set(iv, 0);
  out.set(ct, iv.length);
  return out;
}
