// Action discovery list + route table. Mirrors sonata-studio.plugin.json's
// `actions` array (param specs are kept in sync with the manifest by the
// integration test in tests/actions/index.test.ts).
//
// Route table maps (path, method) → handler. The HTTP server in src/index.ts
// looks up by path+method, parses body/query, calls the handler with
// `ActionCtx`, and serializes the result.

import { room_admit } from "./admit";
import { card } from "./card";
import { cardStatus } from "./cardStatus";
import { comment } from "./comment";
import { dispatch } from "./dispatch";
import { fileAttach } from "./fileAttach";
import { fileFetch } from "./fileFetch";
import { imageAttach } from "./imageAttach";
import { member } from "./member";
import { qa } from "./qa";
import { room } from "./room";
import { storage } from "./storage";
import { track } from "./track";
import type { ActionCtx } from "./room";

export type { ActionCtx } from "./room";
export { errorPayload, HttpError } from "./util";

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

// ── Param specs ─────────────────────────────────────────────────────────────

const ROOM_CREATE_PARAMS: ActionParam[] = [
  { name: "slug", type: "string", required: true, description: "Room slug, [A-Za-z0-9-]+." },
  { name: "title", type: "string", required: true, description: "Human-readable room title (≤200 chars)." },
  { name: "description", type: "string", description: "Optional long description (≤2000 chars)." },
  { name: "project", type: "string", description: "Optional project slug for grouping." },
  {
    name: "default_tracks",
    type: "array",
    description: "Optional array of track slugs to create alongside the room.",
  },
];

const ROOM_JOIN_PARAMS: ActionParam[] = [
  {
    name: "invite_url",
    type: "string",
    required: true,
    description: "s4a:// or https://… invite URL containing slug, epoch, invite_pub, and ?priv= bech32 token.",
  },
  {
    name: "profile",
    type: "object",
    description:
      "Optional volunteered profile preview {nickname?: string, bio?: string} embedded in the claim event content so the founder can identify the joiner before admitting. PRIVACY: anyone holding the invite URL can read claim content — joiner is opting into exposing these strings to invite holders. Avatar is deliberately excluded (no room epoch key yet to encrypt against).",
  },
];

const ROOM_INVITE_PARAMS: ActionParam[] = [
  { name: "room_slug", type: "string", required: true, description: "Slug of the room to invite to (founder-only)." },
  {
    name: "ttl_seconds",
    type: "integer",
    description: "Invite TTL in seconds (default 604800 = 7 days, min 60).",
  },
];

const ROOM_ADMIT_PARAMS: ActionParam[] = [
  { name: "room_slug", type: "string", required: true, description: "Slug of the room to admit pending claims for (founder-only)." },
  {
    name: "max_admit",
    type: "integer",
    description: "Cap admissions per call (default unlimited).",
  },
];

const ROOM_PENDING_PARAMS: ActionParam[] = [
  { name: "room_slug", type: "string", required: true, description: "Slug of the room to list pending claims for (founder-only)." },
];

const ROOM_LIST_PARAMS: ActionParam[] = [];

const ROOM_DELETE_PARAMS: ActionParam[] = [
  { name: "slug", type: "string", required: true, description: "Slug of the room to delete locally." },
];

const ROOM_LEAVE_PARAMS: ActionParam[] = [
  { name: "slug", type: "string", required: true, description: "Slug of the room to leave (member-only; founders close instead)." },
];

const ROOM_CLOSE_PARAMS: ActionParam[] = [
  { name: "slug", type: "string", required: true, description: "Slug of the room to close (founder-only)." },
];

const ROOM_REOPEN_PARAMS: ActionParam[] = [
  { name: "slug", type: "string", required: true, description: "Slug of the room to reopen (founder-only)." },
];

const ROOM_BOOT_PARAMS: ActionParam[] = [
  { name: "slug", type: "string", required: true, description: "Slug of the room to boot a member from (founder-only)." },
  { name: "member_pubkey", type: "string", required: true, description: "64-hex pubkey of the member to remove." },
];

