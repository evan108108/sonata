#!/usr/bin/env bun
/**
 * sonata-bridge — Claude Code channel MCP server for Sonata
 *
 * Replaces convex-bridge. Connects to Sonata's HTTP API.
 * Registers as a worker, claims events, pushes them into the Claude session.
 * Exposes complete_event / fail_event tools.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { createHash } from "node:crypto";
import { appendFileSync, mkdirSync, readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";

// --- Config ---

const SONATA_API = process.env.SONATA_API || "http://localhost:3211";

// --- Crash-resilience scaffolding ---
//
// The bridge is the beating heart of Sonata: when it dies, the supervisor and
// every worker session it serves go blind, and the parent claude process has
// no protocol to respawn an MCP child. Three layers of defense:
//
//   1. Top-level uncaughtException / unhandledRejection handlers append a
//      breadcrumb to ~/.sonata/logs/bridge-crashes.log and DO NOT exit. Bun
//      defaults to terminating on these; we explicitly opt out.
//   2. SIGPIPE is ignored — a broken stdio write would otherwise kill the
//      process before our handlers can react.
//   3. safeInterval() wraps every periodic callback so a thrown error in one
//      tick can't kill the timer (and bun) for every other loop.
//
// The remaining "I should exit" trigger — persistent stdio-transport failure
// (parent claude is gone) — is detected via the MCP notification health budget
// in the worker/supervisor event loop.

const BRIDGE_LOG_DIR = join(homedir(), ".sonata", "logs");
const BRIDGE_CRASH_LOG = join(BRIDGE_LOG_DIR, "bridge-crashes.log");

function logCrash(label: string, err: unknown): void {
  try {
    mkdirSync(BRIDGE_LOG_DIR, { recursive: true });
    const ts = new Date().toISOString();
    const stack = err instanceof Error ? (err.stack || err.message) : String(err);
    const role = process.env.SONATA_ROLE || "unknown";
    const wid = process.env.WORKER_ID || "(none)";
    const line = `[${ts}] ${label} role=${role} workerId=${wid} pid=${process.pid}\n${stack}\n\n`;
    appendFileSync(BRIDGE_CRASH_LOG, line);
  } catch { /* nothing we can do */ }
  try { console.error(`[sonata-bridge] ${label}: ${err instanceof Error ? err.message : err}`); } catch {}
}

process.on("uncaughtException", (err) => { logCrash("uncaughtException", err); });
process.on("unhandledRejection", (reason) => { logCrash("unhandledRejection", reason); });
// Ignore SIGPIPE so a closed stdio peer mid-write doesn't bypass our handlers.
try { process.on("SIGPIPE", () => { /* swallow */ }); } catch {}

/** Wrap a setInterval callback so thrown errors are logged instead of killing
 * the bun process. Returns the timer handle exactly like setInterval. */
function safeInterval(name: string, fn: () => void | Promise<void>, ms: number): ReturnType<typeof setInterval> {
  return setInterval(async () => {
    try {
      await fn();
    } catch (err) {
      logCrash(`safeInterval(${name})`, err);
    }
  }, ms);
}

// MCP-notification health budget. Channel notifications go out via stdio; if
// the parent claude process has died, every notify throws EPIPE. We tolerate
// transient flaps but if the failure streak crosses the threshold, the parent
// is genuinely gone — exit so the SupervisorCoordinator/WorkerCoordinator can
// observe processTerminated and respawn us. The threshold matches what would
// take ~CLAIM_INTERVAL_MS * NOTIFY_FAIL_THRESHOLD seconds (>15s) to trip,
// which is much longer than any normal stdio latency spike.
const NOTIFY_FAIL_THRESHOLD = 5;
let notifyFailureStreak = 0;

/** Safe wrapper for mcp.notification. Returns true on success. On persistent
 * failure (likely dead stdio), exits the process so the coordinator respawns. */
async function safeNotify(notification: { method: string; params: unknown }): Promise<boolean> {
  try {
    await (mcp as unknown as { notification: (n: unknown) => Promise<void> }).notification(notification);
    notifyFailureStreak = 0;
    return true;
  } catch (err) {
    notifyFailureStreak += 1;
    logCrash(`mcp.notification(streak=${notifyFailureStreak})`, err);
    if (notifyFailureStreak >= NOTIFY_FAIL_THRESHOLD) {
      console.error(`[sonata-bridge] notification failures hit threshold (${NOTIFY_FAIL_THRESHOLD}); stdio likely dead — exiting for coordinator respawn`);
      process.exit(0);
    }
    return false;
  }
}

const WORKER_ID = process.env.WORKER_ID;
const SESSION_LABEL = process.env.SESSION_LABEL;
const SONA_SESSION_ID = process.env.SONA_SESSION_ID;
const HEARTBEAT_INTERVAL_MS = 15_000;
const CLAIM_INTERVAL_MS = 5_000;
// Adaptive AFK cadence: poll fast when something is registered for our
// sessionId, back off when idle. The server reports tokensRegistered on every
// poll response so we can snap back to fast on the very next tick after a
// registration appears.
const AFK_POLL_FAST_MS = 5_000;
const AFK_POLL_IDLE_MS = 30_000;
const DM_POLL_INTERVAL_MS = 5_000;
let lastProgressMs = Date.now();

