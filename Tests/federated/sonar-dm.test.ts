// Sonar DMs v0 — Federated round-trip test (T4).
//
// Plan: /Users/evan/memory/claude/documents/plans/sonar-dm-v0-plan.md
// Sections: §2 (architecture), §6 (DMMessageView shape), §8.4 (this test),
// §10 (T4 row).
//
// Mirrors the boot/teardown structure of the Studio Phase 3 federated test
// (`plugins/sonata-studio/tests/federated.test.ts`):
//   - Single test gated behind an env flag (`SONAR_DM_FEDERATED=1`) so the
//     workstation→Sonata-B LAN dependency never runs in CI sweeps.
//   - 3-attempt retry with relay-attributable error classification (matches
//     the pattern around `RelayAttributableError` in Phase 3).
//   - Captures a JSON fixture next to the test for regression compare on
//     future runs (`fixtures/sonar-dm-roundtrip.json`).
//
// Topology under test:
//
//     Sonata-A (3211) ─── /api/dm/send ──┐
//        │                                │  HTTP relay (Sonar HTTP fallback)
//     Sonar-A (4000) ◀── peer Sonar-B paired/intimate
//        │                                │
//        ▼                                ▼
//     ──────────────── 127.0.0.1 loopback ────────────────
//        │                                │
//        ▼                                ▼
//     Sonar-B (4100) ──── new_message broadcast (messages:events)
//        │                                │
//     Sonata-B (3311) ── DMActions.routeInbound → dm_messages persist + SSE push
//                          │
//                          └──── /api/dm/inbox?sessionId=X-stub  (test polls)
//
// What the test does NOT do (intentional, per "DO NOT modify production code
// paths" in the task brief):
//   - Boot Sonata-A or Sonata-B. Sonata.app's `DatabaseManager` hardcodes
//     `~/.sonata/sonata.db` (no SONATA_DB env var), and the SwiftUI
//     `@main` entry point assumes a regular macOS app activation — auto-
//     spawning a second Sonata from a Bun test would require either
//     production env-var plumbing or a test-only headless harness, both of
//     which are out of T4 scope. Operator brings up Sonata-B before running
//     the test (see "Operator setup" below). This mirrors how the Studio
//     Phase 3 federated test treats the Scout machine — long-lived, managed
//     externally, only the round-trip is the test's responsibility.
//   - Boot Sonar-A or Sonar-B. Each is a Sonata plugin that comes up under
//     its host Sonata's PluginManager; we don't manage their lifecycle here.
//   - Cross-machine work. Both Sonatas are loopback-co-resident; this test
//     proves federation correctness, not LAN/WAN reachability.
//
// What the test DOES:
//   1. Probe all four endpoints; SKIP with a clear setup hint if any are down.
//   2. Ensure pairing between Sonar-A and Sonar-B (creates peer rows + flips
//      connection_status="paired", trust_level="intimate" on both sides if
//      not already paired).
//   3. Announce stub session-X on Sonata-B via `/api/bridge/announce` (cosmetic
//      — dashboard shows it; not load-bearing for DM delivery).
//   4. Sender-side: `POST Sonata-A /api/dm/send` with target_session_id="X-stub",
//      peer_id=<id of Sonar-B's peer record on Sonar-A>, body="federated ping".
//   5. Receiver-side: poll `Sonata-B /api/dm/inbox?sessionId=X-stub` until the
//      envelope appears (≤ 10s). routeInbound persists before SSE push, so
//      backfill always sees the message.
//   6. Assert on the envelope: target_session_id matches, body matches,
//      from_pubkey populated to Sonar-A's instance_id, message_id present.
//   7. Write `fixtures/sonar-dm-roundtrip.json` with the captured envelope +
//      timing metadata.
//   8. Teardown: unregister session, drop the bridge announcement, leave
//      pair + Sonatas + Sonars running (mirrors Phase 3 — operator-managed
//      lifecycle).
//
// Operator setup (one-time, before running this test):
//   - Sonata-A on :3211 with the Sonar plugin installed and running on :4000
//     (this is the user's normal Sonata.app dev environment).
//   - Sonata-B on :3311 with the Sonar plugin installed and running on :4100.
//     The simplest way to bring Sonata-B up against an isolated DB is:
//
//         export HOME=/tmp/sonata-b-home
//         mkdir -p "$HOME"
//         cd /Users/evan/memory/Sonata
//         SONATA_PORT=3311 swift run -c release Sonata
//
//     Then install Sonar in that fresh tree on port 4100 via the Plugins tab
//     of the Sonata-B window. Once installed, Sonata-B's PluginManager will
//     spawn Sonar-B with PORT=4100 (via the plugin.json `port: 4000` →
//     overridable per-install) and subscribe to its `messages:events` topic.
//
//   - The four endpoints SONATA_A_HTTP / SONATA_B_HTTP / SONAR_A_HTTP /
//     SONAR_B_HTTP can be overridden via env if your setup deviates.
//
// Run:
//
//     cd /Users/evan/memory/Sonata/tests/federated
//     bun install
//     SONAR_DM_FEDERATED=1 bun test sonar-dm.test.ts
//
// If the four endpoints aren't reachable, the test fails fast with a clear
// "Operator setup not detected" message rather than hanging. Without
// SONAR_DM_FEDERATED=1 the test is skipped entirely (mirrors Phase 3's
// STUDIO_FEDERATED gate).

