// AUTO-GENERATED — copied at build time from:
//   /Users/evan/projects/4a/gateway/src/studio-v0/validators.ts
// Edits will be overwritten by build.sh on the next compile.
// Imports are rewritten from gateway-relative to plugin-relative.

// Well-formedness validators for Sonata Studio v0 (kinds 30530-30536).
//
// Per sonata-studio-v0-spec.md:
//   - Wire-level validator (`validateStudioWireEvent`) checks the rumor before
//     gift-wrapping. Same shape as the encrypted-variant validator (SPEC-v0.5
//     §3.6) with the kind range substituted to 30530-30536.
//   - Plaintext-payload validators (`validateCardPayload`, etc.) check the
//     JSON-LD object the publisher encrypts and the consumer decrypts. Pure
//     functions; no I/O.
//
// Out of scope: rendering, conflict resolution, plugin code. The wire-level
// check that the rumor never escaped a gift-wrap is enforced by the §4.5
// gift-wrap validator rejecting bare 30530-30536 deliveries (same path as
// encrypted-variant kinds).

import type { AudienceLookup } from "./audience-types";
import { blake3ContentTag } from "./crypto/blake3-tag";
import { isStructurallyValid as nip44IsStructurallyValid } from "./crypto/nip44";
import type { NostrEvent } from "./audience-types";

// --- constants ---------------------------------------------------------------

export const STUDIO_KINDS = [30530, 30531, 30532, 30533, 30534, 30535, 30536] as const;
export type StudioKind = (typeof STUDIO_KINDS)[number];

export const STUDIO_KIND_CARD = 30530 as const;
export const STUDIO_KIND_TRACK = 30531 as const;
export const STUDIO_KIND_DISPATCH_INTENT = 30532 as const;
export const STUDIO_KIND_COMMENT = 30533 as const;
export const STUDIO_KIND_QUESTION = 30534 as const;
export const STUDIO_KIND_ANSWER = 30535 as const;
export const STUDIO_KIND_ROOM = 30536 as const;

export const STUDIO_CONTEXT_V0 = "https://sonata.4a4.ai/ns/studio-v0" as const;
const FA_CONTEXT_V0 = "https://4a4.ai/ns/v0";

const HEX64 = /^[0-9a-f]{64}$/i;
const SLUG = /^[A-Za-z0-9-]+$/;
const ADDRESS_PATTERN = /^30520:[0-9a-f]{64}:[A-Za-z0-9-]+$/;

const TRACK_LAYOUTS = ["column", "timeline", "grouped"] as const;
type TrackLayout = (typeof TRACK_LAYOUTS)[number];

// Field-length caps. Centralized so the spec and validators stay in sync.
const MAX_TITLE = 200;
const MAX_CARD_BODY = 10000;
const MAX_DESCRIPTION = 2000;
const MAX_REASON = 2000;
const MAX_BODY = 4000;
const MAX_SIGNAL_KEYS = 32;

export type ValidationResult =
  | { ok: true }
  | { ok: false; error: string };

// --- shared helpers ----------------------------------------------------------

function findTag(tags: string[][], name: string): string | undefined {
  for (const t of tags) if (t[0] === name) return t[1];
  return undefined;
}

function findAllTags(tags: string[][], name: string): string[] {
  const out: string[] = [];
  for (const t of tags) if (t[0] === name && typeof t[1] === "string") out.push(t[1]);
  return out;
}

function setEqualLower(a: string[], b: string[]): boolean {
  if (a.length !== b.length) return false;
  const setA = new Set(a.map((x) => x.toLowerCase()));
  for (const x of b) if (!setA.has(x.toLowerCase())) return false;
  return true;
}

function isPlainObject(x: unknown): x is Record<string, unknown> {
  return typeof x === "object" && x !== null && !Array.isArray(x);
}

function isNonEmptyString(x: unknown): x is string {
  return typeof x === "string" && x.length > 0;
}

function isStringArray(x: unknown): x is string[] {
  return Array.isArray(x) && x.every((v) => typeof v === "string" && v.length > 0);
}

function isStudioKind(k: number): k is StudioKind {
  return (STUDIO_KINDS as readonly number[]).includes(k);
}

// --- §1 wire-level validator -------------------------------------------------

