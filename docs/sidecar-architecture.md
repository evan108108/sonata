# Sidecar architecture

This is what the sidecar framework looks like as it actually ships (2026-07-22, after the tier-2 pivot). The Phase-0 memory (`f2d12f6f`) describes the original tier-1 design; that document was accurate for one day and is preserved for historical context but should NOT be used as a reference. This is the current shape.

## What a sidecar is

A sidecar is a background service that receives events by `event_type` and produces a side effect. It's registered once at boot and lives for the process's lifetime. Everything about it is small on purpose — event routing, config, spend tracking, UI — so a second sidecar for a different purpose is a config change, not an architecture change.

Sonata has one sidecar today: `memory`. It surfaces relevant memories as hints that other Claude Code sessions inject into their next prompt.

## Two kinds

A sidecar registers as one of two kinds. The framework switches on kind at exactly two call sites (`SidecarLifecycle.spawn` and `MCPEventPusher.pushPendingWorkerEvents`). Everything else is uniform.

### `.claudeCode`

Sonata spawns a hidden Claude Code session, drives it from a bundled `SKILL.md`, delivers events via SSE. The session can dispatch sub-agents, reason across turns, rotate when its context fills. Right shape when the work needs LLM judgment (a reviewer that critiques a diff, an enricher that synthesizes across sources, an ambient research sidecar).

Nothing is currently registered as `.claudeCode`. The support is intact — `SidecarSpawnerFactory` implements the spawn path — but the memory sidecar has left this mode.

### `.inProcess`

Sonata registers a Swift closure at boot. No Claude Code session, no `workers` row, no context monitor, no rotation, no `SKILL.md`, no spend tracking. Events land as `workerEvents` rows with a synthetic `assignedTo = "inproc-<name>"`, and `MCPEventPusher` invokes the closure directly and marks the event completed on return.

Right shape when Sonata's own machinery does the work. The memory sidecar is `.inProcess`: `mem_recall`'s 7-layer ranking is the judgment step, so an LLM sitting on top adds cost without adding signal.

## The memory sidecar concretely

The memory sidecar is now driven from `UserPromptSubmit` — synchronous, one HTTP round trip per user turn, all logic in Swift. The `Stop`-hook + `sidecarHints`-table + injected-memory-ledger + query-expansion path from earlier the same day is retired (settings.json entries are purged by `ensureBundledHooks` on boot); the previous approach tried to predict what the next turn would need before the user typed it, and every knob we added — dedup window, ledger, query expansion, noise dedup — was patching around the prediction being unreliable. The synchronous path just answers what the user actually asked.

**Event source.** A dumb-pipe bash hook, `~/.claude/hooks/sidecar-user-prompt-submit-hook.sh` (bundled to `Sources/Sonata/Resources/hooks/`, installed at boot). Reads Claude Code's raw hook input JSON from stdin, `curl`s it verbatim to `/api/sidecar/hint/synthesize` with a 2-second cap, prints the returned `content` field to stdout via `jq -r '.content // ""'`. Claude Code prepends stdout to the user's prompt. Fail-silent by construction: any curl / jq / Sonata failure emits nothing and exits 0.

**Handler.** `MemorySidecarHandler.synthesize(sessionId:prompt:logger:)`:
1. **Role gate** — `SONATA_SESSION_ROLE != "user"` or `cwd` under `~/.sonata/worker|sidecar-|supervisor` → empty.
2. **Distill** — extract distinctive tokens from the prompt (capitalized proper nouns, hyphenated compounds like `Agent-Reach`, quoted strings, ≥6-char non-stopwords). Discard the rest. Empty distilled query → empty response.
3. **Recall** — `GET /api/recall` on the distilled query with `tier=l0`, `recencyMode` from settings.
4. **Filter** — score floor (`minRankScore`); apply noise downweight from `sidecarHintNoise`.
5. **Anchor rule** (below) → up to `top_k` (max 3) candidates.
6. **Format** — the same `- **{takeaway}** — [memory: {id}]` block the sub-agent used to write, wrapped in `<user-prompt-submit-hook>` tags so Claude Code renders it consistently.