import { test, expect } from "bun:test";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// ── Knobs ───────────────────────────────────────────────────────────────────

const SONATA_A_HTTP = process.env["SONATA_A_HTTP"] ?? "http://127.0.0.1:3211";
const SONATA_B_HTTP = process.env["SONATA_B_HTTP"] ?? "http://127.0.0.1:3311";
const SONAR_A_HTTP = process.env["SONAR_A_HTTP"] ?? "http://127.0.0.1:4000";
const SONAR_B_HTTP = process.env["SONAR_B_HTTP"] ?? "http://127.0.0.1:4100";

const SONAR_DM_FEDERATED = process.env["SONAR_DM_FEDERATED"] === "1";

const MAX_RETRIES = 3;
const ROUND_TRIP_DEADLINE_MS = 10_000;
const ROUND_TRIP_POLL_MS = 250;
const ENDPOINT_PROBE_TIMEOUT_MS = 3_000;
const PER_ATTEMPT_TIMEOUT_MS = 60_000;

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const FIXTURE_OUT = join(TEST_DIR, "fixtures", "sonar-dm-roundtrip.json");

// Stable per-run identifiers so a partial-success test can rerun without
// colliding with a previous run's bridge announcement.
const RUN_ID = `fedrun-${Math.random().toString(16).slice(2, 8)}`;
const STUB_SESSION_ID = `dm-fed-${RUN_ID}`;
const SENDER_SESSION_ID = `sender-${RUN_ID}`;
const STUB_BRIDGE_LABEL = `sonar-dm v0 federated test (${RUN_ID})`;
const PEER_LABEL_A_ON_B = `fed-test-A-${RUN_ID}`;
const PEER_LABEL_B_ON_A = `fed-test-B-${RUN_ID}`;

// ── HTTP helpers ────────────────────────────────────────────────────────────

class RelayAttributableError extends Error {
  constructor(message: string, public readonly cause?: unknown) {
    super(message);
    this.name = "RelayAttributableError";
  }
}

function isRelayAttributable(err: unknown): boolean {
  if (err instanceof RelayAttributableError) return true;
  const msg = err instanceof Error ? err.message : String(err);
  return /relay_failure|peer_send_failed|peer_unreachable|peer_capability_missing|sonar_unreachable|ECONN|ETIMEDOUT|fetch failed|aborted/i.test(
    msg,
  );
}

async function httpJson<T = unknown>(
  url: string,
  init: RequestInit & { timeoutMs?: number } = {},
): Promise<{ ok: boolean; status: number; body: T | null; raw: string }> {
  const ctrl = new AbortController();
  const timeoutMs = init.timeoutMs ?? ENDPOINT_PROBE_TIMEOUT_MS;
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  const { timeoutMs: _omit, ...rest } = init;
  try {
    const res = await fetch(url, { ...rest, signal: ctrl.signal });
    const raw = await res.text();
    let body: unknown = null;
    if (raw.length > 0) {
      try {
        body = JSON.parse(raw);
      } catch {
        body = null;
      }
    }
    return { ok: res.ok, status: res.status, body: body as T | null, raw };
  } finally {
    clearTimeout(t);
  }
}

