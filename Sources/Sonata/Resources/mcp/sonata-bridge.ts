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
import { createHash, randomUUID } from "node:crypto";
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// --- Config ---

const SONATA_API = process.env.SONATA_API || "http://localhost:3211";
const WORKER_ID = process.env.WORKER_ID;
const SESSION_LABEL = process.env.SESSION_LABEL;
const SONA_SESSION_ID = process.env.SONA_SESSION_ID;
const HEARTBEAT_INTERVAL_MS = 15_000;
const CLAIM_INTERVAL_MS = 5_000;
const AFK_POLL_INTERVAL_MS = 5_000;
let lastProgressMs = Date.now();

// Stable per-bridge-process identity for AFK routing. Worker bridges already
// have a WORKER_ID; non-worker (interactive) sessions get a fresh UUID at boot
// so the server has something to address replies to. When the bridge dies, the
// AFK registration dies with it — that's fine, AFK is transient.
const BRIDGE_SESSION_ID = WORKER_ID || SONA_SESSION_ID || randomUUID();
let afkPollTimer: ReturnType<typeof setInterval> | null = null;
const registeredAFKTokens = new Set<string>();

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

/** Send the standard worker heartbeat plus, if an event is in flight,
 * the per-event token deltas read from the running transcript JSONL. */
async function pushLiveHeartbeat(): Promise<void> {
  const body: any = { workerId: WORKER_ID, lastProgressAt: lastProgressMs };
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
      // Server has no row for us — either supervisor purged us, or a fresh bridge
      // claimed our sessionLabel (predecessor-cleanup). Exit the bridge process
      // and let the WorkerCoordinator decide whether to auto-restart. Re-registering
      // here would resurrect drained workers and ping-pong with the replacement.
      console.error(`[sonata-bridge] Heartbeat got 410 Gone — bridge ${WORKER_ID} exiting; coordinator will respawn if appropriate`);
      process.exit(0);
    } else if (!res.ok) {
      console.error(`[sonata-bridge] Heartbeat HTTP ${res.status}`);
    }
  } catch (err: any) {
    console.error(`[sonata-bridge] Heartbeat threw: ${err?.message ?? err}`);
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
3. Do NOT call complete_event for afk_reply notifications. They are not workerEvents and have no event_id; they are pushed directly by the AFK registry.`,
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
      name: "afk_register",
      description: "Register this session as the AFK target for a token. After calling this, end your turn — replies tagged [AFK:<token>] will arrive as channel notifications instead of needing inbox polling.",
      inputSchema: {
        type: "object" as const,
        properties: {
          token: { type: "string", description: "The AFK token (also embedded in the email subject as [AFK:<token>])" },
        },
        required: ["token"],
      },
    },
    {
      name: "afk_unregister",
      description: "Unregister an AFK token. Call this on AFK exit so replies stop being routed.",
      inputSchema: {
        type: "object" as const,
        properties: {
          token: { type: "string", description: "The AFK token to unregister" },
        },
        required: ["token"],
      },
    },
  ],
}));

mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args } = req.params;

  if (name === "complete_event") {
    lastProgressMs = Date.now();
    // Push one final heartbeat so the per-event token totals land in
    // promptCacheStats before complete_event clears the worker row.
    await pushLiveHeartbeat();
    const { event_id, result } = args as { event_id: string; result?: string };
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

  if (name === "afk_register") {
    const { token } = args as { token: string };
    try {
      const res = await fetch(`${SONATA_API}/api/afk/register`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token, sessionId: BRIDGE_SESSION_ID }),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      registeredAFKTokens.add(token);
      ensureAFKPollLoop();
      return { content: [{ type: "text" as const, text: `AFK token ${token} registered. Replies will arrive as channel notifications.` }] };
    } catch (err: any) {
      return { content: [{ type: "text" as const, text: `Error: ${err.message}` }], isError: true };
    }
  }

  if (name === "afk_unregister") {
    const { token } = args as { token: string };
    try {
      await fetch(`${SONATA_API}/api/afk/unregister`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token }),
      });
      registeredAFKTokens.delete(token);
      if (registeredAFKTokens.size === 0 && afkPollTimer) {
        clearInterval(afkPollTimer);
        afkPollTimer = null;
      }
      return { content: [{ type: "text" as const, text: `AFK token ${token} unregistered.` }] };
    } catch (err: any) {
      return { content: [{ type: "text" as const, text: `Error: ${err.message}` }], isError: true };
    }
  }

  if (name === "fail_event") {
    lastProgressMs = Date.now();
    await pushLiveHeartbeat();
    const { event_id, error: errMsg } = args as { event_id: string; error: string };
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

/** Start the AFK reply poller if it isn't already running. We share this loop
 * with the worker poll where possible, but in non-worker (interactive) sessions
 * the worker poll never starts, so AFK has its own. */
function ensureAFKPollLoop(): void {
  if (afkPollTimer) return;
  afkPollTimer = setInterval(async () => {
    if (registeredAFKTokens.size === 0) return;
    try {
      const url = `${SONATA_API}/api/afk/poll?sessionId=${encodeURIComponent(BRIDGE_SESSION_ID)}`;
      const res = await fetch(url);
      if (!res.ok) return;
      const data: any = await res.json();
      const replies: any[] = data?.replies || [];
      for (const reply of replies) {
        const content = `[AFK reply for token ${reply.token}]\nFrom: ${reply.fromAddr}\nSubject: ${reply.subject}\n\n${reply.replyText}`;
        await mcp.notification({
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
  }, AFK_POLL_INTERVAL_MS);
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
  }

  // Heartbeat — different endpoint for supervisor
  setInterval(async () => {
    try {
      if (IS_SUPERVISOR) {
        await fetch(`${SONATA_API}/api/supervisor/heartbeat`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ sessionId: WORKER_ID }),
        });
      } else {
        await pushLiveHeartbeat();
      }
    } catch {}
  }, HEARTBEAT_INTERVAL_MS);

  // Poll for events — different source for supervisor
  let knownEventIds = new Set<string>();

  setInterval(async () => {
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
        await mcp.notification({
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

            await mcp.notification({
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
}
