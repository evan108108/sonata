// Tests for the S3 SigV4 client — pure-fn signature helpers + config
// validation. Covers structural correctness of the signature output,
// path-style vs virtual-hosted URL building, mock-fetch round-trip, and
// the typed XML error parser.

import { describe, expect, it } from "bun:test";

import {
  buildS3Url,
  encodeS3Key,
  parseS3Error,
  signGetObject,
  signHeadObject,
  signPutObject,
  validateS3Credentials,
  validateStorageConfig,
} from "../../src/storage/s3";

const KEY_ID = "AKIAIOSFODNN7EXAMPLE";
const SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
const NOW = "20260513T120000Z";

describe("buildS3Url", () => {
  it("builds a path-style URL by default", () => {
    const r = buildS3Url({
      endpoint: "https://abc.r2.cloudflarestorage.com",
      bucket: "my-studio-files",
      key: "studio/room-x/abcd1234",
    });
    expect(r.url).toBe(
      "https://abc.r2.cloudflarestorage.com/my-studio-files/studio/room-x/abcd1234",
    );
    expect(r.host).toBe("abc.r2.cloudflarestorage.com");
    expect(r.canonicalUri).toBe("/my-studio-files/studio/room-x/abcd1234");
  });

  it("builds a virtual-hosted-style URL when pathStyle=false", () => {
    const r = buildS3Url({
      endpoint: "https://s3.us-east-1.amazonaws.com",
      bucket: "my-bucket",
      key: "studio/foo/bar",
      pathStyle: false,
    });
    expect(r.url).toBe(
      "https://my-bucket.s3.us-east-1.amazonaws.com/studio/foo/bar",
    );
    expect(r.host).toBe("my-bucket.s3.us-east-1.amazonaws.com");
    expect(r.canonicalUri).toBe("/studio/foo/bar");
  });

  it("defaults to https when no scheme given", () => {
    const r = buildS3Url({
      endpoint: "abc.r2.cloudflarestorage.com",
      bucket: "b",
      key: "k",
    });
    expect(r.url).toStartWith("https://");
  });

  it("strips trailing slashes from endpoint", () => {
    const r = buildS3Url({
      endpoint: "https://abc.r2.cloudflarestorage.com/",
      bucket: "b",
      key: "k",
    });
    expect(r.url).toBe("https://abc.r2.cloudflarestorage.com/b/k");
  });
});

describe("encodeS3Key", () => {
  it("preserves forward slashes in keys", () => {
    expect(encodeS3Key("studio/room-x/abcd")).toBe("studio/room-x/abcd");
  });

  it("encodes spaces and special chars per segment", () => {
    expect(encodeS3Key("a b/c+d")).toBe("a%20b/c%2Bd");
  });

  it("encodes the parens/apostrophe that encodeURIComponent leaves alone", () => {
    expect(encodeS3Key("file(1)'.txt")).toBe("file%281%29%27.txt");
  });
});