Total wall-time is dominated by recall itself — under 500ms typical, capped at 2s by curl.

**Why distillation matters.** Meili BM25 on the wiki + memory layers is dominated by total-token-match density: verbose prose with 20 common-word matches on generic pages outranks a distinctive-token match on the correct page. Observed 2026-07-22: query "tell me about the social-platform idea using the tool Agent-Reach and the new pilot plan you have created" failed to surface the Agent-Reach wiki page; bare token "Agent-Reach" surfaced it as #1. Distillation gives BM25 a chance to weight the tokens that actually identify the topic.

**Anchor rule.** Hits from `mem_recall` fall into two classes. **Anchor-qualifying** — memories and wiki pages (curated / structured surfaces, present-hit implies strong topic signal). **Ride-along** — conversation chunks (synthetic id prefix `conv-`) and emails (`email-`), raw FTS on transcripts / inbox with no floor of their own. Ride-alongs only surface when at least one anchor-qualifying hit clears the score floor; without an anchor, ride-alongs are almost always noise for weak-signal queries and are dropped along with the block (silence beats noise). When an anchor exists, anchors take the first slots and ride-alongs fill the remainder up to `top_k`.

**Noise feedback (receiver-side).** A hint block the reader judges noisy gets flagged via `POST /api/sidecar/hint/noise` (MCP alias `sidecar_hint_noise`) with the memory ids. Flags are stored in `sidecarHintNoise` (v36 migration) and downweight the affected ids at future recall time via a per-flag penalty applied inside `MemorySidecarHandler.applyNoiseDownweight` with a 7-day rolling window. Negative-only feedback: silence means the block was fine.

**Cleanup.** `HealthMonitor.sweepStaleSidecarHints()` drops `sidecarHints` rows older than 30 minutes (legacy table from the retired async path; kept to drain in-flight rows and left in the schema so a future sidecar can use it). No scratch files, no injected-memory ledger, nothing to reap between sessions.

## Framework surfaces

**`SidecarRegistry`** (Swift). Lock-guarded map of name → `Sidecar` value, plus a name → live sessionKey map. `assignee(forEventType:)` is the routing seam. `ownsEventType(_:)` distinguishes "no owner" from "owner exists but dead" — critical for fail-closed routing.

**`SidecarLifecycle`** (Swift actor). Spawn / rotate / stop. For `.inProcess`, spawn publishes the synthetic sessionKey and sweeps any stale `workers` row from a prior `.claudeCode` life. Rotate is a no-op. Stop withdraws the sessionKey.

**`SidecarInProcessRegistry`** (Swift). Lock-guarded map of name → handler closure. Registered at boot in `bootSidecars`, never touched by lifecycle — the handler code is fixed; only accessibility to routing changes with `.off`.

**`SidecarConfigStore`** (Swift). Persists user preferences to `<dataDir>/config/sidecars.json`. Decoder is forward-compatible — every field falls back to a default via `decodeIfPresent`, so adding a knob doesn't break existing installs.

**`SidecarsConfigView`** (SwiftUI). One row per registered sidecar. Advanced disclosure hides knobs whose consumer doesn't exist for the row's kind (Judge model + Rotation threshold hidden for `.inProcess`).

**`SidecarDetailView`** (SwiftUI). Per-sidecar stats window. Session card renders "In-process handler" for `.inProcess`. A Handler card shows recencyMode / minRankScore / topKCap / hintsInFlight / mostRecentHint for `.inProcess` sidecars.

**`SidecarHintActions`** (SonataAction). HTTP endpoints, all under `/api/sidecar/hint/`:
- `POST /synthesize` — the synchronous UserPromptSubmit path; takes Claude Code's hook input JSON, returns `{content: string}`.
- `POST /noise` — receiver-side noise feedback; records to `sidecarHintNoise`.
- `POST /write`, `POST /pop` — legacy from the retired async path; still registered so any in-flight sidecarHints rows drain cleanly, and available for future non-memory sidecars.