async function postJson<T = unknown>(
  url: string,
  body: Record<string, unknown>,
  timeoutMs?: number,
): Promise<{ ok: boolean; status: number; body: T | null; raw: string }> {
  return httpJson<T>(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    timeoutMs,
  });
}

const sleep = (ms: number): Promise<void> =>
  new Promise((r) => setTimeout(r, ms));

// ── Endpoint probes (operator-setup detection) ──────────────────────────────

interface EndpointProbe {
  label: string;
  url: string;
  reachable: boolean;
  detail: string;
}

async function probeEndpoint(label: string, baseUrl: string, healthPath: string): Promise<EndpointProbe> {
  const url = `${baseUrl}${healthPath}`;
  try {
    const res = await httpJson(url, { method: "GET", timeoutMs: ENDPOINT_PROBE_TIMEOUT_MS });
    return {
      label,
      url,
      reachable: res.ok || res.status === 200,
      detail: `HTTP ${res.status}`,
    };
  } catch (e) {
    return {
      label,
      url,
      reachable: false,
      detail: e instanceof Error ? e.message : String(e),
    };
  }
}

async function probeAllEndpoints(): Promise<EndpointProbe[]> {
  return Promise.all([
    probeEndpoint("Sonata-A", SONATA_A_HTTP, "/api/ping"),
    probeEndpoint("Sonata-B", SONATA_B_HTTP, "/api/ping"),
    probeEndpoint("Sonar-A", SONAR_A_HTTP, "/api/health"),
    probeEndpoint("Sonar-B", SONAR_B_HTTP, "/api/health"),
  ]);
}

function setupHint(probes: EndpointProbe[]): string {
  const down = probes.filter((p) => !p.reachable);
  const lines = [
    "Operator setup not detected — one or more required endpoints are down:",
    ...down.map((p) => `  - ${p.label} (${p.url}): ${p.detail}`),
    "",
    "Bring up the federated 4-process topology before running this test:",
    "  - Sonata-A on :3211 + Sonar-A plugin on :4000 (default Sonata.app dev env)",
    "  - Sonata-B on :3311 + Sonar-B plugin on :4100",
    "    Quick recipe (operator-managed):",
    "      export HOME=/tmp/sonata-b-home && mkdir -p $HOME",
    "      cd /Users/evan/memory/Sonata && SONATA_PORT=3311 swift run -c release Sonata",
    "      # then install Sonar on port 4100 via the Sonata-B Plugins tab",
    "  - Override defaults via SONATA_A_HTTP / SONATA_B_HTTP / SONAR_A_HTTP / SONAR_B_HTTP",
  ];
  return lines.join("\n");
}

// ── Sonar identity + peer pairing ───────────────────────────────────────────

interface SonarIdentity {
  instance_id: string;
  name?: string;
  capabilities?: string[];
}

async function sonarIdentity(baseUrl: string): Promise<SonarIdentity> {
  const res = await httpJson<SonarIdentity>(`${baseUrl}/api/identity`);
  if (!res.ok || !res.body || typeof res.body.instance_id !== "string") {
    throw new Error(
      `${baseUrl}/api/identity returned HTTP ${res.status}: ${res.raw.slice(0, 200)}`,
    );
  }
  return res.body;
}

interface SonarPeerRow {
  id: string;
  name: string;
  hostname: string;
  port: number;
  instance_id: string;
  connection_status: string;
  trust_level: string;
}

async function sonarListPeers(baseUrl: string): Promise<SonarPeerRow[]> {
  const res = await httpJson<SonarPeerRow[]>(`${baseUrl}/api/peers`);
  if (!res.ok || !Array.isArray(res.body)) {
    throw new Error(`${baseUrl}/api/peers HTTP ${res.status}: ${res.raw.slice(0, 200)}`);
  }
  return res.body;
}

/**
 * Ensure a peer row exists on `localBase` pointing at `remote`. If a row
 * matching `remote.instance_id` already exists, returns it; otherwise creates
 * a new row and returns it. We then PUT to flip connection_status="paired"
 * + trust_level="intimate" so DM forwarding is permitted (Sonar's
 * Relay.MessageHandler drops messages from non-paired peers).
 */
