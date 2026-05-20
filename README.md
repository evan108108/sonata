# Sonata

Sonata is a native macOS application that serves as a self-contained runtime for AI agents. It bundles a persistent memory system, a plugin architecture, worker management, a cron-style scheduler, email handling, health monitoring, a SwiftUI dashboard, and an MCP server into a single binary. Open the app and the entire stack is running — no Docker, no external databases, no separate daemons.

## Features

- **Persistent memory** — SQLite (via GRDB) with FTS5 full-text search, embedded vector search (cosine similarity over Accelerate), and a knowledge graph of entities and relations.
- **Plugin system** — install external applications (any language) as plugins. Their HTTP actions are discovered at runtime and exposed as native MCP tools.
- **Worker management** — spawns and supervises Claude Code TUI processes in embedded SwiftTerm terminals. Events are dispatched via a push-based channel server with headless fallback.
- **Scheduler** — cron-style recurring jobs plus a calendar-event system for autonomous background tasks (memory hygiene, consolidation, knowledge-graph enrichment, and similar).
- **Email handling** — polls inboxes on a schedule, stores messages, and dispatches new mail to workers or handler routines.
- **Health monitoring** — periodic liveness checks, supervisor events, and repair routines that keep workers and subsystems running.
- **SwiftUI dashboard** — multi-tab native UI for memory, tasks, workers, schedule, email, contacts, wiki, files, health, and settings, with keyboard shortcuts.
- **MCP server** — 135+ MCP tools exposed over JSON-RPC / WebSocket, covering every domain the runtime supports.
- **Full-text search subsystem** — embeds MeiliSearch as a subprocess to index wiki pages and archived memories.
- **Filesystem watchers** — FSEvents-based sync between on-disk markdown files and database state for the wiki and private documents.

## Quick Start

### Prerequisites

