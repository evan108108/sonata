// NIP-98 HTTP Auth — plugin-side signer.
//
// The 4A gateway's NIP-98 verifier (see gateway/src/lib/nip98.ts) accepts a
// kind:27235 schnorr-signed event embedded in `Authorization: Nostr <base64>`.
// This file produces the matching signed header from a 32-byte private key.
//
// Per https://github.com/nostr-protocol/nips/blob/master/98.md:
//   - kind 27235
//   - tags: ["u", <full-url>], ["method", <UPPERCASE>], optionally
//     ["payload", <sha256-hex of raw body>] for requests with a body.
//   - content: ""
//   - created_at: now (gateway accepts ±60s)
//
// Round-trip parity with the gateway verifier is asserted by tests.

import { schnorr } from "@noble/curves/secp256k1.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils.js";

const NIP98_KIND = 27235;

export interface Nip98SignArgs {
  /** The exact URL the request will be sent to (must match Request.url after URL normalization). */
  url: string;
  /** HTTP method; will be uppercased. */
  method: string;
  /** Raw request body. Omit (or undefined) for GET/HEAD with no body. */
  body?: Uint8Array;
  /** 32-byte schnorr private key used to sign the auth event. */
  pluginPriv: Uint8Array;
}

interface Nip98Event {
  id: string;
  pubkey: string;
  created_at: number;
  kind: number;
  tags: string[][];
  content: string;
  sig: string;
}

function nowSec(): number {
  return Math.floor(Date.now() / 1000);
}

function canonicalEventId(
  pubkey: string,
  createdAt: number,
  kind: number,
  tags: string[][],
  content: string,
): string {
  const ser = JSON.stringify([0, pubkey, createdAt, kind, tags, content]);
  return bytesToHex(sha256(new TextEncoder().encode(ser)));
}

function base64Encode(s: string): string {
  // bun's runtime exposes globalThis.btoa; the encoded JSON is ASCII so
  // round-trips cleanly through atob on the verifier side.
  return btoa(s);
}

export async function signNip98(args: Nip98SignArgs): Promise<string> {
  if (args.pluginPriv.length !== 32) {
    throw new Error(`pluginPriv must be 32 bytes, got ${args.pluginPriv.length}`);
  }
  const pubkey = bytesToHex(schnorr.getPublicKey(args.pluginPriv));
  const created_at = nowSec();
  const method = args.method.toUpperCase();

  const tags: string[][] = [
    ["u", args.url],
    ["method", method],
  ];
  if (args.body !== undefined) {
    const payloadHash = bytesToHex(sha256(args.body));
    tags.push(["payload", payloadHash]);
  }

  const id = canonicalEventId(pubkey, created_at, NIP98_KIND, tags, "");
  const sig = bytesToHex(schnorr.sign(hexToBytes(id), args.pluginPriv));

  const event: Nip98Event = {
    id,
    pubkey,
    created_at,
    kind: NIP98_KIND,
    tags,
    content: "",
    sig,
  };
  return "Nostr " + base64Encode(JSON.stringify(event));
}
