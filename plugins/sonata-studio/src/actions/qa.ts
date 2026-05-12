// Question / Answer actions. Per plan §5.9.

import {
  buildDTag,
  buildScopedDTag,
  buildSignedRumor,
  ensureSlug,
  ensureString,
  HttpError,
  loadRoomCtx,
  publishRumor,
  STUDIO_CONTEXT_V0,
  STUDIO_KIND_ANSWER,
  STUDIO_KIND_QUESTION,
  validatePayload,
} from "./util";
import type { ActionCtx } from "./room";

interface QuestionPostRequest {
  room?: unknown;
  body?: unknown;
  track?: unknown;
  tags?: unknown;
}

interface AnswerPostRequest {
  room?: unknown;
  question_id?: unknown;
  body?: unknown;
}

interface PostResult {
  rumor_event_id: string;
  d_tag: string;
}

export async function postQuestion(
  body: QuestionPostRequest,
  ctx: ActionCtx,
): Promise<PostResult> {
  const roomSlug = ensureSlug(body.room, "room");
  const text = ensureString(body.body, "body");
  const trackSlug = body.track !== undefined ? ensureSlug(body.track, "track") : undefined;
  const tags = normalizeStringArray(body.tags, "tags");

  const room = await loadRoomCtx(roomSlug, ctx.cfg.pluginPub);

  const payload: Record<string, unknown> = {
    "@context": STUDIO_CONTEXT_V0,
    "@type": "Question",
    body: text,
    createdBy: ctx.cfg.pluginPub.toLowerCase(),
  };
  if (trackSlug !== undefined) payload["track"] = trackSlug;
  if (tags.length > 0) payload["tags"] = tags;
  validatePayload(STUDIO_KIND_QUESTION, payload);

  const dTag = buildDTag(text.slice(0, 64));
  const rumor = buildSignedRumor({
    kind: STUDIO_KIND_QUESTION,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    publisherPub: ctx.cfg.pluginPub,
    dTag,
    alt: `Studio question: ${text.slice(0, 80)}`,
  });
  const { rumorEventId } = await publishRumor({
    rumor,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    gateway: ctx.gateway,
  });
  return { rumor_event_id: rumorEventId, d_tag: dTag };
}

export async function postAnswer(
  body: AnswerPostRequest,
  ctx: ActionCtx,
): Promise<PostResult> {
  const roomSlug = ensureSlug(body.room, "room");
  const questionId = ensureString(body.question_id, "question_id");
  if (!/^[0-9a-f]{64}$/i.test(questionId)) {
    throw new HttpError(400, "bad_request", `"question_id" must be 32-byte hex event id`);
  }
  const text = ensureString(body.body, "body");

  const room = await loadRoomCtx(roomSlug, ctx.cfg.pluginPub);

  const payload: Record<string, unknown> = {
    "@context": STUDIO_CONTEXT_V0,
    "@type": "Answer",
    target: { "@id": questionId.toLowerCase() },
    body: text,
    createdBy: ctx.cfg.pluginPub.toLowerCase(),
  };
  validatePayload(STUDIO_KIND_ANSWER, payload);

  const dTag = buildScopedDTag(questionId.toLowerCase());
  const rumor = buildSignedRumor({
    kind: STUDIO_KIND_ANSWER,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    publisherPub: ctx.cfg.pluginPub,
    dTag,
    alt: `Studio answer to ${questionId.slice(0, 8)}…`,
  });
  const { rumorEventId } = await publishRumor({
    rumor,
    payload,
    room,
    publisherPriv: ctx.cfg.pluginPriv,
    gateway: ctx.gateway,
  });
  return { rumor_event_id: rumorEventId, d_tag: dTag };
}

function normalizeStringArray(raw: unknown, field: string): string[] {
  if (raw === undefined) return [];
  if (!Array.isArray(raw)) {
    throw new HttpError(400, "bad_request", `"${field}" must be an array of strings`);
  }
  const out: string[] = [];
  for (let i = 0; i < raw.length; i++) {
    const v = raw[i];
    if (typeof v !== "string" || v.length === 0) {
      throw new HttpError(400, "bad_request", `"${field}[${i}]" must be a non-empty string`);
    }
    out.push(v);
  }
  return out;
}

export const qa = {
  question(body: unknown, ctx: ActionCtx): Promise<PostResult> {
    return postQuestion((body ?? {}) as QuestionPostRequest, ctx);
  },
  answer(body: unknown, ctx: ActionCtx): Promise<PostResult> {
    return postAnswer((body ?? {}) as AnswerPostRequest, ctx);
  },
};