describe("signPutObject", () => {
  const baseArgs = {
    endpoint: "https://abc.r2.cloudflarestorage.com",
    region: "auto",
    bucket: "studio-files",
    key: "studio/room-x/abc123",
    accessKeyId: KEY_ID,
    secretAccessKey: SECRET,
    pathStyle: true,
    nowIsoBasic: NOW,
  };

  it("produces an Authorization header with the right structure", () => {
    const signed = signPutObject({
      ...baseArgs,
      body: new Uint8Array([1, 2, 3, 4]),
      contentType: "application/octet-stream",
    });
    expect(signed.url).toBe(
      "https://abc.r2.cloudflarestorage.com/studio-files/studio/room-x/abc123",
    );
    expect(signed.headers.Authorization).toContain("AWS4-HMAC-SHA256 ");
    expect(signed.headers.Authorization).toContain(
      `Credential=${KEY_ID}/20260513/auto/s3/aws4_request`,
    );
    expect(signed.headers.Authorization).toContain(
      "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date",
    );
    expect(signed.headers.Authorization).toMatch(/Signature=[0-9a-f]{64}/);
  });

  it("defaults to UNSIGNED-PAYLOAD content sha256", () => {
    const signed = signPutObject({
      ...baseArgs,
      body: new Uint8Array(1024),
    });
    expect(signed.headers["x-amz-content-sha256"]).toBe("UNSIGNED-PAYLOAD");
  });

  it("signs the payload when signPayload=true", () => {
    const signed = signPutObject({
      ...baseArgs,
      body: new TextEncoder().encode("hello"),
      signPayload: true,
    });
    // sha256("hello")
    expect(signed.headers["x-amz-content-sha256"]).toBe(
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
    );
  });

  it("produces a deterministic signature given fixed time + keys + body", () => {
    const a = signPutObject({
      ...baseArgs,
      body: new TextEncoder().encode("hello"),
      signPayload: true,
    });
    const b = signPutObject({
      ...baseArgs,
      body: new TextEncoder().encode("hello"),
      signPayload: true,
    });
    expect(a.headers.Authorization).toBe(b.headers.Authorization);
  });

  it("produces different signatures when only the body differs (signed payload)", () => {
    const a = signPutObject({
      ...baseArgs,
      body: new TextEncoder().encode("hello"),
      signPayload: true,
    });
    const b = signPutObject({
      ...baseArgs,
      body: new TextEncoder().encode("world"),
      signPayload: true,
    });
    expect(a.headers.Authorization).not.toBe(b.headers.Authorization);
  });

  it("differs between path-style and virtual-hosted style", () => {
    const a = signPutObject({
      ...baseArgs,
      body: new Uint8Array([1]),
      pathStyle: true,
    });
    const b = signPutObject({
      ...baseArgs,
      body: new Uint8Array([1]),
      pathStyle: false,
    });
    expect(a.url).not.toBe(b.url);
    expect(a.headers.Authorization).not.toBe(b.headers.Authorization);
  });
});

describe("signGetObject / signHeadObject", () => {
  const baseArgs = {
    endpoint: "https://abc.r2.cloudflarestorage.com",
    region: "auto",
    bucket: "studio-files",
    key: "studio/room-x/abc123",
    accessKeyId: KEY_ID,
    secretAccessKey: SECRET,
    pathStyle: true,
    nowIsoBasic: NOW,
  };

  it("uses the empty-body sha256 for GET", () => {
    const r = signGetObject(baseArgs);
    expect(r.headers["x-amz-content-sha256"]).toBe(
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    );
  });

  it("uses the empty-body sha256 for HEAD", () => {
    const r = signHeadObject(baseArgs);
    expect(r.headers["x-amz-content-sha256"]).toBe(
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    );
    expect(r.headers.Authorization).toContain("AWS4-HMAC-SHA256");
  });

  it("includes x-amz-date in the signed headers list", () => {
    const r = signGetObject(baseArgs);
    expect(r.headers["x-amz-date"]).toBe(NOW);
    expect(r.headers.Authorization).toContain("SignedHeaders=host;x-amz-content-sha256;x-amz-date");
  });
});

describe("parseS3Error", () => {
  it("extracts code + message from an S3 XML error body", () => {
    const body =
      '<?xml version="1.0" encoding="UTF-8"?>' +
      "<Error><Code>SignatureDoesNotMatch</Code>" +
      "<Message>The request signature we calculated does not match the signature you provided. Check your key and signing method.</Message>" +
      "<RequestId>ABC123</RequestId></Error>";
    const err = parseS3Error(403, body);
    expect(err.status).toBe(403);
    expect(err.code).toBe("SignatureDoesNotMatch");
    expect(err.message).toContain("SignatureDoesNotMatch");
    expect(err.name).toBe("S3UploadError");
  });

  it("falls back to a generic code when no XML present", () => {
    const err = parseS3Error(500, "Internal Server Error");
    expect(err.code).toBe("s3_http_error");
  });
});

