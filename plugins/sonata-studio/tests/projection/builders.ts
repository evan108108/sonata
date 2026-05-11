// Synthetic Studio rumor + payload builders for projection tests.
//
// We don't run the validators here — these factories produce the shape
// the projection layer is documented to receive (already-validated rumors
// + decrypted JSON-LD payloads).

import type { StudioRumor } from "../../src/projection/types";

const HEX64 = "a".repeat(64);
const STUDIO_CONTEXT = "https://sonata.4a4.ai/ns/studio-v0";

export function audienceAddress(audIdPub: string, slug: string): string {
  return `30520:${audIdPub}:${slug}`;
}

let nonce = 0;
function freshHex(): string {
  nonce += 1;
  const hexNonce = nonce.toString(16).padStart(8, "0");
  return (hexNonce + "0".repeat(64)).slice(0, 64);
}

export interface BuildOpts {
  audIdPub?: string;
  roomSlug?: string;
  pubkey?: string;
  createdAt?: number;
  dTag?: string;
  eventId?: string;
}

function baseRumor(kind: number, opts: BuildOpts): StudioRumor {
  const audIdPub = opts.audIdPub ?? HEX64;
  const slug = opts.roomSlug ?? "studio-rt";
  return {
    id: opts.eventId ?? freshHex(),
    pubkey: opts.pubkey ?? freshHex(),
    kind,
    created_at: opts.createdAt ?? 1_700_000_000,
    tags: [
      ["d", opts.dTag ?? freshHex().slice(0, 16)],
      ["fa:context", "https://4a4.ai/ns/v0"],
      ["alt", "stub"],
      ["a", audienceAddress(audIdPub, slug)],
      ["fa:epoch", "1"],
      ["p", opts.pubkey ?? HEX64],
      ["blake3", "stub"],
    ],
    content: "stub-ciphertext",
  };
}

// ─── Card (30530) ──────────────────────────────────────────────────────────

export function cardRumor(opts: BuildOpts = {}): StudioRumor {
  return baseRumor(30530, opts);
}

export function cardPayload(over: Partial<Record<string, unknown>> = {}): Record<string, unknown> {
  return {
    "@context": STUDIO_CONTEXT,
    "@type": "Card",
    createdBy: "stub-pubkey",
    kind: "note",
    track: "inbox",
    title: "hello",
    summary: "world",
    blocks: [{ type: "text", body: "lorem" }],
    relatedTo: [],
    tags: [],
    ...over,
  };
}

// ─── Track (30531) ─────────────────────────────────────────────────────────

export function trackRumor(opts: BuildOpts = {}): StudioRumor {
  return baseRumor(30531, opts);
}

export function trackPayload(over: Partial<Record<string, unknown>> = {}): Record<string, unknown> {
  return {
    "@context": STUDIO_CONTEXT,
    "@type": "Track",
    createdBy: "stub-pubkey",
    name: "inbox",
    title: "Inbox",
    description: "Default inbox track",
    layout: "column",
    closedAt: null,
    ...over,
  };
}

// ─── DispatchIntent (30532) ────────────────────────────────────────────────

export function dispatchRumor(opts: BuildOpts = {}): StudioRumor {
  return baseRumor(30532, opts);
}

export function dispatchPayload(
  over: Partial<Record<string, unknown>> = {},
): Record<string, unknown> {
  return {
    "@context": STUDIO_CONTEXT,
    "@type": "DispatchIntent",
    createdBy: "stub-pubkey",
    eventId: "evt-1",
    candidates: ["scout", "supervisor"],
    chosen: "scout",
    reason: "matches scout-search trigger",
    signals: { confidence: 0.8 },
    track: "inbox",
    createdAt: 1_700_000_000_000,
    ...over,
  };
}

// ─── Comment (30533) ───────────────────────────────────────────────────────

export function commentRumor(opts: BuildOpts = {}): StudioRumor {
  return baseRumor(30533, opts);
}

export function commentPayload(
  targetId: string,
  over: Partial<Record<string, unknown>> = {},
): Record<string, unknown> {
  return {
    "@context": STUDIO_CONTEXT,
    "@type": "Comment",
    createdBy: "stub-pubkey",
    target: { "@id": targetId },
    body: "looks good",
    intent: undefined,
    ...over,
  };
}

// ─── Question (30534) ──────────────────────────────────────────────────────

export function questionRumor(opts: BuildOpts = {}): StudioRumor {
  return baseRumor(30534, opts);
}

export function questionPayload(
  over: Partial<Record<string, unknown>> = {},
): Record<string, unknown> {
  return {
    "@context": STUDIO_CONTEXT,
    "@type": "Question",
    createdBy: "stub-pubkey",
    body: "what is the deadline?",
    track: "inbox",
    tags: [],
    ...over,
  };
}

// ─── Answer (30535) ────────────────────────────────────────────────────────

export function answerRumor(opts: BuildOpts = {}): StudioRumor {
  return baseRumor(30535, opts);
}

export function answerPayload(
  questionId: string,
  over: Partial<Record<string, unknown>> = {},
): Record<string, unknown> {
  return {
    "@context": STUDIO_CONTEXT,
    "@type": "Answer",
    createdBy: "stub-pubkey",
    target: { "@id": questionId },
    body: "next Tuesday",
    ...over,
  };
}

// ─── Room (30536) ──────────────────────────────────────────────────────────

export function roomRumor(opts: BuildOpts = {}): StudioRumor {
  return baseRumor(30536, opts);
}

export function roomPayload(
  over: Partial<Record<string, unknown>> = {},
): Record<string, unknown> {
  return {
    "@context": STUDIO_CONTEXT,
    "@type": "Room",
    createdBy: "stub-pubkey",
    slug: "studio-rt",
    title: "Studio round-trip",
    description: "Test room",
    project: "demo",
    defaultTracks: ["inbox", "decisions"],
    ...over,
  };
}