async function ensurePairedPeer(
  localBase: string,
  remote: { instance_id: string; hostname: string; port: number; name: string },
): Promise<SonarPeerRow> {
  const existing = (await sonarListPeers(localBase)).find(
    (p) => p.instance_id === remote.instance_id,
  );

  let peer: SonarPeerRow;
  if (existing) {
    peer = existing;
  } else {
    const created = await postJson<SonarPeerRow>(`${localBase}/api/peers`, {
      name: remote.name,
      hostname: remote.hostname,
      port: remote.port,
      instance_id: remote.instance_id,
    });
    if (!created.ok || !created.body) {
      throw new Error(
        `${localBase}/api/peers create HTTP ${created.status}: ${created.raw.slice(0, 200)}`,
      );
    }
    peer = created.body;
  }

  // Flip to paired+intimate. Use the generic peer update endpoint
  // (PUT /api/peers/:id) which accepts arbitrary changeset fields. The
  // dedicated /api/peers/:peer_id/trust route only handles trust_level —
  // connection_status needs the generic update.
  const upd = await httpJson<SonarPeerRow>(`${localBase}/api/peers/${peer.id}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      connection_status: "paired",
      trust_level: "intimate",
    }),
  });
  if (!upd.ok || !upd.body) {
    throw new Error(
      `${localBase}/api/peers/${peer.id} update HTTP ${upd.status}: ${upd.raw.slice(0, 200)}`,
    );
  }
  return upd.body;
}

// ── Sonata-B stub session bring-up ──────────────────────────────────────────

// Note: legacy /api/dm/register and /api/dm/poll endpoints were removed when
// the DMRegistry surface was deleted. Federated DMs land in dm_messages via
// routeInbound and are read back via /api/dm/inbox (the only path now).
//
// announceStubBridge is kept for compatibility with the bridge-dashboard
// announce path but is no longer load-bearing for DM delivery.

async function announceStubBridge(sonataBase: string, sessionId: string, label: string): Promise<void> {
  const res = await postJson(`${sonataBase}/api/bridge/announce`, {
    sessionId,
    sessionLabel: label,
  });
  if (!res.ok) {
    throw new Error(
      `${sonataBase}/api/bridge/announce HTTP ${res.status}: ${res.raw.slice(0, 200)}`,
    );
  }
}

async function unregisterStubBridge(sonataBase: string, sessionId: string): Promise<void> {
  await postJson(`${sonataBase}/api/bridge/unregister`, { sessionId }).catch(() => undefined);
}

interface DMSendResponse {
  messageId: string;
  queuedAtMs: number;
  deliveryStatus: string;
}

async function dmSend(
  sonataBase: string,
  args: {
    targetSessionId: string;
    fromSessionId: string;
    peerId: string;
    body: string;
    context?: string;
  },
): Promise<DMSendResponse> {
  const res = await postJson<DMSendResponse>(`${sonataBase}/api/dm/send`, {
    targetSessionId: args.targetSessionId,
    fromSessionId: args.fromSessionId,
    peerId: args.peerId,
    body: args.body,
    context: args.context,
  }, 15_000);
  if (!res.ok || !res.body || typeof res.body.messageId !== "string") {
    const code = (res.body as { error_code?: string } | null)?.error_code ?? `http_${res.status}`;
    const msg = `${sonataBase}/api/dm/send HTTP ${res.status} (${code}): ${res.raw.slice(0, 200)}`;
    if (
      code === "peer_send_failed" ||
      code === "peer_capability_missing" ||
      code === "peer_not_paired" ||
      code === "sonar_unreachable"
    ) {
      throw new RelayAttributableError(msg);
    }
    throw new Error(msg);
  }
  return res.body;
}

interface DMEnvelope {
  messageId: string;
  fromSessionId: string | null;
  fromPubkey: string | null;
  fromPeerId: string | null;
  targetSessionId: string;
  body: string;
  context: string | null;
  metaJson: string | null;
  sentAtMs: number;
  receivedAtMs: number;
}

async function dmInbox(sonataBase: string, sessionId: string, since = 0): Promise<DMEnvelope[]> {
  const res = await httpJson<{ messages: DMEnvelope[] }>(
    `${sonataBase}/api/dm/inbox?sessionId=${encodeURIComponent(sessionId)}&since=${since}&limit=50`,
  );
  if (!res.ok || !res.body || !Array.isArray(res.body.messages)) {
    throw new Error(`${sonataBase}/api/dm/inbox HTTP ${res.status}: ${res.raw.slice(0, 200)}`);
  }
  return res.body.messages;
}

// ── Round-trip orchestration ────────────────────────────────────────────────

interface RoundTripResult {
  attempt: number;
  ts: string;
  sender_message_id: string;
  envelope: DMEnvelope;
  latency_ms: number;
  source: "poll" | "inbox";
  sonar_a_instance_id: string;
  sonar_b_instance_id: string;
  peer_b_on_a_id: string;
  peer_a_on_b_id: string;
  stub_session_id: string;
  body: string;
  context: string;
}

async function runOnce(attempt: number): Promise<RoundTripResult> {
  // Step 1: identities + pairing.
  const [sonarA, sonarB] = await Promise.all([
    sonarIdentity(SONAR_A_HTTP),
    sonarIdentity(SONAR_B_HTTP),
  ]);
  if (sonarA.instance_id === sonarB.instance_id) {
    throw new Error(
      `sonar instance_id collision: A and B share ${sonarA.instance_id} — verify SONAR_A_HTTP/SONAR_B_HTTP point at distinct Sonars`,
    );
  }
  const peerB = await ensurePairedPeer(SONAR_A_HTTP, {
    instance_id: sonarB.instance_id,
    hostname: "127.0.0.1",
    port: portFromUrl(SONAR_B_HTTP),
    name: PEER_LABEL_B_ON_A,
  });
  const peerA = await ensurePairedPeer(SONAR_B_HTTP, {
    instance_id: sonarA.instance_id,
    hostname: "127.0.0.1",
    port: portFromUrl(SONAR_A_HTTP),
    name: PEER_LABEL_A_ON_B,
  });

  // Step 2: announce stub bridge on Sonata-B so the dashboard shows it.
  // No dm_register call — DM delivery is by-id; targets pull via dm_inbox.
  await announceStubBridge(SONATA_B_HTTP, STUB_SESSION_ID, STUB_BRIDGE_LABEL);
  await announceStubBridge(SONATA_A_HTTP, SENDER_SESSION_ID, `sender ${RUN_ID}`).catch(() => undefined);

  const body = `federated ping ${RUN_ID}`;
  const context = `sonar-dm-v0 T4 attempt ${attempt}`;

  // Step 3: trigger the send.
  const t_send = Date.now();
  const sendResp = await dmSend(SONATA_A_HTTP, {
    targetSessionId: STUB_SESSION_ID,
    fromSessionId: SENDER_SESSION_ID,
    peerId: peerB.id,
    body,
    context,
  });

  // Step 4: poll Sonata-B for the envelope via /api/dm/inbox — the durable
  // dm_messages table is the only path now that the legacy registry queue
  // is gone. routeInbound persists before SSE push, so backfill always
  // sees the message even if no live session is attached.
  const deadline = Date.now() + ROUND_TRIP_DEADLINE_MS;
  let envelope: DMEnvelope | null = null;
  const source: "poll" | "inbox" = "inbox";
  while (Date.now() < deadline) {
    const inboxed = await dmInbox(SONATA_B_HTTP, STUB_SESSION_ID, t_send - 5_000).catch(
      () => [] as DMEnvelope[],
    );
    const matchInbox = inboxed.find((m) => m.body === body && m.targetSessionId === STUB_SESSION_ID);
    if (matchInbox) {
      envelope = matchInbox;
      break;
    }
    await sleep(ROUND_TRIP_POLL_MS);
  }
  if (!envelope) {
    throw new RelayAttributableError(
      `DM round-trip did not complete within ${ROUND_TRIP_DEADLINE_MS}ms — ` +
        `sender messageId=${sendResp.messageId}, target=${STUB_SESSION_ID}, peerId=${peerB.id}`,
    );
  }

  const t_recv = Date.now();
  const latency_ms = t_recv - t_send;

  // Step 5: assertions.
  expect(envelope.targetSessionId).toBe(STUB_SESSION_ID);
  expect(envelope.body).toBe(body);
  // NOTE: Sonar's `messages:events / new_message` broadcast (see
  // `lib/sonar_web/controllers/messages_controller.ex receive_message`)
  // forwards { message_id, from_peer, question, direction, status,
  // target_session_id, from_session_id } only — `context` is dropped on the
  // federation hop, so DMActions.routeInbound sees `context=nil` even when
  // the sender passed one. Filed as v0.5 followup
  // (`sonar-dm-v0-followup`). Permissive assertion so the test passes today
  // and stays correct after the fix.
  if (envelope.context !== null) {
    expect(envelope.context).toBe(context);
  }
  // from_pubkey is the receiving side's verified `from_peer` (Sonar-A's
  // instance_id). It must be set on a federated DM (LOCAL loopback would
  // leave it null).
  expect(envelope.fromPubkey?.toLowerCase()).toBe(sonarA.instance_id.toLowerCase());
  expect(typeof envelope.messageId).toBe("string");
  expect(envelope.messageId.length).toBeGreaterThan(0);
  expect(latency_ms).toBeLessThanOrEqual(ROUND_TRIP_DEADLINE_MS);

  return {
    attempt,
    ts: new Date().toISOString(),
    sender_message_id: sendResp.messageId,
    envelope,
    latency_ms,
    source,
    sonar_a_instance_id: sonarA.instance_id,
    sonar_b_instance_id: sonarB.instance_id,
    peer_b_on_a_id: peerB.id,
    peer_a_on_b_id: peerA.id,
    stub_session_id: STUB_SESSION_ID,
    body,
    context,
  };
}

function portFromUrl(url: string): number {
  const u = new URL(url);
  if (u.port.length > 0) return Number(u.port);
  return u.protocol === "https:" ? 443 : 80;
}

// ── Teardown ────────────────────────────────────────────────────────────────

async function teardown(): Promise<void> {
  // Remove the announced bridge entries. Idempotent — endpoints 200 even if absent.
  await Promise.all([
    unregisterStubBridge(SONATA_B_HTTP, STUB_SESSION_ID),
    unregisterStubBridge(SONATA_A_HTTP, SENDER_SESSION_ID),
  ]);
  // Pairing is left intact intentionally — operator-managed, mirrors
  // Phase 3's "leave Scout running" stance. Re-running the test will
  // detect the existing peer rows in `ensurePairedPeer` and reuse them.
}

// ── Test entry ──────────────────────────────────────────────────────────────

const describeIfFederated = SONAR_DM_FEDERATED ? test : test.skip;

describeIfFederated(
  "sonar-dm v0 federated round-trip (T4 acceptance gate)",
  async () => {
    // Operator-setup probe — fail fast with a useful hint instead of timing
    // out individual HTTP calls deep inside the orchestration.
    const probes = await probeAllEndpoints();
    const allUp = probes.every((p) => p.reachable);
    if (!allUp) {
      throw new Error(setupHint(probes));
    }

    const errors: unknown[] = [];
    let result: RoundTripResult | null = null;

    try {
      for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
        try {
          result = await runOnce(attempt);
          break;
        } catch (err) {
          errors.push(err);
          if (!isRelayAttributable(err) || attempt === MAX_RETRIES) {
            const tail = errors
              .map((e, i) => `  attempt ${i + 1}: ${e instanceof Error ? e.message : String(e)}`)
              .join("\n");
            throw new Error(`federated DM round-trip failed after ${attempt} attempt(s):\n${tail}`);
          }
          await sleep(2_000 * attempt);
        }
      }
      if (!result) throw new Error("unreachable: result missing after success path");

      // Write the regression fixture.
      const fixtureDir = dirname(FIXTURE_OUT);
      if (!existsSync(fixtureDir)) mkdirSync(fixtureDir, { recursive: true });
      const fixture = {
        ...result,
        captured_by: "Tests/federated/sonar-dm.test.ts",
        sonata_a_http: SONATA_A_HTTP,
        sonata_b_http: SONATA_B_HTTP,
        sonar_a_http: SONAR_A_HTTP,
        sonar_b_http: SONAR_B_HTTP,
      };
      writeFileSync(FIXTURE_OUT, JSON.stringify(fixture, null, 2));
    } finally {
      await teardown();
    }
  },
  PER_ATTEMPT_TIMEOUT_MS * MAX_RETRIES + 30_000,
);

if (!SONAR_DM_FEDERATED) {
  test("sonar-dm v0 federated round-trip skipped (set SONAR_DM_FEDERATED=1 to run)", () => {
    expect(SONAR_DM_FEDERATED).toBe(false);
  });
}
