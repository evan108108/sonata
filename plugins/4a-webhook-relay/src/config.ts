// Plugin config & first-run identity bootstrap.
//
// Unlike sonata-studio (per-room audience keypairs stored via plugin
// config_json), this plugin has ONE stable per-Sonata-instance identity:
// a fresh secp256k1 keypair generated on first boot and persisted to
// `<data-dir>/identity.json`. That pubkey is:
//   - the path + NIP-98 auth identity for GET /v0/inbox/<pubkey>/stream
//   - the pubkey third parties embed in hook URLs
//     (https://api.4a4.ai/v0/hook/<pubkey>/<slug>)
//   - what the `4a_pubkey_get` introspection action returns.
//
// SONATA_WEBHOOK_BEARER is injected by Sonata's PluginManager at spawn time
// when the manifest declares capabilities.webhookReceiver. Until the Sonata
// side ships, the plugin boots without it and the forwarder logs a warning —
// the plugin is an intentional no-op in that state (plan: "the plugin can
// ship as a no-op until Sonata's webhook_deliver endpoint exists").

import { schnorr, secp256k1 } from "@noble/curves/secp256k1.js";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils.js";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync, chmodSync } from "node:fs";
import { dirname, join } from "node:path";
import { log } from "./logger";

export interface PluginConfig {
  identityPriv: Uint8Array;
  identityPub: string;
  gatewayBaseUrl: string;
  sonataHost: string;
  pluginDataDir: string;
  /** Shared bearer for POST /api/webhook/deliver; absent until Sonata injects it. */
  webhookBearer: string | null;
}

// PluginManager injects config_json entries as `<UPPERCASED-NAME>_<KEY>`
// env vars (hyphen kept literal — see sonata-studio/src/config.ts).
const ENV_PREFIX = "4A-WEBHOOK-RELAY";
const DEFAULT_GATEWAY = "https://api.4a4.ai";
const IDENTITY_FILE = "identity.json";

function envVar(key: string): string | undefined {
  return process.env[`${ENV_PREFIX}_${key}`];
}

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) {
    throw new Error(`Required env var ${name} is missing — is this plugin running under Sonata?`);
  }
  return v;
}

interface IdentityFile {
  priv_hex: string;
  pub_hex: string;
}

function loadIdentity(path: string): IdentityFile | null {
  if (!existsSync(path)) return null;
  const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<IdentityFile>;
  if (typeof parsed.priv_hex !== "string" || !/^[0-9a-f]{64}$/i.test(parsed.priv_hex)) {
    throw new Error(`${path} exists but priv_hex is malformed — refusing to overwrite an identity file; fix or remove it manually`);
  }
  const priv = hexToBytes(parsed.priv_hex);
  const pub = bytesToHex(schnorr.getPublicKey(priv));
  if (typeof parsed.pub_hex === "string" && parsed.pub_hex.toLowerCase() !== pub) {
    throw new Error(`${path} pub_hex does not match priv_hex — refusing to guess which is right`);
  }
  return { priv_hex: parsed.priv_hex.toLowerCase(), pub_hex: pub };
}

function persistIdentity(path: string, identity: IdentityFile): void {
  mkdirSync(dirname(path), { recursive: true });
  // Atomic write: tmp + rename so a crash mid-write never leaves a torn key.
  const tmp = path + ".tmp";
  writeFileSync(tmp, JSON.stringify(identity, null, 2) + "\n", { mode: 0o600 });
  renameSync(tmp, path);
  chmodSync(path, 0o600);
}

export function loadOrInitConfig(): PluginConfig {
  const sonataHost = requireEnv("SONATA_HOST");
  const pluginDataDir = requireEnv("SONATA_PLUGIN_DATA_DIR");
  const gatewayBaseUrl = envVar("GATEWAY_BASE_URL") ?? DEFAULT_GATEWAY;
  const webhookBearer = process.env["SONATA_WEBHOOK_BEARER"] ?? null;

  const identityPath = join(pluginDataDir, IDENTITY_FILE);
  let identity = loadIdentity(identityPath);
  if (!identity) {
    const priv = secp256k1.utils.randomSecretKey();
    identity = {
      priv_hex: bytesToHex(priv),
      pub_hex: bytesToHex(schnorr.getPublicKey(priv)),
    };
    persistIdentity(identityPath, identity);
    log.info("Generated plugin identity on first run", { pubkey: identity.pub_hex });
  }

  return {
    identityPriv: hexToBytes(identity.priv_hex),
    identityPub: identity.pub_hex,
    gatewayBaseUrl,
    sonataHost,
    pluginDataDir,
    webhookBearer,
  };
}
