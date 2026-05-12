#!/usr/bin/env bun
/**
 * MCP Bridge — Generic stdio-to-HTTP proxy.
 * Auto-discovers tools from Sonata's /api/mcp/tools endpoint.
 * Mostly zero tool-specific code. Bundled inside Sonata.app.
 *
 * One tool-specific helper: when `afk_register` is called without a sessionId,
 * we inject the sibling sonata-bridge's BRIDGE_SESSION_ID. Both this proxy and
 * sonata-bridge.ts are children of the same Claude Code parent, so they
 * compute the same fallback identifier (`claude-<ppid>`) and agree without
 * any IPC. This is what makes `mcp__memory__afk_register(token)` a single
 * footgun-free call from the LLM's perspective.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const API = process.env.SONATA_URL || "http://localhost:3211";

// Mirrors sonata-bridge.ts BRIDGE_SESSION_ID — keep in sync.
const BRIDGE_SESSION_ID =
  process.env.WORKER_ID ||
  process.env.SONA_SESSION_ID ||
  `claude-${process.ppid}`;

async function fetchJSON(path: string, opts?: RequestInit) {
  const res = await fetch(`${API}${path}`, {
    ...opts,
    headers: { "Content-Type": "application/json", ...opts?.headers },
  });
  return res.json();
}

// Discover tools from Sonata on startup
const tools = await fetchJSON("/api/mcp/tools");

const mcp = new Server(
  { name: "memory", version: "3.0.0" },
  {
    capabilities: { tools: {} },
    instructions:
      "Sona's persistent memory system. Use mem_recall for retrieval, mem_store for saving, mem_wiki_read for structured knowledge.",
  }
);

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools,
}));

mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args } = req.params;

  let finalArgs: Record<string, unknown> = (args as Record<string, unknown>) || {};

  // afk_register: auto-inject sessionId from the sibling bridge's identity so
  // callers (the LLM, scripts) can pass just a token. See file header comment.
  if (name === "afk_register" && !finalArgs.sessionId) {
    finalArgs = { ...finalArgs, sessionId: BRIDGE_SESSION_ID };
  }

  const result = await fetchJSON("/api/mcp/call", {
    method: "POST",
    body: JSON.stringify({ name, arguments: finalArgs }),
  });

  return {
    content: [
      {
        type: "text" as const,
        text: result.error ? `Error: ${result.result}` : result.result,
      },
    ],
    isError: result.error || false,
  };
});

const transport = new StdioServerTransport();
await mcp.connect(transport);