## Knobs, mapped to consumers

The knob surface shrank significantly with the pivot — most of the stop-hook-era knobs (context depth, top-K, triggers, dedup window) no longer have consumers. The handler caps `top_k` at 3 internally; the legacy stop-hook-only knobs are still stored in `SidecarUserConfig` for forward-compat but are ignored by the synthesize path.

| Knob | Kind | Consumer | Applied when |
|---|---|---|---|
| Tier | both | `SidecarLifecycle.spawn` / `.stop` and `synthesize` role gate | Immediately |
| Subscription cap | `.claudeCode` | `SidecarSpendTracker` | On next spend record |
| Judge model | `.claudeCode` | SKILL.md prompt template | On next spawn |
| Rotation threshold | `.claudeCode` | `SidecarLifecycle.tick` | On next monitor tick |
| Recency mode | `.inProcess` (memory) | `MemorySidecarHandler.recall` | On next hook fire |
| Min rank score | `.inProcess` (memory) | `MemorySidecarHandler.synthesize` | On next hook fire |

## Adding a new sidecar

**In-process handler** (recommended when the work is one Sonata function + a table write):

1. Write a handler closure — signature `@Sendable (SidecarEventPayload) async throws -> Void`. Follow `MemorySidecarHandler`'s shape.
2. Add a registration enum modeled on `MemorySidecarRegistration` — `name`, `eventTypes`, `sidecar(config:) -> Sidecar` with `kind: .inProcess`.
3. In `bootSidecars`, register the sidecar with `SidecarRegistry.shared.register(...)`, then register the handler with `SidecarInProcessRegistry.shared.register(name:handler:)`. Handler is registered ONCE at boot, not per spawn — spawn only publishes the sessionKey.
4. Add the event type to `MCPEventPusher.sidecarOwnedFallbacks` so the boot-race belt catches events that fire before registration.
5. If the sidecar needs a config knob no existing sidecar uses, add it to `SidecarUserConfig` with a default in `Defaults`. The `decodeIfPresent` walk in `init(from:)` picks it up automatically; the panel needs a `knob(...)` row.

**Claude Code sidecar** (when the work needs an LLM in the loop):

1. Drop `SKILL.md` (and any per-request prompt templates) at `Sources/Sonata/Resources/sidecars/<name>/`. Add `.copy("Sonata/Resources/sidecars")` back to `Package.swift` if the directory is empty today (it is, as of this doc).
2. Registration enum with `kind: .claudeCode` and a `bundledSkillPath()` static that resolves the bundle URL. See git history for what `MemorySidecarRegistration` looked like when it did this.
3. `SidecarSpawnerFactory` currently uses one `defaultDispatcherModel` for every `.claudeCode` sidecar. If you need per-sidecar model choice, promote it to a field on the `Sidecar` struct rather than growing a switch on name.
4. Bundle-and-install still applies — hooks that fire your sidecar's event type go in `Sources/Sonata/Resources/hooks/` and get copied to `~/.claude/hooks/` + registered in `~/.claude/settings.json` by `ensureBundledHooks`.

## Gotchas we hit

**Boot ordering.** `MCPEventPusher.start` runs ~350 lines before `bootSidecars` in `SonataApp`. Any memory_request that fires in that gap goes `pending` because the sidecar hasn't registered yet, and the fan-out block would broadcast it to a random pool worker. Fix is `sidecarOwnedFallbacks` — a static set of "always sidecar-owned" event types the fan-out block checks alongside the dynamic registry.

**Codable forward-compat.** Adding a non-optional field to `SidecarUserConfig` breaks decode on every existing install — synthesized `init(from:)` refuses partial matches. Solution is an explicit `init(from:)` with `decodeIfPresent` and default fallbacks per field, so knob additions never break persistence.

