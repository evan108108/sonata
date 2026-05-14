// parseInviteUrl — round-trips the gateway-emitted current URL form
// (`?k=<bech32>` with no invite_pub on path) plus the legacy form
// (`?priv=<bech32>` with invite_pub on path), and rejects malformed
// inputs. Phase 3 §4.1 acceptance: feed `RawInviteResponse.https_url` and
// reach the same {slug, epoch, invitePub} the gateway minted.

import { describe, expect, it } from "bun:test";
import { schnorr } from "@noble/curves/secp256k1.js";
import { bytesToHex, randomBytes } from "@noble/hashes/utils.js";
import { bech32 } from "@scure/base";

import { parseInviteUrl } from "../../src/actions/room";

const INVITE_HRP = "4ainv";
const BECH32_LIMIT = 256;

function encodeBech32Priv(priv: Uint8Array): string {
  return bech32.encode(INVITE_HRP, bech32.toWords(priv), BECH32_LIMIT);
}

function makeInvite(): { priv: Uint8Array; privBech: string; pubHex: string } {
  const priv = randomBytes(32);
  return {
    priv,
    privBech: encodeBech32Priv(priv),
    pubHex: bytesToHex(schnorr.getPublicKey(priv)),
  };
}

describe("parseInviteUrl — gateway-emitted current form", () => {
  it("parses s4a://invite/<slug>/<epoch>?k=<bech32>", () => {
    const inv = makeInvite();
    const url = `s4a://invite/test-slug/3?k=${inv.privBech}`;
    const parsed = parseInviteUrl(url);
    expect(parsed.slug).toBe("test-slug");
    expect(parsed.epoch).toBe(3);
    expect(parsed.invitePub).toBe(inv.pubHex);
    expect(parsed.invitePrivBech).toBe(inv.privBech);
    expect(bytesToHex(parsed.invitePrivBytes)).toBe(bytesToHex(inv.priv));
  });

  it("parses https://<host>/invite/<slug>/<epoch>?k=<bech32>", () => {
    const inv = makeInvite();
    const url = `https://claim.4a4.ai/invite/fed-rt-abc/2?k=${inv.privBech}`;
    const parsed = parseInviteUrl(url);
    expect(parsed.slug).toBe("fed-rt-abc");
    expect(parsed.epoch).toBe(2);
    expect(parsed.invitePub).toBe(inv.pubHex);
  });

  it("derives invite_pub from priv when path omits it", () => {
    const inv = makeInvite();
    const parsed = parseInviteUrl(`s4a://invite/derive-test/1?k=${inv.privBech}`);
    expect(parsed.invitePub).toBe(inv.pubHex);
  });
});

describe("parseInviteUrl — legacy form (back-compat)", () => {
  it("parses s4a://invite/<slug>/<epoch>/<invite_pub>?priv=<bech32>", () => {
    const inv = makeInvite();
    const url = `s4a://invite/legacy-slug/5/${inv.pubHex}?priv=${inv.privBech}`;
    const parsed = parseInviteUrl(url);
    expect(parsed.slug).toBe("legacy-slug");
    expect(parsed.epoch).toBe(5);
    expect(parsed.invitePub).toBe(inv.pubHex);
  });

  it("parses https://<host>/invite/<slug>/<epoch>/<invite_pub>?priv=<bech32>", () => {
    const inv = makeInvite();
    const url = `https://claim.4a4.ai/invite/legacy-https/7/${inv.pubHex}?priv=${inv.privBech}`;
    const parsed = parseInviteUrl(url);
    expect(parsed.slug).toBe("legacy-https");
    expect(parsed.epoch).toBe(7);
    expect(parsed.invitePub).toBe(inv.pubHex);
  });

  it("accepts bare 64-hex priv on the legacy form", () => {
    const inv = makeInvite();
    const privHex = bytesToHex(inv.priv);
    const url = `s4a://invite/hex-priv/1/${inv.pubHex}?priv=${privHex}`;
    const parsed = parseInviteUrl(url);
    expect(parsed.invitePub).toBe(inv.pubHex);
    expect(bytesToHex(parsed.invitePrivBytes)).toBe(privHex);
  });

  it("rejects when path invite_pub does not match the priv", () => {
    const inv = makeInvite();
    const wrong = makeInvite();
    const url = `s4a://invite/mismatch/1/${wrong.pubHex}?priv=${inv.privBech}`;
    expect(() => parseInviteUrl(url)).toThrow(/invite_pub does not match/);
  });
});

describe("parseInviteUrl — rejection", () => {
  it("rejects unknown URL scheme", () => {
    expect(() => parseInviteUrl("ftp://example.com/invite/a/1?k=4ainv1xxx"))
      .toThrow(/s4a:\/\/ or https:\/\//);
  });

  it("rejects when slug is missing", () => {
    const inv = makeInvite();
    expect(() => parseInviteUrl(`s4a://invite//1?k=${inv.privBech}`))
      .toThrow(/invite_url path/);
  });

  it("rejects when epoch is not a positive integer", () => {
    const inv = makeInvite();
    expect(() => parseInviteUrl(`s4a://invite/slug/0?k=${inv.privBech}`))
      .toThrow(/epoch invalid/);
    expect(() => parseInviteUrl(`s4a://invite/slug/abc?k=${inv.privBech}`))
      .toThrow(/epoch invalid/);
  });

  it("rejects when ?k= and ?priv= are both missing", () => {
    expect(() => parseInviteUrl(`s4a://invite/slug/1`))
      .toThrow(/missing.*k.*priv/);
  });

  it("rejects bech32 priv with wrong HRP", () => {
    // npub-style: hrp=npub
    const fake = bech32.encode(
      "npub",
      bech32.toWords(randomBytes(32)),
      BECH32_LIMIT,
    );
    expect(() => parseInviteUrl(`s4a://invite/slug/1?k=${fake}`))
      .toThrow(/wrong HRP/);
  });

  it("rejects bech32 priv with bad checksum", () => {
    const inv = makeInvite();
    // Mangle one character of the checksum (last char).
    const broken = inv.privBech.slice(0, -1) + (inv.privBech.endsWith("q") ? "p" : "q");
    expect(() => parseInviteUrl(`s4a://invite/slug/1?k=${broken}`))
      .toThrow(/bech32/);
  });
});