// Stable per-bridge-process identity for AFK and DM routing. Worker bridges
// already have a WORKER_ID; sessions launched by Sonata.app get SONA_SESSION_ID;
// everything else falls back to a deterministic `claude-<ppid>` so the sibling
// mem-server.ts (same Claude Code parent) can compute the same value without
// any IPC. Determinism matters because mem-server auto-injects sessionId into
// afk_register calls — see mem-server.ts.
const BRIDGE_SESSION_ID = WORKER_ID || SONA_SESSION_ID || `claude-${process.ppid}`;
let afkPollTimer: ReturnType<typeof setInterval> | null = null;

// DM (Sonar session-addressable direct messages) — single registration per
// bridge process keyed by BRIDGE_SESSION_ID. The poll loop only runs while
// dmRegistered is true; sonar_dm_unregister flips it back off.
let dmPollTimer: ReturnType<typeof setInterval> | null = null;
let dmRegistered = false;

// --- Live monitoring: in-flight event tracking ---

interface InFlightEvent {
  eventId: string;
  eventType: string;
  promptHash: string;
}
let inFlight: InFlightEvent | null = null;

/** Resolve the running JSONL transcript path for this worker's session.
 *
 * Two subtleties caught while bringing this online (2026-05-06):
 *   1. Claude Code's project-dir encoding replaces BOTH `/` and `.` with `-`,
 *      not just `/`. e.g. `/Users/evan/.sonata/worker` becomes
 *      `-Users-evan--sonata-worker`, NOT `-Users-evan-.sonata-worker`.
 *   2. `--session-id` is intent, not reality — Claude often generates its own
 *      session id and writes the transcript under that, so the DB-tracked
 *      sessionId may not match what's on disk.
 *
 * Strategy: encode the cwd correctly, then prefer the explicit SONA_SESSION_ID
 * file if it exists; otherwise fall back to the most-recently-modified .jsonl
 * in the dir, since each worker's bridge sits inside exactly one live Claude
 * session and that session is the one being touched. */
function resolveTranscriptPath(): string | null {
  const cwd = process.cwd();
  const encoded = cwd.replace(/[\/.]/g, "-");
  const dir = join(homedir(), ".claude", "projects", encoded);

  if (SONA_SESSION_ID) {
    const explicit = join(dir, `${SONA_SESSION_ID}.jsonl`);
    if (existsSync(explicit)) return explicit;
  }

  try {
    const files = readdirSync(dir).filter((f) => f.endsWith(".jsonl"));
    if (files.length === 0) return null;
    let bestPath: string | null = null;
    let bestMtime = 0;
    for (const f of files) {
      const p = join(dir, f);
      try {
        const s = statSync(p);
        if (s.mtimeMs > bestMtime) {
          bestMtime = s.mtimeMs;
          bestPath = p;
        }
      } catch { /* skip unreadable */ }
    }
    return bestPath;
  } catch {
    return null;
  }
}

/** Stable per-(eventType, worker-pool, cwd) prompt-prefix hash. v0 proxy for
 * "system + skill + tools" — those are determined by the worker pool's
 * CLAUDE.md, the session-label-driven mcp config, and the working dir. */
function computePromptHash(eventType: string): string {
  const material = [eventType, SESSION_LABEL || "", process.cwd()].join("|");
  return createHash("sha256").update(material).digest("hex").slice(0, 8);
}

/** Read the transcript JSONL and sum usage across all assistant turns. Returns
 * null if the file isn't readable yet. */
function readTranscriptUsage(transcriptPath: string): {
  totalTokens: number;
  inputTokens: number;
  cacheReadTokens: number;
} | null {
  try {
    // Whole-file read is fine: workers' transcripts are well under a MB and we
    // need cumulative usage, not just the last turn.
    const text = readFileSync(transcriptPath, "utf-8");
    let totalTokens = 0, inputTokens = 0, cacheReadTokens = 0;
    let sawAssistant = false;
    for (const line of text.split("\n")) {
      if (!line) continue;
      let entry: any;
      try { entry = JSON.parse(line); } catch { continue; }
      if (entry.type !== "assistant") continue;
      const usage = entry.message?.usage;
      if (!usage) continue;
      sawAssistant = true;
      const input = usage.input_tokens || 0;
      const cacheCreate = usage.cache_creation_input_tokens || 0;
      const cacheRead = usage.cache_read_input_tokens || 0;
      const output = usage.output_tokens || 0;
      totalTokens += input + cacheCreate + cacheRead + output;
      inputTokens += input + cacheCreate + cacheRead;
      cacheReadTokens += cacheRead;
    }
    if (!sawAssistant) return null;
    return { totalTokens, inputTokens, cacheReadTokens };
  } catch {
    return null;
  }
}

/** Snapshot usage at the moment the event is claimed, so subsequent
 * heartbeats report tokens *for this event only* (not session lifetime). */
let usageBaseline: { totalTokens: number; inputTokens: number; cacheReadTokens: number } | null = null;

/** Register (or re-register) this worker. Called on boot and on first 410 response
 * from /heartbeat (server lost our row — supervisor purge, predecessor-cleanup, etc). */
async function registerWorker(): Promise<void> {
  try {
    const res = await fetch(`${SONATA_API}/api/worker/register`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        workerId: WORKER_ID,
        sessionLabel: SESSION_LABEL,
        capabilities: ["email", "task", "alert"],
      }),
    });
    if (!res.ok) {
      console.error(`[sonata-bridge] Register failed: HTTP ${res.status}`);
    } else {
      console.error(`[sonata-bridge] Registered as ${WORKER_ID}`);
    }
  } catch (err: any) {
    console.error(`[sonata-bridge] Register threw: ${err?.message ?? err}`);
  }
}