/**
 * Validate the rumor-level (encrypted-variant-style) shape of a Studio event.
 * Mirrors validateEncryptedVariantEvent for kinds 30530-30536. Optional
 * AudienceLookup enables the cross-event "current declaration" checks; passing
 * `{}` runs the structural checks only.
 */
export function validateStudioWireEvent(
  event: NostrEvent,
  lookup: AudienceLookup = {},
): ValidationResult {
  if (!isStudioKind(event.kind)) {
    return {
      ok: false,
      error: `kind ${event.kind} not in studio-v0 range 30530-30536`,
    };
  }
  const dTag = findTag(event.tags, "d");
  if (!dTag || dTag.length === 0) {
    return { ok: false, error: 'tag "d" missing' };
  }
  const faContext = findTag(event.tags, "fa:context");
  if (faContext !== FA_CONTEXT_V0) {
    return { ok: false, error: `fa:context must equal "${FA_CONTEXT_V0}"` };
  }
  const altTag = findTag(event.tags, "alt");
  if (!altTag || altTag.length === 0) {
    return { ok: false, error: 'tag "alt" missing or empty' };
  }
  const aTag = findTag(event.tags, "a");
  if (!aTag || !ADDRESS_PATTERN.test(aTag)) {
    return { ok: false, error: '"a" tag must match 30520:<aud_id-hex>:<slug>' };
  }
  const epochTag = findTag(event.tags, "fa:epoch");
  if (!epochTag || !/^[1-9]\d*$/.test(epochTag)) {
    return { ok: false, error: '"fa:epoch" must be a positive integer' };
  }
  const epoch = Number(epochTag);

  const pTags = findAllTags(event.tags, "p");
  if (pTags.length === 0) {
    return { ok: false, error: 'must carry at least one "p" tag (per current member)' };
  }
  for (const p of pTags) {
    if (!HEX64.test(p)) {
      return { ok: false, error: `"p" tag value not 32-byte hex: ${p}` };
    }
  }
  const blake3Tag = findTag(event.tags, "blake3");
  if (!blake3Tag) {
    return { ok: false, error: '"blake3" tag missing' };
  }
  const expectedBlake3 = blake3ContentTag(event.content);
  if (blake3Tag !== expectedBlake3) {
    return {
      ok: false,
      error: `blake3 tag mismatch: tag="${blake3Tag}", expected="${expectedBlake3}"`,
    };
  }
  if (!nip44IsStructurallyValid(event.content)) {
    return { ok: false, error: "content is not valid NIP-44 v2 ciphertext" };
  }

  if (lookup.currentDeclarationByAddress) {
    const decl = lookup.currentDeclarationByAddress(aTag);
    if (!decl) {
      return { ok: false, error: '"a" tag does not resolve to a known kind:30520 declaration' };
    }
    if (decl.epoch !== epoch) {
      return {
        ok: false,
        error: `fa:epoch (${epoch}) does not equal current declaration epoch (${decl.epoch})`,
      };
    }
    if (!setEqualLower(pTags, decl.members)) {
      return {
        ok: false,
        error: '"p" tag set does not equal the current declaration member set',
      };
    }
  }

  return { ok: true };
}

// --- §2 common plaintext checks ----------------------------------------------

function checkCommonPayload(
  payload: unknown,
  expectedType: string,
):
  | { ok: true; obj: Record<string, unknown> }
  | { ok: false; error: string } {
  if (!isPlainObject(payload)) {
    return { ok: false, error: "payload must be a JSON object" };
  }
  if (payload["@context"] !== STUDIO_CONTEXT_V0) {
    return {
      ok: false,
      error: `@context must equal "${STUDIO_CONTEXT_V0}"`,
    };
  }
  if (payload["@type"] !== expectedType) {
    return { ok: false, error: `@type must equal "${expectedType}"` };
  }
  if (!isNonEmptyString(payload.createdBy)) {
    return { ok: false, error: '"createdBy" must be a non-empty string' };
  }
  return { ok: true, obj: payload };
}

// --- §3 Card -----------------------------------------------------------------

function validateCardBlock(b: unknown, idx: number): ValidationResult {
  if (!isPlainObject(b)) {
    return { ok: false, error: `blocks[${idx}] must be a JSON object` };
  }
  if (!isNonEmptyString(b.type)) {
    return { ok: false, error: `blocks[${idx}].type must be a non-empty string` };
  }
  return { ok: true };
}