const CARD_POST_PARAMS: ActionParam[] = [
  { name: "room", type: "string", required: true, description: "Room slug." },
  { name: "track", type: "string", required: true, description: "Track slug within the room." },
  {
    name: "kind",
    type: "string",
    required: true,
    description: 'Card kind ("lead" | "review" | "finding" | "observation" | "task" | "note" | "document" | other).',
  },
  { name: "title", type: "string", required: true, description: "Title (≤200 chars)." },
  { name: "body", type: "string", required: true, description: "Long-form markdown body (≤10000 chars)." },
  {
    name: "summary",
    type: "string",
    description: "DEPRECATED alias for `body`. Accepted for one cutover release past 2026-05-12; new clients should send `body`.",
  },
  {
    name: "blocks",
    type: "array",
    description: "Optional array of structured content blocks, each {type: <string>, ...}.",
  },
  { name: "related_to", type: "array", description: "Optional array of related event ids or 4A addresses." },
  { name: "tags", type: "array", description: "Optional array of free-form tag strings." },
  { name: "d_tag", type: "string", description: "Override d-tag for replaceable-event addressing (default: sluggified title + 8-hex)." },
  {
    name: "assignees",
    type: "array",
    description:
      "Optional 0-1 lowercase 64-hex pubkeys. UI enforces single-assignee; wire shape is array for future multi-assign compatibility.",
  },
  {
    name: "status",
    type: "string",
    description:
      "Optional lifecycle status (open|in_progress|done|archived). Defaults to 'open' on create.",
  },
];

const CARD_LIST_PARAMS: ActionParam[] = [
  { name: "room", type: "string", required: true, description: "Room slug." },
  { name: "track", type: "string", description: "Optional track slug filter." },
  { name: "since", type: "integer", description: "Optional Unix-ms cutoff; cards older than this are excluded." },
  { name: "limit", type: "integer", description: "Page size, default 50, max 200." },
];

const CARD_DELETE_PARAMS: ActionParam[] = [
  { name: "room", type: "string", required: true, description: "Room slug." },
  { name: "d_tag", type: "string", required: true, description: "d_tag of the card to soft-delete (from CardPostResult)." },
];

const CARD_STATUS_TRANSITION_PARAMS: ActionParam[] = [
  { name: "room", type: "string", required: true, description: "Room slug." },
  { name: "d_tag", type: "string", required: true, description: "d_tag of the card to transition." },
  {
    name: "status",
    type: "string",
    required: true,
    description:
      "Next lifecycle status: open | in_progress | done | archived. Author may set any; assignee may set in_progress or done.",
  },
];

const CARD_UPDATE_PARAMS: ActionParam[] = [
  { name: "room", type: "string", required: true, description: "Room slug." },
  { name: "d_tag", type: "string", required: true, description: "d_tag of the card to update." },
  { name: "track", type: "string", description: "Override track slug. Omit to preserve." },
  { name: "kind", type: "string", description: "Override card kind. Omit to preserve." },
  { name: "title", type: "string", description: "Override title (≤200 chars). Omit to preserve." },
  { name: "body", type: "string", description: "Override long-form markdown body (≤10000 chars). Omit to preserve." },
  {
    name: "summary",
    type: "string",
    description: "DEPRECATED alias for `body`. Accepted for one cutover release past 2026-05-12; new clients should send `body`.",
  },
  { name: "blocks", type: "array", description: "Override blocks array. Omit to preserve." },
  { name: "related_to", type: "array", description: "Override related_to list. Omit to preserve." },
  { name: "tags", type: "array", description: "Override tags list. Omit to preserve." },
  {
    name: "assignees",
    type: "array",
    description:
      "Override assignee list (length 0 or 1). Pass [] to unassign, [pubkey_hex] to reassign. Omit to preserve.",
  },
  {
    name: "status",
    type: "string",
    description:
      "Override lifecycle status (open|in_progress|done|archived). Omit to preserve. Status transitions are normally routed through /api/card/transition for authorization checks.",
  },
];

const TRACK_CREATE_PARAMS: ActionParam[] = [
  { name: "room", type: "string", required: true, description: "Room slug." },
  { name: "name", type: "string", required: true, description: "Track slug, [A-Za-z0-9-]+." },
  { name: "title", type: "string", required: true, description: "Display title (≤200 chars)." },
  { name: "layout", type: "string", description: "One of: column | timeline | grouped (default column)." },
  { name: "description", type: "string", description: "Optional long description (≤2000 chars)." },
];

