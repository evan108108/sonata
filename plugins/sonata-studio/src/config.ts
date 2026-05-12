// Plugin config & first-run keypair bootstrap.
//
// Subsequent runs: PluginManager injects the config back via env vars of the
// form `SONATA-STUDIO_<UPPERCASED_KEY>` (yes, the hyphen is literal — POSIX
// env vars allow hyphens, and PluginManager.swift uppercases the plugin name
// without any sanitization). See plan §3.3.
//
// First run: generate a fresh secp256k1 priv, write it back to
// plugins.config_json via the Sonata HTTP API, and continue with the
// in-memory key for this run.

import { schnorr, secp256k1 } from "@noble/curves/secp256k1.js";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils.js";
import { setPluginConfig } from "./memory-client";
import { log } from "./logger";

export interface PluginConfig {
  pluginPriv: Uint8Array;
  pluginPub: string;
  gatewayBaseUrl: string;
  sonataHost: string;
  pluginDataDir: string;
}

const PLUGIN_NAME = "sonata-studio";
const ENV_PREFIX = "SONATA-STUDIO";
const DEFAULT_GATEWAY = "https://api.4a4.ai";

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

export async function loadOrInitConfig(): Promise<PluginConfig> {
  const sonataHost = requireEnv("SONATA_HOST");
  const pluginDataDir = requireEnv("SONATA_PLUGIN_DATA_DIR");
  const gatewayBaseUrl = envVar("GATEWAY_BASE_URL") ?? DEFAULT_GATEWAY;

  const privHex = envVar("PLUGIN_PRIV");
  const pubHex = envVar("PLUGIN_PUB");

  if (privHex && pubHex) {
    const priv = hexToBytes(privHex);
    if (priv.length !== 32) {
      throw new Error(`SONATA-STUDIO_PLUGIN_PRIV must be 32 bytes (64 hex chars), got ${priv.length}`);
    }
    return {
      pluginPriv: priv,
      pluginPub: pubHex.toLowerCase(),
      gatewayBaseUrl,
      sonataHost,
      pluginDataDir,
    };
  }

  // First run — generate a fresh keypair. (@noble/curves v2 calls this
  // `randomSecretKey`; older versions called it `randomPrivateKey`.)
  const priv = secp256k1.utils.randomSecretKey();
  const pub = bytesToHex(schnorr.getPublicKey(priv));
  const privHexNew = bytesToHex(priv);

  log.info("Generating plugin keypair on first run", { plugin_pub: pub });

  await setPluginConfig(PLUGIN_NAME, {
    plugin_priv: privHexNew,
    plugin_pub: pub,
    gateway_base_url: gatewayBaseUrl,
  });

  // PluginManager re-reads config_json on the next plugin restart. For this
  // run, proceed with the in-memory key.
  return {
    pluginPriv: priv,
    pluginPub: pub,
    gatewayBaseUrl,
    sonataHost,
    pluginDataDir,
  };
}
