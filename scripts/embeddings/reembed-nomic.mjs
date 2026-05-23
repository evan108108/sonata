#!/usr/bin/env node --experimental-sqlite
// reembed-nomic.mjs — cut Sonata's memory embeddings over to local nomic.
//
// Re-embeds every existing row in memoryEmbeddings (currently OpenRouter
// text-embedding-3-small, 1536-dim) with nomic-embed-text-v1.5 (768-dim) served
// by a local llama-server, and rewrites each row's embedding BLOB + model +
// dimensions in place. The two vector spaces are incomparable, so the whole
// stored corpus must be rebuilt for recall to work after the cutover.
//
// MUST be run with the Sonata app STOPPED (no concurrent GRDB writes) and with
// a llama-server already serving the SAME GGUF the app uses at query time:
//
//   llama-server -m ~/.sonata/bin/nomic-embed-text-v1.5-Q8_0 \
//     --embedding --pooling mean --host 127.0.0.1 --port 7712 --ctx-size 8192
//
// Run:   node --experimental-sqlite reembed-nomic.mjs
// Flags (env): DRY=1 (embed + report, never write)   LIMIT=N (first N rows)
//
// Design: embed-phase then write-phase. All embedding (slow, network) happens
// first into memory; only then is a single atomic transaction applied. If any
// embed fails, the DB is never touched. A fresh backup should exist regardless.
//
// BLOB format must match Swift: packFloatsForAction = Data(buffer: [Float]) and
// unpackFloats reads Float (Float32) — i.e. little-endian Float32, 4 bytes each
// on arm64. We write with Buffer.writeFloatLE to match exactly.

import { DatabaseSync } from "node:sqlite";
import os from "node:os";

const DB = process.env.SONATA_DB || `${os.homedir()}/.sonata/sonata.db`;
const SERVER = process.env.EMBED_URL || "http://127.0.0.1:7712/v1/embeddings";
const MODEL_ID = "nomic-embed-text-v1.5"; // EmbeddingProvider.local.modelId
const DIMS = 768;
const BATCH = Number(process.env.BATCH || 8); // single-chunk docs per request
// nomic-embed-text-v1.5's trained context is 2048 tokens (--ctx-size can't
// extend it — llama-server 400s on longer input). ~4000 chars stays well under
// 2048 tokens even for dense text, with room for the "search_document: " prefix.
const CHUNK_CHARS = 4000;
const DRY = process.env.DRY === "1";
const LIMIT = process.env.LIMIT ? parseInt(process.env.LIMIT, 10) : 0;

const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
const chunksOf = (s) => {
  const out = [];
  for (let i = 0; i < s.length; i += CHUNK_CHARS) out.push(s.slice(i, i + CHUNK_CHARS));
  return out.length ? out : [""];
};

// L2-normalized mean of one or more chunk vectors. A doc longer than the model
// context is split into chunks, each embedded, then recombined here — same
// strategy the nomic eval used (embed-nomic.mjs meanPool) so long docs still
// yield one in-space vector instead of being truncated or skipped.
function meanPoolL2(vecs) {
  const d = vecs[0].length;
  const out = new Array(d).fill(0);
  for (const v of vecs) for (let i = 0; i < d; i++) out[i] += v[i];
  let nrm = 0;
  for (let i = 0; i < d; i++) { out[i] /= vecs.length; nrm += out[i] * out[i]; }
  nrm = Math.sqrt(nrm) || 1;
  for (let i = 0; i < d; i++) out[i] /= nrm;
  return out;
}

// POST already-prefixed inputs to llama-server; returns vectors in input order.
// Robust to unordered responses (OpenAI shape carries .index) and to transient
// slowness: each request has its own timeout and is retried with backoff, so a
// single hung response can't sink a multi-thousand-row run.
async function embedRaw(inputs, attempt = 0) {
  let res;
  try {
    res = await fetch(SERVER, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ input: inputs, model: "nomic" }),
      signal: AbortSignal.timeout(90000),
    });
    if (!res.ok) throw new Error(`server ${res.status}: ${(await res.text()).slice(0, 300)}`);
  } catch (e) {
    if (attempt >= 4) throw e;
    await new Promise((r) => setTimeout(r, 1000 * 2 ** attempt));
    return embedRaw(inputs, attempt + 1);
  }
  const j = await res.json();
  const out = new Array(inputs.length);
  j.data.forEach((d, i) => { out[Number.isInteger(d.index) ? d.index : i] = d.embedding; });
  for (let i = 0; i < out.length; i++) {
    if (!Array.isArray(out[i]) || out[i].length !== DIMS) {
      throw new Error(`bad embedding at index ${i}: dims=${out[i] && out[i].length}`);
    }
  }
  return out;
}

// Embed one long doc by chunk + mean-pool.
async function embedLong(text) {
  const vecs = await embedRaw(chunksOf(clean(text)).map((c) => "search_document: " + c));
  return meanPoolL2(vecs);
}

function packLE(floats) {
  const buf = Buffer.allocUnsafe(floats.length * 4);
  for (let i = 0; i < floats.length; i++) buf.writeFloatLE(floats[i], i * 4);
  return buf;
}

const db = new DatabaseSync(DB);
const rows = db
  .prepare(
    `SELECT e.id AS eid, m.content AS content
       FROM memoryEmbeddings e JOIN memories m ON m.id = e.memoryId
      ORDER BY e.id` + (LIMIT ? ` LIMIT ${LIMIT}` : "")
  )
  .all();
console.error(`rows to re-embed: ${rows.length}${DRY ? "  (DRY RUN — no writes)" : ""}`);

// ---- embed phase (no DB lock) ----
const packed = new Map(); // eid -> Buffer
const t0 = Date.now();

// Partition: most docs fit one chunk and batch across docs; the rare long doc
// is chunked + mean-pooled on its own.
const short = [];
const long = [];
for (const r of rows) (clean(r.content).length <= CHUNK_CHARS ? short : long).push(r);
console.error(`  ${short.length} single-chunk, ${long.length} long (chunk+pool)`);

for (let i = 0; i < short.length; i += BATCH) {
  const slice = short.slice(i, i + BATCH);
  const embs = await embedRaw(slice.map((r) => "search_document: " + clean(r.content)));
  for (let k = 0; k < slice.length; k++) packed.set(slice[k].eid, packLE(embs[k]));
  if (packed.size % 1000 < BATCH) {
    const rate = packed.size / ((Date.now() - t0) / 1000);
    console.error(`  embedded ${packed.size}/${rows.length}  (${rate.toFixed(0)}/s)`);
  }
}
for (const r of long) packed.set(r.eid, packLE(await embedLong(r.content)));
console.error(`embedded all ${packed.size} in ${((Date.now() - t0) / 1000).toFixed(1)}s`);

if (DRY) {
  console.error("DRY RUN — skipping writes.");
  db.close();
  process.exit(0);
}

// ---- write phase (single atomic transaction) ----
const upd = db.prepare(
  `UPDATE memoryEmbeddings SET embedding = ?, model = ?, dimensions = ? WHERE id = ?`
);
db.exec("BEGIN");
try {
  let n = 0;
  for (const [eid, buf] of packed) {
    upd.run(buf, MODEL_ID, DIMS, eid);
    n++;
  }
  db.exec("COMMIT");
  console.error(`COMMIT — updated ${n} rows to ${MODEL_ID} / ${DIMS}-dim`);
} catch (e) {
  db.exec("ROLLBACK");
  console.error("ROLLBACK — DB unchanged:", e.message);
  db.close();
  process.exit(1);
}
db.close();
