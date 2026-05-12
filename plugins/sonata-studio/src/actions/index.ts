// Action discovery list + route table. Mirrors sonata-studio.plugin.json's
// `actions` array (param specs are kept in sync with the manifest by the
// integration test in tests/actions/index.test.ts).
//
// Route table maps (path, method) → handler. The HTTP server in src/index.ts
// looks up by path+method, parses body/query, calls the handler with
// `ActionCtx`, and serializes the result.

import { room_admit } from "./admit";
import { card } from "./card";
import { comment } from "./comment";
import { dispatch } from "./dispatch";
import { imageAttach } from "./imageAttach";
import { member } from "./member";
import { qa } from "./qa";
import { room } from "./room";
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
    description: "4a:// or https://… invite URL containing slug, epoch, invite_pub, and ?priv= bech32 token.",
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

const ROOM_LIST_PARAMS: ActionParam[] = [];

const ROOM_DELETE_PARAMS: ActionParam[] = [
  { name: "slug", type: "string", required: true, description: "Slug of the room to delete locally." },
];

const CARD_POST_PARAMS: ActionParam[] = [
  { name: "room", type: "string", required: true, description: "Room slug." },
  { name: "track", type: "string", required: true, description: "Track slug within the room." },
  {
    name: "kind",
    type: "string",
    required: true,
    description: 'Card kind ("lead" | "review" | "finding" | "observation" | "task" | "note" | other).',
  },
  { name: "title", type: "string", required: true, description: "Title (≤200 chars)." },
  { name: "summary", type: "string", required: true, description: "One-line summary (≤240 chars)." },
  {
    name: "blocks",
    type: "array",
    description: "Optional array of structured content blocks, each {type: <string>, ...}.",
  },
  { name: "related_to", type: "array", description: "Optional array of related event ids or 4A addresses." },
  { name: "tags", type: "array", description: "Optional array of free-form tag strings." },
  { name: "d_tag", type: "string", description: "Override d-tag for replaceable-event addressing (default: sluggified title + 8-hex)." },
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

const CARD_UPDATE_PARAMS: ActionParam[] = [
  { name: "room", type: "string", required: true, description: "Room slug." },
  { name: "d_tag", type: "string", required: true, description: "d_tag of the card to update." },
  { name: "track", type: "string", description: "Override track slug. Omit to preserve." },
  { name: "kind", type: "string", description: "Override card kind. Omit to preserve." },
  { name: "title", type: "string", description: "Override title (≤200 chars). Omit to preserve." },
  { name: "summary", type: "string", description: "Override summary (≤240 chars). Omit to preserve." },
  { name: "blocks", type: "array", description: "Override blocks array. Omit to preserve." },
  { name: "related_to", type: "array", description: "Override related_to list. Omit to preserve." },
  { name: "tags", type: "array", description: "Override tags list. Omit to preserve." },
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
  { name: "file_path", type: "string", required: true, description: "Absolute path under ~/Library/Caches/com.sonata/ or ~/Downloads/." },
  { name: "room_slug", type: "string", required: true, description: "Room slug — used to look up the current epoch." },
  { name: "mime_type", type: "string", description: "Optional MIME override; inferred from extension if absent." },
];

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
    description: "Join a Studio room from a 4a:// or https:// invite URL.",
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
    name: "studio_identity",
    description:
      "Return the plugin's signing pubkey (lowercase hex). Renderer uses this to gate author-only UI (Delete/Edit) without waiting on optimistic-reconcile heuristics.",
    method: "get",
    path: "/api/identity",
    params: [],
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
  "/api/room/list": {
    method: "get",
    handler: async (_b, _q, ctx) => room.list(ctx),
  },
  "/api/room/delete": {
    method: "post",
    handler: async (body, _q, ctx) => room.delete(body, ctx),
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
  "/api/identity": {
    method: "get",
    handler: async (_b, _q, ctx) => ({ pubkey: ctx.cfg.pluginPub.toLowerCase() }),
  },
};

// Re-export the action namespaces for consumers that want to call handlers
// directly (used by tests).
export { card, comment, dispatch, imageAttach, member, qa, room, room_admit, track };
