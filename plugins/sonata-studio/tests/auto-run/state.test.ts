// Unit tests for the pure state.ts gates: consent decision, token bucket,
// daily quota rollover. These are HTTP-free; they exercise the in-memory
// arithmetic that gates dispatch.

import { describe, expect, test } from "bun:test";
import {
  BUCKET_CAPACITY,
  BUCKET_REFILL_MS,
  DEFAULT_DAILY_CAP,
  consentDecision,
  consumeOnceDecision,
  tryConsumeRoomToken,
  tryReserveDailyQuota,
  type AutoRunProfile,
} from "../../src/auto-run/state";

function freshProfile(overrides: Partial<AutoRunProfile> = {}): AutoRunProfile {
  return {
    enabled: true,
    max_per_day: DEFAULT_DAILY_CAP,
    today_count: 0,
    today_date: "2026-05-12",
    allowed_founders: [],
    founder_decisions: {},
    room_buckets: {},
    ...overrides,
  };
}

describe("consentDecision", () => {
  test("auto_run_off when master toggle off and room override != on", () => {
    const p = freshProfile({ enabled: false });
    expect(consentDecision(p, "default", "ab".repeat(32))).toBe("auto_run_off");
  });

  test("allowed when room override on (even if master toggle off)", () => {
    const p = freshProfile({ enabled: false });
    expect(consentDecision(p, "on", "ab".repeat(32))).toBe("allowed");
  });

  test("blocked when room override off", () => {
    const p = freshProfile();
    expect(consentDecision(p, "off", "ab".repeat(32))).toBe("blocked");
  });

  test("needs_consent when founder unknown", () => {
    const p = freshProfile();
    expect(consentDecision(p, "default", "ab".repeat(32))).toBe("needs_consent");
  });

  test("allowed when founder in allow-list", () => {
    const founder = "cd".repeat(32);
    const p = freshProfile({ allowed_founders: [founder] });
    expect(consentDecision(p, "default", founder)).toBe("allowed");
  });

  test("allowed when founder decision is `always`", () => {
    const founder = "ef".repeat(32);
    const p = freshProfile({ founder_decisions: { [founder]: "always" } });
    expect(consentDecision(p, "default", founder)).toBe("allowed");
  });

  test("allowed when founder decision is `once`", () => {
    const founder = "1a".repeat(32);
    const p = freshProfile({ founder_decisions: { [founder]: "once" } });
    expect(consentDecision(p, "default", founder)).toBe("allowed");
  });

  test("blocked when founder decision is `never`", () => {
    const founder = "2b".repeat(32);
    const p = freshProfile({ founder_decisions: { [founder]: "never" } });
    expect(consentDecision(p, "default", founder)).toBe("blocked");
  });

  test("consumeOnceDecision clears `once` only", () => {
    const founder = "3c".repeat(32);
    const p = freshProfile({
      founder_decisions: { [founder]: "once", other: "always" },
    });
    consumeOnceDecision(p, founder);
    expect(p.founder_decisions[founder]).toBeUndefined();
    expect(p.founder_decisions["other"]).toBe("always");
    // No-op on `always`.
    consumeOnceDecision(p, "other");
    expect(p.founder_decisions["other"]).toBe("always");
  });
});

describe("tryConsumeRoomToken", () => {
  test("first call on a fresh bucket succeeds and persists state", () => {
    const p = freshProfile();
    const t0 = 1_000_000_000;
    const r = tryConsumeRoomToken(p, "room-a", t0);
    expect(r.ok).toBe(true);
    expect(r.remaining).toBe(BUCKET_CAPACITY - 1);
    expect(p.room_buckets["room-a"]).toBeDefined();
    expect(p.room_buckets["room-a"]!.tokens).toBe(BUCKET_CAPACITY - 1);
  });

  test("draining the bucket then attempting one more returns ok=false", () => {
    const p = freshProfile();
    const t0 = 1_000_000_000;
    for (let i = 0; i < BUCKET_CAPACITY; i++) {
      expect(tryConsumeRoomToken(p, "room-a", t0).ok).toBe(true);
    }
    const r = tryConsumeRoomToken(p, "room-a", t0);
    expect(r.ok).toBe(false);
    expect(r.remaining).toBe(0);
  });

  test("after refill window passes, token re-issues", () => {
    const p = freshProfile();
    const t0 = 1_000_000_000;
    for (let i = 0; i < BUCKET_CAPACITY; i++) {
      tryConsumeRoomToken(p, "room-a", t0);
    }
    expect(tryConsumeRoomToken(p, "room-a", t0).ok).toBe(false);
    // Jump forward past one refill window.
    const t1 = t0 + BUCKET_REFILL_MS + 1;
    expect(tryConsumeRoomToken(p, "room-a", t1).ok).toBe(true);
  });

  test("buckets are per-room independent", () => {
    const p = freshProfile();
    const t0 = 1_000_000_000;
    for (let i = 0; i < BUCKET_CAPACITY; i++) {
      tryConsumeRoomToken(p, "room-a", t0);
    }
    expect(tryConsumeRoomToken(p, "room-a", t0).ok).toBe(false);
    // Room-b has its own capacity.
    expect(tryConsumeRoomToken(p, "room-b", t0).ok).toBe(true);
  });
});

describe("tryReserveDailyQuota", () => {
  test("succeeds while under cap, returns remaining count", () => {
    const p = freshProfile({ max_per_day: 3, today_count: 0 });
    const t0 = Date.parse("2026-05-12T10:00:00Z");
    const r = tryReserveDailyQuota(p, t0);
    expect(r.ok).toBe(true);
    expect(p.today_count).toBe(1);
    expect(r.remaining).toBe(2);
  });

  test("fails at the cap", () => {
    const p = freshProfile({ max_per_day: 2, today_count: 2 });
    // Use the same date as the profile to avoid rollover masking the cap.
    const t0 = Date.parse("2026-05-12T10:00:00Z");
    p.today_date = isoDate(t0);
    const r = tryReserveDailyQuota(p, t0);
    expect(r.ok).toBe(false);
    expect(p.today_count).toBe(2); // unchanged
  });

  test("rolls over to a fresh count on date change", () => {
    const yesterday = Date.parse("2026-05-11T20:00:00Z");
    const today = Date.parse("2026-05-13T08:00:00Z");
    const p = freshProfile({
      max_per_day: 5,
      today_count: 5,
      today_date: isoDate(yesterday),
    });
    const r = tryReserveDailyQuota(p, today);
    expect(r.ok).toBe(true);
    expect(p.today_date).toBe(isoDate(today));
    expect(p.today_count).toBe(1);
  });
});

function isoDate(ms: number): string {
  const d = new Date(ms);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${dd}`;
}