const COMMENT_POST_PARAMS: ActionParam[] = [
  { name: "room", type: "string", required: true, description: "Room slug." },
  {
    name: "target",
    type: "string",
    required: true,
    description: "64-hex event id, nostr: URI, or 4A address of the comment target.",
  },
  { name: "body", type: "string", required: true, description: "Comment body (≤4000 chars)." },
  {
    name: "intent",
    type: "string",
    description: "Optional intent tag: agree | disagree | question | verify | dispatch | note | other.",
  },
  {
    name: "blocks",
    type: "array",
    description:
      "Optional array of structured content blocks, each {type: <string>, ...}. Same shape as card blocks — image/file blocks come from studio_image_attach / studio_file_attach.",
  },
];

const QUESTION_POST_PARAMS: ActionParam[] = [
  { name: "room", type: "string", required: true, description: "Room slug." },
  { name: "body", type: "string", required: true, description: "Question body (≤4000 chars)." },
  { name: "track", type: "string", description: "Optional track slug." },
  { name: "tags", type: "array", description: "Optional array of free-form tag strings." },
];

const ANSWER_POST_PARAMS: ActionParam[] = [
  { name: "room", type: "string", required: true, description: "Room slug." },
  { name: "question_id", type: "string", required: true, description: "64-hex event id of the question being answered." },
  { name: "body", type: "string", required: true, description: "Answer body (≤4000 chars)." },
];

const DISPATCH_INTENT_POST_PARAMS: ActionParam[] = [
  { name: "room", type: "string", required: true, description: "Room slug." },
  { name: "event_id", type: "string", required: true, description: "Bus event id this intent decides." },
  { name: "candidates", type: "array", required: true, description: "Non-empty array of candidate identifier strings." },
  { name: "chosen", type: "string", required: true, description: "Selected candidate (must appear in candidates)." },
  { name: "reason", type: "string", required: true, description: "Reason for the choice (≤2000 chars)." },
  {
    name: "signals",
    type: "object",
    description: "Optional flat map of string|number|boolean signals (≤32 keys).",
  },
  { name: "track", type: "string", description: "Optional track slug." },
];

const MEMBER_SET_NICKNAME_PARAMS: ActionParam[] = [
  { name: "pubkey_or_npub", type: "string", required: true, description: "Member 32-byte hex pubkey (npub bech32 deferred)." },
  { name: "nickname", type: "string", required: true, description: "Display name to remember locally." },
];

const IMAGE_ATTACH_PARAMS: ActionParam[] = [
  { name: "file_path", type: "string", required: true, description: "Absolute path to the source image file (any readable location)." },
  { name: "room_slug", type: "string", required: true, description: "Room slug — used to look up the current epoch." },
  { name: "mime_type", type: "string", description: "Optional MIME override; inferred from extension if absent." },
  {
    name: "s3_credentials",
    type: "object",
    description:
      "Required when the resolved storage backend is S3: {access_key_id, secret_access_key}. Renderer reads from Keychain and passes per-call; plugin never persists raw credentials.",
  },
];

const FILE_ATTACH_PARAMS: ActionParam[] = [
  { name: "file_path", type: "string", required: true, description: "Absolute path to the source file (any readable location). Symlinks are rejected." },
  { name: "room_slug", type: "string", required: true, description: "Room slug — used to look up the current epoch the wrap is bound to." },
  { name: "mime_type", type: "string", description: "Optional MIME override; inferred from extension if absent." },
  {
    name: "s3_credentials",
    type: "object",
    description:
      "Required when the resolved storage backend is S3: {access_key_id, secret_access_key}. Renderer reads from Keychain and passes per-call; plugin never persists raw credentials.",
  },
];