**Ledger silently dead.** The tier-2 rewrite of the UserPromptSubmit hook dropped the injected-memory ledger append. Turning `dedupWindow` up in the panel changed nothing because `already_injected` was always empty. Symptom is the same 2-3 topical memories repeating across the whole session. Restored in `333c02d`.

**Sub-agent tool surface is narrower than parent.** Sonata's MCP server exposes 250+ deferred tools; sub-agents launched via the Agent tool don't get them via `ToolSearch`. This is why the tier-1 sub-agent couldn't call `worker_event_complete` and every memory_request event sat `assigned` forever. Notification-type auto-complete (on the sidecar-owned assigned path in `MCPEventPusher`) is the general-purpose fix — the framework completes on delivery so a handler doesn't need any Sonata tools at all.

**Sub-agent inherits the parent's model.** The Agent tool's `model:` parameter isn't set by default, so a sub-agent spawned from a Sonnet dispatcher runs on Sonnet. Advisory text in the sub-agent's prompt ("Judge model: haiku") has zero effect. If a `.claudeCode` sidecar is registered in the future and dispatches to sub-agents, the SKILL.md MUST pass `model:` explicitly.

**Judgment overhead often loses to ranking.** The tier-1 sub-agent's job was to filter mem_recall's ranked list. Its LLM judgment was mostly cutting the bottom of the list — which `limit: 3` does for free. Whenever a sidecar's proposed job is "an LLM sitting on top of a Sonata function," check whether the Sonata function's own ranking is enough; if it is, choose `.inProcess`.

**Live-config seam.** `SidecarsConfigView` writes to `SidecarConfigStore` on every field edit, then calls `SidecarLifecycle.spawn`/`.stop`/`.rotate` based on the tier transition. Without this, a user flipping tier in Settings would have to relaunch Sonata to see any effect — that WAS the case until commit `3011ed3`, and the panel's own header comment used to be honest about it ("records intent only"). New sidecars should mirror this seam by having their handler read from `SidecarConfigStore` on every invocation.

## Where to look in the code

| File | Role |
|---|---|
| `Sources/Sidecar/Sidecar.swift` | Immutable config struct + `SidecarKind` + `SidecarBudgetTier` |
| `Sources/Sidecar/SidecarKind.swift` | The `.claudeCode` / `.inProcess` split + `SidecarEventPayload` |
| `Sources/Sidecar/SidecarRegistry.swift` | Config + live sessionKey routing table |
| `Sources/Sidecar/SidecarInProcessRegistry.swift` | Handler closures + synthetic sessionKey |
| `Sources/Sidecar/SidecarLifecycle.swift` | Spawn / rotate / stop / context monitor |
| `Sources/Sidecar/SidecarSpawner.swift` | Claude Code process spawner + memory sidecar registration |
| `Sources/Sidecar/SidecarConfigStore.swift` | User preferences persistence + forward-compat decode |
| `Sources/Sidecar/MemorySidecarHandler.swift` | The tier-2 in-process handler |
| `Sources/Sidecar/SidecarSpendTracker.swift` | Rolling 7-day token budget (`.claudeCode` only in practice) |
| `Sources/MCPServer/MCPEventPusher.swift` | Event delivery — SSE for `.claudeCode`, direct dispatch for `.inProcess` |
| `Sources/Actions/SidecarHintActions.swift` | `/api/sidecar/hint/{write,pop}` endpoints |
| `Sources/Actions/WorkerActions.swift` | Fail-closed enqueue check for sidecar-owned types |
| `Sources/Views/SidecarsConfigView.swift` | Settings panel row per registered sidecar |
| `Sources/Views/SidecarDetailView.swift` | Per-sidecar detail window |
| `Sources/Views/SidecarsMenuContent.swift` | Window ▸ Sidecars submenu |
| `Sources/Sonata/Resources/hooks/` | Bundled `sidecar-*.js` hooks |
| `Sources/Sonata/SonataApp.swift` `bootSidecars()` | Boot-time registration entry point |
| `Sources/Sonata/SonataApp.swift` `ensureBundledHooks()` | Bundle-and-install hooks + settings.json registration |
