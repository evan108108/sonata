#!/usr/bin/env bun
/**
 * Sonata Channel Bridge
 *
 * Bridges stdio (what Claude Code expects for MCP channels)
 * to Sonata's WebSocket endpoint at ws://localhost:3211/mcp
 *
 * This is configured as "sonata-channel" in .mcp.json
 */

const WS_URL = process.env.SONATA_WS_URL || "ws://localhost:3211/mcp";

const ws = new WebSocket(WS_URL);

ws.onopen = () => {
  // Read from stdin (Claude Code sends JSON-RPC messages)
  process.stdin.setEncoding("utf-8");
  let buffer = "";
  process.stdin.on("data", (chunk: string) => {
    buffer += chunk;
    // Try to parse complete JSON messages
    const lines = buffer.split("\n");
    buffer = lines.pop() || "";
    for (const line of lines) {
      if (line.trim()) {
        ws.send(line.trim());
      }
    }
  });
};

ws.onmessage = (event: MessageEvent) => {
  // Write to stdout (Claude Code reads JSON-RPC responses)
  process.stdout.write(event.data + "\n");
};

ws.onerror = (err: Event) => {
  process.stderr.write(`[sonata-channel] WebSocket error: ${err}\n`);
};

ws.onclose = () => {
  process.stderr.write("[sonata-channel] WebSocket closed\n");
  process.exit(0);
};

// Handle process exit
process.on("SIGINT", () => { ws.close(); process.exit(0); });
process.on("SIGTERM", () => { ws.close(); process.exit(0); });