export function validateCardPayload(payload: unknown): ValidationResult {
  const c = checkCommonPayload(payload, "Card");
  if (!c.ok) return c;
  const obj = c.obj;

  if (!isNonEmptyString(obj.kind)) {
    return { ok: false, error: '"kind" must be a non-empty string' };
  }
  if (!isNonEmptyString(obj.track)) {
    return { ok: false, error: '"track" must be a non-empty string slug' };
  }
  if (!SLUG.test(obj.track)) {
    return { ok: false, error: '"track" must match slug grammar [A-Za-z0-9-]+' };
  }
  if (!isNonEmptyString(obj.title)) {
    return { ok: false, error: '"title" must be a non-empty string' };
  }
  if (obj.title.length > MAX_TITLE) {
    return { ok: false, error: `"title" exceeds ${MAX_TITLE} characters` };
  }
  // Card body (long-form markdown). `summary` is the pre-2026-05-12 alias —
  // accept it as a legacy fallback so unmigrated publishers still validate.
  // Cutover: remove the `summary` fallback once all known publishers have
  // upgraded past 2026-05-12.
  const cardBody =
    isNonEmptyString(obj.body) ? obj.body
    : isNonEmptyString(obj.summary) ? obj.summary
    : null;
  if (cardBody === null) {
    return { ok: false, error: '"body" must be a non-empty string' };
  }
  if (cardBody.length > MAX_CARD_BODY) {
    return { ok: false, error: `"body" exceeds ${MAX_CARD_BODY} characters` };
  }
  if (
    isNonEmptyString(obj.body) &&
    isNonEmptyString(obj.summary) &&
    obj.body !== obj.summary
  ) {
    return {
      ok: false,
      error: '"body" and "summary" both present with different content',
    };
  }
  if (!Array.isArray(obj.blocks)) {
    return { ok: false, error: '"blocks" must be an array' };
  }
  for (let i = 0; i < obj.blocks.length; i++) {
    const r = validateCardBlock(obj.blocks[i], i);
    if (!r.ok) return r;
  }
  if (obj.relatedTo !== undefined) {
    if (!isStringArray(obj.relatedTo)) {
      return { ok: false, error: '"relatedTo" must be an array of non-empty strings' };
    }
  }
  if (obj.tags !== undefined) {
    if (!isStringArray(obj.tags)) {
      return { ok: false, error: '"tags" must be an array of non-empty strings' };
    }
  }
  return { ok: true };
}

// --- §4 Track ----------------------------------------------------------------

export function validateTrackPayload(payload: unknown): ValidationResult {
  const c = checkCommonPayload(payload, "Track");
  if (!c.ok) return c;
  const obj = c.obj;

  if (!isNonEmptyString(obj.name)) {
    return { ok: false, error: '"name" must be a non-empty slug' };
  }
  if (!SLUG.test(obj.name)) {
    return { ok: false, error: '"name" must match slug grammar [A-Za-z0-9-]+' };
  }
  if (!isNonEmptyString(obj.title)) {
    return { ok: false, error: '"title" must be a non-empty string' };
  }
  if (obj.title.length > MAX_TITLE) {
    return { ok: false, error: `"title" exceeds ${MAX_TITLE} characters` };
  }
  if (obj.description !== undefined) {
    if (typeof obj.description !== "string") {
      return { ok: false, error: '"description" must be a string when present' };
    }
    if (obj.description.length > MAX_DESCRIPTION) {
      return { ok: false, error: `"description" exceeds ${MAX_DESCRIPTION} characters` };
    }
  }
  if (typeof obj.layout !== "string" || !(TRACK_LAYOUTS as readonly string[]).includes(obj.layout)) {
    return {
      ok: false,
      error: `"layout" must be one of ${TRACK_LAYOUTS.join(", ")}`,
    };
  }
  if (obj.closedAt !== null) {
    if (typeof obj.closedAt !== "number" || !Number.isFinite(obj.closedAt) || obj.closedAt < 0) {
      return { ok: false, error: '"closedAt" must be null or a non-negative finite number' };
    }
  }
  return { ok: true };
}

// --- §5 DispatchIntent -------------------------------------------------------

