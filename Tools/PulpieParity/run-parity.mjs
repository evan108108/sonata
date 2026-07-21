/**
 * Parity harness: pulpie-simplify.js (JS/DOM) vs pulpie.simplify() (Python/lxml).
 *
 * For each corpus page it renders the saved HTML into a DOM, runs the JS port,
 * asks the reference service for the Python truth, and diffs block-by-block.
 *
 * Tolerance: whitespace is normalized on both sides before comparison (the two
 * serializers differ in how they emit insignificant whitespace). Block COUNT
 * and block TEXT must match exactly.
 *
 *   node run-parity.mjs [--verbose] [--page <substring>]
 */
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';

import { simplify } from '../../Sources/Sonata/Resources/web/pulpie-simplify.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const CORPUS = join(HERE, 'corpus');
const SERVICE = 'http://127.0.0.1:8765/simplify';

const argv = process.argv.slice(2);
const VERBOSE = argv.includes('--verbose');
const pageFilter = argv.includes('--page') ? argv[argv.indexOf('--page') + 1] : null;

/** Whitespace-normalize for comparison — the documented tolerance. */
const norm = (s) => (s ?? '').replace(/\s+/g, ' ').trim();

/** Longest-common-subsequence alignment so one inserted block doesn't cascade. */
function align(a, b) {
  const n = a.length, m = b.length;
  const dp = Array.from({ length: n + 1 }, () => new Int32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const ops = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { ops.push(['same', i, j]); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) { ops.push(['js-only', i, -1]); i++; }
    else { ops.push(['py-only', -1, j]); j++; }
  }
  while (i < n) ops.push(['js-only', i++, -1]);
  while (j < m) ops.push(['py-only', -1, j++]);
  return ops;
}

async function pythonSimplify(html) {
  const res = await fetch(SERVICE, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ html, cutoff_length: 500 }),
  });
  if (!res.ok) throw new Error(`service ${res.status}: ${await res.text()}`);
  return res.json();
}

const files = readdirSync(CORPUS).filter((f) => f.endsWith('.html')).sort()
  .filter((f) => !pageFilter || f.includes(pageFilter));

const report = [];
let totalJs = 0, totalPy = 0, totalMatch = 0;

for (const file of files) {
  const html = readFileSync(join(CORPUS, file), 'utf8');

  const t0 = Date.now();
  const dom = new JSDOM(html);
  const parseMs = Date.now() - t0;

  const t1 = Date.now();
  const jsResult = simplify({ root: dom.window.document.documentElement });
  const jsMs = Date.now() - t1;

  const py = await pythonSimplify(html);

  const jsTexts = jsResult.blocks.map((b) => norm(b.text));
  const pyTexts = py.blocks.map((b) => norm(b.text));

  const ops = align(jsTexts, pyTexts);
  const same = ops.filter((o) => o[0] === 'same').length;
  const jsOnly = ops.filter((o) => o[0] === 'js-only');
  const pyOnly = ops.filter((o) => o[0] === 'py-only');

  totalJs += jsTexts.length;
  totalPy += pyTexts.length;
  totalMatch += same;

  // How much of the page's actual content survived on each side.
  const jsChars = jsTexts.join('').length;
  const pyChars = pyTexts.join('').length;

  // data-pulpie-id coverage: every block should be reachable from the DOM.
  const marked = dom.window.document.querySelectorAll('[data-pulpie-id]');
  const markedIds = new Set();
  for (const el of marked) for (const id of el.getAttribute('data-pulpie-id').split(' ')) markedIds.add(id);

  const entry = {
    file,
    inputBytes: html.length,
    jsBlocks: jsTexts.length,
    pyBlocks: pyTexts.length,
    exactTextMatches: same,
    jsOnly: jsOnly.length,
    pyOnly: pyOnly.length,
    matchRate: pyTexts.length ? +(same / Math.max(jsTexts.length, pyTexts.length) * 100).toFixed(2) : 0,
    jsTextChars: jsChars,
    pyTextChars: pyChars,
    charRatio: pyChars ? +(jsChars / pyChars).toFixed(4) : 0,
    markedElements: marked.length,
    markedIds: markedIds.size,
    unmarkedBlocks: jsTexts.length - markedIds.size,
    jsdomParseMs: parseMs,
    jsSimplifyMs: jsMs,
    pySimplifyMs: py.simplify_ms,
  };
  report.push(entry);

  console.log(`\n=== ${file} (${(html.length / 1024).toFixed(0)} KB) ===`);
  console.log(`  blocks   js=${entry.jsBlocks}  py=${entry.pyBlocks}  matched=${same}  (${entry.matchRate}%)`);
  console.log(`  text     js=${jsChars} py=${pyChars} chars  ratio=${entry.charRatio}`);
  console.log(`  marking  ${marked.length} elements carry ${markedIds.size}/${jsTexts.length} ids`);
  console.log(`  timing   jsdom-parse=${parseMs}ms  js-simplify=${jsMs}ms  py-simplify=${py.simplify_ms}ms`);

  if (VERBOSE && (jsOnly.length || pyOnly.length)) {
    console.log(`  --- js-only (${jsOnly.length}) ---`);
    for (const [, i] of jsOnly.slice(0, 15)) console.log(`    +[${i}] ${JSON.stringify(jsTexts[i].slice(0, 110))}`);
    console.log(`  --- py-only (${pyOnly.length}) ---`);
    for (const [, , j] of pyOnly.slice(0, 15)) console.log(`    -[${j}] ${JSON.stringify(pyTexts[j].slice(0, 110))}`);
  }

  writeFileSync(join(HERE, `out-${file}.json`), JSON.stringify({
    js: jsResult.blocks, py: py.blocks, ops,
  }, null, 2));
}

console.log('\n================ SUMMARY ================');
console.table(report.map((r) => ({
  page: r.file.replace('.html', ''),
  js: r.jsBlocks, py: r.pyBlocks, matched: r.exactTextMatches,
  'match%': r.matchRate, 'char ratio': r.charRatio,
  'js ms': r.jsSimplifyMs, 'py ms': r.pySimplifyMs,
})));
console.log(`TOTAL  js=${totalJs}  py=${totalPy}  matched=${totalMatch}  ` +
  `(${(totalMatch / Math.max(totalJs, totalPy) * 100).toFixed(2)}%)`);
writeFileSync(join(HERE, 'parity-report.json'), JSON.stringify(report, null, 2));
