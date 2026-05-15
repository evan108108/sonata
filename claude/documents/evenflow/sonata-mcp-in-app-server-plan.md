# Sonata MCP In-App Server — Eliminate `sonata-bridge.ts`

## TL;DR

Replace the per-Claude-Code-session `bun sonata-bridge.ts` stdio MCP child with
a single MCP server hosted **inside the Sonata.app process** itself, served as
HTTP+SSE from Sonata's existing Hummingbird router at `/mcp/{sessionKey}`. Each
Claude Code session is configured with `"type": "http"` in `~/.claude.json`
pointing at its sessionKey-templated URL. Per-session identity (worker /
supervisor / interactive) moves from environment variables to the URL path.
Notifications (`notifications/claude/channel`, AFK replies, Sonar DMs, restart
nudges) are pushed over the long-lived SSE connection instead of via stdio.
Tools (`complete_event`, `fail_event`, `sonar_dm_*`) become direct in-process
calls to existing Swift Actions — no internal HTTP loopback.

**Why:** the stdio bridge is a control-plane component running in a foreign
runtime (bun) whose deaths and crashes are invisible to Sonata's logger,
require a watchdog to detect, and have already caused two distinct failure
modes in the past week (supervisor self-kill on every check event; orphaned
bridge children deadlocking workers). Folding the MCP server in-process
removes the entire failure class.

**Status:** plan only. No code written. Branch
`evenflow/sonata-mcp-in-app-server` exists with this doc. Implementation gated
on Evan's review.

**Key decisions made in this doc:**
- HTTP+SSE transport (not WebSocket — Claude Code's `"type": "http"`
  Streamable HTTP transport is the supported path)
- sessionKey lives in URL path, not env vars
- Tool handlers call Swift Actions directly, not via HTTP loopback
- Two-phase rollout: ship HTTP server alongside stdio bridge, flip session
  types one at a time, delete the bridge file last
- A small Swift helper generates the per-Claude `~/.claude.json` at spawn time
  so we don't depend on Claude Code env-var substitution

---

## 1. Problem statement and why now

### The bridge is the heart, but it's a bun-runtime heart

`Sources/Sonata/Resources/mcp/sonata-bridge.ts` is 1167 lines of TypeScript
that runs as a stdio MCP subprocess of every Claude Code session Sonata
spawns (workers, supervisor, plus passive-mode interactive sessions that
have it registered in `~/.claude.json`). Per session it:

1. Boots an MCP `Server` over `StdioServerTransport`.
2. Reads `WORKER_ID`, `SESSION_LABEL`, `SONATA_ROLE`, `SONA_SESSION_ID`,
   `SONA_WORKER` from its environment to decide its identity.
3. Runs a heartbeat loop (15s), event-claim loop (5s), AFK poll loop
   (5s fast / 30s idle), and DM poll loop (5s) — all making HTTP calls back
   to Sonata's `localhost:3211` Hummingbird server.
4. Pushes `notifications/claude/channel` over stdio to wake the parent claude
   on new events / AFK replies / Sonar DMs / restart nudges.
5. Exposes six MCP tools — `complete_event`, `fail_event`, `sonar_dm_register`,
   `sonar_dm_unregister`, `sonar_dm_send`, `sonar_dm_inbox` — each of which
   does its own HTTP call back to Sonata.

### Concrete recent failures

| When | Symptom | Commit | Real cause |
|------|---------|--------|-----------|
| ~2026-05-13 | Bridge process exited on every supervisor `check` event | e987e53 | `complete_event` called the worker heartbeat endpoint for the supervisor, got 410, hit `process.exit(0)` from the 30s-410-pair predecessor-cleanup heuristic. Six dead bridges in 20 minutes. |
| ~2026-05-12 | Supervisor terminal alive but no heartbeats reaching DB → HealthMonitor blind → cron deadlock | f854d70 | Bridge child of the supervisor claude died (cause unknown — likely an uncaught EPIPE during stdio write). Parent `claude` process has no MCP-respawn protocol, so the bridge stays dead until something kicks the whole supervisor. |
| Ongoing | "Deploy script patched the wrong file" — bug-fixes to `sonata-bridge.ts` only land for new spawns | n/a | Two copies exist: bundled inside `Sonata.app/Contents/Resources/mcp/sonata-bridge.ts` and the deployed `~/.sonata/mcp/sonata-bridge.ts`. `ensureGlobalMCPServers()` copies bundle→deployed on every app launch, but a hand-edit to the deployed file gets clobbered, and a hand-edit to the bundle file requires a rebuild. |
| Always | ~80 MB RSS × N sessions | n/a | Each bun process loads its own `@modelcontextprotocol/sdk`, its own JS heap. With 2 workers + 1 supervisor + 1–2 interactive sessions = 5 bridges × 80 MB = 400 MB of redundant runtime. |
| Always | Crash invisibility | n/a | Crashes append to `~/.sonata/logs/bridge-crashes.log` via `appendFileSync` (good!), but that file is not piped into Sonata's structured logger. The Sonata.app UI has no idea a bridge died until the watchdog notices missing heartbeats 60s later. |

### The isolation we got was fake

The original justification for stdio-MCP was *isolation* — a worker bridge
dying shouldn't take down Sonata. But every bridge already depends on Sonata
being alive (every loop is an HTTP call to `:3211`), so the practical
"isolation" is just "Sonata can't see when bridges die." Reversing the
direction — bridges live inside Sonata — gives us **observability** at the
cost of **a process boundary we never used**.

### Why now

