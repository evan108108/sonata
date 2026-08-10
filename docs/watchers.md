# Watchers

Filesystem event source primitive. A **watcher** is one config row that says: "when a file event happens under this path, run this LLM-powered action." Peer to Sessions, Workers, Tasks, Rooms.

## What this is

Sonata already had reactive primitives (Workers respond to Tasks, Sessions respond to messages) and scheduled ones (Scheduler for cron / calendar events). Watchers fill the third slot: file-event → LLM action. The action is either a slash-command skill (`/meeting`) or a free-form prompt.

Every fire dispatches a task via `mem_task_create` — same infrastructure any other worker task uses. The task carries `source: "watcher/<id>"` and `sourceRef: "<absolute-file-path>"` so watcher-triggered work traces back in the Tasks view (via the `▲ Watcher: <id>` pill) and in `mem_recall`.

## Adding a watcher

### Via the UI

Sonata → Watchers tab (between Files and Plugins). Click **New**. The sheet leads with four one-click templates (meeting logger, screenshot OCR, downloads categorizer, inbox.txt to tasks), or fill the form manually:

| Field | Meaning |
|---|---|
| Name | Human label |
| Watched path | Absolute path to a directory or single file |
| Pattern | Basename glob (`*.md`, `Screenshot*.png`); default `*` |
| Trigger | `file_added` / `file_modified` / `file_deleted` / `size_threshold` |
| Prompt | Slash-command (`/meeting`) or free-form. Tokens: `{{path}}`, `{{name}}`, `{{ext}}`, `{{dir}}`, `{{event}}`, `{{watcher}}`. If NO tokens appear, a preamble with the file path is prepended automatically. |
| Cooldown / Retries | Advanced disclosure |

The **Preview** line under the form shows exactly what will run — reads like a sentence so you can sanity-check before saving.

Templates install as complete watcher rows; you can edit them after install like any other.

### Via MCP / HTTP

```bash
# Create
curl -X POST http://127.0.0.1:3211/api/watcher/create \
  -H 'content-type: application/json' \
  -d '{
    "id": "meeting-logger",
    "name": "Meeting transcript logger",
    "path": "/Users/evan/Documents/meetings",
    "pattern": "*.md",
    "trigger": "file_added",
    "prompt": "/meeting",
    "cooldownMs": 5000
  }'

# List / get / enable / disable / delete
curl http://127.0.0.1:3211/api/watcher/list
curl 'http://127.0.0.1:3211/api/watcher/get?id=meeting-logger'
curl -X POST http://127.0.0.1:3211/api/watcher/enable -d '{"id":"meeting-logger"}'
curl -X POST http://127.0.0.1:3211/api/watcher/disable -d '{"id":"meeting-logger"}'
curl -X DELETE 'http://127.0.0.1:3211/api/watcher/delete?id=meeting-logger'
```

MCP tools: `watcher_create`, `watcher_list`, `watcher_get`, `watcher_update`, `watcher_delete`, `watcher_enable`, `watcher_disable`, `watcher_test`, `watcher_events_recent`.

## How the prompt is rendered

Two rules — the runtime picks based on whether your prompt contains any of the six tokens:

**No tokens** — the runtime prepends a preamble and appends your original prompt at the bottom. The worker sees:

```
You are a Sonata filewatcher-triggered task.

Watcher: Meeting transcript logger
Trigger: file_added
File path: /Users/evan/Documents/meetings/Stand up - 2026-08-06.md

Your prompt:
/meeting
```

This is the default and covers 90% of use cases — dropping a file into a folder and letting the skill do the rest.

**Tokens present** — substitution only, no preamble. Every token is replaced globally, unknown tokens stay as-is. Example: `"Summarize {{path}} and email me the highlights."` becomes `"Summarize /Users/…/foo.md and email me the highlights."`.

## Triggers

| Trigger | Fires on |
|---|---|
| `file_added` | New file matching pattern lands in the watched path (or a rename lands one) |
| `file_modified` | Existing file's contents change |
| `file_deleted` | A matching file was removed |
| `size_threshold` | File is created or grown; runtime checks against `sizeThreshold` bytes before firing |

Pattern is matched against the **basename** only, not the full path. `*.md` matches `foo.md` regardless of the depth under the watched dir.

Watchers on a single file work — the runtime watches the parent directory and filters by name.

## Test Now

The detail panel has a **Test now** button (and the `watcher_test` MCP tool). Pick an existing file and it runs the same dispatch path — same prompt rendering, same `mem_task_create` — without waiting for a real FSEvent. Uses:

- Debugging your prompt without renaming/re-creating files
- Sanity-checking a new watcher before enabling
- Re-running a skill against a file that already fired once and got debounced

Test fires DO NOT touch the `consecutiveFailures` counter, so they can't accidentally trip auto-disable.

## Debounce and coalescing

`cooldownMs` is a per-`(watcherId, path)` window. A single file being written in chunks (a `pip install`, a large `git clone`, a screen recording growing over time) fires one dispatch, not N. Different files under the same watcher fire independently.

Default: 5000 ms. Raise it for files that write slowly, lower it for genuinely quick events.

## Failure handling and auto-disable

If dispatch fails (task creation errors, invalid destination path, etc.):

- `watcher_events` records the failure with `status='errored'` and the error text
- `watchers.consecutiveFailures` increments
- After **5 consecutive failures**, the watcher is auto-disabled and its FSEventStream torn down

Re-enable via the UI or `watcher_enable` — this clears the counter and reopens the stream.

Path errors (watched directory doesn't exist at boot) mark `lastError` on the row and skip stream registration for that watcher only; other watchers are unaffected.

## Where it lives in the code

| Piece | File |
|---|---|
| Schema | `Sources/Database/Schema.swift` — v42_watchers |
| Actions | `Sources/Actions/WatcherActions.swift` — `makeWatcherActions(runner:)` |
| Runner | `Sources/Scheduler/WatcherRunner.swift` — `WatcherRunner` actor + `Registration` + FSEvents trampoline |
| UI | `Sources/Views/WatchersView.swift`, `Sources/ViewModels/WatchersViewModel.swift` |
| NavRail | `Sources/Views/ContentView.swift` — `.watchers` tab |
| Cross-primitive pill | `Sources/Views/TasksView.swift` — `TaskItem.watcherSourceId` |

## Templates catalog

| Template | Watches | Action |
|---|---|---|
| Meeting transcript logger | `~/Documents/meetings/*.md` | `/meeting` |
| Screenshot OCR | `~/Desktop/Screenshot*.png` | OCR + memory-store the extracted text |
| Downloads categorizer | `~/Downloads/*` | LLM suggests a destination folder; moves if unambiguous |
| Inbox.txt to tasks | `~/inbox.txt` on modify | Reads last line, creates a Sona task from it |

All template paths are assembled from `$HOME` at runtime — no hard-coded user paths.

## What v1 does not include

- Non-filesystem triggers (URL polling, RSS, calendar events). Watchers are file/folder-scoped.
- Workflows as the action target (Sonata doesn't have Workflows yet). Current prompt-string action is forward-compatible.
- Batch triggers ("fire once when N files land in a window").
- Cross-machine watchers (macOS local only).

See `~/.sonata/wiki/ideas/watchers.md` for the full design rationale and the deferred items.
