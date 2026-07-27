# Webhook Routes

Third-party webhook ingestion via the 4a relay. Every incoming HTTP webhook — AgentMail, GitHub, Stripe, svix-based services, or anything with a "send POST to this URL when X happens" affordance — can be routed to a Sonata action, worker, or DM without opening a public port on your machine.

## What this is

Sonata runs as a local process. It has no public URL, so third parties can't POST to it directly. This feature uses the 4a gateway (`api.4a4.ai`, a Cloudflare Worker) as an **encrypted low-trust relay**:

1. Third party POSTs to `https://api.4a4.ai/v0/hook/<your-pubkey>/<slug>`.
2. 4a captures the raw bytes and a curated set of headers, wraps them as a NIP-59 gift-wrap addressed to your plugin's operational pubkey, and stores them.
3. The `4a-webhook-relay` plugin (running locally) tails 4a's per-pubkey inbox stream, decrypts, and POSTs to `http://127.0.0.1:3211/api/webhook/deliver` with a shared bearer.
4. Sonata's `webhook_deliver` action verifies the bearer, dedupes on the wrap event id, verifies the third party's signature per the route's scheme, records an audit row, and dispatches to the route's destination.

The design keeps 4a low-trust: it sees plaintext at ingress (unavoidable — third parties can't gift-wrap to you), so the real authenticity check is HMAC/Svix/bearer verification at Sonata against your per-slug secret. If the gateway is compromised the payload is exposed at that moment; the HMAC verification is what proves the delivery came from the real sender either way.

Full design: `~/.claude/plans/sparkling-splashing-garden.md`. Design idea page: `~/.sonata/wiki/ideas/webhook-relay.md`.

## Adding a webhook route

### 1. Get the URL parts

The URL your third party will POST to is:

```
https://api.4a4.ai/v0/hook/<your-pubkey>/<slug>
```

- **`<your-pubkey>`** — your plugin's operational pubkey (32-byte hex). Get it once:

  ```bash
  curl -s http://127.0.0.1:4300/api/pubkey
  ```

  It stays stable across restarts (persisted to `~/.sonata/plugins/4a-webhook-relay/identity.json`).

- **`<slug>`** — a short URL-safe name you choose per third party (`agentmail`, `github-sonata`, `stripe-billing`). Must match `[A-Za-z0-9_-]+`. Slug is the identity — creating a route with an existing slug updates it.

### 2. Configure on the third-party side

- **Endpoint URL:** the full URL from step 1.
- **Event:** whatever event you want (usually just the one that fires when the thing happens — e.g. AgentMail's `message.received`, GitHub's `push` or `pull_request`).
- **Signing secret / auth:** copy whatever the third party generates. You'll paste it into Sonata next.

### 3. Create the route in Sonata

**Via Settings UI** (Sonata → Settings → Webhook Routes → New):

| Field | Value |
|---|---|
| Name | Human-readable label |
| Slug | Matches the URL you gave the third party |
| Auth scheme | See "Signature schemes" below |
| Header name | The header carrying the signature (only for `hmacSha256`) |
| Secret | Paste the third party's signing secret |
| Destination | See "Destinations" below |

**Via HTTP** (for scripting / automation):

```bash
# Store the secret
curl -X POST http://127.0.0.1:3211/api/secrets/set \
  -H 'content-type: application/json' \
  -d '{"name":"webhook_secret_myslug","value":"whsec_..."}'

# Create the route
curl -X POST http://127.0.0.1:3211/api/webhook/routes/upsert \
  -H 'content-type: application/json' \
  -d '{
    "slug": "myslug",
    "name": "My webhook",
    "authScheme": "svix",
    "authSecretRef": "webhook_secret_myslug",
    "destKind": "action",
    "destTarget": "some_action_name",
    "enabled": true
  }'
```

## Signature schemes

Pick based on what the third party sends.

### `svix`

Used by **AgentMail** and hundreds of other providers built on [Svix](https://www.svix.com/). Look for a signing secret that starts with `whsec_`.

Verification: HMAC-SHA256 over `{svix-id}.{svix-timestamp}.{raw-body}`, base64-encoded, presented as one or more space-separated `v1,<sig>` candidates in the `svix-signature` header. Timestamp must be within 5 minutes of receipt (Svix's replay defense).

You don't configure header names for this scheme — Svix's are fixed (`svix-id`, `svix-timestamp`, `svix-signature`).

### `hmacSha256`

Used by **GitHub** (`x-hub-signature-256: sha256=<hex>`), **Stripe** if you strip the timestamp prefix, and many bespoke services.

Verification: HMAC-SHA256 over the raw request body, presented as either a 64-character hex string or a 32-byte base64 string in the header of your choice (configurable via "Header name"). The `sha256=` prefix (if present) is stripped automatically.

### `bearer`

Used when a third party just sends a shared token in a header (usually `Authorization: Bearer <token>` or a custom header like `x-webhook-token`). Simple but no per-request signing.

### `none`

No verification. **Only appropriate for low-stakes signals where the URL secrecy (per-pubkey hard-to-guess) is your only defense**. Useful for:
- Prototyping a route before the third-party integration is wired up
- Sonata-internal signals from your own Workers/scripts hitting the URL
- Testing

## Dispatch filter (optional, all destinations)

Every route can define a `dispatchFilter` — a compact gate that runs AFTER signature verification but BEFORE the destination fires. Shape: `<json.path>=<v1>|<v2>|<v3>`. If set and the resolved payload value doesn't match one of the allowed values, the delivery is audited as `skipped: filter miss (path=... value=... expected=[...])` and no destination is invoked. Blank → always dispatch.

**Examples**:

| Service | Filter | Effect |
|---|---|---|
| GitHub PRs | `body.action=opened\|synchronize\|reopened` | Skip labeled, closed, review_requested, edited, etc. |
| Linear | `body.type=Issue` | Skip Comment / Reaction / Project events |
| Stripe | `body.type=invoice.payment_failed\|charge.refunded` | Only escalate the ones that matter |
| AgentMail | `body.event_type=message.received` | Skip .spam / .blocked / .unauthenticated variants |
| GitHub ping | (any filter) | Skips the initial ping event GitHub sends when you first add a webhook |

Malformed filters (no `=`, empty allowlist) are treated as no-filter — the audit trail would silently blackhole otherwise.

## Destinations

What happens when a delivery is verified AND passes the dispatch filter.

### `action`

Invokes a named action in Sonata's `ActionRegistry`. Plugin-registered actions (e.g. `prstar_review`, `linear_process_issue`) are included in the same registry, so the destination dropdown lists them alongside core actions — no per-plugin Sonata code.

Two modes:

**With `actionParams`** (recommended for plugin actions): a JSON template rendered against the payload, parsed, and spread into the target action's params. Lets a plugin action receive its expected arg shape directly — no dispatcher worker in the middle, no `/skill-run-review` chain that spawns a second worker.

```
{"pr":"{{ body.pull_request.number }}","repo":"{{ body.repository.full_name }}"}
```

Rendered against a GitHub PR webhook, this becomes `{"pr":"483","repo":"enginable/adaptengine-monorepo"}` and is passed straight to `prstar_review`. One turn, one worker.

The template must be valid JSON up front (substitutions live inside string values, so it must tokenize before rendering). Malformed JSON is rejected at upsert time.

**Without `actionParams`** (backward compat): the action receives the raw envelope:

```
{
  "slug": "agentmail",
  "body": "<utf8-decoded raw body, if valid utf8>",
  "body_b64": "<base64 of raw body — always present>",
  "headers": { "x-github-event": "push", ... },
  "receivedAtMs": 1785174000000,
  "sourceIp": "192.0.2.42",
  "wrapEventId": "<inner rumor id>"
}
```

Existing built-in action for AgentMail (`email_process_agentmail_webhook`) uses this shape.

### `worker`

The generic "make a webhook trigger a Claude turn" destination. **The whole point of this destination is that a route configures a *prompt template* — new integrations are route configurations, not new Sonata code.**

Two modes:

**With a `promptTemplate`** (recommended): the template is rendered against the webhook payload; the rendered text becomes a worker's prompt. Dispatched via `mem_task_create` with title `webhook: <slug>` and source `webhook:<slug>`. Optional `workerPool` hint on the route routes the task to a specific pool.

Template substitution is intentionally dumb — no logic, no conditionals, no filters — just JSON-path lookup:

- `{{ path.to.value }}` walks the payload's JSON along the dotted path. Scalars (string/number/bool) render as text; objects and arrays render as pretty-printed JSON in a fenced code block.
- `{{ payload }}` (or `{{ . }}`) renders the entire webhook envelope — headers, body, slug, receivedAtMs, sourceIp — as JSON. Escape hatch for "give the worker the whole webhook for reference."
- Unknown paths render as empty string AND append a warning to the delivery's `error` column, so silent template typos surface in the audit trail.

**Example — GitHub PR review** (destKind=`worker`, promptTemplate=):

```
/prstar-review {{ body.pull_request.number }}

Repo: {{ body.repository.full_name }}
Head: {{ body.pull_request.head.ref }}
Author: {{ body.pull_request.user.login }}
Action: {{ body.action }}

Full event for reference:
{{ payload }}
```

The worker session receives a task with the rendered prompt, invokes `/prstar-review` on the specific PR number, and has the full event JSON to consult.

Add Linear later? Different template, same shape:
```
Research this issue: {{ body.data.title }}
Team: {{ body.data.team.key }}
State: {{ body.data.state.name }}
{{ payload }}
```

Zero Sonata code per service. Just a route with an appropriate template.

**Without a `promptTemplate`** (backward compat): dispatches a raw `workerEvents` row of type `webhook_<slug>` with the payload as JSON. A downstream handler must know what to do with events of that type. Rarely useful — prefer the templated mode.

### `dm`

Formats the body as a short text preview and DMs it to a Sonar target (session/worker/supervisor/peer). Useful for notifications: "webhook X fired, take a look".

### `log`

No-op dispatch — the audit row is written, nothing else happens. Useful for smoke tests and diagnostic captures.

## Provider guides

### AgentMail (Svix)

AgentMail supports two scopes for webhooks: **workspace-scoped** (via the dashboard) fires for every inbox in your workspace; **inbox-scoped** (via the API/CLI only) fires only for one specific inbox. Pick based on the Sonata instance's role.

**A. Workspace-scoped (recommended for general-purpose Sonata instances)**

Best when this Sonata instance may own multiple inboxes and you don't want to remember to reconfigure AgentMail every time you add one. Costs a wasted round-trip per email to any inbox this instance doesn't own — the action soft-skips those cleanly.

1. AgentMail dashboard → Webhooks → New Endpoint:
   - Endpoint URL: `https://api.4a4.ai/v0/hook/<your-pubkey>/agentmail`
   - Subscribe to events: `message.received` only (the three `.blocked` / `.spam` / `.unauthenticated` variants are opt-in and Sonata would skip them anyway).
   - Advanced: no throttling, no custom headers.
   - Save. Copy the `whsec_...` signing secret.

2. Sonata Settings → Webhook Routes → New:
   - Slug: `agentmail`
   - Auth: `Svix`
   - Secret: paste the `whsec_...`
   - Destination: `Action → email_process_agentmail_webhook`

3. Send a real email to your monitored inbox. Within 2–5 seconds you should see:
   - New row in `webhookDeliveries` with `verified=1` and `handlerResult` = `{"action":"ingested",...}`
   - New row in `emails` — the poller path's routing chain has run

Latency drops from ~60s poll to ~3–5s webhook.

**B. Inbox-scoped (recommended for dedicated Sonata instances)**

Best when this Sonata instance is dedicated to a single inbox (e.g. a Scout instance that should only see `scoutleader@agentmail.co`). Zero wasted webhooks; the trade-off is you have to remember to create a scoped webhook per inbox you want, and you can't do it from the dashboard.

Create via one of these — pick the shape that fits your tooling:

Python:
```python
client.inboxes.webhooks.create(
    inbox_id="scoutleader@agentmail.co",
    url="https://api.4a4.ai/v0/hook/<your-pubkey>/agentmail",
    event_types=["message.received"],
)
```

TypeScript:
```typescript
await client.inboxes.webhooks.create("scoutleader@agentmail.co", {
  url: "https://api.4a4.ai/v0/hook/<your-pubkey>/agentmail",
  eventTypes: ["message.received"],
});
```

CLI:
```bash
agentmail inboxes:webhooks create \
  --inbox-id scoutleader@agentmail.co \
  --url https://api.4a4.ai/v0/hook/<your-pubkey>/agentmail \
  --event-type message.received
```

Note: once created, an inbox-scoped webhook is immutable to that inbox — you can only change `event_types`, not reassign to a different inbox.

The Sonata route setup (step 2 above) is identical for both scopes.

### GitHub (HMAC-SHA256)

1. GitHub repo Settings → Webhooks → Add webhook:
   - Payload URL: `https://api.4a4.ai/v0/hook/<your-pubkey>/github-<something>`
   - Content type: `application/json`
   - Secret: pick a random string, note it.
   - Events: pick just what you want.

2. Sonata route:
   - Slug matches
   - Auth: `HMAC-SHA256`
   - Header name: `x-hub-signature-256`
   - Secret: same random string
   - Destination: your call — often `worker` with a specialized handler.

### Anything Svix-based (Clerk, Resend, some parts of Cloudflare, etc.)

Same shape as AgentMail. If the secret starts with `whsec_`, use the `svix` scheme.

### Anything with a plain HMAC header

Use `hmacSha256`, set the header name to whatever they use.

### Anything with just a shared token

Use `bearer`, set the header name to where the token lives.

### Anything else / unknown scheme

Ship with `none`, verify by observing raw deliveries in the audit table, then either graduate to one of the built-in schemes or add a new verifier (see "Extending").

## Debugging

### Check delivery status

```bash
sqlite3 ~/.sonata/sonata.db "SELECT slug, verified, handlerResult, error FROM webhookDeliveries JOIN webhookRoutes ON webhookDeliveries.routeId = webhookRoutes.id ORDER BY receivedAtMs DESC LIMIT 10"
```

Or open a specific route's detail sheet in Settings.

### Common errors

- **`verified=0, error="svix signature mismatch or timestamp outside tolerance"`** — clock skew (>5 min drift), or wrong secret, or wrong payload bytes reached us (rare — byte preservation invariant).
- **`verified=0, error="HMAC-SHA256 mismatch on header 'x-...'"`** — wrong secret, wrong header name, or the third party is signing something other than the raw body.
- **`verified=0, error="missing signature header 'x-...'"`** — the header didn't reach Sonata. Check the 4a gateway forwards it (allowlist is pattern-based: `x-*`, `svix-*`, `*-signature`, plus content-type and user-agent).
- **`handlerResult="skipped", detail="inbox '...' is not monitored by this Sonata instance"`** — soft-skip for an inbox not in `EmailHandler.currentInboxes`. Expected behavior for canned Svix test payloads (their placeholder is literally `"string"`) AND for real emails in the workspace that belong to inboxes this Sonata doesn't own (e.g. `scoutleader@agentmail.co` from the same workspace as Sona's user inbox). If you want zero wasted round-trips for irrelevant inboxes, use AgentMail's inbox-scoped webhook API instead of the workspace-scoped dashboard flow — see the AgentMail section below.
- **`error="action '...' threw: Email handler not available"`** — you're on a build before commit XYZ; the ActionRegistry emailHandler capture-time bug. Rebuild.
- **`verified=1, error="dm to 'X': not_found"`** — DM destination target isn't live. Check `dm_targets`.

### Test event flow without a third party

```bash
# 1. Create a log-only route
curl -X POST http://127.0.0.1:3211/api/webhook/routes/upsert \
  -H 'content-type: application/json' \
  -d '{"slug":"test","name":"Test","destKind":"log","authScheme":"none","enabled":true}'

# 2. Fire a synthetic POST
curl -X POST "https://api.4a4.ai/v0/hook/<your-pubkey>/test" \
  -H 'content-type: application/json' \
  -d '{"hello":"world"}'

# 3. Wait ~3 seconds, check the delivery row
sleep 3
sqlite3 ~/.sonata/sonata.db "SELECT * FROM webhookDeliveries WHERE routeId = (SELECT id FROM webhookRoutes WHERE slug='test') ORDER BY receivedAtMs DESC LIMIT 1"
```

You should see `verified=1, handlerResult=logged`.

## Extending

### Add a new signature scheme

1. Add the scheme name to `webhookAuthSchemes` in `Sources/Actions/WebhookActions.swift`.
2. Add a `case "<name>":` branch in the `webhook_deliver` verify switch that reads whatever headers/params it needs and returns a bool.
3. If the verification logic is complex, put it in a dedicated file (see `Sources/Server/SvixVerifier.swift` or `HMACVerifier.swift` for shape).
4. Add the option to the UI picker in `Sources/Views/WebhookRoutesView.swift`.

### Add a new destination kind

1. Add the kind name to `webhookDestKinds`.
2. Add a `case "<name>":` branch in the dispatch switch that does the thing.

### Add a service-specific action

Just write a `SonataAction` that expects the standard webhook payload params. Register the bundle in `SonataApp.swift`. Users create routes with `destKind=action` and pick your action name from the dropdown.

## Security posture and limits

- **Rate limits at the gateway:** 60 req/hour per (pubkey, slug) AND per source IP. In-memory per Cloudflare isolate — for pilot only; DO-scoped counters are a follow-up.
- **Body size cap:** 64 KiB raw at the gateway. GitHub can send bodies up to 25 MB — those bounce with 413; use a lightweight event and re-fetch details via the destination action.
- **Retention:** 7 days for both the gateway's stored wraps (opportunistic prune on write and read) and Sonata's `webhookDeliveries` audit rows (`HealthMonitor` sweep).
- **At-least-once delivery:** SSE reconnect + persistent cursor + wrapEventId UNIQUE on `webhookDeliveries` + INSERT OR IGNORE. Duplicates are silently absorbed.
- **Bearer secret rotation:** the plugin↔Sonata shared bearer is generated once via `SecretStore.getOrSet("4a_webhook_shared_secret")`. To rotate: delete the SecretStore entry, restart the plugin (Sonata will regenerate + re-inject on next spawn).

## Known v1 limitations

- No orphan tracking. Deliveries for unregistered slugs get 404'd, log-and-dropped by the plugin. They don't show up in the UI. Add a `webhookOrphans` surface in v2 so 404s prompt "create the route".
- No opaque `inbox_...`-id resolution for AgentMail. Webhook uses whatever the payload provides; if AgentMail sends an opaque id and no matching inbox address is configured, the delivery 404s with a clear error. Poller catches the missed email. Add `AgentMailProvider.getInboxAddress(inboxId:)` as a fallback in v2.
- No timestamp / replay protection for `hmacSha256` scheme (Svix has it built in). If a route needs replay protection with GitHub-style HMAC, add an idempotency check in the destination action.
- No web UI on 4a — the gateway stays a Worker with no HTML.
- Auth schemes are the union `none | bearer | hmacSha256 | svix`. Stripe's full signature scheme (`t=..,v1=..`) and GitHub-app JWTs are future verifiers.

## Related

- Plan: `~/.claude/plans/sparkling-splashing-garden.md`
- Wiki idea page: `~/.sonata/wiki/ideas/webhook-relay.md`
- Plugin: `plugins/4a-webhook-relay/`
- Core dispatcher: `Sources/Actions/WebhookActions.swift`
- Verifiers: `Sources/Server/SvixVerifier.swift`, `Sources/Server/HMACVerifier.swift`
- Email seam: `Sources/Actions/EmailWebhookActions.swift`, `Sources/Scheduler/EmailHandler.swift`
- Gateway (in `/Users/evan/projects/4a/gateway/`): `src/webhook-receiver.ts`, `src/inbox-stream.ts`, `src/relay-pool.ts`
