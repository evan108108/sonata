// Unit coverage for buildAudienceClaim's optional `profile` field and the
// inverse `parseClaimProfile`. Wire-format-only — no network or signing.

import { describe, expect, it } from "bun:test";
import { buildAudienceClaim, parseClaimProfile } from "../src/audience-events";

const fixedInput = {
  audIdPub: "a".repeat(64),
  slug: "demo",
  epoch: 7,
  invitePub: "b".repeat(64),
  inviterPub: "c".repeat(64),
  claimPub: "d".repeat(64),
};

describe("buildAudienceClaim", () => {
  it("omits the profile field when none supplied (back-compat with kind:30522 v0)", () => {
    const tpl = buildAudienceClaim(fixedInput);
    const obj = JSON.parse(tpl.content);
    expect(obj.profile).toBeUndefined();
    expect(obj.audience).toBe("demo");
    expect(obj.claimPubkey).toBe(fixedInput.claimPub);
  });

  it("embeds nickname + bio when both supplied", () => {
    const tpl = buildAudienceClaim({
      ...fixedInput,
      profile: { nickname: "Sona", bio: "knowledge in toki pona" },
    });
    const obj = JSON.parse(tpl.content);
    expect(obj.profile).toEqual({ nickname: "Sona", bio: "knowledge in toki pona" });
  });

  it("trims and length-caps profile strings (nickname ≤200, bio ≤500)", () => {
    const longNick = "a".repeat(300);
    const longBio = "b".repeat(700);
    const tpl = buildAudienceClaim({
      ...fixedInput,
      profile: { nickname: `  ${longNick}  `, bio: `\t${longBio}\n` },
    });
    const obj = JSON.parse(tpl.content);
    expect(obj.profile.nickname).toHaveLength(200);
    expect(obj.profile.bio).toHaveLength(500);
  });

  it("drops empty / whitespace-only strings instead of writing them", () => {
    const tpl = buildAudienceClaim({
      ...fixedInput,
      profile: { nickname: "   ", bio: "" },
    });
    const obj = JSON.parse(tpl.content);
    expect(obj.profile).toBeUndefined();
  });

  it("writes bio-only when nickname missing (and vice versa)", () => {
    const bioOnly = JSON.parse(
      buildAudienceClaim({ ...fixedInput, profile: { bio: "just-a-bio" } }).content,
    );
    expect(bioOnly.profile).toEqual({ bio: "just-a-bio" });

    const nickOnly = JSON.parse(
      buildAudienceClaim({ ...fixedInput, profile: { nickname: "just-a-name" } }).content,
    );
    expect(nickOnly.profile).toEqual({ nickname: "just-a-name" });
  });
});

describe("parseClaimProfile", () => {
  it("round-trips through buildAudienceClaim", () => {
    const tpl = buildAudienceClaim({
      ...fixedInput,
      profile: { nickname: "Scout", bio: "lead-discovery agent" },
    });
    expect(parseClaimProfile(tpl.content)).toEqual({
      nickname: "Scout",
      bio: "lead-discovery agent",
    });
  });

  it("returns null on missing content", () => {
    expect(parseClaimProfile(null)).toBeNull();
    expect(parseClaimProfile("")).toBeNull();
    expect(parseClaimProfile(undefined)).toBeNull();
  });

  it("returns null on non-JSON content", () => {
    expect(parseClaimProfile("not-json")).toBeNull();
  });

  it("returns null when JSON has no profile field", () => {
    expect(parseClaimProfile(JSON.stringify({ audience: "demo" }))).toBeNull();
  });

  it("returns null on hostile shapes (array, non-object profile)", () => {
    expect(parseClaimProfile(JSON.stringify([1, 2, 3]))).toBeNull();
    expect(parseClaimProfile(JSON.stringify({ profile: "string-not-object" }))).toBeNull();
    expect(parseClaimProfile(JSON.stringify({ profile: [] }))).toBeNull();
  });

  it("ignores non-string nickname/bio fields", () => {
    const content = JSON.stringify({ profile: { nickname: 42, bio: { nope: true } } });
    expect(parseClaimProfile(content)).toBeNull();
  });

  it("partial profiles parse to partial result", () => {
    const content = JSON.stringify({ profile: { nickname: "  Sona  " } });
    expect(parseClaimProfile(content)).toEqual({ nickname: "Sona" });
  });
});
