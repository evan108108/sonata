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

// --- Config ---

const SONATA_API = process.env.SONATA_API || "http://localhost:3211";
const WORKER_ID = process.env.WORKER_ID || `worker-${Date.now().toString(36)}`;
const SESSION_LABEL = process.env.SESSION_LABEL || "worker";
const SONA_SESSION_ID = process.env.SONA_SESSION_ID || undefined;
const HEARTBEAT_INTERVAL_MS = 15_000;
const CLAIM_INTERVAL_MS = 5_000;
let lastProgressMs = Date.now();

// Only act as a worker when SONA_WORKER=1 is set.
const IS_WORKER = process.env.SONA_WORKER === "1";
const SONATA_ROLE = process.env.SONATA_ROLE || "worker";
const IS_SUPERVISOR = SONATA_ROLE === "supervisor";
const IS_INSPECTOR = SONATA_ROLE === "inspector";

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

Read and acknowledge the alert. Call complete_event.`,
  }
);

// --- Tools ---

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: IS_INSPECTOR ? [] : [
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
  ],
}));

mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args } = req.params;

  if (name === "complete_event") {
    lastProgressMs = Date.now();
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
    }
  }

  if (name === "fail_event") {
    lastProgressMs = Date.now();
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
    }
  }

  throw new Error(`Unknown tool: ${name}`);
});

// --- Connect MCP ---

await mcp.connect(new StdioServerTransport());
console.error(`[sonata-bridge] Connected. Worker: ${WORKER_ID}`);

// --- Worker mode ---

if (IS_INSPECTOR) {
  console.error(`[sonata-bridge] Inspector mode — no registration, no claim, no heartbeat. MCP tools available.`);
} else if (IS_WORKER || IS_SUPERVISOR) {
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
    try {
      await fetch(`${SONATA_API}/api/worker/register`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          workerId: WORKER_ID,
          sessionLabel: SESSION_LABEL,
          sessionId: SONA_SESSION_ID,
          capabilities: ["email", "task", "alert"],
        }),
      });
      console.error(`[sonata-bridge] Registered as ${WORKER_ID}`);
    } catch (err: any) {
      console.error(`[sonata-bridge] Registration failed: ${err.message}`);
    }
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
        await fetch(`${SONATA_API}/api/worker/heartbeat`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ workerId: WORKER_ID, lastProgressAt: lastProgressMs }),
        });
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
