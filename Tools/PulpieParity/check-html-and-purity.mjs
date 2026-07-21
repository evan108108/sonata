/**
 * Two stricter checks on top of run-parity.mjs:
 *
 *  1. MARKUP parity — the classifier tokenizes each block's HTML, not its text,
 *     so compare the serialized blocks, not just their visible strings.
 *  2. PURITY — assert simplify() mutates nothing in the live DOM except
 *     data-pulpie-id, and that a second run is idempotent.
 */
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';
import { simplify } from '../../Sources/Sonata/Resources/web/pulpie-simplify.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const CORPUS = join(HERE, 'corpus');

const norm = (s) => (s ?? '').replace(/\s+/g, ' ').trim();

/** Strip the document tail extract_blocks() leaves on Python's final block. */
const stripDocTail = (h) => h.replace(/<\/body><\/html>$/, '').trim();

/** Serialize the DOM with data-pulpie-id removed — the purity baseline. */
function domFingerprint(document) {
  const html = document.documentElement.outerHTML;
  return html.replace(/ data-pulpie-id="[^"]*"/g, '');
}

let totalBlocks = 0, htmlExact = 0, htmlNormOnly = 0, htmlDiff = 0;
const diffs = [];

for (const file of readdirSync(CORPUS).filter((f) => f.endsWith('.html')).sort()) {
  const html = readFileSync(join(CORPUS, file), 'utf8');
  const dom = new JSDOM(html);
  const doc = dom.window.document;

  const before = domFingerprint(doc);
  const r1 = simplify({ root: doc.documentElement });
  const after = domFingerprint(doc);

  const pure = before === after;

  // Idempotency: a second run must produce identical blocks and identical marks.
  const marks1 = [...doc.querySelectorAll('[data-pulpie-id]')]
    .map((e) => e.getAttribute('data-pulpie-id')).join('|');
  const r2 = simplify({ root: doc.documentElement });
  const marks2 = [...doc.querySelectorAll('[data-pulpie-id]')]
    .map((e) => e.getAttribute('data-pulpie-id')).join('|');
  const idempotent = marks1 === marks2
    && JSON.stringify(r1.blocks) === JSON.stringify(r2.blocks);

  const py = JSON.parse(readFileSync(join(HERE, `out-${file}.json`), 'utf8')).py;

  let exact = 0, normOnly = 0, diff = 0;
  for (let i = 0; i < Math.min(r1.blocks.length, py.length); i++) {
    const j = r1.blocks[i].html;
    const p = stripDocTail(py[i].html);
    if (j === p) exact++;
    else if (norm(j) === norm(p)) normOnly++;
    else {
      diff++;
      if (diffs.length < 12) diffs.push({ file, i, js: j.slice(0, 200), py: p.slice(0, 200) });
    }
  }
  totalBlocks += r1.blocks.length; htmlExact += exact; htmlNormOnly += normOnly; htmlDiff += diff;

  console.log(`${file}`);
  console.log(`  markup   exact=${exact}  ws-only=${normOnly}  differing=${diff}  / ${r1.blocks.length}`);
  console.log(`  pure     ${pure ? 'YES — no DOM change beyond data-pulpie-id' : 'NO — DOM MUTATED'}`);
  console.log(`  idempot. ${idempotent ? 'YES' : 'NO'}`);
  if (!pure) {
    for (let k = 0; k < Math.min(before.length, after.length); k++) {
      if (before[k] !== after[k]) {
        console.log(`    first divergence @${k}: ${JSON.stringify(before.slice(k - 60, k + 60))}`);
        console.log(`                     vs: ${JSON.stringify(after.slice(k - 60, k + 60))}`);
        break;
      }
    }
  }
}

console.log(`\nMARKUP TOTAL  exact=${htmlExact}  ws-only=${htmlNormOnly}  differing=${htmlDiff}  / ${totalBlocks}`);
for (const d of diffs) {
  console.log(`\n[${d.file} #${d.i}]\n  js: ${JSON.stringify(d.js)}\n  py: ${JSON.stringify(d.py)}`);
}
