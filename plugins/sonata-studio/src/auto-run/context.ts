// Module-level holder for the auto-run subsystem's dependencies.
//
// The auto-run hook runs inside the projection layer, which is intentionally
// pure (test fakes pass an in-memory MemoryClient). Calling out to the
// gateway (for status transitions, dispatch_intent records, and comments)
// needs the plugin's signing keypair and GatewayClient — neither of which
// the projection layer carries. We solve that with a process-level singleton
// initialized once at boot from `index.ts` and read by the auto-run modules.
//
// When unset (e.g. unit tests that don't boot the full server), the auto-run
// hook short-circuits — the eligibility checks return early and projection
// continues unchanged.

import type { ActionCtx } from "../actions";

let registered: ActionCtx | null = null;

export function initAutoRunContext(ctx: ActionCtx): void {
  registered = ctx;
}

export function getAutoRunContext(): ActionCtx | null {
  return registered;
}

export function getSelfPubkey(): string | null {
  return registered?.cfg.pluginPub.toLowerCase() ?? null;
}