// Track the most recent 410 timestamp + heartbeat failure streak so we can
// distinguish "transient purge" from "real predecessor-cleanup" and surface
// persistent connectivity issues without exiting.
let lastHeartbeat410At = 0;
let heartbeatFailureStreak = 0;

/** Send the standard worker heartbeat plus, if an event is in flight,
 * the per-event token deltas read from the running transcript JSONL. */
async function pushLiveHeartbeat(): Promise<void> {
  const body: any = { workerId: WORKER_ID, lastProgressAt: lastProgressMs };
  body.sessionLabel = SESSION_LABEL || null;
  body.cwdBasename = process.cwd().split("/").pop() || null;
  if (inFlight) {
    body.currentSlug = inFlight.eventType;
    body.promptHash = inFlight.promptHash;
    const transcriptPath = resolveTranscriptPath();
    if (transcriptPath) {
      const usage = readTranscriptUsage(transcriptPath);
      if (usage) {
        const baseline = usageBaseline ?? { totalTokens: 0, inputTokens: 0, cacheReadTokens: 0 };
        body.currentEventTokens = Math.max(0, usage.totalTokens - baseline.totalTokens);
        body.currentInputTokens = Math.max(0, usage.inputTokens - baseline.inputTokens);
        body.currentCacheReadTokens = Math.max(0, usage.cacheReadTokens - baseline.cacheReadTokens);
      }
    }
  }
  try {
    const res = await fetch(`${SONATA_API}/api/worker/heartbeat`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (res.status === 410) {
      // Server has no row for us. Two possible causes:
      //   1. Transient purge — supervisor's worker_purge swept us during a
      //      missed-heartbeat window. We are still the legitimate worker for
      //      this sessionLabel; re-register and continue.
      //   2. Predecessor-cleanup — a fresh bridge claimed our sessionLabel.
      //      Re-registering would ping-pong; we must exit.
      // Heuristic: re-register on the first 410, but if we get another 410
      // within 30s, treat it as predecessor-cleanup and exit. The fresh bridge
      // will keep claiming our row and our re-register attempts will keep
      // losing the race; two 410s in 30s is the unmistakable signal.
      const now = Date.now();
      if (now - lastHeartbeat410At < 30_000) {
        console.error(`[sonata-bridge] Two 410 Gones in <30s — treating as predecessor-cleanup; exiting (workerId=${WORKER_ID})`);
        process.exit(0);
      }
      lastHeartbeat410At = now;
      console.error(`[sonata-bridge] Heartbeat got 410 Gone — re-registering ${WORKER_ID} (transient purge?)`);
      await registerWorker();
    } else if (!res.ok) {
      heartbeatFailureStreak += 1;
      if (heartbeatFailureStreak === 3 || heartbeatFailureStreak % 10 === 0) {
        console.error(`[sonata-bridge] Heartbeat HTTP ${res.status} (streak=${heartbeatFailureStreak})`);
      }
    } else {
      heartbeatFailureStreak = 0;
    }
  } catch (err: any) {
    heartbeatFailureStreak += 1;
    if (heartbeatFailureStreak === 3 || heartbeatFailureStreak % 10 === 0) {
      console.error(`[sonata-bridge] Heartbeat threw (streak=${heartbeatFailureStreak}): ${err?.message ?? err}`);
    }
  }
}

// Only act as a worker when SONA_WORKER=1 is set AND both WORKER_ID and
// SESSION_LABEL are explicitly provided. Without them, sessions started
// outside the Sonata-spawned pool used to silently auto-register with
// bogus IDs and label="worker", polluting the workers table.
const IS_WORKER = process.env.SONA_WORKER === "1" && !!WORKER_ID && !!SESSION_LABEL;
if (process.env.SONA_WORKER === "1" && !IS_WORKER) {
  console.error("[sonata-bridge] SONA_WORKER=1 but WORKER_ID/SESSION_LABEL missing — not registering as worker");
}
const SONATA_ROLE = process.env.SONATA_ROLE || "worker";
const IS_SUPERVISOR = SONATA_ROLE === "supervisor";

// --- MCP Server ---

const mcp = new Server(
  { name: "sonata-bridge", version: "0.1.0" },
  {
    capabilities: {
      experimental: { "claude/channel": {} },
      tools: {},
    },
    instructions: `You are a Sona Worker receiving events from the Sonata backend via the sonata-bridge channel.

When a <channel source="sonata-bridge"> event arrives, it contains a work item. The meta attributes include:
- event_id: the event ID (use for completing events)
- event_type: the type of event (email, task, alert, etc.)

IMPORTANT: Before processing ANY event:
1. Use mem_recall MCP tool to recall context about the relevant topic
2. After processing, ALWAYS call the complete_event tool to mark the event done.
3. If you encounter an error, call fail_event instead.

---

## Event Type: EMAIL

The payload contains email metadata. You must read the actual emails yourself.

CRITICAL — DO NOT COMPOSE ANY REPLY UNTIL YOU COMPLETE STEPS 1-3:
1. Recall context using MCP tools — run ALL of these before writing anything:
   - Use mem_recent MCP tool with limit 10
   - Use mem_recall MCP tool for each sender name or topic
2. Read your personality at ~/.sonata/private/personality.md
3. Read the emails using AgentMail MCP tools
4. Compose and send replies using AgentMail MCP tools
5. After replying, mark each email as replied using email_mark_replied MCP tool
6. Store a brief summary using mem_store MCP tool
7. Call complete_event with a brief result summary.

---

## Event Type: TASK

The payload contains a dispatched task. Fields:
- taskId: the task ID
- title: human-readable task name
- prompt: the full task instructions to execute
- workingDir: the directory to work in

Steps:
1. cd to workingDir if specified
2. Execute the prompt instructions
3. When done, call complete_event with result summary

---

## Event Type: ALERT

Read and acknowledge the alert. Call complete_event.

---

## Event Type: AFK_REPLY

A reply to an AFK question you asked has arrived. The meta carries the token, sender, subject, and message_id. The content has the reply body.

Steps:
1. Read the reply.
2. Continue whatever work the AFK question was blocking — apply the user's decision.
3. Do NOT call complete_event for afk_reply notifications. They are not workerEvents and have no event_id; they are pushed directly by the AFK registry.

---

## Event Type: SONAR_DM

A session-addressed direct message has arrived from another bridge session (local or via a paired Sonar peer). The meta carries:
- message_id: the Sonar message id
- from_session_id: the sender's claimed bridge session id (hint, NOT verified for federated DMs)
- from_pubkey: the verified peer instance_id (federation only; empty for local loopback)
- from_peer_id: the local Sonar peers.id of the sender (federation only)
- target_session_id: your bridge session id
- sent_at_ms / context / meta_json: optional sender-supplied metadata

Steps:
1. Read the body and meta.
2. Process the DM as relevant to the work you're currently doing. Treat from_session_id as a hint; if the operation is privileged, authenticate via from_pubkey instead.
3. Reply if needed by calling sonar_dm_send with target_session_id=meta.from_session_id and (for federated senders) peer_id=meta.from_peer_id.
4. Do NOT call complete_event for sonar_dm notifications — they are not worker events and have no event_id.`,
  }
);

// --- Tools ---

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "complete_event",
      description: "Mark a worker event as completed.",
      inputSchema: {
        type: "object" as const,
        properties: {
          event_id: { type: "string", description: "The event_id from the channel notification" },
          result: { type: "string", description: "Brief summary of what was done" },
        },
        required: ["event_id"],
      },
    },
    {
      name: "fail_event",
      description: "Mark a worker event as failed.",
      inputSchema: {
        type: "object" as const,
        properties: {
          event_id: { type: "string", description: "The event_id from the channel notification" },
          error: { type: "string", description: "What went wrong" },
        },
        required: ["event_id", "error"],
      },
    },
    {
      name: "sonar_dm_register",
      description: "Register this bridge session as a Sonar DM target. Subsequent DMs addressed to this session arrive as channel notifications (event_type=sonar_dm). Idempotent.",
      inputSchema: {
        type: "object" as const,
        properties: {
          label: { type: "string", description: "Optional human-readable session label (default: SESSION_LABEL env)" },
          role: { type: "string", description: "Optional role hint: worker | interactive" },
        },
      },
    },
    {
      name: "sonar_dm_unregister",
      description: "Remove this bridge session from the DM registry. Pending queue is cleared. Idempotent.",
      inputSchema: {
        type: "object" as const,
        properties: {},
      },
    },
    {
      name: "sonar_dm_send",
      description: "Send a session-addressed DM. Local target: omit peer_id. Remote target: include peer_id (Sonar peers.id, NOT instance_id).",
      inputSchema: {
        type: "object" as const,
        properties: {
          target_session_id: { type: "string", description: "Target bridge session id (1-128 chars, [A-Za-z0-9_-])" },
          body: { type: "string", description: "Message body, ≤ 256 KB" },
          peer_id: { type: "string", description: "Sonar peer id (omit for local targets)" },
          context: { type: "string", description: "Optional context string" },
          meta: { type: "object", description: "Optional ≤4KB JSON metadata blob" },
        },
        required: ["target_session_id", "body"],
      },
    },
    {
      name: "sonar_dm_inbox",
      description: "Backfill: fetch persisted DMs addressed to this session since a timestamp. Use after restart/registration to catch up.",
      inputSchema: {
        type: "object" as const,
        properties: {
          since_ts: { type: "number", description: "Epoch ms; default 0 (returns up to limit)" },
          limit: { type: "number", description: "Max rows (default 50, max 500)" },
        },
      },
    },
  ],
}));

mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args } = req.params;

  if (name === "complete_event") {
    lastProgressMs = Date.now();
    const { event_id, result } = args as { event_id: string; result?: string };
    // CRITICAL: the supervisor's WORKER_ID is "supervisor" but it is NOT in the
    // workers table — it lives in supervisorState. Calling pushLiveHeartbeat()
    // here would hit /api/worker/heartbeat and get 410 Gone, which on line ~210
    // calls process.exit(0). That would kill the bridge on every single check
    // event completion. So: only touch the worker heartbeat for true workers.
    if (IS_SUPERVISOR) {
      try {
        await fetch(`${SONATA_API}/api/supervisor/heartbeat`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ sessionId: WORKER_ID }),
        });
      } catch { /* heartbeat is best-effort, don't fail the event */ }
      // supervisorEvents has no completion endpoint yet — claim is the only
      // state transition. Returning success here is the documented contract.
      inFlight = null;
      usageBaseline = null;
      return { content: [{ type: "text" as const, text: `Supervisor event ${event_id} acknowledged` }] };
    }
    if (IS_WORKER) {
      // Push one final heartbeat so the per-event token totals land in
      // promptCacheStats before complete_event clears the worker row.
      await pushLiveHeartbeat();
    }
    try {
      await fetch(`${SONATA_API}/api/worker/events/complete`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ eventId: event_id, workerId: WORKER_ID, result }),
      });
      return { content: [{ type: "text" as const, text: `Event ${event_id} completed` }] };
    } catch (err: any) {
      return { content: [{ type: "text" as const, text: `Error: ${err.message}` }], isError: true };
    } finally {
      inFlight = null;
      usageBaseline = null;
    }
  }

  if (name === "sonar_dm_register") {
    const { label, role } = args as { label?: string; role?: string };
    try {
      const res = await fetch(`${SONATA_API}/api/dm/register`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          sessionId: BRIDGE_SESSION_ID,
          sessionLabel: label ?? SESSION_LABEL ?? null,
          role: role ?? null,
        }),
      });
      if (!res.ok) {
        let detail = `HTTP ${res.status}`;
        try {
          const data: any = await res.json();
          if (data?.error_code || data?.message) {
            detail = `${data.error_code || res.status}: ${data.message || ""}`;
          }
        } catch { /* keep status-only detail */ }
        throw new Error(detail);
      }
      dmRegistered = true;
      ensureDMPollLoop();
      return {
        content: [{
          type: "text" as const,
          text: `Registered as DM target ${BRIDGE_SESSION_ID}. DMs will arrive as channel notifications (event_type=sonar_dm).`,
        }],
      };
    } catch (err: any) {
      return { content: [{ type: "text" as const, text: `Error: ${err.message}` }], isError: true };
    }
  }

  if (name === "sonar_dm_unregister") {
    try {
      await fetch(`${SONATA_API}/api/dm/unregister`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ sessionId: BRIDGE_SESSION_ID }),
      });
      dmRegistered = false;
      if (dmPollTimer) {
        clearInterval(dmPollTimer);
        dmPollTimer = null;
      }
      return {
        content: [{ type: "text" as const, text: `DM session ${BRIDGE_SESSION_ID} unregistered.` }],
      };
    } catch (err: any) {
      return { content: [{ type: "text" as const, text: `Error: ${err.message}` }], isError: true };
    }
  }

  if (name === "sonar_dm_send") {
    const {
      target_session_id,
      body,
      peer_id,
      context,
      meta,
    } = args as {
      target_session_id: string;
      body: string;
      peer_id?: string;
      context?: string;
      meta?: Record<string, unknown>;
    };

    // Bridge-side input validation — same regex/limits as Sonata's HTTP
    // handler, surfaced here so the caller gets immediate feedback without a
    // round-trip. Sonata still revalidates server-side.
    const sessionIdRe = /^[A-Za-z0-9_-]{1,128}$/;
    if (!target_session_id || !sessionIdRe.test(target_session_id)) {
      return {
        content: [{ type: "text" as const, text: `bad_session_id: ${target_session_id}` }],
        isError: true,
      };
    }
    if (typeof body !== "string" || body.length === 0) {
      return { content: [{ type: "text" as const, text: "body_empty" }], isError: true };
    }
    const bodyBytes = Buffer.byteLength(body, "utf8");
    if (bodyBytes > 262_144) {
      return { content: [{ type: "text" as const, text: "body_too_large" }], isError: true };
    }
    if (meta !== undefined && meta !== null) {
      try {
        const metaBytes = Buffer.byteLength(JSON.stringify(meta), "utf8");
        if (metaBytes > 4096) {
          return { content: [{ type: "text" as const, text: "meta_too_large" }], isError: true };
        }
      } catch (err: any) {
        return { content: [{ type: "text" as const, text: `meta_invalid: ${err.message}` }], isError: true };
      }
    }

    try {
      const res = await fetch(`${SONATA_API}/api/dm/send`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          targetSessionId: target_session_id,
          fromSessionId: BRIDGE_SESSION_ID,
          body,
          context,
          peerId: peer_id,
          meta,
        }),
      });
      let data: any = null;
      try { data = await res.json(); } catch { /* non-JSON error body */ }
      if (!res.ok) {
        const code = data?.error_code || String(res.status);
        const msg = data?.message || "";
        return {
          content: [{ type: "text" as const, text: `${code}: ${msg}` }],
          isError: true,
        };
      }
      return {
        content: [{
          type: "text" as const,
          text: JSON.stringify({
            message_id: data?.messageId,
            queued_at_ms: data?.queuedAtMs,
            delivery_status: data?.deliveryStatus,
          }),
        }],
      };
    } catch (err: any) {
      return { content: [{ type: "text" as const, text: `Error: ${err.message}` }], isError: true };
    }
  }

  if (name === "sonar_dm_inbox") {
    const { since_ts = 0, limit = 50 } = args as { since_ts?: number; limit?: number };
    try {
      const url =
        `${SONATA_API}/api/dm/inbox` +
        `?sessionId=${encodeURIComponent(BRIDGE_SESSION_ID)}` +
        `&since=${encodeURIComponent(String(since_ts))}` +
        `&limit=${encodeURIComponent(String(limit))}`;
      const res = await fetch(url);
      const data: any = await res.json();
      if (!res.ok) {
        const code = data?.error_code || String(res.status);
        const msg = data?.message || "";
        return {
          content: [{ type: "text" as const, text: `${code}: ${msg}` }],
          isError: true,
        };
      }
      return { content: [{ type: "text" as const, text: JSON.stringify(data) }] };
    } catch (err: any) {
      return { content: [{ type: "text" as const, text: `Error: ${err.message}` }], isError: true };
    }
  }

  if (name === "fail_event") {
    lastProgressMs = Date.now();
    const { event_id, error: errMsg } = args as { event_id: string; error: string };
    // Same supervisor-safety as complete_event: do NOT hit worker heartbeat.
    if (IS_SUPERVISOR) {
      try {
        await fetch(`${SONATA_API}/api/supervisor/heartbeat`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ sessionId: WORKER_ID }),
        });
      } catch {}
      inFlight = null;
      usageBaseline = null;
      return { content: [{ type: "text" as const, text: `Supervisor event ${event_id} failed: ${errMsg}` }] };
    }
    if (IS_WORKER) {
      await pushLiveHeartbeat();
    }
    try {
      await fetch(`${SONATA_API}/api/worker/events/fail`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ eventId: event_id, workerId: WORKER_ID, error: errMsg }),
      });
      return { content: [{ type: "text" as const, text: `Event ${event_id} failed` }] };
    } catch (err: any) {
      return { content: [{ type: "text" as const, text: `Error: ${err.message}` }], isError: true };
    } finally {
      inFlight = null;
      usageBaseline = null;
    }
  }

  throw new Error(`Unknown tool: ${name}`);
});

