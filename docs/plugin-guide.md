# Sonata Plugin Development Guide

> How to build, package, and ship plugins that extend Sonata with new MCP tools, HTTP endpoints, and scheduled work.

This guide is for developers who want to write a plugin for [Sonata](https://github.com/evan108108/sonata) — the native macOS runtime that hosts AI agents, schedulers, memory, and tool registries in a single binary. You don't need to know Swift. A plugin is a program in any language that speaks HTTP.

---

## Table of contents

1. [What is a Sonata plugin?](#what-is-a-sonata-plugin)
2. [The plugin contract](#the-plugin-contract)
3. [Build your first plugin](#build-your-first-plugin)
4. [Plugin lifecycle](#plugin-lifecycle)
5. [Installation & management](#installation--management)
6. [Scheduler integration](#scheduler-integration)
7. [Events channel (bidirectional plugins)](#events-channel-bidirectional-plugins)
8. [Tips & gotchas](#tips--gotchas)
9. [Real examples](#real-examples-sonar--prstar)

---

## What is a Sonata plugin?

A Sonata plugin is a self-contained program that runs as an external process and speaks HTTP. When a plugin is installed and enabled, Sonata:

- **Spawns and supervises the process** — starts it at boot, restarts it on crash (with backoff), stops it cleanly on shutdown.
- **Discovers its actions** at runtime by calling `GET /api/actions` on the plugin.
- **Mounts each action as an MCP tool**, prefixed with the plugin's name. A plugin named `sonar` that exposes an action named `send` becomes the MCP tool `sonar_send`, callable by any Claude agent connected to Sonata.
- **Proxies HTTP calls** through `/api/plugins/<name>/...` so external clients can reach the plugin too.
- **Injects environment variables** — the assigned port, a data directory, a callback URL for Sonata, and any user-provided config.
- **Subscribes to an optional events channel** for bidirectional flows (incoming messages, pushed updates).

What a plugin is **not**:
- Not an in-process module. Sonata is Swift; plugins can be any language.
- Not a patch to Sonata's source tree.
- Not a shell script — Sonata won't fork and run `.sh` files as actions.

If it speaks HTTP and ships a manifest, it's a plugin. That's the whole contract.

### What you get for free

By becoming a plugin instead of a standalone service, you inherit:

| Capability | How it works |
|---|---|
| **MCP tool exposure** | Every action in `GET /api/actions` becomes an MCP tool in the same registry as Sonata's built-ins. Agents call them the same way. |
| **HTTP proxying** | `/api/plugins/<name>/<path>` routes through Sonata's server, so your plugin is reachable from the outside without opening extra ports publicly. |
| **Lifecycle management** | Starts at boot, restarts on crash (3 attempts, 2s/5s/15s backoff), stops cleanly on disable. |
| **Config injection** | `config_schema` entries become uppercased env vars prefixed with your plugin name. |
| **Data directory** | `~/.sonata/plugins/<name>/` is yours. Preserved across reinstalls. |
| **Scheduler integration** | Cron entries can invoke your plugin actions via shell tasks or internal calls. |
| **Dashboard UI** | Native SwiftUI Plugins tab shows status, logs, and toggle controls. |

---

## The plugin contract

### Manifest

Every plugin ships a single manifest file named `<plugin-name>.plugin.json` at the tarball root.

```json
{
  "name": "sonar",
  "version": "0.1.0",
  "description": "Peer-to-peer agent communication relay",
  "author": "evan108108",
  "sonata_version": ">= 3.0",
  "port": 4000,
  "arch": "arm64",
  "start_command": "bin/sonar start",
  "events_channel": "/socket/websocket",
  "events_topic": "messages:events",
  "config_schema": {
    "discovery_enabled": {"type": "boolean", "default": false}
  },
  "actions": [
    {
      "name": "send",
      "description": "Send a message to a peer",
      "method": "post",
      "path": "/api/messages/send",
      "params": [
        {"name": "peer_id",  "type": "string", "required": true,  "description": "Target peer ID"},
        {"name": "question", "type": "string", "required": true,  "description": "The message"},
        {"name": "context",  "type": "string", "required": false, "description": "Additional context"}
      ]
    }
  ]
}
```

#### Field reference

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Lowercase alphanumeric + hyphens. Regex: `^[a-z0-9][a-z0-9-]*$`. Becomes the MCP tool prefix. |
| `version` | yes | Semver. Shown in the dashboard. |
| `description` | no | One-liner. Shown in plugin listings. |
| `author` | no | String. Shown in the dashboard. |
| `sonata_version` | no | Minimum Sonata version (e.g. `">= 3.0"`). Informational in v1; not enforced yet. |
| `port` | yes | Default port. Sonata will pass this to your process via the `PORT` env var. Pick something unlikely to clash with common services — see [port conventions](#port-assignment-conventions). |
| `arch` | no | Target architecture for pre-compiled binaries (`arm64`, `x86_64`, or omit for runtime-dependent plugins). Informational. |
| `start_command` | yes | Command Sonata spawns from the plugin directory. Space-separated. First token is the executable path **relative to the plugin dir**. See [start_command and the stop arg](#start_command-and-the-stop-arg). |
| `events_channel` | no | Phoenix/WebSocket path to subscribe to. Only needed if you push events. |
| `events_topic` | no | The channel topic Sonata joins. Must be set if `events_channel` is. |
| `config_schema` | no | Map of `{key: {type: ...}}`. Values set via `plugin_config` are injected as env vars. |
| `actions` | no | Informational manifest of what your actions look like. The source of truth is runtime discovery (`GET /api/actions`). |

The `actions` array in the manifest is **informational**. It lets humans and future marketplace tooling see what you expose without having to start the plugin. At runtime, Sonata ignores it and calls `GET /api/actions` to get the authoritative list.

### The discovery endpoint (`GET /api/actions`)

Your HTTP server **must** expose `GET /api/actions` and return a JSON array of action descriptors:

```json
[
  {
    "name": "send",
    "description": "Send a message to a peer",
    "method": "post",
    "path": "/api/messages/send",
    "params": [
      {"name": "peer_id",  "type": "string",  "required": true},
      {"name": "question", "type": "string",  "required": true},
      {"name": "context",  "type": "string",  "required": false}
    ]
  },
  {
    "name": "inbox",
    "description": "List received messages",
    "method": "get",
    "path": "/api/messages/inbox",
    "params": [
      {"name": "limit", "type": "integer", "required": false}
    ]
  }
]
```

Rules:

- **`name`** — the short, lowercased name. Sonata prefixes it: `<plugin>_<name>`.
- **`method`** — `get`, `post`, `patch`, or `delete`. Anything else defaults to `post`.
- **`path`** — full URL path on your server, including any leading prefix (e.g. `/api/messages/send`). Sonata will POST/GET here directly.
- **`params[].type`** — one of `string`, `integer`, `number`, `boolean`, `array`, `object`. These map to MCP tool schema types.
- **`params[].required`** — boolean. Defaults to `false`.
- **`params[].description`** — human-readable; surfaces in MCP tool descriptions to the agent.

Sonata calls this endpoint:
1. **At boot / enable** — to register your actions as MCP tools.
2. **As the health check** — if `GET /api/actions` returns 200 within 15 seconds, your plugin is healthy.
3. **After a crash restart** — to re-register the tool set.

### How actions become HTTP calls

When an agent (or dashboard user, or cron job) invokes MCP tool `sonar_send`, Sonata:

1. Looks up the registered proxy action for `sonar_send`.
2. Builds a request: `POST http://127.0.0.1:4000/api/messages/send` with the tool args as the JSON body.
3. Substitutes any path parameters (`:message_id` in the path, etc.) using named params from the tool call.
4. Awaits your response with a 30s timeout.
5. Returns your JSON body as the MCP tool result.

Path-param substitution means you can write `/api/messages/:message_id/reply` in your action descriptor and declare `message_id` as a param — Sonata will plug it into the URL before dispatching.

GET calls serialize params into the query string. POST/PATCH/DELETE calls serialize them as a JSON body.

### Port assignment conventions

Pick a port that's unlikely to clash. Informal reservations used in the wild:

| Plugin | Port |
|---|---|
| Sonar | 4000 |
| PRStar | 4100 |
| (Your plugin) | 4200+ |

Sonata itself uses 3211. MeiliSearch uses 7700. Stay out of 3000–3099 (Node/React dev servers) and 8000–9000 (common app servers). Users can't override your port today; pick carefully and document it.

### `start_command` and the stop arg

`start_command` is whatever Sonata runs to spawn your plugin. It's parsed by space-splitting: the first token is the executable **relative to the plugin's install directory**, and the rest are its arguments.

Examples:
- `bin/sonar start` — run the Elixir release script with the `start` argument.
- `bin/prstar` — run the standalone Bun binary with no arguments.
- `node src/server.js` — run a Node script. Works only if `node` is on Sonata's PATH (it usually isn't — prefer a bundled binary).

**The stop arg requirement.** Sonata ensures a clean port release by running your start command with the argument `stop` before each spawn and on disable. If your process is long-running (a daemon, a PID file, a supervised release), `<executable> stop` must gracefully terminate it. If your process is stateless, still handle the argument — just exit 0 immediately:

```javascript
// src/server.js — first two lines
if (process.argv.includes("stop")) {
  process.exit(0);
}
```

This is the single most common bootstrapping bug. Forgetting it causes the respawn after a crash or disable to double-bind the port, fail the health check, and mark the plugin failed.

For Elixir releases the release script handles `stop` natively (`bin/sonar stop`). For other runtimes you need to write this yourself.

### Environment variables injected at spawn

When Sonata starts a managed plugin, the child process inherits Sonata's environment plus:

| Variable | Value | Notes |
|---|---|---|
| `PORT` | The manifest's `port` field. | Always use this, not a hardcoded port. |
| `SONATA_PLUGIN_DATA_DIR` | `~/.sonata/plugins/<name>/` | Your plugin's install directory. Safe to write anywhere under here. |
| `SONATA_HOST` | `http://127.0.0.1:3211` | Use this to call back into Sonata's own HTTP API. |
| `<NAME>_<KEY>` | User config values. | See below. |

**Config injection.** If your manifest declares a `config_schema`:

```json
"config_schema": {
  "api_token": {"type": "string"},
  "discovery_enabled": {"type": "boolean", "default": false}
}
```

…and the user calls `plugin_config` with `{"api_token": "secret", "discovery_enabled": true}`, Sonata sets:

```
SONAR_API_TOKEN=secret
SONAR_DISCOVERY_ENABLED=true
```

Keys are uppercased and prefixed with the uppercase plugin name. Values are stringified.

**External-mode plugins don't get these env vars** — they're already running under their own lifecycle, so Sonata doesn't touch them.

---

## Build your first plugin

Here's the minimum viable plugin. It exposes two actions: `ping` and `echo`.

### Directory layout

```
myplugin/
├── myplugin.plugin.json   # manifest (required)
├── bin/
│   └── myplugin            # the executable (can be a binary, a script, anything)
└── src/                    # optional: sources for your build
    └── server.js
```

The tarball you ship is whatever's inside `myplugin/`. Sonata extracts it to `~/.sonata/plugins/myplugin/` and runs `start_command` from that directory.

### Node/Bun example (full)

**`myplugin.plugin.json`**

```json
{
  "name": "myplugin",
  "version": "0.1.0",
  "description": "My first Sonata plugin",
  "author": "you",
  "sonata_version": ">= 3.0",
  "port": 4200,
  "start_command": "bin/myplugin",
  "actions": [
    {"name": "ping", "description": "Health check", "method": "get",  "path": "/api/ping", "params": []},
    {"name": "echo", "description": "Echo a string",  "method": "post", "path": "/api/echo",
      "params": [{"name": "text", "type": "string", "required": true, "description": "Text to echo"}]}
  ]
}
```

**`src/server.js`** (single file, no deps)

```javascript
// CRITICAL: handle 'stop' before anything else.
// Sonata calls `bin/myplugin stop` before each respawn to release the port.
if (process.argv.includes("stop")) {
  process.exit(0);
}

import { createServer } from "http";

const PORT = parseInt(process.env.PORT, 10) || 4200;

const ACTIONS = [
  { name: "ping", description: "Health check", method: "get",  path: "/api/ping", params: [] },
  { name: "echo", description: "Echo a string", method: "post", path: "/api/echo",
    params: [{ name: "text", type: "string", required: true, description: "Text to echo" }] },
];

function json(res, status, data) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

async function parseBody(req) {
  if (req.method === "GET") return {};
  return new Promise((resolve) => {
    let body = "";
    req.on("data", (c) => body += c);
    req.on("end", () => {
      try { resolve(JSON.parse(body)); } catch { resolve({}); }
    });
  });
}

const server = createServer(async (req, res) => {
  try {
    if (req.url === "/api/actions" && req.method === "GET") {
      return json(res, 200, ACTIONS);
    }
    if (req.url === "/api/ping" && req.method === "GET") {
      return json(res, 200, { ok: true, plugin: "myplugin" });
    }
    if (req.url === "/api/echo" && req.method === "POST") {
      const body = await parseBody(req);
      if (!body.text) return json(res, 400, { error: "text required" });
      return json(res, 200, { echo: body.text });
    }
    json(res, 404, { error: "not found" });
  } catch (err) {
    json(res, 500, { error: err.message });
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`myplugin listening on ${PORT}`);
});

process.on("SIGTERM", () => server.close(() => process.exit(0)));
process.on("SIGINT",  () => server.close(() => process.exit(0)));
```

**Build a standalone binary with Bun.** Runtime-dependent plugins (`node src/server.js`) only work if the target machine has Node/Bun on PATH. Managed mode doesn't guarantee that. Ship a compiled binary instead:

```bash
bun build --compile --target=bun-darwin-arm64 src/server.js --outfile bin/myplugin
chmod +x bin/myplugin
```

This produces a single self-contained executable in `bin/myplugin` that Sonata can spawn on any arm64 Mac without asking the user to install anything.

**Package the tarball:**

```bash
cd /path/to/parent/of/myplugin
tar czf myplugin-0.1.0.tar.gz myplugin/
```

**Install it:**

```bash
curl -X POST http://127.0.0.1:3211/api/plugins/install \
  -H 'Content-Type: application/json' \
  -d '{"path": "/Users/you/myplugin-0.1.0.tar.gz"}'

curl -X POST http://127.0.0.1:3211/api/plugins/myplugin/enable
```

Check that it's running:

```bash
curl http://127.0.0.1:3211/api/plugins | jq '.[] | select(.name=="myplugin")'
```

Any Claude agent started after this point sees `myplugin_ping` and `myplugin_echo` as MCP tools.

### The pattern in any language

Whatever your language, the HTTP server you need to write has three parts:

1. **Read PORT from env, bind 127.0.0.1:$PORT.** Never bind `0.0.0.0` — plugins should not be directly network-reachable.
2. **Handle `GET /api/actions`.** Return the JSON array described above.
3. **Handle your actual action endpoints.** Return JSON; the body is what the MCP caller receives.
4. **Handle the `stop` argument.** If your executable receives `stop` as a command-line argument, exit 0 cleanly (or kill your daemon cleanly, then exit 0).

A Python sketch:

```python
import sys, os, json
from http.server import BaseHTTPRequestHandler, HTTPServer

if "stop" in sys.argv:
    sys.exit(0)

PORT = int(os.environ.get("PORT", "4200"))
ACTIONS = [
    {"name": "ping", "description": "Health check", "method": "get", "path": "/api/ping", "params": []},
]

class H(BaseHTTPRequestHandler):
    def _ok(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_GET(self):
        if self.path == "/api/actions": return self._ok(ACTIONS)
        if self.path == "/api/ping":    return self._ok({"ok": True})
        self.send_response(404); self.end_headers()

HTTPServer(("127.0.0.1", PORT), H).serve_forever()
```

A Go sketch:

```go
package main

import (
  "encoding/json"
  "fmt"
  "net/http"
  "os"
)

func main() {
  for _, a := range os.Args[1:] {
    if a == "stop" { os.Exit(0) }
  }
  port := os.Getenv("PORT")
  if port == "" { port = "4200" }

  http.HandleFunc("/api/actions", func(w http.ResponseWriter, _ *http.Request) {
    json.NewEncoder(w).Encode([]map[string]any{
      {"name": "ping", "description": "Health check", "method": "get", "path": "/api/ping", "params": []any{}},
    })
  })
  http.HandleFunc("/api/ping", func(w http.ResponseWriter, _ *http.Request) {
    json.NewEncoder(w).Encode(map[string]any{"ok": true})
  })
  http.ListenAndServe(fmt.Sprintf("127.0.0.1:%s", port), nil)
}
```

Build with `go build -o bin/myplugin` and ship the resulting binary.

---

## Plugin lifecycle

Every plugin row in Sonata's `plugins` table has a `status` column that advances through a fixed state machine.

```
installed ──→ enabled ──→ starting ──→ running ──→ disabled ──→ uninstalled
                                          │
                                          └──(crash)──→ failed
                                          │
                                          └──(health timeout)──→ failed
```

| State | Meaning |
|---|---|
| `installed` | Tarball extracted. Manifest parsed. DB row inserted. Not running. |
| `enabled` | Marked for startup (intermediate state). |
| `starting` | Process spawned. Waiting for `GET /api/actions` to return 200. |
| `running` | Health check passed. Actions registered as MCP tools. |
| `failed` | 3 consecutive spawn attempts failed or health check timed out. Gives up. |
| `disabled` | Stopped. Actions unregistered. On disk, but not active. |
| `uninstalled` | Row deleted. Files removed from `~/.sonata/plugins/<name>/`. |

### Crash recovery

If Sonata detects your plugin process exited unexpectedly while `status = running`:

1. All its MCP tools are unregistered immediately.
2. A backoff wait: 2s on crash #1, 5s on crash #2, 15s on crash #3.
3. Process respawned. Health check polled for up to 15 seconds.
4. On success: tools re-registered, status back to `running`, crash counter reset.
5. **After 3 consecutive failures** it's marked `failed` and not restarted. You must `plugin_disable` + `plugin_enable` to retry.

Intentional stops (disable, uninstall) do not trigger crash recovery. Sonata sets `status = disabled` before terminating so its `terminationHandler` knows the exit was intentional.

### Health check details

- **Endpoint**: `GET /api/actions` (not `/api/health` or similar — discovery doubles as the health probe).
- **Timeout**: 15 seconds from spawn.
- **Poll interval**: 250ms.
- **Success criteria**: HTTP 200 with a valid JSON array body. Anything else is treated as "not ready yet".

If your plugin has heavy initialization (loading a model, warming a cache), consider starting your HTTP server first and returning `[]` or a partial action list early, then registering more actions as they come online — but note that Sonata only discovers once, at enable time. A better pattern: return the full action list early, and have your actions themselves return 503 until they're ready.

---

## Installation & management

### Tarball format

- gzipped tar: `plugin-name-version.tar.gz`
- Manifest at the tarball root, OR inside a single wrapper directory (Sonata checks both).
- Recommended contents:
  - `<name>.plugin.json` — manifest
  - `bin/<name>` — your executable (made `chmod +x` before packaging)
  - `README.md` — optional; not read by Sonata
  - Any other assets your plugin needs at runtime

Sonata **preserves `.db`, `.db-wal`, and `.db-shm` files** across reinstalls — so if your plugin uses SQLite, users don't lose their data when they upgrade.

### Management API

All management endpoints are also available as MCP tools (and as Sonata HTTP actions), so you can install/enable plugins from any Claude agent or from the dashboard.

| MCP tool | HTTP | Body | Purpose |
|---|---|---|---|
| `plugin_list` | `GET /api/plugins` | — | List all plugins and their status |
| `plugin_install` | `POST /api/plugins/install` | `{"path": "/abs/path/to/plugin.tar.gz"}` | Install from a tarball |
| `plugin_connect` | `POST /api/plugins/connect` | `{"name": "x", "url": "http://host:port", "manifest_path": "..."}` | Register an external-mode plugin |
| `plugin_enable` | `POST /api/plugins/:name/enable` | — | Start |
| `plugin_disable` | `POST /api/plugins/:name/disable` | — | Stop |
| `plugin_config` | `POST /api/plugins/:name/config` | `{"config": {...}}` | Update config (re-injected as env on next start) |
| `plugin_uninstall` | `DELETE /api/plugins/:name` | — | Stop, delete from DB, remove files |

### Managed mode vs external mode

**Managed mode (default, from `plugin_install`)** — Sonata spawns and supervises your process. Use this for shipping to end users.

**External mode (from `plugin_connect`)** — Your process is already running somewhere (e.g. `mix phx.server` in your dev terminal). Sonata connects over HTTP, discovers your actions, and proxies to them — but does not start or stop you. Use this during development: edit and restart your plugin without reinstalling.

Development loop:

```bash
# In terminal 1 — your plugin
cd /Users/you/code/myplugin
PORT=4200 node src/server.js

# In terminal 2 — register it with Sonata
curl -X POST http://127.0.0.1:3211/api/plugins/connect \
  -H 'Content-Type: application/json' \
  -d '{
        "name": "myplugin",
        "url": "http://127.0.0.1:4200",
        "manifest_path": "/Users/you/code/myplugin/myplugin.plugin.json"
      }'
```

Now iterate on `src/server.js` and restart your dev server. Sonata stays connected. To fully remove: `plugin_disable` + `plugin_uninstall`.

### Dashboard UI

The Sonata app has a native **Plugins** tab that shows each plugin's status, version, port, mode, PID, discovered action count, and recent log lines from `plugin.log` (stdout/stderr captured and timestamped). Enable/disable/uninstall buttons are present.

Logs land at `~/.sonata/plugins/<name>/plugin.log`, one line per captured stdio line, prefixed with ISO-8601 timestamp and `[name/stdout]` or `[name/stderr]`. This is often the first place to look when debugging.

---

## Scheduler integration

Sonata has a built-in scheduler (cron). You can schedule your plugin's actions just like any other task.

### Shell task with curl (the usual pattern)

Create a scheduled job that hits your plugin via Sonata's HTTP proxy:

```bash
curl -X POST http://127.0.0.1:3211/api/scheduler/create \
  -H 'Content-Type: application/json' \
  -d '{
        "name": "prstar-scan",
        "cron": "*/10 * * * *",
        "type": "shell",
        "command": "curl -X POST http://127.0.0.1:3211/api/plugins/prstar/scan"
      }'
```

This runs every 10 minutes and POSTs to `/api/plugins/prstar/scan`, which Sonata proxies to your plugin's `POST /api/scan` endpoint.

### Why proxy instead of calling the plugin directly?

You could `curl http://127.0.0.1:4100/api/scan` — but routing through Sonata's `/api/plugins/<name>/...` proxy gets you:

- Consistent logging (calls appear in Sonata's request log).
- Automatic failure if the plugin is disabled (you get a clean 503 instead of ECONNREFUSED).
- Single URL that keeps working if port assignment changes.

### Long-running scheduled work

If your scheduled action takes more than a few seconds, **don't block the scheduler.** Return 202 immediately from your HTTP endpoint and do the work in a background task. PRStar's `/api/scan` is a good example:

```javascript
if (path === "/api/scan" && method === "POST") {
  if (scanning) return json(res, 409, { error: "scan already in progress" });
  scanning = true;
  json(res, 202, { status: "accepted", action: "scan" });    // respond NOW
  runScan()                                                    // do work async
    .catch(err => log("error", `Scan failed: ${err.message}`))
    .finally(() => { scanning = false; });
  return;
}
```

Two things to notice:
1. The response is sent *before* `runScan()` starts. The scheduler returns right away.
2. A `scanning` flag prevents overlap if the next cron tick arrives while work is still in flight. Return 409 in that case.

---

## Events channel (bidirectional plugins)

Most plugins are pull-only: Sonata calls your HTTP endpoints, you respond. That's enough for 90% of use cases.

A plugin needs an events channel when something outside the process drives work — an inbound network message, an external webhook, a state change in shared storage — and you need to push that into Sonata (which then routes it to a worker, resumes a pending tool call, etc.).

### When you need one

- **Inbound messaging** (Sonar): a peer agent sends you a message over the network. Your plugin receives it. You need Sonata to dispatch that to a worker so a Claude agent can read and reply.
- **Long-running task completion**: your plugin kicks off an expensive operation, finishes it 20 minutes later, and wants to resume a pending MCP call that's waiting for the result.
- **External webhooks**: GitHub pings your plugin on a PR event. You want to turn that into a workerEvent.

If your plugin is just "call action, get response," you do not need an events channel.

### Wire protocol

Sonata speaks **Phoenix Channels v2** over WebSockets. This is the same wire format Elixir's Phoenix framework uses, and it's straightforward to implement from other languages — it's just a framed array over a regular WebSocket.

**Join message** (Sonata → plugin) on connect:
```
["1", "1", "<topic>", "phx_join", {}]
```

**Heartbeat** (Sonata → plugin, every 25 seconds, required to avoid disconnect):
```
[null, "<ref>", "phoenix", "heartbeat", {}]
```

**Event from plugin to Sonata**:
```
[null, null, "<topic>", "<event_name>", {...payload...}]
```

Sonata ignores all messages whose event name starts with `phx_` (those are Phoenix's internal join/leave plumbing).

### Wiring it up

1. In your manifest, set `events_channel` (the WebSocket path) and `events_topic` (the channel topic):
   ```json
   "events_channel": "/socket/websocket",
   "events_topic": "messages:events"
   ```
2. Your plugin runs a WebSocket server on the same port, at the `events_channel` path.
3. On plugin health-check success, Sonata connects to `ws://127.0.0.1:<PORT><events_channel>?vsn=2.0.0`, joins your topic, and starts heartbeating.
4. Broadcast events from your plugin code to all subscribers on the topic. Sonata receives them.

### Event routing

When Sonata receives a plugin event, it calls `handlePluginEvent(pluginName, event, payload)`. The current built-in routes are:

- `new_message` → creates a `SONAR_MESSAGE` workerEvent (a worker picks it up and processes it).
- `reply_received` → resumes any pending `<name>_send` continuation waiting on that `message_id`.
- `reply_sent` → no-op, but logged.

If your plugin needs a new event type, you'll need to extend `handlePluginEvent` in Sonata. This is a small Swift patch; the event-handling code is centralized in `PluginManager.swift`.

### The synchronous send pattern

Sonar's `sonar_send` demonstrates a clever pattern: one MCP tool call, awaits a reply that arrives asynchronously.

1. Agent calls `sonar_send(peer_id, question)` — one MCP call.
2. Sonata proxies `POST /api/messages/send`. Your plugin returns `{message_id: "abc123"}` immediately.
3. Sonata's proxy handler **awaits** a Swift continuation keyed by `message_id`, with a 60s timeout.
4. Meanwhile, the reply arrives over the network. Your plugin broadcasts `reply_received` on the events channel.
5. Sonata matches the `message_id`, resumes the continuation with the reply.
6. The original `sonar_send` call returns the reply to the agent — as if it were a synchronous round trip.

If the reply doesn't arrive in 60 seconds, the continuation resolves with `{message_id, status: "pending"}`. The agent can poll with `sonar_message(message_id)` later.

Sonata auto-wires this pattern for any action literally named `send`. If you want the same behavior for a differently-named action, you'd add a case in `makeProxyActionsForPlugin`.

---

## Tips & gotchas

### Long-running operations → return 202, work in background

Sonata's proxy has a 30-second HTTP timeout. If your action takes longer, respond 202 immediately and do the work async (see PRStar's scan pattern above). If the result needs to come back to the caller, either use the events channel to resume, or expose a polling endpoint.

### The `stop` arg is load-bearing

Plugins that forget to handle `stop` as a CLI arg get stuck in respawn loops: Sonata tries to release the port, the process doesn't exit, the next spawn can't bind. Every `start_command` executable must accept `stop` and exit 0 cleanly. Two lines at the top of your entrypoint:

```javascript
if (process.argv.includes("stop")) process.exit(0);
```

Elixir releases handle this for you (`bin/sonar stop` is built into the release script).

### Port conflicts

Sonata doesn't dynamically reassign ports. If your manifest says port 4000 and something else is on 4000 at startup, your plugin fails its health check.

- Before shipping, grep for common services on your chosen port: `lsof -i :4200`.
- Document your port in the README.
- Users can't override today — pick a defensible default.

### PATH in managed mode

Sonata spawns your process with its own env plus the injected vars. The PATH it inherits is whatever the macOS app was launched with — which often does NOT include `/usr/local/bin`, Homebrew paths, or user-installed binaries.

Symptom: `node: command not found` in `plugin.log` even though `node` is on your shell PATH.

Fix: **ship a standalone binary.** Use `bun build --compile`, `go build`, `pkg`, or cargo to produce a single-file executable. Don't rely on the user's runtime being on PATH.

### Standalone binaries vs runtime-dependent scripts

| | Standalone binary | Runtime-dependent script |
|---|---|---|
| User setup | None — works out of the box | Must install runtime (Node/Python/etc.) |
| Tarball size | Large (10–50 MB typical) | Small |
| Distribution | Single artifact per arch | Fewer artifacts, more fragile |
| PATH issues | None | Common |
| Startup speed | Fast | Fast-ish |

For anything you intend to publish for others to install, ship a standalone binary. Scripts are fine for plugins you're only ever running yourself in external mode.

### JSON encoding gotcha

If you return raw JSON from your action handler, Sonata decodes it as `Any` and re-encodes it through its own Codable pipeline (`JSONPassthrough`). This preserves real JSON structure — arrays stay arrays, booleans stay booleans, etc. But if you accidentally return a string that contains JSON text (`"[]"` instead of `[]`), that string gets returned as-is to the caller — not parsed. Always return real JSON values.

### Preserve database files across upgrades

Sonata's installer automatically preserves any file in your install directory ending in `.db`, `.db-wal`, or `.db-shm`. If you use a different storage format (JSON files, a directory of artifacts), they are **not** preserved across reinstalls — they'll be wiped.

If your plugin has important state in other file types, store it outside your install directory. `~/.sonata/plugins/<name>/data/` is inside the install dir and gets wiped. A path like `~/.yourplugin/data/` under the user's home survives reinstalls.

### Don't bind to 0.0.0.0

Bind to `127.0.0.1`. Plugins should not be directly network-reachable — Sonata's `/api/plugins/<name>/` proxy is the one controlled entry point. Binding to `0.0.0.0` exposes your action endpoints on the LAN without auth.

### Graceful shutdown

Handle SIGTERM and SIGINT — close your HTTP server, flush any pending writes, then exit. On macOS, if your process ignores SIGTERM, the OS follows up with SIGKILL after a grace period, which may corrupt your SQLite write-ahead log.

### Debugging a plugin that won't start

1. Check `~/.sonata/plugins/<name>/plugin.log` — stdout/stderr capture.
2. Check Sonata's own log for `Plugin <name>: ...` lines. Look for "failed to spawn", "health check timeout", "discovery failed".
3. Try the plugin standalone: `cd ~/.sonata/plugins/<name> && PORT=4200 bin/<name>`. If it doesn't run outside Sonata, it won't run inside.
4. Hit `GET /api/actions` yourself: `curl http://127.0.0.1:4200/api/actions`. Must return 200 with JSON.
5. Check if the port is stuck: `lsof -i :4200`. If a stale process is bound, `bin/<name> stop` should clear it.

---

## Real examples: Sonar & PRStar

### Sonar — Elixir, events channel, messaging

[Sonar](https://github.com/evan108108/sonar) is a peer-to-peer agent communication relay. It was the first Sonata plugin and drove most of the plugin system's design.

- **Stack**: Elixir 1.19 + Phoenix 1.8 + Ecto + SQLite3 (WAL mode).
- **Manifest**: `port 4000`, `start_command: bin/sonar start`, `events_channel: /socket/websocket`, `events_topic: messages:events`, 11 actions.
- **Release**: `MIX_ENV=prod mix release sonar` → 9.4 MB self-contained tarball (Elixir bakes in BEAM).
- **Uses the events channel**: `new_message` when a peer DMs this instance → Sonata dispatches a `SONAR_MESSAGE` workerEvent → a worker reads the message via `sonar_message(message_id)` and replies via `sonar_reply(message_id, answer)`.
- **Uses the synchronous send pattern**: calling `sonar_send` POSTs to `/api/messages/send`, gets back a `message_id`, and the Sonata proxy waits on a continuation until `reply_received` fires on the channel. One MCP call, one reply, no polling.
- **Handles `stop`**: `bin/sonar stop` is provided by the Elixir release script.

### PRStar — Bun binary, scheduler-triggered

[PRStar](https://github.com/evan108108/prstar) is an autonomous PR review agent for the `adaptengine-monorepo` repository.

- **Stack**: Bun + JavaScript. `bun build --compile --target=bun-darwin-arm64` produces a single-file binary.
- **Manifest**: `port 4100`, `start_command: bin/prstar`, 10 actions, no events channel.
- **No bidirectional flow**: all actions are RPC-style — `review`, `scan`, `fix`, `resolve_conflicts`, `sync`, `pause`, `unpause`, etc.
- **Long-running work**: `review`, `scan`, `fix` return 202 immediately and do the actual work in a background promise chain. The scheduler fires `/api/plugins/prstar/scan` every 10 minutes — the scheduler doesn't wait.
- **Handles `stop`**: the first two lines of `src/server.js` are `if (process.argv.includes("stop")) process.exit(0);`.

```javascript
// From PRStar — the first two lines of the entrypoint
if (process.argv.includes("stop")) {
  process.exit(0);
}
```

The two plugins bracket the spectrum: Sonar is a complex bidirectional event system written in a BEAM language; PRStar is a single-file JavaScript HTTP server compiled to a binary. Both speak the same plugin contract. That's the whole point.

---

## Summary checklist

Before you publish, make sure your plugin:

- [ ] Has a `<name>.plugin.json` manifest with `name`, `version`, `port`, `start_command`.
- [ ] Exposes `GET /api/actions` returning a JSON array of action descriptors.
- [ ] Reads `PORT` from env and binds `127.0.0.1:$PORT`.
- [ ] Handles the `stop` CLI arg by exiting 0 (or stopping its daemon, then exiting 0).
- [ ] Handles SIGTERM and SIGINT gracefully.
- [ ] Responds to long work with 202 plus async follow-up — nothing over 30 seconds synchronously.
- [ ] Ships as a standalone binary (not a runtime-dependent script) if intended for others.
- [ ] Doesn't rely on PATH for anything critical.
- [ ] Is packaged as `tar czf name-version.tar.gz name/`.
- [ ] Stores any must-preserve state in `.db*` files or outside the install directory.
- [ ] Documents its port assignment.

That's everything. Welcome to the Sonata plugin ecosystem.
