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

**Event source.** A stop hook in `~/.claude/hooks/sidecar-stop-hook.js` (bundled to `Sources/Sonata/Resources/hooks/`, installed to `~/.claude/hooks/` at boot by `ensureBundledHooks`) fires a `memory_request` event on every user-role session's turn completion. Worker/supervisor/sidecar sessions no-op via a `role=user` gate — nothing else on the machine should be asking for memory hints.

**Delivery.** `WorkerActions.worker_event_enqueue` looks up the sidecar's assignee. For sidecar-owned event types (types the registry owns), a nil assignee means fail-closed with a 503 — this prevents fan-out to pool workers when the sidecar is registered but not yet spawned. `MCPEventPusher.pushPendingNotifications` has a belt-and-suspenders check with `sidecarOwnedFallbacks` for the boot-race window between HTTP server up and `bootSidecars` completing.

**Handler.** `MemorySidecarHandler.run` decodes the payload, extracts a query from the last user prompt, calls `/api/recall` (loopback HTTP with `tier=l0`, `recencyMode` from settings), filters the response against `already_injected`, applies the `minRankScore` floor, caps at `top_k` (max 3), formats a hint markdown block, and INSERTs to `sidecarHints`.

**Consumption.** A `UserPromptSubmit` hook (`sidecar-user-prompt-submit-hook.js`) calls `/api/sidecar/hint/pop` for the current session id — read-and-delete in one transaction — and prepends the returned content as a `<user-prompt-submit-hook>` block. It also extracts memory ids from the popped content and appends to `~/.sonata/scratch/injected-memory-<sessionId>.jsonl`, which the stop hook reads on the next fire to populate `already_injected`.

**Cleanup.** A `HealthMonitor` sweep line drops `sidecarHints` rows older than 30 minutes. Session-end handling would eventually retire the ledger file too; that's not in place yet, but the file is bounded by the dedup window so it doesn't grow unbounded within a session.

## Framework surfaces

**`SidecarRegistry`** (Swift). Lock-guarded map of name → `Sidecar` value, plus a name → live sessionKey map. `assignee(forEventType:)` is the routing seam. `ownsEventType(_:)` distinguishes "no owner" from "owner exists but dead" — critical for fail-closed routing.

**`SidecarLifecycle`** (Swift actor). Spawn / rotate / stop. For `.inProcess`, spawn publishes the synthetic sessionKey and sweeps any stale `workers` row from a prior `.claudeCode` life. Rotate is a no-op. Stop withdraws the sessionKey.

**`SidecarInProcessRegistry`** (Swift). Lock-guarded map of name → handler closure. Registered at boot in `bootSidecars`, never touched by lifecycle — the handler code is fixed; only accessibility to routing changes with `.off`.

**`SidecarConfigStore`** (Swift). Persists user preferences to `<dataDir>/config/sidecars.json`. Decoder is forward-compatible — every field falls back to a default via `decodeIfPresent`, so adding a knob doesn't break existing installs.

**`SidecarsConfigView`** (SwiftUI). One row per registered sidecar. Advanced disclosure hides knobs whose consumer doesn't exist for the row's kind (Judge model + Rotation threshold hidden for `.inProcess`).

**`SidecarDetailView`** (SwiftUI). Per-sidecar stats window. Session card renders "In-process handler" for `.inProcess`. A Handler card shows recencyMode / minRankScore / topKCap / hintsInFlight / mostRecentHint for `.inProcess` sidecars.

**`SidecarHintActions`** (SonataAction). Two HTTP endpoints, `POST /api/sidecar/hint/write` and `POST /api/sidecar/hint/pop`, used by the handler and the UserPromptSubmit hook respectively. Empty content rejected on write.

## Knobs, mapped to consumers

| Knob | Kind | Consumer | Applied when |
|---|---|---|---|
| Tier | both | `SidecarLifecycle.spawn` / `.stop` | Immediately (live-config commit `3011ed3`) |
| Subscription cap | `.claudeCode` | `SidecarSpendTracker` | On next spend record |
| Judge model | `.claudeCode` | SKILL.md prompt template | On next spawn |
| Context depth | both | stop hook payload construction | On next hook fire |
| Top-K | both | stop hook payload; handler caps at 3 | On next hook fire |
| Triggers | both | stop hook + UserPromptSubmit hook | On next hook fire |
| Dedup window | both | stop hook reads last N ledger entries | On next hook fire |
| Rotation threshold | `.claudeCode` | `SidecarLifecycle.tick` | On next monitor tick |
| Recency mode | `.inProcess` (memory) | `MemorySidecarHandler.recall` | On next event |
| Min rank score | `.inProcess` (memory) | `MemorySidecarHandler.run` | On next event |

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
