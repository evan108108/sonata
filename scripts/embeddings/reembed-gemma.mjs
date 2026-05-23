#!/usr/bin/env node --experimental-sqlite
// reembed-gemma.mjs — cut Sonata's memory embeddings over to local EmbeddingGemma-300m.
//
// Re-embeds every row in memoryEmbeddings with EmbeddingGemma-300m (768-dim) served by
// a local llama-server, and rewrites each row's embedding BLOB + model + dimensions in
// place. The previous (nomic, 768-dim) vectors live in a different space, so the whole
// stored corpus must be rebuilt for recall to work after the cutover.
//
// MUST be run with the Sonata app STOPPED (no concurrent GRDB writes) and with a
// llama-server serving the SAME GGUF the app uses at query time:
//
//   llama-server -m ~/.sonata/bin/embeddinggemma-300m-Q8_0 \
//     --embedding --pooling mean --host 127.0.0.1 --port 7712 \
//     --ctx-size 2048 --batch-size 2048 --ubatch-size 2048
//
// Run:   node --experimental-sqlite reembed-gemma.mjs
// Flags (env): DRY=1 (embed + report, never write)   LIMIT=N (first N rows)
//              SONATA_DB=path   EMBED_URL=http://127.0.0.1:PORT/v1/embeddings   BATCH=N
//
// Design: embed-phase then write-phase. All embedding (slow) happens first into
// memory; only then is a single atomic transaction applied. If any embed fails, the
// DB is never touched. A fresh backup should exist regardless.
//
// Embedding semantics MATCH the live EmbeddingServerManager exactly: prefix the doc
// with "title: none | text: " and clip to 4000 chars. EmbeddingGemma's context is
// 2048 tokens; dense text runs ~2.5 chars/token, so 6000 chars (the original guess)
// overran to ~2400 tokens and 500'd — 4000 chars stays under 2048 even when dense,
// with room for the prefix. Clipping (rather
// than chunk+pool) keeps stored corpus vectors identical to what the app produces for
// the same text at store time. Only ~6 of 26.7k memories exceed this.
//
// BLOB format matches Swift: packFloatsForAction = Data(buffer: [Float]); unpackFloats
// reads Float32 — little-endian Float32, 4 bytes each. Written with writeFloatLE.

import { DatabaseSync } from "node:sqlite";
import os from "node:os";

const DB = process.env.SONATA_DB || `${os.homedir()}/.sonata/sonata.db`;
const SERVER = process.env.EMBED_URL || "http://127.0.0.1:7712/v1/embeddings";
const MODEL_ID = "embeddinggemma-300m"; // EmbeddingProvider.local.modelId
const DIMS = 768;
const DOC_PREFIX = "title: none | text: ";
const MAXCHARS = 4000; // matches EmbeddingServerManager.maxInputChars
const BATCH = Number(process.env.BATCH || 8);
const DRY = process.env.DRY === "1";
const LIMIT = process.env.LIMIT ? parseInt(process.env.LIMIT, 10) : 0;

const clean = (s) => (s || "").replace(/\s+/g, " ").trim().slice(0, MAXCHARS);

// POST already-prefixed inputs to llama-server; returns vectors in input order.
// Robust to unordered responses (OpenAI shape carries .index) and transient slowness:
// each request has its own timeout and retries with backoff.
async function embedRaw(inputs, attempt = 0) {
  let res;
  try {
    res = await fetch(SERVER, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ input: inputs, model: "embeddinggemma-300m" }),
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
for (let i = 0; i < rows.length; i += BATCH) {
  const slice = rows.slice(i, i + BATCH);
  const embs = await embedRaw(slice.map((r) => DOC_PREFIX + clean(r.content)));
  for (let k = 0; k < slice.length; k++) packed.set(slice[k].eid, packLE(embs[k]));
  if (packed.size % 1000 < BATCH) {
    const rate = packed.size / ((Date.now() - t0) / 1000);
    console.error(`  embedded ${packed.size}/${rows.length}  (${rate.toFixed(0)}/s)`);
  }
}
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
  for (const [eid, buf] of packed) { upd.run(buf, MODEL_ID, DIMS, eid); n++; }
  db.exec("COMMIT");
  console.error(`COMMIT — updated ${n} rows to ${MODEL_ID} / ${DIMS}-dim`);
} catch (e) {
  db.exec("ROLLBACK");
  console.error("ROLLBACK — DB unchanged:", e.message);
  db.close();
  process.exit(1);
}
db.close();