- macOS 14 (Sonoma) or newer
- Xcode 16 with the Swift 6 toolchain
- [Bun](https://bun.sh) (used by the bundled MCP bridge scripts)

### Build

```bash
git clone <repo-url> Sonata
cd Sonata
swift build
```

### Run

```bash
swift run Sonata
```

The HTTP server starts on port `3211` (override with `SONATA_PORT`). The SwiftUI dashboard opens in the menu bar, and data is written to `~/.sonata/`.

To install as a standard macOS app, package `.build/debug/Sonata` into an `.app` bundle and place it in `/Applications/`.

## Architecture

```
+----------------------------------------------------------------------+
|                        Sonata.app (single process)                    |
|                                                                       |
|  +-----------------+  +------------------+  +----------------------+  |
|  |  SQLite (GRDB)  |  |  HTTP Server     |  |  Scheduler           |  |
|  |  FTS5 + WAL     |  |  Hummingbird     |  |  Cron + calendar     |  |
|  +-----------------+  |  MCP over WS     |  |  Email handler       |  |
|  +-----------------+  |  Port 3211       |  |  Task dispatcher     |  |
|  |  Vector Search  |  +------------------+  |  Backup manager      |  |
|  |  Accelerate     |  +------------------+  |  Health monitor      |  |
|  +-----------------+  |  Channel Server  |  |  Wiki watcher        |  |
|  +-----------------+  |  Worker dispatch |  +----------------------+  |
|  |  MeiliSearch    |  +------------------+  +----------------------+  |
|  |  Subprocess     |  +------------------+  |  SwiftUI Dashboard   |  |
|  +-----------------+  |  PluginManager   |  |  Multi-tab UI        |  |
|                       +------------------+  +----------------------+  |
+----------------------------------------------------------------------+
```

Top-level components:

- **`Database/`** — SQLite schema, migrations, and the GRDB wrapper.
- **`Actions/`** — domain logic grouped by topic (memory, tasks, calendar, wiki, workers, plugins, and more). Each `*Actions.swift` file defines `SonataAction` values.
- **`Server/`** — Hummingbird routes, `ActionRegistry`, `SonataAction`, and `PluginManager`. Actions auto-generate both HTTP routes and MCP tools.
- **`MCP/`** — JSON-RPC MCP server and the channel server that pushes events to workers.
- **`Scheduler/`** — `SchedulerActor`, cron parser, `TaskDispatcher`, email handler, backup manager, health monitor, and the filesystem watcher.
- **`Search/`** — MeiliSearch subprocess manager and the `SearchService` abstraction.
- **`Views/` / `ViewModels/`** — SwiftUI dashboard.
- **`Sonata/`** — app entry point, resources, and bundled MCP bridge scripts.

### Unified Action Model

Every capability is defined as a `SonataAction`. The `ActionRegistry` exposes each action as both an HTTP endpoint and an MCP tool from a single source of truth, so adding a new tool is a single declaration rather than two parallel wiring steps.

## Plugins

Sonata is extensible through a plugin system. A plugin is an external process (any language) that:

1. Ships a `<name>.plugin.json` manifest with metadata and a port.
2. Starts an HTTP server on that port.
3. Exposes `GET /api/actions` for runtime discovery.
4. Handles action calls over HTTP.

Once installed, a plugin's actions are mounted as MCP tools prefixed with the plugin name (e.g. `sonar_send`), its routes are reverse-proxied under `/api/plugins/<name>/`, and it gets a private data directory at `~/.sonata/plugins/<name>/`. Plugins can optionally push events through a WebSocket channel that Sonata subscribes to on startup.

Install, enable, disable, and remove plugins through the dashboard or the HTTP API. See [docs/plugins.md](docs/plugins.md) for the full contract, event format, and security model.

## Configuration

All state lives under `~/.sonata/`:

```
~/.sonata/
  sonata.db          SQLite database (primary state)
  wiki/              compiled wiki pages (markdown)
  private/           local-only notes
  documents/         planning docs, drafts
  plugins/<name>/    plugin data directories
  mcp/               deployed MCP bridge scripts
  worker/            worker instructions
  supervisor/        supervisor instructions
  backups/           nightly SQLite snapshots
  meili-data/        MeiliSearch index data
  logs/              subprocess and session logs
```

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `SONATA_PORT` | `3211` | HTTP server port |
| `SONATA_WORKER_COUNT` | `2` | Number of Claude Code worker terminals spawned at launch |

Most runtime configuration — email inboxes, supervisor settings, schedules, plugins, secrets — is managed through the dashboard's Settings tab, which writes to the SQLite database.

On startup Sonata registers `sonata-bridge` in `~/.claude/mcp.json` and `~/.claude.json` so every Claude Code session picks it up automatically. `sonata-bridge` is an HTTP MCP transport (`POST /mcp`) that serves the full ActionRegistry surface (~220 tools) alongside a handful of worker-only narrow shims (`complete_event`, `fail_event`, `sonata_identify`, `sonar_dm_*`, `afk_register`, `mem_task_*`) — one transport, one namespace. Any earlier `memory` stdio entry left behind by older Sonata builds is scrubbed on startup.

## MCP Tools

Sonata exposes 230+ tools through its MCP server, organized by domain:

| Category | Examples |
|----------|----------|
| Memory | `mem_recall`, `mem_store`, `mem_search`, `mem_archive`, `mem_supersede` |
| Tasks | `mem_task_create`, `mem_task_list`, `mem_task_complete`, `mem_task_retry` |
| Calendar | `calendar_create`, `calendar_upcoming`, `calendar_trigger`, `calendar_enable` |
| Workers | `worker_register`, `worker_heartbeat`, `worker_status`, `worker_drain` |
| Email | `email_check`, `email_recent`, `email_store`, `email_inbox_upsert` |
| Wiki | `wiki_create`, `wiki_patch`, `wiki_children`, `wiki_dirty_list` |
| Documents | `doc_index`, `doc_get`, `doc_patch`, `mem_doc_search` |
| Entities & graph | `mem_entity_upsert`, `mem_entity_search`, `mem_relation_create`, `mem_expand` |
| Plugins | `plugin_install`, `plugin_enable`, `plugin_list`, `plugin_config` |
| System | `system_ping`, `system_status`, `system_backup`, `system_deploy` |

Tool schemas are discoverable over the MCP protocol at runtime. See [docs/mcp-tools.md](docs/mcp-tools.md) for a full catalogue.

## Development

### Build and run

```bash
swift build              # debug build
swift run Sonata         # build and launch
swift build -c release   # optimized build
```

A clean rebuild is recommended after changing resources:

```bash
rm -rf .build && swift build
```

### Tests

```bash
swift test
```

### Project layout

- `Package.swift` — Swift Package Manager manifest.
- `Sources/` — all Swift source code, grouped by subsystem.
- `Sources/Sonata/Resources/` — bundled resources (web dashboard, worker/supervisor instructions, MCP bridge scripts).
- `docs/` — architecture notes and reference docs.

### Contributing

Issues and pull requests are welcome. Please:

1. Open an issue describing the change before starting significant work.
2. Keep pull requests focused — one concern per PR.
3. Run `swift build` and `swift test` locally before pushing.
4. Match the existing code style (Swift 6, actor-based concurrency, no force-unwraps outside tests).

## License

License terms have not yet been finalized. Until a license file is added, all rights are reserved by the copyright holder. Please contact the maintainers before redistributing or building on this code.
