#!/usr/bin/env node
// Regenerates the classifier parity fixtures from the Python pulpie service.
//
// These are the CLASSIFIER's inputs and verdicts: the block strings that get
// tokenized, plus the label the Python model assigns to each. Distinct from
// ../pulpie-golden, which freezes stage 2/3 (simplify + markdown) output for a
// different article and cannot exercise the model.
//
//   PULPIE_CORPUS=/path/to/corpus node regenerate.mjs
//
// Corpus pages (browser-rendered HTML, captured 2026-07-21):
//   wikipedia_rag       en.wikipedia.org/wiki/Retrieval-augmented_generation
//   usaspending_dod     usaspending.gov/agency/department-of-defense?fy=2025
//   anthropic_newsroom  anthropic.com/news
//   chicago_permits     data.cityofchicago.org/Buildings/Building-Permits/ydr8-5enu
//                       (<script>/<style>/comments stripped in-page before
//                        capture — provably a no-op for pulpie, which drops
//                        those tags in simplify() anyway)
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const SERVICE = process.env.PULPIE_SERVICE ?? 'http://127.0.0.1:8765';
const CORPUS = process.env.PULPIE_CORPUS;
const OUT = new URL('.', import.meta.url).pathname;

if (!CORPUS) {
  console.error('set PULPIE_CORPUS to the directory holding the rendered .html corpus');
  process.exit(2);
}

async function post(path, payload) {
  const r = await fetch(SERVICE + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  if (!r.ok) throw new Error(`${path} -> HTTP ${r.status}`);
  return r.json();
}

const index = [];
for (const file of readdirSync(CORPUS).filter((f) => f.endsWith('.html')).sort()) {
  const name = file.replace(/\.html$/, '');
  const html = readFileSync(join(CORPUS, file), 'utf8');

  const simp = await post('/simplify', { html });
  const cls = await post('/classify', { simplified_html: simp.simplified_html });

  // Block order is document order; item_id is the join key back to labels.
  const blocks = simp.blocks.map((b) => ({
    itemId: b.item_id == null ? null : String(b.item_id),
    html: b.html,
  }));
  const labels = blocks.map((b) => (b.itemId == null ? null : cls.labels[b.itemId] ?? null));

  const missing = labels.filter((l) => l === null).length;
  const fixture = {
    page: name,
    blockCount: blocks.length,
    mainCount: labels.filter((l) => l === 'main').length,
    otherCount: labels.filter((l) => l === 'other').length,
    blocks,
    labels,
  };
  const path = join(OUT, `${name}.json`);
  writeFileSync(path, JSON.stringify(fixture, null, 1));
  const bytes = readFileSync(path).length;
  index.push({ name, blocks: blocks.length, main: fixture.mainCount, bytes });
  console.log(
    `${name.padEnd(20)} blocks=${String(blocks.length).padStart(4)} ` +
      `main=${String(fixture.mainCount).padStart(4)} unlabelled=${missing} ` +
      `${(bytes / 1024).toFixed(0)}KB`,
  );
}

writeFileSync(join(OUT, 'index.json'), JSON.stringify(index, null, 1));
console.log(`\ntotal blocks: ${index.reduce((a, b) => a + b.blocks, 0)}`);
