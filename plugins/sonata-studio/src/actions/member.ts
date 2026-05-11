// Member action: setNickname. Per plan §5.11.
// Local-only — no relay traffic; just upserts the studio_member entity.

import { entity } from "../memory-client";
import { ensureString, HttpError, isHex64 } from "./util";
import type { ActionCtx } from "./room";

interface MemberSetNicknameRequest {
  pubkey_or_npub?: unknown;
  nickname?: unknown;
}

interface MemberSetNicknameResult {
  ok: true;
}

export async function setNickname(
  body: MemberSetNicknameRequest,
  _ctx: ActionCtx,
): Promise<MemberSetNicknameResult> {
  const idIn = ensureString(body.pubkey_or_npub, "pubkey_or_npub");
  const nickname = ensureString(body.nickname, "nickname");

  const pubkeyHex = resolvePubkeyHex(idIn);
  if (!pubkeyHex) {
    throw new HttpError(400, "bad_request", `"pubkey_or_npub" must be 64-hex or npub1...`);
  }

  const name = `studio:member:${pubkeyHex}`;
  const existing = await entity.byNameOrNull(name);
  let attrs: Record<string, unknown> = {};
  if (existing && existing.attributes) {
    try {
      const parsed = JSON.parse(existing.attributes);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        attrs = parsed as Record<string, unknown>;
      }
    } catch {
      // ignore — corrupt attrs treated as empty
    }
  }

  const merged: Record<string, unknown> = {
    ...attrs,
    pubkey_hex: pubkeyHex,
    nickname,
    tags: Array.isArray(attrs["tags"])
      ? attrs["tags"]
      : ["sonata-studio", "studio-member"],
  };
  if (typeof attrs["first_seen_in_room"] !== "string") {
    merged["first_seen_in_room"] = null;
  }
  if (typeof attrs["first_seen_at_ms"] !== "number") {
    merged["first_seen_at_ms"] = Date.now();
  }

  await entity.upsert({
    name,
    type: "studio_member",
    description: `Studio member ${nickname} (${pubkeyHex.slice(0, 8)}…)`,
    attributes: merged,
  });

  return { ok: true };
}

/**
 * Coerce input to canonical lowercase 64-hex. v0 accepts 64-hex directly;
 * npub1... bech32 decode is intentionally deferred (gateway returns hex
 * everywhere we surface pubkeys today). Returns null on unrecognized input.
 */
function resolvePubkeyHex(s: string): string | null {
  if (isHex64(s)) return s.toLowerCase();
  if (s.startsWith("npub1")) {
    // Per plan: bech32 decode is out-of-scope for v0 first ship; the helper
    // landing in T6/T7's codepaths uses libnostr. For now, refuse cleanly.
    return null;
  }
  return null;
}

export const member = {
  setNickname(body: unknown, ctx: ActionCtx): Promise<MemberSetNicknameResult> {
    return setNickname((body ?? {}) as MemberSetNicknameRequest, ctx);
  },
};
