// Per-room trust config for Studio auto-run.
//
// Studio auto-run's default is SANDBOX: workers get a prompt that tells them
// "no shell, filesystem is scoped, no network." That default is right for
// rooms whose members include untrusted-by-you counterparties — a card from
// any room member becomes tool-call requests on the receiving host.
//
// For rooms where you HAVE decided to trust every member with full local
// tools (e.g. a two-machine setup where both hosts are yours: the Sona /
// Scout shared workspace pattern), a per-room override widens the auto-run
// worker's tool grant to "full" — Bash, arbitrary FS, network. The
// decision is LOCAL to each host: enabling `full` for room X on evan-mac
// does NOT propagate to Scout, and vice versa. Same principle as GPG key
// trust — the signature network is public, the trust decision is local.
//
// Storage: JSON at `~/.sonata/plugins/sonata-studio/config/trusted-rooms.json`.
// Editable by hand until a Settings UI ships. Structure:
//
//   {
//     "trusted_rooms": {
//       "sona-scout-shared-work-space": {
//         "granted_at_ms": 1731028800000,
//         "acknowledged_members": [
//           "049b628c…",  // evan-mac Sonata pubkey
//           "c0eced15…"   // Scout Sonata pubkey
//         ],
//         "note": "Two-machine setup, both mine, full trust intentional."
//       }
//     }
//   }
//
// The acknowledged_members list is a safety belt: at dispatch time, if the
// current room membership differs from the acknowledged list, we DROP BACK
// to sandbox and log a warning telling the operator to re-affirm. This
// catches the "founder silently invites a third party" escalation class.
//
// See project-sonata/bugs card 8de151e5 for the full design + follow-ups
// (Settings UI, per-invocation audit stream, invite-time re-affirm prompt).

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { homedir } from "os";

export type TrustLevel = "sandbox" | "full";

export interface TrustedRoomEntry {
  granted_at_ms: number;
  acknowledged_members: string[];
  note?: string;
}

export interface TrustedRoomsConfig {
  trusted_rooms?: Record<string, TrustedRoomEntry>;
}

const CONFIG_PATH = join(
  homedir(),
  ".sonata",
  "plugins",
  "sonata-studio",
  "config",
  "trusted-rooms.json",
);

function readConfig(): TrustedRoomsConfig {
  if (!existsSync(CONFIG_PATH)) return {};
  try {
    const raw = readFileSync(CONFIG_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === "object") return parsed as TrustedRoomsConfig;
  } catch {
    // Malformed config → fall back to sandbox for every room. Safer than
    // failing dispatch entirely, and the operator will notice the log line.
  }
  return {};
}

export interface TrustDecision {
  level: TrustLevel;
  reason: string;
  entry?: TrustedRoomEntry;
}

/**
 * Resolve the trust level for a room dispatch. `currentMembers` is the full
 * membership set of the room right now (pubkeys). If the room appears in
 * the trusted-rooms config AND the current membership set equals what was
 * acknowledged, return `full`. Otherwise `sandbox` — with a `reason` string
 * suitable for logging.
 */
export function resolveTrust(
  roomSlug: string,
  currentMembers: string[],
): TrustDecision {
  const config = readConfig();
  const entry = config.trusted_rooms?.[roomSlug];
  if (!entry) return { level: "sandbox", reason: "no trust entry" };

  const wanted = new Set(entry.acknowledged_members);
  const actual = new Set(currentMembers);
  const same = wanted.size === actual.size
    && [...wanted].every((pk) => actual.has(pk));

  if (!same) {
    const added = [...actual].filter((pk) => !wanted.has(pk));
    const removed = [...wanted].filter((pk) => !actual.has(pk));
    const detail = [
      added.length ? `added=[${added.join(",")}]` : "",
      removed.length ? `removed=[${removed.join(",")}]` : "",
    ].filter(Boolean).join(" ");
    return {
      level: "sandbox",
      reason: `room membership changed since consent — re-affirm to restore full trust (${detail})`,
      entry,
    };
  }

  return { level: "full", reason: "acknowledged membership matches", entry };
}