const FILE_FETCH_PARAMS: ActionParam[] = [
  { name: "sha256", type: "string", required: true, description: "64-lowercase-hex sha256 of the ciphertext blob (the Blossom key + integrity check)." },
  { name: "wrapped_key", type: "string", required: true, description: "Base64 NIP-44 ciphertext of (file_key || nonce), as emitted by studio_file_attach's decrypt_hint.wrapped_key." },
  { name: "epoch_n", type: "integer", required: true, description: "Room audience epoch the wrap is bound to (from decrypt_hint.epoch_n). Prior epochs are supported when the receiver still has the priv locally." },
  { name: "room_slug", type: "string", required: true, description: "Room slug — used to resolve the epoch_keys secret and confirm caller membership." },
  { name: "mirror_url", type: "string", required: true, description: "http(s) URL of the ciphertext mirror (from mirrors[]). Must be reachable from the plugin host." },
  { name: "author_pubkey", type: "string", required: true, description: "64-lowercase-hex plugin pubkey of the file's original author (the card event's sender). Required for NIP-44 ECDH." },
  { name: "blake3", type: "string", description: "Optional 64-lowercase-hex blake3 of the ciphertext; when provided the fetch verifies it and returns blake3_verified=true." },
  { name: "filename", type: "string", description: "Optional filename to use for the on-disk output (basename only; separators are stripped). Defaults to blob.bin." },
  { name: "mime_type", type: "string", description: "Optional MIME override for the returned metadata; inferred from filename extension if absent." },
];

const STORAGE_CONFIG_SET_PARAMS: ActionParam[] = [
  { name: "room", type: "string", required: true, description: "Room slug." },
  {
    name: "config",
    type: "object",
    description:
      "Storage backend config, or null to clear the per-room override and fall back to the user default. Shape: {kind: 'blossom', blossom_url} | {kind: 's3', s3_endpoint, s3_region, s3_bucket, s3_path_style, s3_access_key_id_keychain_ref, s3_secret_access_key_keychain_ref}.",
  },
];

const STORAGE_CONFIG_GET_PARAMS: ActionParam[] = [
  { name: "room", type: "string", required: true, description: "Room slug." },
];

const STORAGE_TEST_PARAMS: ActionParam[] = [
  { name: "config", type: "object", required: true, description: "Storage config to test (same shape as set)." },
  {
    name: "credentials",
    type: "object",
    description:
      "Required for kind=s3: {access_key_id, secret_access_key}. Renderer fetches from Keychain before calling; plugin uses them in-memory only.",
  },
];

const STORAGE_DEFAULT_SET_PARAMS: ActionParam[] = [
  {
    name: "config",
    type: "object",
    description:
      "User-wide default storage backend config, or null to clear (falls back to hosted Blossom).",
  },
];

const STORAGE_DEFAULT_GET_PARAMS: ActionParam[] = [];

// ── Action definitions ──────────────────────────────────────────────────────