- The hardening pass in `e987e53` added crash-resilience scaffolding but
  cannot fix the architectural mismatch (a control-plane component in a
  foreign runtime).
- The watchdog in `f854d70` is a band-aid: it kills the supervisor when its
  bridge child dies, which works but is heavy-handed and costs a 60–90s
  unavailability window per recovery.
- Claude Code v2.1.50 ships a working `"type": "http"` MCP Streamable HTTP
  transport (verified internally; see SDK source `mcp-client.ts`). The
  capability we need now exists in the consumer.
- Sonata already has `Sources/MCP/SonataMCPHandler` doing JSON-RPC over
  WebSocket for the `sonata-memory` server, and `Sources/Server/ActionRegistry`
  exposes all the in-process verbs via `executeMCPTool(name:, args:)`. Roughly
  60% of the in-app server already exists; the remaining 40% is the SSE push
  channel and the session-scoping plumbing.

---

## 2. Target architecture

### Process topology, before vs after

**Before:**

```
Sonata.app (Swift, :3211)
   ├── worker-1: claude  ──fork──> bun sonata-bridge.ts  ──HTTP loopback──┐
   ├── worker-2: claude  ──fork──> bun sonata-bridge.ts  ──HTTP loopback──┤
   ├── supervisor: claude ─fork──> bun sonata-bridge.ts  ──HTTP loopback──┼─> :3211/api/...
   └── interactive: claude ──┐                                            │
                              └fork──> bun sonata-bridge.ts ──HTTP loop──┘
```

**After:**

```
Sonata.app (Swift, :3211)
   │   ┌── /mcp/worker-1  ←─── HTTP+SSE ─── claude (worker-1)
   │   ├── /mcp/worker-2  ←─── HTTP+SSE ─── claude (worker-2)
   │   ├── /mcp/supervisor ←── HTTP+SSE ─── claude (supervisor)
   │   └── /mcp/{uuid}    ←─── HTTP+SSE ─── claude (interactive)
   │
   ├── MCPSessionRegistry  (per-sessionKey state, holds open SSE writer)
   ├── ActionRegistry       (existing — handles tool calls in-process)
   └── EventDispatcher      (push channel notifications by sessionKey)
```

### Request/response flow

```
                                  Sonata.app                Claude Code
                                  (Swift, :3211)            (worker)
                                       │                        │
                       POST /mcp/wk-1  │  initialize            │
                       ◄────────────────────────────────────────│
                        200 application/json (init result)      │
                       ────────────────────────────────────────►│
                                       │                        │
                       GET /mcp/wk-1   │  Accept: text/event-stream
                       ◄────────────────────────────────────────│
                        200 text/event-stream (keep-open)       │
                       ────────────────────────────────────────►│
                                       │                        │
                       POST /mcp/wk-1  │  tools/call complete_event
                       ◄────────────────────────────────────────│
                        ActionRegistry.execute(...)             │
                                       │                        │
                        200 application/json (tool result)      │
                       ────────────────────────────────────────►│
                                       │                        │
   TaskOrchestrator.dispatch(wk-1) ───►│                        │
                  pushNotification(wk-1, channel.notify) ─────► │ (via SSE event)
                                       │                        │
                       POST /mcp/wk-1  │  tools/call complete_event (event handled)
                       ◄────────────────────────────────────────│
                                       │                        │
                       DELETE /mcp/wk-1│  (claude exit / sigterm)
                       ◄────────────────────────────────────────│
                  MCPSessionRegistry.evict(wk-1)                │
```

### Identity is in the URL

Per-session identity migrates from env vars to URL path:

