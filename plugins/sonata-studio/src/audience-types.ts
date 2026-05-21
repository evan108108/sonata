// Plugin-local type stubs for the gateway's audience-validator + relay-pool
// modules. The validators.ts file (build-time copy from
// gateway/src/studio-v0/validators.ts) refers to AudienceLookup,
// AudienceDeclaration, and NostrEvent — types that live in the gateway's
// internal modules. The plugin doesn't ship those modules, so we restate
// the shapes here. The structure must match the gateway's exports
// byte-for-byte; if they drift, the plugin's validator path will silently
// mis-validate or crash.
//
// build.sh rewrites validators.ts's `../audience-validator` and
// `../relay-pool` imports to point here.

export interface NostrEvent {
  id: string;
  pubkey: string;
  created_at: number;
  kind: number;
  tags: string[][];
  content: string;
  sig: string;
}

export interface AudienceDeclaration {
  audIdPub: string;
  slug: string;
  epoch: number;
  epochPub: string;
  members: string[];
  pending: { invitePub: string; expirationUnix: number }[];
  /**
   * Room lifecycle status from `fa:status` on the kind:30520. Absence on
   * the wire is treated as "active" by the parser, so plugin code may rely
   * on this always being set.
   */
  status: "active" | "closed";
  /** `fa:closed-at` unix seconds; only meaningful when status==="closed". */
  closedAt?: number;
}

export interface AudienceLookup {
  priorAudienceDeclarationPubkey?(slug: string): string | undefined;
  currentDeclarationByAddress?(address: string): AudienceDeclaration | undefined;
}