export const ACTIONS: ActionDef[] = [
  {
    name: "studio_room_create",
    description:
      "Create a new Studio room (audience). Generates aud_id + epoch_1 keypairs locally and publishes the founding declaration + grant via the 4A gateway.",
    method: "post",
    path: "/api/room/create",
    params: ROOM_CREATE_PARAMS,
  },
  {
    name: "studio_room_join",
    description: "Join a Studio room from a s4a:// or https:// invite URL.",
    method: "post",
    path: "/api/room/join",
    params: ROOM_JOIN_PARAMS,
  },
  {
    name: "studio_room_invite",
    description: "Mint a one-time invite for a room. Founder-only.",
    method: "post",
    path: "/api/room/invite",
    params: ROOM_INVITE_PARAMS,
  },
  {
    name: "studio_room_admit",
    description:
      "Founder-only. Scan pending claims for a room; rotate epoch + grant new keys to admitted members.",
    method: "post",
    path: "/api/room/admit",
    params: ROOM_ADMIT_PARAMS,
  },
  {
    name: "studio_room_pending",
    description:
      "Founder-only. List pending kind:30522 claims for a room without rotating, with each claim's volunteered profile preview (nickname + bio) parsed from the claim's content. Used by the admit dialog to render per-row identity previews.",
    method: "post",
    path: "/api/room/pending",
    params: ROOM_PENDING_PARAMS,
  },
  {
    name: "studio_room_list",
    description: "List all Studio rooms this Sonata is a member of.",
    method: "get",
    path: "/api/room/list",
    params: ROOM_LIST_PARAMS,
  },
  {
    name: "studio_room_delete",
    description:
      "Local-only delete: removes the room entity + keys from this Sonata. Does NOT publish a revocation event — other members keep their copies (federated revoke is v0.x+ work).",
    method: "post",
    path: "/api/room/delete",
    params: ROOM_DELETE_PARAMS,
  },
  {
    name: "studio_room_leave",
    description:
      "Federated self-removal: publish a kind:30522 with fa:status=left so peers see this Sonata depart the audience. Founders cannot leave their own room — they close it instead. Local state flips to 'left' (or 'removed' if the gateway reports we were already booted).",
    method: "post",
    path: "/api/room/leave",
    params: ROOM_LEAVE_PARAMS,
  },
  {
    name: "studio_room_close",
    description:
      "Founder-only. Republish kind:30520 with fa:status=closed; freezes the audience to mutating operations gateway-side. Local state flips to 'closed' immediately so the UI reflects the founder's intent; if the gateway POST fails, the signed declaration is queued for retry.",
    method: "post",
    path: "/api/room/close",
    params: ROOM_CLOSE_PARAMS,
  },
  {
    name: "studio_room_reopen",
    description:
      "Founder-only. Republish kind:30520 with fa:status=active; lifts the gateway-side freeze on a previously-closed room.",
    method: "post",
    path: "/api/room/reopen",
    params: ROOM_REOPEN_PARAMS,
  },
  {
    name: "studio_room_boot",
    description:
      "Founder-only. Remove a member from the audience roster by republishing kind:30520 without their pubkey. Does NOT rotate the epoch; the booted member keeps their current epoch key (v0 acceptance; see room-lifecycle §11). Rejected with 403 closed_room while the room is closed.",
    method: "post",
    path: "/api/room/boot",
    params: ROOM_BOOT_PARAMS,
  },
  {
    name: "studio_card_post",
    description: "Post a card (kind 30530) to a room/track.",
    method: "post",
    path: "/api/card/post",
    params: CARD_POST_PARAMS,
  },
  {
    name: "studio_card_list",
    description: "List cards in a room, optionally filtered by track or recency.",
    method: "get",
    path: "/api/card/list",
    params: CARD_LIST_PARAMS,
  },
  {
    name: "studio_card_delete",
    description:
      "Author-only soft-delete: republishes the card (kind 30530) with status='deleted'. The replaceable d_tag overwrites the original; renderers filter status=deleted out.",
    method: "post",
    path: "/api/card/delete",
    params: CARD_DELETE_PARAMS,
  },
  {
    name: "studio_card_update",
    description:
      "Author-only edit: republishes the card (kind 30530) with merged fields. Omitted fields preserve the existing value from the local entity; present fields overwrite. Replaceable d_tag overwrites the prior rumor at every member.",
    method: "post",
    path: "/api/card/update",
    params: CARD_UPDATE_PARAMS,
  },
  {
    name: "studio_card_status_transition",
    description:
      "Move a card through its lifecycle (open ↔ in_progress ↔ done ↔ archived). Author may set any status; assignee may set in_progress or done; other room members are rejected with not_permitted. Re-publishes the card AND emits an audit comment with intent='status_change' carrying 'status: <prev> → <next>'.",
    method: "post",
    path: "/api/card/transition",
    params: CARD_STATUS_TRANSITION_PARAMS,
  },
  {
    name: "studio_track_create",
    description: "Create a track within a room (kind 30531).",
    method: "post",
    path: "/api/track/create",
    params: TRACK_CREATE_PARAMS,
  },
  {
    name: "studio_comment_post",
    description: "Post a comment on a card or other target (kind 30533).",
    method: "post",
    path: "/api/comment/post",
    params: COMMENT_POST_PARAMS,
  },
  {
    name: "studio_question_post",
    description: "Post a question to a room (kind 30534).",
    method: "post",
    path: "/api/question/post",
    params: QUESTION_POST_PARAMS,
  },
  {
    name: "studio_answer_post",
    description: "Post an answer to a question (kind 30535).",
    method: "post",
    path: "/api/answer/post",
    params: ANSWER_POST_PARAMS,
  },
  {
    name: "studio_dispatch_intent_post",
    description: "Publish a dispatch-intent record for a bus event (kind 30532).",
    method: "post",
    path: "/api/dispatch/post",
    params: DISPATCH_INTENT_POST_PARAMS,
  },
  {
    name: "studio_member_set_nickname",
    description: "Locally set a nickname for a peer pubkey/npub. Does not publish.",
    method: "post",
    path: "/api/member/nickname",
    params: MEMBER_SET_NICKNAME_PARAMS,
  },
  {
    name: "studio_image_attach",
    description:
      "Encrypt + upload an image to Blossom under the room's current audience epoch key. Returns an image-block payload for embedding in a card's blocks[].",
    method: "post",
    path: "/api/image/attach",
    params: IMAGE_ATTACH_PARAMS,
  },
  {
    name: "studio_file_attach",
    description:
      "Encrypt + upload an arbitrary file to Blossom via hybrid encryption (random ChaCha20-Poly1305 file_key, NIP-44-wrapped to the room's current audience-epoch). Returns a file-block payload for embedding in a card's blocks[]. 256 MiB hard cap.",
    method: "post",
    path: "/api/file/attach",
    params: FILE_ATTACH_PARAMS,
  },
  {
    name: "studio_file_fetch",
    description:
      "Receive-side symmetric to studio_file_attach: given a file-block's fields (sha256, wrapped_key, epoch_n, mirror_url, author_pubkey), download the ciphertext, verify integrity, NIP-44-unwrap the file_key, ChaCha20-Poly1305 decrypt, and write plaintext to a scoped scratch dir. Returns {file_path, size_bytes, mime_type, sha256_verified, blake3_verified}. 256 MiB hard cap enforced on the download.",
    method: "post",
    path: "/api/file/fetch",
    params: FILE_FETCH_PARAMS,
  },
  {
    name: "studio_identity",
    description:
      "Return the plugin's signing pubkey (lowercase hex). Renderer uses this to gate author-only UI (Delete/Edit) without waiting on optimistic-reconcile heuristics.",
    method: "get",
    path: "/api/identity",
    params: [],
  },
  {
    name: "studio_storage_config_set",
    description:
      "Set or clear the per-room storage backend (Blossom URL or BYO S3-compatible). Pass config=null to clear the override and fall back to the user default. Secrets are stored in macOS Keychain on the renderer; this entity carries only Keychain references.",
    method: "post",
    path: "/api/storage/config/set",
    params: STORAGE_CONFIG_SET_PARAMS,
  },
  {
    name: "studio_storage_config_get",
    description:
      "Get the resolved storage backend for a room: per-room override, user-default fallback, and effective config with source.",
    method: "post",
    path: "/api/storage/config/get",
    params: STORAGE_CONFIG_GET_PARAMS,
  },
  {
    name: "studio_storage_test",
    description:
      "Test a storage_config by uploading and retrieving a 19-byte probe object. For s3, requires credentials in the body. Probe is deleted after a successful round-trip.",
    method: "post",
    path: "/api/storage/test",
    params: STORAGE_TEST_PARAMS,
  },
  {
    name: "studio_storage_default_set",
    description:
      "Set or clear the user-wide default storage backend used by rooms without a per-room override. Persists on the studio:user_profile singleton entity.",
    method: "post",
    path: "/api/storage/default/set",
    params: STORAGE_DEFAULT_SET_PARAMS,
  },
  {
    name: "studio_storage_default_get",
    description:
      "Get the user-wide default storage backend (null when none is configured — uploads fall through to hosted Blossom).",
    method: "get",
    path: "/api/storage/default/get",
    params: STORAGE_DEFAULT_GET_PARAMS,
  },
];

