#!/usr/bin/env bun
/**
 * MCP Bridge — Generic stdio-to-HTTP proxy.
 * Auto-discovers tools from Sonata's /api/mcp/tools endpoint.
 * Zero tool-specific code. Bundled inside Sonata.app.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const API = process.env.SONATA_URL || "http://localhost:3211";

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

  const result = await fetchJSON("/api/mcp/call", {
    method: "POST",
    body: JSON.stringify({ name, arguments: args || {} }),
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