// --- AFK polling ---

/** Start the AFK reply poller if it isn't already running.
 *
 * The loop runs unconditionally for every bridge process (passive, worker,
 * supervisor) once boot completes. This makes `mcp__memory__afk_register` the
 * single safe registration call: as long as a bridge process is alive for the
 * registered sessionId, replies arrive as channel notifications. Servers do
 * the gating; we just drain.
 *
 * Cadence is adaptive: 5s while AFKRegistry has at least one token for our
 * sessionId, 30s otherwise. The server returns tokensRegistered on every
 * poll, so we re-tune on each tick. Snap-back to fast cadence happens on the
 * tick AFTER a registration lands (≤ 30s worst case). */
let afkCurrentIntervalMs = AFK_POLL_IDLE_MS;
function ensureAFKPollLoop(): void {
  if (afkPollTimer) return;
  scheduleAFKPoll(AFK_POLL_IDLE_MS);
}

function scheduleAFKPoll(intervalMs: number): void {
  if (afkPollTimer) clearInterval(afkPollTimer);
  afkCurrentIntervalMs = intervalMs;
  afkPollTimer = safeInterval("afk-poll", runAFKPollTick, intervalMs);
}

async function runAFKPollTick(): Promise<void> {
  try {
    const url = `${SONATA_API}/api/afk/poll?sessionId=${encodeURIComponent(BRIDGE_SESSION_ID)}`;
    const res = await fetch(url);
    if (!res.ok) return;
    const data: any = await res.json();
    const replies: any[] = data?.replies || [];
    const tokensRegistered: number = typeof data?.tokensRegistered === "number" ? data.tokensRegistered : 0;
    const desiredInterval = tokensRegistered > 0 ? AFK_POLL_FAST_MS : AFK_POLL_IDLE_MS;
    if (desiredInterval !== afkCurrentIntervalMs) {
      scheduleAFKPoll(desiredInterval);
    }
    for (const reply of replies) {
      const content = `[AFK reply for token ${reply.token}]\nFrom: ${reply.fromAddr}\nSubject: ${reply.subject}\n\n${reply.replyText}`;
      await safeNotify({
        method: "notifications/claude/channel",
        params: {
          content,
          meta: {
            event_type: "afk_reply",
            afk_token: String(reply.token || ""),
            message_id: String(reply.messageId || ""),
            from_addr: String(reply.fromAddr || ""),
            subject: String(reply.subject || ""),
          },
        },
      });
    }
  } catch {}
}

