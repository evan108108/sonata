// Action discovery list + route table. Mirrors 4a-webhook-relay.plugin.json's
// `actions` array — same pattern as sonata-studio.

import type { PluginConfig } from "../config";

export interface ActionParam {
  name: string;
  type: "string" | "integer" | "boolean" | "object" | "array";
  required?: boolean;
  description?: string;
}

export interface ActionDef {
  name: string;
  description: string;
  method: "get" | "post";
  path: string;
  params: ActionParam[];
}

export interface ActionCtx {
  cfg: PluginConfig;
}

export type ActionHandler = (
  body: Record<string, unknown>,
  query: Record<string, string>,
  ctx: ActionCtx,
) => Promise<unknown>;

export const ACTIONS: ActionDef[] = [
  {
    name: "4a_pubkey_get",
    description:
      "Return the plugin's operational pubkey — the identity the inbox stream is authenticated with and the pubkey to embed in webhook URLs (https://api.4a4.ai/v0/hook/<pubkey>/<slug>).",
    method: "get",
    path: "/api/pubkey",
    params: [],
  },
];

export const ROUTES: Record<string, { method: "get" | "post"; handler: ActionHandler }> = {
  "/api/pubkey": {
    method: "get",
    handler: async (_body, _query, ctx) => ({ pubkey: ctx.cfg.identityPub }),
  },
};
