#!/bin/bash
# Bridges stdio to Sonata's WebSocket MCP endpoint.
# Used by Claude Code's ~/.claude.json MCP config.
#
# Usage in ~/.claude.json:
#   "mcpServers": {
#     "sonata-memory": {
#       "command": "/Users/evan/memory/Sonata/sonata-mcp-bridge.sh"
#     }
#   }

SONATA_WS="ws://127.0.0.1:3211/mcp"

# Try websocat first (fastest, zero overhead)
if command -v websocat &>/dev/null; then
    exec websocat "$SONATA_WS"
fi

# Fallback: bun inline script
if command -v bun &>/dev/null; then
    exec bun -e "
const ws = new WebSocket('$SONATA_WS');
ws.onopen = () => {
    process.stdin.setEncoding('utf8');
    let buf = '';
    process.stdin.on('data', chunk => {
        buf += chunk;
        let nl;
        while ((nl = buf.indexOf('\\n')) !== -1) {
            const line = buf.slice(0, nl).trim();
            buf = buf.slice(nl + 1);
            if (line) ws.send(line);
        }
    });
    process.stdin.on('end', () => { ws.close(); process.exit(0); });
};
ws.onmessage = e => process.stdout.write(e.data + '\\n');
ws.onerror = e => { process.stderr.write('ws error: ' + e.message + '\\n'); process.exit(1); };
ws.onclose = () => process.exit(0);
"
fi

# Fallback: node
if command -v node &>/dev/null; then
    exec node -e "
const { WebSocket } = require('ws');
const ws = new WebSocket('$SONATA_WS');
ws.on('open', () => {
    process.stdin.setEncoding('utf8');
    let buf = '';
    process.stdin.on('data', chunk => {
        buf += chunk;
        let nl;
        while ((nl = buf.indexOf('\\n')) !== -1) {
            const line = buf.slice(0, nl).trim();
            buf = buf.slice(nl + 1);
            if (line) ws.send(line);
        }
    });
    process.stdin.on('end', () => { ws.close(); process.exit(0); });
});
ws.on('message', data => process.stdout.write(data.toString() + '\\n'));
ws.on('error', e => { process.stderr.write('ws error: ' + e.message + '\\n'); process.exit(1); });
ws.on('close', () => process.exit(0));
"
fi

echo "Error: need websocat, bun, or node to bridge stdio to WebSocket" >&2
exit 1