// --- DM polling ---

/** Start the Sonar-DM reply poller if it isn't already running. Independent
 * of the AFK loop (separate timer, separate endpoint) but shares
 * BRIDGE_SESSION_ID — both routes drain into the same Claude session. */
function ensureDMPollLoop(): void {
  if (dmPollTimer) return;
  dmPollTimer = safeInterval("dm-poll", async () => {
    if (!dmRegistered) return;
    try {
      const url = `${SONATA_API}/api/dm/poll?sessionId=${encodeURIComponent(BRIDGE_SESSION_ID)}`;
      const res = await fetch(url);
      if (!res.ok) return;
      const data: any = await res.json();
      const messages: any[] = data?.messages || [];
      for (const m of messages) {
        const sender = m.fromSessionId || m.fromPubkey || "unknown";
        await safeNotify({
          method: "notifications/claude/channel",
          params: {
            content: `[DM from ${sender}]\n${m.body || ""}`,
            meta: {
              event_type: "sonar_dm",
              message_id: String(m.messageId || ""),
              from_session_id: String(m.fromSessionId || ""),
              from_pubkey: String(m.fromPubkey || ""),
              from_peer_id: String(m.fromPeerId || ""),
              target_session_id: String(m.targetSessionId || ""),
              sent_at_ms: String(m.sentAtMs || ""),
              context: String(m.context || ""),
              meta_json: m.metaJson ? String(m.metaJson) : "",
            },
          },
        });
      }
    } catch {}
  }, DM_POLL_INTERVAL_MS);
}

/** Auto-register this bridge as a DM target so plain `claude` sessions are
 * reachable without a CLAUDE.md directive. Idempotent; safe to call after the
 * `sonar_dm_register` MCP tool has already run. 422 is the documented
 * "heartbeat-not-yet-propagated" signal — retried once after 500ms. Persistent
 * failure is logged but never crashes the bridge. */
