// studio_member is a local-only entity, never projected from a Studio
// event. It's auto-created on first-sight of any pubkey we observe via
// `ensureMember()` (see ./util.ts) and updated by the explicit
// `studio_member_set_nickname` action.
//
// This file exposes `setNickname` as a small helper the action handler
// can call directly. Cross-room: one entity per pubkey.

import { ensureMember, parseExistingAttributes } from "./util";
import type { MemoryClient } from "./types";

const HEX64 = /^[0-9a-f]{64}$/i;

export async function setNickname(
  client: MemoryClient,
  pubkeyHex: string,
  nickname: string | null,
  roomSlug?: string,
): Promise<{ id: string }> {
  if (!HEX64.test(pubkeyHex)) {
    throw new Error(`pubkey is not 32-byte hex: ${pubkeyHex}`);
  }
  const pubkey = pubkeyHex.toLowerCase();
  const id = await ensureMember(client, pubkey, roomSlug ?? "(unspecified)");
  const existing = await client.entity.byNameOrNull(`studio:member:${pubkey}`);
  const attrs = parseExistingAttributes(existing?.attributes);
  await client.entity.patch({
    id,
    attributes: { ...attrs, nickname },
  });
  return { id };
}