function validateSignals(signals: unknown): ValidationResult {
  if (!isPlainObject(signals)) {
    return { ok: false, error: '"signals" must be a JSON object when present' };
  }
  const keys = Object.keys(signals);
  if (keys.length > MAX_SIGNAL_KEYS) {
    return { ok: false, error: `"signals" must have ≤ ${MAX_SIGNAL_KEYS} keys` };
  }
  for (const k of keys) {
    const v = signals[k];
    if (typeof v !== "string" && typeof v !== "number" && typeof v !== "boolean") {
      return {
        ok: false,
        error: `"signals.${k}" must be string, number, or boolean (no nested objects in v0)`,
      };
    }
  }
  return { ok: true };
}

export function validateDispatchIntentPayload(payload: unknown): ValidationResult {
  const c = checkCommonPayload(payload, "DispatchIntent");
  if (!c.ok) return c;
  const obj = c.obj;

  if (!isNonEmptyString(obj.eventId)) {
    return { ok: false, error: '"eventId" must be a non-empty string' };
  }
  if (!isStringArray(obj.candidates) || obj.candidates.length === 0) {
    return { ok: false, error: '"candidates" must be a non-empty array of non-empty strings' };
  }
  if (!isNonEmptyString(obj.chosen)) {
    return { ok: false, error: '"chosen" must be a non-empty string' };
  }
  if (!obj.candidates.includes(obj.chosen)) {
    return { ok: false, error: '"chosen" must appear in "candidates"' };
  }
  if (!isNonEmptyString(obj.reason)) {
    return { ok: false, error: '"reason" must be a non-empty string' };
  }
  if (obj.reason.length > MAX_REASON) {
    return { ok: false, error: `"reason" exceeds ${MAX_REASON} characters` };
  }
  if (obj.signals !== undefined) {
    const r = validateSignals(obj.signals);
    if (!r.ok) return r;
  }
  if (obj.track !== undefined) {
    if (!isNonEmptyString(obj.track) || !SLUG.test(obj.track)) {
      return { ok: false, error: '"track" must match slug grammar when present' };
    }
  }
  if (typeof obj.createdAt !== "number" || !Number.isFinite(obj.createdAt) || obj.createdAt <= 0 || !Number.isInteger(obj.createdAt)) {
    return { ok: false, error: '"createdAt" must be a positive integer (Unix ms)' };
  }
  return { ok: true };
}

// --- §6 Comment / §8 Answer share a target shape -----------------------------

function validateTarget(target: unknown): ValidationResult {
  if (!isPlainObject(target)) {
    return { ok: false, error: '"target" must be a JSON object' };
  }
  const id = target["@id"];
  if (!isNonEmptyString(id)) {
    return { ok: false, error: '"target.@id" must be a non-empty string' };
  }
  // Accept nostr: URI, bare 64-hex event id, or 4A address
  const isNostrUri = id.startsWith("nostr:");
  const isBareHex = HEX64.test(id);
  const isAddress = /^\d+:[0-9a-f]{64}:[A-Za-z0-9-]+$/.test(id);
  if (!isNostrUri && !isBareHex && !isAddress) {
    return {
      ok: false,
      error: '"target.@id" must be a nostr: URI, 64-hex event id, or 4A address',
    };
  }
  return { ok: true };
}

export function validateCommentPayload(payload: unknown): ValidationResult {
  const c = checkCommonPayload(payload, "Comment");
  if (!c.ok) return c;
  const obj = c.obj;

  const targetCheck = validateTarget(obj.target);
  if (!targetCheck.ok) return targetCheck;
  if (!isNonEmptyString(obj.body)) {
    return { ok: false, error: '"body" must be a non-empty string' };
  }
  if (obj.body.length > MAX_BODY) {
    return { ok: false, error: `"body" exceeds ${MAX_BODY} characters` };
  }
  if (obj.intent !== undefined && !isNonEmptyString(obj.intent)) {
    return { ok: false, error: '"intent" must be a non-empty string when present' };
  }
  if (obj.blocks !== undefined) {
    if (!Array.isArray(obj.blocks)) {
      return { ok: false, error: '"blocks" must be an array when present' };
    }
    for (let i = 0; i < obj.blocks.length; i++) {
      const r = validateCardBlock(obj.blocks[i], i);
      if (!r.ok) return r;
    }
  }
  return { ok: true };
}