async function autoRegisterDM(): Promise<void> {
  if (dmRegistered) return;
  const labelDefault = `${basename(process.cwd())}·${process.pid}`;
  const sessionLabel = SESSION_LABEL || labelDefault;
  const role = (process.env.SONA_WORKER === "1" || !!WORKER_ID) ? "worker" : "interactive";

  const attempt = async (): Promise<{ ok: boolean; status: number }> => {
    try {
      const res = await fetch(`${SONATA_API}/api/dm/register`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ sessionId: BRIDGE_SESSION_ID, sessionLabel, role }),
      });
      return { ok: res.ok, status: res.status };
    } catch {
      return { ok: false, status: 0 };
    }
  };

  let result = await attempt();
  if (!result.ok && result.status === 422) {
    await new Promise((r) => setTimeout(r, 500));
    result = await attempt();
  }
  if (result.ok) {
    dmRegistered = true;
    ensureDMPollLoop();
    console.error(`[sonata-bridge] DM auto-registered: sessionId=${BRIDGE_SESSION_ID} role=${role}`);
    void maybeFireRestartNudge();
  } else {
    console.error(`[sonata-bridge] DM auto-register failed (status ${result.status}); sonar_dm_register MCP tool can be used as fallback`);
  }
}

/** One-shot restart-recovery nudge. When Sonata.app respawns a worker after a
 * restart it sets SONATA_RESTART_NUDGE=1 in the child env; on first successful
 * DM auto-register we push a `sonata_restart` channel notification so the
 * resumed claude session knows to look at its last action and decide whether
 * to retry / recover / continue. Fire-and-forget; never crashes the bridge. */
async function maybeFireRestartNudge(): Promise<void> {
  if (process.env.SONATA_RESTART_NUDGE !== "1") return;
  const taskId = process.env.SONATA_RESTART_TASK_ID || "";
  const lastEventId = process.env.SONATA_RESTART_LAST_EVENT_ID || "";
  const restartedAt = Date.now();
  const content =
    `[SONATA_RESTART] task=${taskId} ts=${restartedAt}\n` +
    `Sonata.app was restarted. You are resumed in your prior conversation. ` +
    `Look at your most recent action — if it was a tool call without a result, ` +
    `decide whether to retry, recover, or continue. Otherwise carry on.`;
  const ok = await safeNotify({
    method: "notifications/claude/channel",
    params: {
      content,
      meta: {
        event_type: "sonata_restart",
        task_id: taskId,
        last_event_id: lastEventId,
        restarted_at_ms: String(restartedAt),
      },
    },
  });
  if (ok) {
    console.error("[sonata-bridge] sonata_restart nudge fired for task=" + taskId);
  }
}

/** Unregister DM on shutdown if we ever registered. Best-effort; safe if the
 * bridge crashes hard since pruneStale will eventually evict the row. */
async function unregisterDMOnShutdown(): Promise<void> {
  if (!dmRegistered) return;
  try {
    await fetch(`${SONATA_API}/api/dm/unregister`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sessionId: BRIDGE_SESSION_ID }),
    });
  } catch {}
}

// --- External bridge tracking ---
//
// Bridges that aren't pool workers/supervisors (typically interactive `claude`
// or claude-patched sessions with sonata-bridge configured as an MCP server)
// announce themselves so the Sonata dashboard can surface a live count.
// Workers/supervisors are tracked separately via the workers/supervisor tables
// and never call these endpoints.

const BRIDGE_HEARTBEAT_INTERVAL_MS = 15_000;

async function announceExternalBridge(): Promise<void> {
  try {
    await fetch(`${SONATA_API}/api/bridge/announce`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        sessionId: BRIDGE_SESSION_ID,
        sessionLabel: SESSION_LABEL || null,
        pid: process.pid,
      }),
    });
  } catch {}
}

async function heartbeatExternalBridge(): Promise<void> {
  try {
    await fetch(`${SONATA_API}/api/bridge/heartbeat`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sessionId: BRIDGE_SESSION_ID }),
    });
  } catch {}
}

async function unregisterExternalBridge(): Promise<void> {
  try {
    await fetch(`${SONATA_API}/api/bridge/unregister`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sessionId: BRIDGE_SESSION_ID }),
    });
  } catch {}
}