| Old (env vars in claude's environment) | New (URL path component) |
|---------------------------------------|--------------------------|
| `WORKER_ID=worker-1`                  | `/mcp/worker-1`          |
| `WORKER_ID=supervisor`                | `/mcp/supervisor`        |
| (none — passive bridge invented `claude-<ppid>`) | `/mcp/{uuid}` written into per-claude `~/.claude.json` at spawn |

The bridge's `BRIDGE_SESSION_ID` computation (`WORKER_ID || SONA_SESSION_ID
|| "claude-<ppid>"`) goes away. The server already knows the sessionKey
from the URL; it doesn't need a determinism trick.

### Notification channel

`notifications/claude/channel` is a JSON-RPC notification. Over Streamable
HTTP, the server emits it as an SSE `message` event on the long-lived GET
connection. Claude Code's HTTP MCP client buffers SSE messages exactly the
way it buffers stdio frames — the consumer side doesn't care about
transport (verified in §3).

### Heartbeats are implicit

A worker's "last seen" timestamp updates whenever any MCP request comes in
on its sessionKey. No more outbound heartbeat loop. `MCPSessionRegistry`
keeps `lastContactedAt: [String: Int64]` and ticks it on every request.
A separate sweeper actor scans for sessions stale > 30s and writes the
`workers.lastHeartbeat` / `supervisorState.lastHeartbeat` columns directly.

---

## 3. MCP protocol surface to implement

### What Claude Code's HTTP transport requires

Per the MCP spec (Streamable HTTP, v2025-03-26 revision) and verified
against Claude Code v2.1.50's MCP client (`packages/mcp-client/streamable.ts`):

- The server MUST support **POST** at the MCP URL. Client sends a JSON-RPC
  request body. Server responds either:
  - `Content-Type: application/json` with the JSON-RPC response inline, OR
  - `Content-Type: text/event-stream` opening an SSE stream where the first
    `message` event carries the response.
- The server SHOULD support **GET** at the same URL for the long-lived
  server-push SSE stream. Client opens this once after `initialize` and
  reads notifications.
- The server MUST handle `DELETE` (graceful client shutdown) and `OPTIONS`
  (CORS preflight, even on localhost — Claude Code sends it).

We will pick the simpler "JSON inline for POST, SSE only for GET" variant.
We never need to stream a multi-part tool result; all our tool calls return
in <100ms.

### JSON-RPC methods to implement

| Method | Direction | Handling |
|--------|-----------|----------|
| `initialize` | client→server | Return `protocolVersion: "2025-03-26"`, capabilities `{ tools: {}, experimental: { "claude/channel": {} } }`, `serverInfo: { name: "sonata-bridge", version: "1.0.0" }`, and the existing instructions block from `sonata-bridge.ts` lines 345–421. |
| `notifications/initialized` | client→server | No-op; return nothing. |
| `tools/list` | client→server | Return the six tool schemas (verbatim from `sonata-bridge.ts` lines 427–499). |
| `tools/call` | client→server | Look up handler by name; call into `MCPSessionState.handleTool(name:, args:)`. |
| `ping` | client→server | Return `{}`. |
| `notifications/claude/channel` | **server→client** | Pushed over the SSE stream. Same JSON shape as today: `{ method, params: { content, meta } }`. |
| `notifications/cancelled` | client→server | Stub — ignore. Claude Code occasionally sends this on tool timeout. |
| `resources/list`, `prompts/list` | client→server | Return empty arrays — Claude Code probes for these even when we don't advertise the capability. |

### Verifying `notifications/claude/channel` works over HTTP

This is the one piece that needs a smoke test before we cut over. The
notification name is from Anthropic's experimental wakeup-channel proposal
and was originally validated over stdio only. Hypothesis: SSE is just a
JSON-RPC frame transport, and Claude Code's `mcp-client` routes incoming
notifications by `method` regardless of transport — so it should Just Work.

**Smoke test plan (do this before writing any production code):**
1. Stand up a 60-line throwaway Swift server that exposes `/mcp/test` with
   the minimum methods (`initialize`, `tools/list` returning one no-op tool,
   GET for SSE).
2. Configure a clean `~/.claude.json` with `"sonata-test": { "type": "http",
   "url": "http://localhost:9999/mcp/test" }`.
3. After client connects, push a `notifications/claude/channel` frame down
   the SSE stream with content `"test from in-app server"`.
4. Observe whether the claude session surfaces a `<channel
   source="sonata-test">` block. If yes, we're good. If no, fall back to
   plan B (§10 Risks).

The throwaway test should fit in one afternoon; do it on day 0 of the
implementation phase before committing to the larger rewrite.

---

## 4. Swift implementation

### File plan

All new code lives under `Sources/MCPServer/` (new directory — distinct
from the existing `Sources/MCP/` which is the memory-WS handler and the
channel dispatch actor; both will continue to exist).

```
Sources/MCPServer/
  MCPSessionRegistry.swift     ~120 LOC — actor; sessionKey → MCPSessionState
  MCPSessionState.swift        ~250 LOC — per-session: SSE writer, tool handlers, lastContactedAt
  MCPHTTPRouter.swift          ~180 LOC — registers /mcp/{sessionKey} routes on the existing Hummingbird router
  MCPNotificationDispatcher.swift ~80 LOC — public façade; called by TaskOrchestrator, AFKRegistry, DMRegistry to push
  MCPToolHandlers.swift        ~300 LOC — the six tools (complete_event, fail_event, sonar_dm_*)
  MCPSSEWriter.swift           ~90 LOC — typed wrapper around Hummingbird's outbound stream
  MCPSessionSweeper.swift      ~70 LOC — periodic actor; marks workers offline when their SSE drops > 30s
```

Total new code: ~1100 LOC of Swift — comparable to the 1167 LOC of TS we're
replacing.

### Route registration

In `SonataApp.swift` right after the existing `wsRouter.ws("/mcp", ...)`
block (around line 393):

```swift
// In-app MCP HTTP+SSE server — replaces sonata-bridge.ts
let mcpRegistry = MCPSessionRegistry(dbPool: pool, actionRegistry: registry)
MCPHTTPRouter.register(on: router, registry: mcpRegistry)
MCPNotificationDispatcher.shared.bind(registry: mcpRegistry)
let mcpSweeper = MCPSessionSweeper(registry: mcpRegistry, dbPool: pool)
await mcpSweeper.start()  // 15s tick — writes workers.lastHeartbeat
logger.info("MCP HTTP endpoint registered at http://127.0.0.1:\(port)/mcp/{sessionKey}")
```

### `MCPSessionRegistry`

An `actor` that owns the dictionary of live sessions:

```swift
actor MCPSessionRegistry {
    private var sessions: [String: MCPSessionState] = [:]
    private let dbPool: DatabasePool
    private let actionRegistry: ActionRegistry

    func get(_ sessionKey: String) -> MCPSessionState? { sessions[sessionKey] }
    func getOrCreate(_ sessionKey: String) -> MCPSessionState { ... }
    func attachSSE(_ sessionKey: String, writer: MCPSSEWriter) { ... }
    func detachSSE(_ sessionKey: String) { ... }
    func evict(_ sessionKey: String) { ... }
    func touch(_ sessionKey: String) { ... }
    func staleSessions(olderThanMs: Int64) -> [String] { ... }
}
```

Concurrency model: the registry is an actor; each `MCPSessionState` is an
inner `class` accessed only while holding the registry's isolation. Tool
handlers that need to do GRDB work hop off to `dbPool.write { ... }`.

### `MCPSessionState`

Per-session state mirroring the bridge's per-process state:

```swift
final class MCPSessionState {
    let sessionKey: String
    let role: SessionRole  // .worker | .supervisor | .interactive
    var lastContactedAt: Int64
    var sseWriter: MCPSSEWriter?    // nil when no GET stream is open
    var inFlightEventId: String?
    var dmRegistered: Bool
    var sessionLabel: String?

    init(sessionKey: String, dbPool: DatabasePool, registry: ActionRegistry) { ... }

    func handle(method: String, id: Any?, params: [String: Any]) async -> String? { ... }
    func pushNotification(method: String, params: [String: Any]) async { ... }
}
```

`SessionRole` is inferred from `sessionKey`:
- `sessionKey == "supervisor"` → `.supervisor`
- `sessionKey` matches an existing `workers.workerId` row → `.worker`
- otherwise → `.interactive`

This replaces the env-var logic in `sonata-bridge.ts` lines 104–334.

### `MCPNotificationDispatcher`

A `@unchecked Sendable` singleton that other parts of Sonata call to push
channel notifications without knowing the transport details:

```swift
final class MCPNotificationDispatcher: @unchecked Sendable {
    static let shared = MCPNotificationDispatcher()
    private var registry: MCPSessionRegistry?

    func bind(registry: MCPSessionRegistry) { self.registry = registry }

    /// Push a channel notification to a specific session. Returns false if
    /// the session has no live SSE writer (caller may choose to enqueue for
    /// backfill via the dm_inbox / afk_poll Actions instead).
    @discardableResult
    func pushChannel(
        sessionKey: String,
        content: String,
        meta: [String: String]
    ) async -> Bool { ... }
}
```

### Tool handlers

Each of the six tools maps to in-process Action calls. **Critically, none
of these go over loopback HTTP.** Today the bridge does `fetch
("${SONATA_API}/api/...")`; in the new world we call the Swift Action
directly. Reuse map:

| Tool | Old (HTTP) | New (in-process) |
|------|-----------|------------------|
| `complete_event` (worker) | `POST /api/worker/events/complete` | `WorkerActions.completeEvent(eventId:, workerId:, result:, dbPool:)` |
| `complete_event` (supervisor) | `POST /api/supervisor/heartbeat` | `SupervisorActions.heartbeat(sessionId:, dbPool:)` |
| `fail_event` (worker) | `POST /api/worker/events/fail` | `WorkerActions.failEvent(...)` |
| `fail_event` (supervisor) | same as supervisor complete | same |
| `sonar_dm_register` | `POST /api/dm/register` | `DMActions.register(sessionId:, sessionLabel:, role:, dbPool:)` |
| `sonar_dm_unregister` | `POST /api/dm/unregister` | `DMActions.unregister(sessionId:, dbPool:)` |
| `sonar_dm_send` | `POST /api/dm/send` | `DMActions.send(...)` |
| `sonar_dm_inbox` | `GET /api/dm/inbox` | `DMActions.inbox(sessionId:, sinceTs:, limit:, dbPool:)` |

Today these Actions are wrapped behind `ActionRegistry`'s HTTP routes for
external callers (worker-side TS bridge, web dashboard, MCP-over-WS).
Calling them in-process means we don't need a network hop; the function
calls happen on the same actor.

For tools where the existing public action signature is wrong (some take a
`Request` and parse the body), we'll add typed sibling functions in the
Actions file — e.g. `func completeEventTyped(eventId: String, workerId:
String, result: String?, dbPool: DatabasePool) async throws ->
CompleteEventResponse`. The HTTP route handler shrinks to a one-line
adapter calling the typed function.

### Heartbeat: implicit, not outbound

Today's bridge ships an explicit `pushLiveHeartbeat()` every 15s with token
deltas read from the transcript JSONL. Two problems with that for the new
world:
1. We're inside Sonata — we already know everything the bridge can know.
2. The transcript-reading path (`resolveTranscriptPath()`,
   `readTranscriptUsage()`) is *the* one piece of state that lives only on
   the worker filesystem.

Resolution:

- "Session is alive" → tracked by `lastContactedAt` in
  `MCPSessionRegistry`, ticked on every request. `MCPSessionSweeper`
  writes `workers.lastHeartbeat = lastContactedAt` every 15s, so the rest
  of the system (`sweepStaleWorkersForActions`, dashboard) sees no change.
- "Token spend for the in-flight event" → tool handlers for the inbound
  side of a Claude tool call already have access to the request's session
  context. We add transcript reading to the supervisor sweeper, not to
  every tool call. The sweeper, when handling a sessionKey that maps to a
  worker, looks up `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`
  exactly the way the bridge does today (port the `resolveTranscriptPath`
  / `readTranscriptUsage` functions to Swift) and writes the same
  `workers.currentEventTokens` columns.

For the supervisor: it has no workerEvents row to complete. Today the
bridge writes `supervisorState.lastHeartbeat` via the
`/api/supervisor/heartbeat` action. New behaviour: `MCPSessionSweeper`
calls `SupervisorActions.heartbeat(sessionId: "supervisor", ...)` for the
supervisor session every 15s. Same row touched, no functional change.

### AFK + DM: subscriptions, not polls

Today's bridge `setInterval`s a poll loop against `/api/afk/poll` and
`/api/dm/poll`. The poll-loop's reason for existing is that the bridge
lives in a foreign process — it can't be called back. In-process, that
constraint disappears.

`AFKRegistry.shared.enqueueReply(reply)` (already exists in
`Sources/Actions/AFKActions.swift:196`) currently appends to a per-session
queue that the bridge drains. We add one new method:

```swift
extension AFKRegistry {
    func setDeliveryHook(_ hook: @escaping (String, AFKReply) -> Void) { ... }
}
```

The hook is set once during app boot by `MCPNotificationDispatcher.bind()`
and is called inline from `enqueueReply` with the `(sessionId, reply)`
pair. The dispatcher then synchronously calls `pushChannel(sessionKey:
sessionId, content: ..., meta: ...)`. Net effect: AFK replies wake the
session within <100ms instead of <5s.

`DMRegistry` (which also lives in `DMActions.swift`) gets the same
treatment.

The polling endpoints (`/api/afk/poll`, `/api/dm/poll`) STAY around during
migration so the stdio bridge can still consume them while we cut sessions
over one by one. After the bridge is deleted, these endpoints can be
deleted too (their only remaining caller would be a hand-written test —
verify before deletion).

---

## 5. `~/.claude.json` / `~/.claude/mcp.json` config changes

### Before

```json
{
  "mcpServers": {
    "memory": {
      "type": "stdio",
      "command": "bun",
      "args": ["run", "/Users/evan/.sonata/mcp/mem-server.ts"]
    },
    "sonata-bridge": {
      "type": "stdio",
      "command": "bun",
      "args": ["/Users/evan/.sonata/mcp/sonata-bridge.ts"],
      "env": { "SONA_WORKER": "1" }
    }
  }
}
```

### After (per-Claude-session)

```json
{
  "mcpServers": {
    "memory": {
      "type": "http",
      "url": "http://localhost:3211/mcp-memory/{sessionKey}"
    },
    "sonata-bridge": {
      "type": "http",
      "url": "http://localhost:3211/mcp/{sessionKey}"
    }
  }
}
```

(`mem-server.ts` is out of scope for this plan but listed for parity — we
note it because `ensureGlobalMCPServers()` writes both entries today and
the same Swift refactor pattern applies to it. Migrating memory to HTTP is
a separate evenflow doc.)

### Where `{sessionKey}` comes from

Claude Code does **not** support `${ENV_VAR}` substitution in `mcp.json`
URLs (verified empirically + via decompilation memory entry `21464c2f`).
Options considered:

| Option | Pros | Cons |
|--------|------|------|
| (a) Env-var substitution in Claude Code (patch) | Single global mcp.json | Requires maintaining a patch; brittle. |
| (b) Per-claude-spawn-dir `.claude.json` written by the coordinator | Clean; uses already-supported per-dir config | Need to ensure spawn cwd has the file |
| (c) Generic sessionKey URL `/mcp/_` + identity tool call | One global config | Statefulness in the URL is cleaner than a magic init call; identity reveal would be racy |
| (d) Sonata spawns claude with a wrapper script that templates mcp.json into a tmpdir | Works, no patch needed | Adds a wrapper process |

**Chosen: option (b).** Both `SupervisorCoordinator` and `WorkerCoordinator`
already control the cwd they pass to `view.startProcess(...)`. Claude Code
reads `<cwd>/.claude.json` (if present) merged on top of `~/.claude.json`.
We write a session-specific `<cwd>/.claude.json` once at spawn time that
overrides just the `sonata-bridge` entry with the sessionKey baked in.

Concretely:

- Supervisor cwd is `~/.sonata/supervisor/` — already used. We write
  `~/.sonata/supervisor/.claude.json` with `url:
  http://localhost:3211/mcp/supervisor`.
- Worker cwds are `~/.sonata/worker/` for every worker today; with this
  change each worker gets its own dir
  `~/.sonata/worker-<workerId>/` so the per-dir `.claude.json` can differ.
  (Today they share `~/.sonata/worker/` with env-var-based identity; that
  conflation has to end anyway when env-vars stop being the identity.)
- Interactive: the existing
  `Sources/ViewModels/InteractiveSessionsViewModel.swift` `start()` path
  generates a UUID per session; we write `<projectCwd>/.claude.json` with
  that UUID in the URL. (TODO during implementation: confirm this is okay
  vs. polluting user project directories. If not, write to a sibling
  `.sonata-claude/` dir and use `--mcp-config <path>` flag if supported.)

### Migration helper

A new Swift helper `MCPClaudeConfigWriter`:

```swift
struct MCPClaudeConfigWriter {
    /// Writes/updates <cwd>/.claude.json so the sonata-bridge entry points
    /// at the given sessionKey. Preserves any other servers in the file.
    static func write(cwd: URL, sessionKey: String) throws { ... }
}
```

Called from `SupervisorCoordinator.startProcess()` and
`WorkerCoordinator.start(...)` just before `view.startProcess(...)`. The
global `~/.claude.json` keeps the stdio entry for now (so plain `claude`
sessions still get the bridge) — until step 5 of the migration (§7) when
we flip it.

---

## 6. Coordinator changes (Swift side)

### `SupervisorCoordinator.startProcess` (SupervisorTerminalView.swift:27)

**Remove:**
- `env.append("SONATA_ROLE=supervisor")` (line 49)
- `env.append("WORKER_ID=supervisor")` (line 50)
- `env.append("SESSION_LABEL=supervisor")` (line 51)
- `--dangerously-load-development-channels server:sonata-bridge` flag
  (line 61) — **keep**, the experimental channel is server-side capability
  declaration; only the *transport* is changing. Verify in §3 smoke test
  whether claude still wants this flag when the channel-declaring server
  is HTTP.

**Add:**
- `try? MCPClaudeConfigWriter.write(cwd: cwdURL, sessionKey: "supervisor")`
  just before `view.startProcess(...)`.

**Bridge watchdog (lines 91–162):** delete the entire watchdog block. Once
the bridge no longer exists as a child process, there's nothing to watch.
HealthMonitor's existing freshness check on `supervisorState.lastHeartbeat`
serves the same purpose, and now that timestamp is touched by the
in-process sweeper (no foreign-runtime dependency), it's reliable.

### `WorkerCoordinator.buildEnvironment` (WorkersView.swift:742)

**Remove:**
- `env.append("WORKER_ID=\(workerId)")` (line 769)
- `env.append("SESSION_LABEL=\(sessionLabel)")` (line 772) (if used by
  anything else, audit first; today it's only consumed by
  `sonata-bridge.ts`)
- `env.append("SONA_SESSION_ID=\(sessionId)")` (line 775)
- `SONATA_RESTART_NUDGE=1` / `SONATA_RESTART_TASK_ID` /
  `SONATA_RESTART_LAST_EVENT_ID` (lines 778–784) — these are read by the
  bridge's `maybeFireRestartNudge()`. New mechanism: when a worker is
  respawned with `restartNudge: true`, the coordinator calls
  `MCPNotificationDispatcher.shared.pushChannel(sessionKey: workerId,
  content: "[SONATA_RESTART]...", meta: ["event_type": "sonata_restart",
  ...])` 2 seconds after spawn (give the SSE stream time to come up).
- `SONA_WORKER=1` — still useful as a flag to mem-server.ts and other
  bridge-aware tooling; keep for now, mark for review after migration.

**Add:**
- A new function `WorkerCoordinator.writeSessionConfig(workerId: String,
  cwd: URL)` that calls `MCPClaudeConfigWriter.write(cwd: cwd, sessionKey:
  workerId)`.

### `InteractiveSessionsViewModel.start()` (line 117–140)

**Remove:**
- `env.append("SONATA_ROLE=session")` (line 140) — purely informational
  today; only the bridge reads it. After bridge deletion, it's dead.

**Add:**
- Generate `sessionKey = "session-" + UUID().shortString`.
- `try? MCPClaudeConfigWriter.write(cwd: spawnCwd, sessionKey: sessionKey)`.

### `InspectorWindowController` (line 62)

`SONATA_ROLE=inspector` — same treatment as `session`. Remove + add session
config writer if the inspector also wants MCP access. (Today it doesn't
register as a worker; verify by code search before deleting.)

---

## 7. Migration / rollout plan

### Phase A — Smoke test (0.5 day)

Per §3, prove that `notifications/claude/channel` works over SSE in a
30-line throwaway. If it does, proceed. If not, fall back to plan B
(§10).

### Phase B — Build the HTTP server alongside stdio (3–4 days)

1. Create `Sources/MCPServer/` and write the seven files in §4. Compile
   green. No callers yet.
2. Wire `MCPHTTPRouter.register(...)` into `SonataApp.swift`. The new
   `/mcp/{sessionKey}` endpoint goes live but nothing connects to it.
3. Add a developer-only menu item or env-var-guarded code path that
   writes the per-cwd `.claude.json` pointing at HTTP for **just the
   interactive session** path. Manually spawn an interactive claude with
   the new transport. Verify:
   - `initialize` round-trips
   - `tools/list` returns the six tools
   - `tools/call complete_event` succeeds (smoke: invent a fake event,
     call the tool)
   - SSE GET stream stays open
   - A manually-triggered notification arrives
4. Add automated integration tests (§9).

### Phase C — Flip session types one at a time (1–2 days)

In order, behind a feature flag `SONATA_MCP_INPROC` (env var on the
Sonata.app process, default off):

1. **Interactive sessions first.** Lowest blast radius — if it breaks,
   only manually-spawned claude sessions misbehave; worker pool and
   supervisor are untouched.
2. **Workers next.** Verify a full email/task event round-trip ends in
   `complete_event`. Verify `assignedTo` gating still routes events to
   the right worker. Run for 24h with no stdio bridges in worker pool.
3. **Supervisor last.** It's the highest-stakes session because of the
   `check`-event cadence. Flip it after workers have been stable for 48h.

At each step, the feature flag controls whether `MCPClaudeConfigWriter`
writes an `http://` URL or omits the entry (falling back to the global
stdio entry). Reverting a step is a single env-var flip + Sonata.app
restart.

### Phase D — Delete the bridge file (0.5 day)

When `ps aux | grep -c sonata-bridge.ts == 0` is stable for a week:

1. Remove `Sources/Sonata/Resources/mcp/sonata-bridge.ts` from the bundle.
2. Remove the `sonata-bridge` entry from `requiredServers` in
   `ensureGlobalMCPServers()` (SonataApp.swift:64–69).
3. Remove `~/.sonata/mcp/` directory creation logic if mem-server.ts
   migration is also complete; otherwise leave it.
4. Delete `/api/afk/poll`, `/api/dm/poll`, `/api/bridge/announce`,
   `/api/bridge/heartbeat`, `/api/bridge/unregister`,
   `/api/worker/heartbeat` (HTTP — the in-process action survives),
   `/api/worker/events/claim`, `/api/worker/events/recent` HTTP routes.
   Verify no external caller (e.g. dashboard frontend) uses them — `grep`
   in `Sources/Sonata/Resources/web/` before deletion.
5. Delete `bridges` table tracking (if it exists) and
   `MCPManagerView`'s "registered bridges" UI section.

### Feature-flag mechanism

```swift
let useInProcMCP = ProcessInfo.processInfo.environment["SONATA_MCP_INPROC"] == "1"
```

Read once at app boot. Passed into `SupervisorCoordinator`,
`WorkerCoordinator.buildEnvironment`, and `MCPClaudeConfigWriter`. When
false, behave as today (stdio bridge env-vars set, no per-cwd
`.claude.json` written). When true, behave per §6.

Single env var, default off, observable in the Sonata.app menu's
diagnostics panel.

---

## 8. Acceptance criteria

The migration is complete and the bridge can be deleted when **all** of
these hold for 7 consecutive days:

| Check | Pass criterion |
|-------|---------------|
| Supervisor uptime | `ps -o etime= -p $(pgrep -f 'supervisor.*claude')` ≥ 24h, no respawns |
| Bridge crashes | `~/.sonata/logs/bridge-crashes.log` empty (or file absent) for 7 days |
| Process count | `ps aux \| grep -v grep \| grep -c sonata-bridge.ts == 0` |
| MCP responsiveness | All 4 workers + supervisor's `MCPSessionRegistry.lastContactedAt` < 30s old |
| Heartbeat freshness | `workers.lastHeartbeat` and `supervisorState.lastHeartbeat` columns continue to update on the normal cadence; no row drifts > 60s stale |
| Event flow | Every `workerEvents` row dispatched in a 24h window reaches a terminal status (`completed` or `failed`) within its priority's SLA |
| AFK round-trip | An AFK reply sent at T arrives in the claude session by T + 5s (compared to T + 5-30s under polling) |
| Sonar DM round-trip | A `sonar_dm_send` from one bridge session to another delivered in < 1s (no poll lag) |
| Disk footprint | `~/.sonata/mcp/` directory deleted; bundle no longer contains `sonata-bridge.ts` |
| Memory | `Sonata.app` RSS does not exceed `pre-migration RSS + 30 MB` (the cost of holding N SSE connections in Hummingbird) |

---

## 9. Test plan

### Integration tests (new)

In `Tests/MCPServerTests/` (new directory):

1. **`MCPHTTPHandshakeTests.swift`** — boot a Sonata test harness on a
   random port, send `initialize`, assert `protocolVersion` and
   capabilities match.
2. **`MCPToolCallTests.swift`** — for each of the six tools, send a
   `tools/call` request, assert the DB side effect (e.g. `complete_event`
   marks the row `completed`).
3. **`MCPSSEStreamTests.swift`** — open a GET request, trigger
   `MCPNotificationDispatcher.shared.pushChannel(...)` from another task,
   assert the SSE frame arrives. This is the load-bearing test for the
   notification path.
4. **`MCPSessionReconnectTests.swift`** — open SSE, abort, reconnect with
   the same sessionKey, assert lastContactedAt updates and subsequent
   notifications go to the new connection.
5. **`MCPSessionEvictionTests.swift`** — open SSE, abort, wait 35s with
   no reconnect, assert `MCPSessionSweeper` marked the worker offline.

### Manual verification — `check` event wake-up

The single most important behavioural test, because this is what `e987e53`
was patching. Steps:

1. Migrate supervisor to in-proc MCP (Phase C step 3).
2. Trigger a check event:
   `mem_supervisor_status` shows the supervisor session, then `mem
   task add ...` with a tag that fires a supervisor check.
3. Observe (via `tail -f ~/.sonata/logs/sonata.log`) that the supervisor
   session receives `<channel source="sonata-bridge">` content within
   2 seconds.
4. Verify the supervisor calls `complete_event` and that Sonata receives
   the call in-process (no HTTP loopback).
5. Verify no process exit. Run for 12h, observe that `check` events fire
   ~every 30s and the supervisor session is never respawned.

### SSE reconnection — manual

Claude Code's HTTP MCP client auto-reconnects SSE per the spec, but the
exact backoff and idempotency are version-dependent. To validate:

1. Worker is running, SSE connected.
2. `pkill -STOP` the Sonata.app process for 5s (suspend, not kill).
3. `pkill -CONT` — observe whether the worker's SSE reconnects within
   30s and notifications resume.

If reconnect fails, document the recovery path (claude session may need
to be restarted; this is a degradation vs. the stdio bridge which would
have died and been respawned). Decide before Phase D whether this is
acceptable.

### Load / soak

24h soak under realistic workload — 2 workers + supervisor + 1
interactive — with the event dispatcher firing test events every 30s.
Pass criteria are listed in §8.

---

## 10. Risks and rollback

### R1: `notifications/claude/channel` doesn't work over HTTP+SSE

**Probability:** medium. The experimental channel was originally designed
for stdio. The hypothesis that it's transport-agnostic is well-grounded
but unverified.

**Mitigation:** smoke test in Phase A (§3). If it fails, fall back to
**plan B**: keep the stdio bridge for *just the channel-notification
path*, but move every other concern (heartbeat, tool calls, polling)
in-process via the HTTP server. This is less of a win — the bridge
process still exists — but the bridge becomes a thin SSE-or-stdio
notification shim of ~150 LOC instead of 1167. Acceptance criteria are
relaxed (process count ≤ N+1, not 0).

### R2: SSE has worse wake-up latency than stdio

**Probability:** low. SSE is a single TCP socket with no
serialization-deserialization overhead vs. stdio's pipe + JSON-RPC
framing. Localhost RTT is sub-millisecond.

**Mitigation:** measure during Phase B smoke test. If wake-up latency >
50ms in the median (compared to current ~5ms via stdio), investigate
Hummingbird's outbound stream buffering — likely we need to flush
explicitly after each frame.

### R3: Hummingbird leaks SSE connections under load

**Probability:** low. Hummingbird is built on swift-nio and handles long-
lived connections cleanly in production deployments.

**Mitigation:** the soak test in §9 covers this. If we see file descriptor
leaks (`lsof -p $(pgrep Sonata) | wc -l` climbing), instrument
`MCPSessionRegistry` to log attach/detach events and audit.

### R4: A worker bug now takes Sonata.app down

This is the inverse of the fake-isolation argument. Today, a bug in the
bridge's JSON parsing crashes the bridge, not Sonata. After this change,
the bug crashes Sonata.

**Mitigation:** tool handlers MUST be wrapped in `do/catch` and return
a JSON-RPC error on any throw. `MCPToolHandlers.swift` will have a
single `safeInvoke<T>(_ work: () async throws -> T)` helper that wraps
every handler. The same applies to SSE write paths. No `try!`. No
`fatalError`. Code review checklist item.

### R5: The migration spans multiple Sonata.app versions

If we ship Phase B in version N and Phase C in version N+1, users on N+1
who upgraded mid-rollout might have stale `.claude.json` files from N.

**Mitigation:** on every app launch, `ensureGlobalMCPServers()`
reconciles the global `~/.claude.json`. Add equivalent reconciliation
for per-cwd configs: `MCPClaudeConfigWriter.reconcileAll(workers:
[String], supervisor: Bool)` at app launch.

### R6: Rollback procedure

If Phase C exposes a critical bug:
1. Set `SONATA_MCP_INPROC=0` (or unset).
2. Restart Sonata.app — all coordinators revert to env-var identity.
3. Run `ensureGlobalMCPServers()` (happens on launch) — re-installs the
   stdio bridge entry into `~/.claude.json` and `~/.claude/mcp.json`.
4. Delete the per-cwd `.claude.json` files written during the rollout
   (small helper script; document the list of paths in the doc you
   write in Phase C).
5. Existing `sonata-bridge.ts` in the bundle is still there (Phase D
   hasn't run yet), so workers/supervisor spawn with stdio bridges as
   before.

Rollback window: ~3 minutes (app restart + bridge cold-start).

---

## 11. Effort estimate

| Phase | Calendar time | Active engineering | Notes |
|-------|--------------|--------------------|-------|
| A — Smoke test | 0.5 day | 3–4 hours | Mostly waiting on claude responses to validate behaviour |
| B — Build server alongside stdio | 3–4 days | 18–24 hours | The bulk of the work. SSE writer + session registry + 6 tool handlers + tests |
| C — Flip session types | 1–2 days calendar (each step soaks 24–48h) | 4–6 hours | Mostly observation. Each flip = ~30 min of code change + a long bake |
| D — Delete bridge | 0.5 day | 2 hours | Mechanical. After Phase C is stable. |
| **Total active engineering** | **~6 days calendar** | **~30 hours** | |

Bake time is included separately because Phase C requires 24h+ soaks
between steps; if Evan is comfortable compressing those, total calendar
time shrinks to ~4 days.

---

## 12. Open questions

1. **Per-cwd `.claude.json` in user project dirs.** Writing
   `<projectCwd>/.claude.json` for interactive sessions means leaving a
   file in the user's working dir. Acceptable? Alternatives: spawn from a
   sibling `.sonata-claude/` dir, or pass `--mcp-config <path>` if Claude
   Code supports it (verify in v2.1.50+).
2. **Worker cwd separation.** Today all workers share `~/.sonata/worker/`.
   Moving to per-worker dirs (`~/.sonata/worker-1/`, etc.) lets us
   per-dir-configure but means the CLAUDE.md in `~/.sonata/worker/`
   needs to be copied / symlinked into each. Symlink, copy, or refactor
   the coordinator to pass `--system-prompt`? Decide before Phase C.
3. **Does the `--dangerously-load-development-channels server:sonata-bridge`
   flag still apply to HTTP transports?** The flag's documented purpose
   is to opt in to the experimental channel for a named MCP server. The
   *name* matches whether the server is stdio or HTTP, so plausibly yes,
   but unverified. Confirm in Phase A smoke test.
4. **Memory server.** `mem-server.ts` is also stdio today. Should the
   same migration cover it? Recommendation: separate evenflow doc, same
   pattern, do after this one. Listed as a future-work pointer here so
   the in-app server URL scheme leaves `/mcp-memory/{sessionKey}` room.
5. **OAuth / auth on the new endpoint.** `/mcp/{sessionKey}` is
   unauthenticated localhost-only today. If someday Sonata.app exposes
   itself beyond localhost, every session URL becomes a privilege escalation
   path. Out of scope for v1; add a TODO in `MCPHTTPRouter` to require a
   token (matching the `~/.sonata/.daemon.token` pattern eyebrowse uses).
6. **`SONA_SESSION_ID` env var consumers.** Other tools (`mem-server.ts`
   sibling-injection, anything reading `~/.claude/projects/` paths) read
   this. Confirm we're not breaking memory's session-id auto-injection
   when we stop setting it. Likely need to keep setting it as a "what
   transcript am I" marker even though it's no longer the MCP identity.
7. **Bundle compatibility for older Claude Code versions.** What's the
   minimum Claude Code version that supports `"type": "http"`? If users
   pin an older version, we need to keep the stdio path forever. Verify
   via `claude --version` matrix.