describe("validateStorageConfig", () => {
  it("accepts a blossom config", () => {
    const r = validateStorageConfig({ kind: "blossom", blossom_url: "https://api.4a4.ai/blossom" });
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.config.kind).toBe("blossom");
      if (r.config.kind === "blossom") {
        expect(r.config.blossom_url).toBe("https://api.4a4.ai/blossom");
      }
    }
  });

  it("accepts a full s3 config", () => {
    const r = validateStorageConfig({
      kind: "s3",
      s3_endpoint: "https://abc.r2.cloudflarestorage.com",
      s3_region: "auto",
      s3_bucket: "studio-files",
      s3_path_style: true,
      s3_access_key_id_keychain_ref: "studio-room-x-s3-access-key",
      s3_secret_access_key_keychain_ref: "studio-room-x-s3-secret",
    });
    expect(r.ok).toBe(true);
  });

  it("rejects unknown kind", () => {
    const r = validateStorageConfig({ kind: "magic" });
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.error.code).toBe("invalid_storage_config");
      expect(r.error.field).toBe("kind");
    }
  });

  it("rejects s3 config missing required fields", () => {
    const r = validateStorageConfig({ kind: "s3", s3_endpoint: "x" });
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.error.code).toBe("invalid_storage_config");
      expect(r.error.field).toBe("s3_region");
    }
  });

  it("rejects s3 config with non-bool path_style", () => {
    const r = validateStorageConfig({
      kind: "s3",
      s3_endpoint: "https://x",
      s3_region: "auto",
      s3_bucket: "b",
      s3_path_style: "true",
      s3_access_key_id_keychain_ref: "x",
      s3_secret_access_key_keychain_ref: "y",
    });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error.field).toBe("s3_path_style");
  });

  it("rejects non-object payloads", () => {
    expect(validateStorageConfig(null).ok).toBe(false);
    expect(validateStorageConfig("blossom").ok).toBe(false);
    expect(validateStorageConfig(42).ok).toBe(false);
  });
});

describe("validateS3Credentials", () => {
  it("accepts a valid credential pair", () => {
    const r = validateS3Credentials({ access_key_id: "AKIA…", secret_access_key: "secret" });
    expect(r.ok).toBe(true);
  });

  it("rejects missing or empty fields", () => {
    expect(validateS3Credentials({ access_key_id: "x" }).ok).toBe(false);
    expect(validateS3Credentials({ access_key_id: "", secret_access_key: "y" }).ok).toBe(false);
    expect(validateS3Credentials(null).ok).toBe(false);
  });
});

describe("end-to-end mock fetch — PUT 200", () => {
  it("signs a PUT and a mock R2 returns 200", async () => {
    const signed = signPutObject({
      endpoint: "https://abc.r2.cloudflarestorage.com",
      region: "auto",
      bucket: "studio-files",
      key: "studio/room-x/test-sha",
      body: new TextEncoder().encode("ciphertext"),
      accessKeyId: KEY_ID,
      secretAccessKey: SECRET,
      pathStyle: true,
      contentType: "application/octet-stream",
      nowIsoBasic: NOW,
    });

    const captured: { url?: string; method?: string; auth?: string } = {};
    const fetcher: typeof fetch = async (input, init) => {
      captured.url = typeof input === "string" ? input : (input as Request).url;
      captured.method = init?.method ?? "GET";
      const h = new Headers(init?.headers ?? {});
      captured.auth = h.get("Authorization") ?? "";
      return new Response("", { status: 200 });
    };

    const res = await fetcher(signed.url, {
      method: "PUT",
      headers: signed.headers,
      body: new TextEncoder().encode("ciphertext"),
    });
    expect(res.status).toBe(200);
    expect(captured.method).toBe("PUT");
    expect(captured.auth).toContain("AWS4-HMAC-SHA256");
    expect(captured.url).toContain("/studio-files/studio/room-x/test-sha");
  });
});

describe("end-to-end mock fetch — PUT 403 SignatureDoesNotMatch", () => {
  it("wraps an S3 error body in a typed S3UploadError", async () => {
    const fetcher: typeof fetch = async () =>
      new Response(
        "<Error><Code>SignatureDoesNotMatch</Code><Message>bad sig</Message></Error>",
        { status: 403 },
      );
    const res = await fetcher("https://example/", { method: "PUT" });
    const body = await res.text();
    const err = parseS3Error(res.status, body);
    expect(err.status).toBe(403);
    expect(err.code).toBe("SignatureDoesNotMatch");
  });
});