// ── Route table ─────────────────────────────────────────────────────────────

export type ActionHandler = (
  body: Record<string, unknown>,
  query: Record<string, string>,
  ctx: ActionCtx,
) => Promise<unknown>;

export const ROUTES: Record<string, { method: "get" | "post"; handler: ActionHandler }> = {
  "/api/room/create": {
    method: "post",
    handler: async (body, _q, ctx) => room.create(body, ctx),
  },
  "/api/room/join": {
    method: "post",
    handler: async (body, _q, ctx) => room.join(body, ctx),
  },
  "/api/room/invite": {
    method: "post",
    handler: async (body, _q, ctx) => room.invite(body, ctx),
  },
  "/api/room/admit": {
    method: "post",
    handler: async (body, _q, ctx) => room_admit.admit(body, ctx),
  },
  "/api/room/pending": {
    method: "post",
    handler: async (body, _q, ctx) => room_admit.pending(body, ctx),
  },
  "/api/room/list": {
    method: "get",
    handler: async (_b, _q, ctx) => room.list(ctx),
  },
  "/api/room/delete": {
    method: "post",
    handler: async (body, _q, ctx) => room.delete(body, ctx),
  },
  "/api/room/leave": {
    method: "post",
    handler: async (body, _q, ctx) => room.leave(body, ctx),
  },
  "/api/room/close": {
    method: "post",
    handler: async (body, _q, ctx) => room.close(body, ctx),
  },
  "/api/room/reopen": {
    method: "post",
    handler: async (body, _q, ctx) => room.reopen(body, ctx),
  },
  "/api/room/boot": {
    method: "post",
    handler: async (body, _q, ctx) => room.boot(body, ctx),
  },
  "/api/card/post": {
    method: "post",
    handler: async (body, _q, ctx) => card.post(body, ctx),
  },
  "/api/card/list": {
    method: "get",
    handler: async (_b, query, ctx) => card.list(query, ctx),
  },
  "/api/card/delete": {
    method: "post",
    handler: async (body, _q, ctx) => card.delete(body, ctx),
  },
  "/api/card/update": {
    method: "post",
    handler: async (body, _q, ctx) => card.update(body, ctx),
  },
  "/api/card/transition": {
    method: "post",
    handler: async (body, _q, ctx) => cardStatus.transition(body, ctx),
  },
  "/api/track/create": {
    method: "post",
    handler: async (body, _q, ctx) => track.create(body, ctx),
  },
  "/api/comment/post": {
    method: "post",
    handler: async (body, _q, ctx) => comment.post(body, ctx),
  },
  "/api/question/post": {
    method: "post",
    handler: async (body, _q, ctx) => qa.question(body, ctx),
  },
  "/api/answer/post": {
    method: "post",
    handler: async (body, _q, ctx) => qa.answer(body, ctx),
  },
  "/api/dispatch/post": {
    method: "post",
    handler: async (body, _q, ctx) => dispatch.post(body, ctx),
  },
  "/api/member/nickname": {
    method: "post",
    handler: async (body, _q, ctx) => member.setNickname(body, ctx),
  },
  "/api/image/attach": {
    method: "post",
    handler: async (body, _q, ctx) => imageAttach.attach(body, ctx),
  },
  "/api/file/attach": {
    method: "post",
    handler: async (body, _q, ctx) => fileAttach.attach(body, ctx),
  },
  "/api/file/fetch": {
    method: "post",
    handler: async (body, _q, ctx) => fileFetch.fetch(body, ctx),
  },
  "/api/identity": {
    method: "get",
    handler: async (_b, _q, ctx) => ({ pubkey: ctx.cfg.pluginPub.toLowerCase() }),
  },
  "/api/storage/config/set": {
    method: "post",
    handler: async (body, _q, ctx) => storage.set(body, ctx),
  },
  "/api/storage/config/get": {
    method: "post",
    handler: async (body, _q, ctx) => storage.get(body, ctx),
  },
  "/api/storage/test": {
    method: "post",
    handler: async (body, _q, ctx) => storage.test(body, ctx),
  },
  "/api/storage/default/set": {
    method: "post",
    handler: async (body, _q, ctx) => storage.setDefault(body, ctx),
  },
  "/api/storage/default/get": {
    method: "get",
    handler: async (_b, _q, ctx) => storage.getDefault({}, ctx),
  },
};

// Re-export the action namespaces for consumers that want to call handlers
// directly (used by tests).
export { card, cardStatus, comment, dispatch, fileAttach, fileFetch, imageAttach, member, qa, room, room_admit, storage, track };