// --- §7 Question -------------------------------------------------------------

export function validateQuestionPayload(payload: unknown): ValidationResult {
  const c = checkCommonPayload(payload, "Question");
  if (!c.ok) return c;
  const obj = c.obj;

  if (!isNonEmptyString(obj.body)) {
    return { ok: false, error: '"body" must be a non-empty string' };
  }
  if (obj.body.length > MAX_BODY) {
    return { ok: false, error: `"body" exceeds ${MAX_BODY} characters` };
  }
  if (obj.track !== undefined) {
    if (!isNonEmptyString(obj.track) || !SLUG.test(obj.track)) {
      return { ok: false, error: '"track" must match slug grammar when present' };
    }
  }
  if (obj.tags !== undefined && !isStringArray(obj.tags)) {
    return { ok: false, error: '"tags" must be an array of non-empty strings when present' };
  }
  return { ok: true };
}

// --- §8 Answer ---------------------------------------------------------------

export function validateAnswerPayload(payload: unknown): ValidationResult {
  const c = checkCommonPayload(payload, "Answer");
  if (!c.ok) return c;
  const obj = c.obj;

  const targetCheck = validateTarget(obj.target);
  if (!targetCheck.ok) return targetCheck;
  if (!isNonEmptyString(obj.body)) {
    return { ok: false, error: '"body" must be a non-empty string' };
  }
  if (obj.body.length > MAX_BODY) {
    return { ok: false, error: `"body" exceeds ${MAX_BODY} characters` };
  }
  return { ok: true };
}

// --- §9 Room -----------------------------------------------------------------

export function validateRoomPayload(payload: unknown): ValidationResult {
  const c = checkCommonPayload(payload, "Room");
  if (!c.ok) return c;
  const obj = c.obj;

  if (!isNonEmptyString(obj.slug) || !SLUG.test(obj.slug)) {
    return { ok: false, error: '"slug" must match slug grammar [A-Za-z0-9-]+' };
  }
  if (!isNonEmptyString(obj.title)) {
    return { ok: false, error: '"title" must be a non-empty string' };
  }
  if (obj.title.length > MAX_TITLE) {
    return { ok: false, error: `"title" exceeds ${MAX_TITLE} characters` };
  }
  if (obj.description !== undefined) {
    if (typeof obj.description !== "string") {
      return { ok: false, error: '"description" must be a string when present' };
    }
    if (obj.description.length > MAX_DESCRIPTION) {
      return { ok: false, error: `"description" exceeds ${MAX_DESCRIPTION} characters` };
    }
  }
  if (obj.project !== undefined) {
    if (!isNonEmptyString(obj.project) || !SLUG.test(obj.project)) {
      return { ok: false, error: '"project" must match slug grammar when present' };
    }
  }
  if (obj.defaultTracks !== undefined) {
    if (!Array.isArray(obj.defaultTracks)) {
      return { ok: false, error: '"defaultTracks" must be an array when present' };
    }
    for (const t of obj.defaultTracks) {
      if (typeof t !== "string" || !SLUG.test(t)) {
        return { ok: false, error: '"defaultTracks" entries must be slugs' };
      }
    }
  }
  return { ok: true };
}

// --- dispatcher --------------------------------------------------------------

const PAYLOAD_VALIDATORS: Record<StudioKind, (payload: unknown) => ValidationResult> = {
  [STUDIO_KIND_CARD]: validateCardPayload,
  [STUDIO_KIND_TRACK]: validateTrackPayload,
  [STUDIO_KIND_DISPATCH_INTENT]: validateDispatchIntentPayload,
  [STUDIO_KIND_COMMENT]: validateCommentPayload,
  [STUDIO_KIND_QUESTION]: validateQuestionPayload,
  [STUDIO_KIND_ANSWER]: validateAnswerPayload,
  [STUDIO_KIND_ROOM]: validateRoomPayload,
};

/**
 * Look up the plaintext payload validator for a given Studio kind.
 * Returns `undefined` if the kind is reserved (30537-30539) or out of range.
 */
export function payloadValidatorFor(
  kind: number,
): ((payload: unknown) => ValidationResult) | undefined {
  if (!isStudioKind(kind)) return undefined;
  return PAYLOAD_VALIDATORS[kind];
}