// Boot side-effects only run when this file is the entrypoint (bun /path/to/sonata-bridge.ts).
// Skips the boot when loaded as a module (syntax checks, test imports, IDE language server, etc.) so
// importing the file does not phantom-register against live Sonata.
if (import.meta.main) {
  // --- Connect MCP ---

  await mcp.connect(new StdioServerTransport());
  console.error(`[sonata-bridge] Connected. Worker: ${WORKER_ID}`);

  // --- Worker mode ---

  if (IS_WORKER || IS_SUPERVISOR) {
    // Register
    if (IS_SUPERVISOR) {
      try {
        await fetch(`${SONATA_API}/api/supervisor/heartbeat`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ sessionId: WORKER_ID }),
        });
        console.error(`[sonata-bridge] Supervisor registered as ${WORKER_ID}`);
      } catch (err: any) {
        console.error(`[sonata-bridge] Supervisor registration failed: ${err.message}`);
      }
    } else {
      await registerWorker();
      // First worker heartbeat so /api/dm/register can find our worker row.
      await pushLiveHeartbeat();
    }

    // Auto-register as a DM target now that this bridge is known to Sonata.
    await autoRegisterDM();

    // AFK poll loop is always on. mcp__memory__afk_register stores a token →
    // sessionId mapping; this loop drains replies for our BRIDGE_SESSION_ID
    // and pushes them as channel notifications. Workers' WORKER_ID is the
    // same sessionId mem-server.ts injects, so this just works.
    ensureAFKPollLoop();

    // Heartbeat — different endpoint for supervisor
    safeInterval("heartbeat", async () => {
      if (IS_SUPERVISOR) {
        await fetch(`${SONATA_API}/api/supervisor/heartbeat`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ sessionId: WORKER_ID }),
        });
      } else {
        await pushLiveHeartbeat();
      }
    }, HEARTBEAT_INTERVAL_MS);

    // Poll for events — different source for supervisor
    let knownEventIds = new Set<string>();

    safeInterval("event-claim", async () => {
      try {
        if (IS_SUPERVISOR) {
          // Supervisor: poll supervisorEvents table
          const res = await fetch(`${SONATA_API}/api/supervisor/events/claim`);
          if (!res.ok) return;
          const data: any = await res.json();
          if (!data || !data._id) return;

          const eventId = data._id;
          const eventType = data.type || "check";
          const payload = data.payload || "{}";

          if (knownEventIds.has(eventId)) return;
          knownEventIds.add(eventId);
          lastProgressMs = Date.now();

          let content = "";
          const meta: Record<string, string> = { event_id: eventId, event_type: eventType };

          if (eventType === "check") {
            content = "Periodic health check. Run your checklist and report findings.";
          } else if (eventType === "query") {
            try {
              const parsed = JSON.parse(payload);
              content = parsed.message || payload;
              if (parsed.messageId) meta.message_id = String(parsed.messageId);
            } catch {
              content = payload;
            }
          } else {
            content = payload;
          }

          console.error(`[sonata-bridge] Supervisor event ${eventId} (${eventType})`);
          await safeNotify({
            method: "notifications/claude/channel",
            params: { content, meta },
          });
        } else {
          // Worker: claim a pending event, then push assigned into session
          await fetch(`${SONATA_API}/api/worker/events/claim`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ workerId: WORKER_ID }),
          });

          // Fetch assigned events
          const res = await fetch(`${SONATA_API}/api/worker/events/recent?limit=10`);
          const events: any[] = await res.json();

          for (const evt of events) {
            if (evt.assignedTo !== WORKER_ID) continue;
            if (evt.status !== "assigned") continue;
            if (knownEventIds.has(evt._id)) continue;
            knownEventIds.add(evt._id);
            lastProgressMs = Date.now();

            console.error(`[sonata-bridge] Pushing event: ${evt.type} (${evt._id})`);

            // Track in-flight event for live monitoring heartbeats. Snapshot
            // the transcript usage NOW (at claim time) so even short events
            // that finish before the first heartbeat report a non-zero delta.
            inFlight = {
              eventId: evt._id,
              eventType: evt.type,
              promptHash: computePromptHash(evt.type),
            };
            {
              const transcriptPath = resolveTranscriptPath();
              usageBaseline = transcriptPath
                ? (readTranscriptUsage(transcriptPath) ?? { totalTokens: 0, inputTokens: 0, cacheReadTokens: 0 })
                : { totalTokens: 0, inputTokens: 0, cacheReadTokens: 0 };
            }

            try {
              const payload = JSON.parse(evt.payload);
              const content = typeof payload === "string"
                ? payload
                : payload.summary || payload.prompt || payload.body || JSON.stringify(payload);

              await safeNotify({
                method: "notifications/claude/channel",
                params: {
                  content: `[${evt.type.toUpperCase()}] ${content}`,
                  meta: {
                    event_id: evt._id,
                    event_type: evt.type,
                    priority: String(evt.priority),
                    timestamp: new Date(evt.createdAt).toISOString(),
                  },
                },
              });
            } catch (err: any) {
              console.error(`[sonata-bridge] Push error: ${err.message}`);
            }
          }
        }
      } catch {}
    }, CLAIM_INTERVAL_MS);

    // Cleanup on exit
    const cleanup = async () => {
      await unregisterDMOnShutdown();
      if (!IS_SUPERVISOR) {
        try {
          await fetch(`${SONATA_API}/api/worker/unregister`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ workerId: WORKER_ID }),
          });
        } catch {}
      }
      process.exit(0);
    };
    process.on("SIGTERM", cleanup);
    process.on("SIGINT", cleanup);

    const modeLabel = IS_SUPERVISOR ? "Supervisor" : "Worker";
    console.error(`[sonata-bridge] ${modeLabel} mode active. Claiming every ${CLAIM_INTERVAL_MS / 1000}s.`);
  } else {
    console.error(`[sonata-bridge] Passive mode. Tools available but not claiming events.`);
    // Interactive bridges still need to be reachable as DM targets so any plain
    // `claude` session can receive session-addressed messages.
    await autoRegisterDM();

    // Announce ourselves as a live external bridge so the dashboard and the
    // memory-namespace afk_register action can see we exist (and so AFK
    // registration through mem-server can validate routing).
    await announceExternalBridge();
    safeInterval("external-bridge-heartbeat", heartbeatExternalBridge, BRIDGE_HEARTBEAT_INTERVAL_MS);

    // AFK poll loop runs in passive mode too — interactive `claude` sessions
    // (including the orchestrator) can call mcp__memory__afk_register and rely
    // on this loop to deliver replies.
    ensureAFKPollLoop();

    const passiveCleanup = async () => {
      await unregisterDMOnShutdown();
      await unregisterExternalBridge();
      process.exit(0);
    };
    process.on("SIGTERM", passiveCleanup);
    process.on("SIGINT", passiveCleanup);
  }
}
