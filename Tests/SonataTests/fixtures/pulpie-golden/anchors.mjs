#!/usr/bin/env node
/*
 * Stage 2 -> stage 3 integration check.
 *
 *   node Tests/SonataTests/fixtures/pulpie-golden/anchors.mjs
 *
 * WHY THIS EXISTS SEPARATELY FROM parity.mjs
 * ------------------------------------------
 * parity.mjs feeds stage 3 the PYTHON pipeline's `map_html`, where every
 * `_item_id` is a single id on its own element and loose text runs are real
 * `<cc-alg-uc-text>` elements. Production feeds it STAGE 2's output, which has
 * neither: one element can carry several ids, and the runs are identified by
 * `anchor` instead of by a wrapper element. Those goldens can be 22/22 green
 * while the production path is broken — and were.
 *
 * So this runs the real stage 2 over hand-built DOMs and asserts stage 3
 * resolves each id to the right span. Offline: no Python, no model, no network.
 * Needs jsdom the same way parity.mjs does ($JSDOM_FROM to override).
 */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const HERE = import.meta.dirname;
const WEB = path.resolve(HERE, '../../../../Sources/Sonata/Resources/web');
const JSDOM_FROM = process.env.JSDOM_FROM || '/Users/evan/test/slider-captcha/react/package.json';

const { JSDOM, VirtualConsole } = createRequire(JSDOM_FROM)('jsdom');
const quiet = new VirtualConsole();

const sandbox = { console };
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(WEB, 'pulpie-markdown.js'), 'utf8'), sandbox,
  { filename: 'pulpie-markdown.js' });
const P = sandbox.PulpieMarkdown;

const { simplify } = await import(path.join(WEB, 'pulpie-simplify.js'));

let failures = 0, checks = 0;

function check(label, got, want) {
  checks++;
  const ok = typeof want === 'function' ? want(got) : got === want;
  if (ok) { console.log(`PASS  ${label}`); return; }
  failures++;
  console.log(`FAIL  ${label}`);
  console.log(`   want ${JSON.stringify(want)}`);
  console.log(`   got  ${JSON.stringify(got)}`);
}

/** Run the real two-stage pipeline. `mainIds` decides the synthetic labels. */
function pipeline(html, mainIds, { useAnchors = true } = {}) {
  const doc = new JSDOM(html, { virtualConsole: quiet }).window.document;
  const { blocks } = simplify({ root: doc.documentElement });
  const labels = {};
  for (const b of blocks) labels[String(b.item_id)] = mainIds.includes(b.item_id) ? 'main' : 'other';
  const anchors = Object.fromEntries(blocks.map((b) => [String(b.item_id), b.anchor]));
  const md = P.extractMainMarkdown(doc, labels, useAnchors ? { anchors } : {});
  return { blocks, md };
}

// ── 1. Three loose runs sharing one parent ─────────────────────────────────
// #host carries ids "1 3 5" — parent-text, child-tail{0}, child-tail{1}.
const THREE_RUNS =
  '<html><body><div id="host">FIRST-RUN<p>block one</p>SECOND-RUN<p>block two</p>THIRD-RUN</div></body></html>';

{
  const { blocks } = pipeline(THREE_RUNS, []);
  check('three-runs / stage 2 emits 5 blocks', blocks.length, 5);
  check('three-runs / anchor kinds',
    blocks.map((b) => b.anchor.kind).join(','),
    'parent-text,element,child-tail,element,child-tail');
}

// The middle run only. This is the case the whole anchor mechanism exists for:
// all three runs hang off ONE element, so an id->element map cannot separate
// them and the other two runs ride along.
{
  const { md } = pipeline(THREE_RUNS, [3]);
  check('three-runs / keeps the labeled run', md.includes('SECOND-RUN'), true);
  check('three-runs / drops the preceding run', md.includes('FIRST-RUN'), false);
  check('three-runs / drops the following run', md.includes('THIRD-RUN'), false);
  check('three-runs / drops unlabeled blocks', md.includes('block one'), false);
}

// Same input, anchors withheld: documents the fallback is over-inclusive rather
// than lossy — the labeled run is still there, its neighbors leak in with it.
{
  const { md } = pipeline(THREE_RUNS, [3], { useAnchors: false });
  check('three-runs / no anchors still keeps the labeled run', md.includes('SECOND-RUN'), true);
  check('three-runs / no anchors leaks neighbors',
    md.includes('FIRST-RUN') && md.includes('THIRD-RUN'), true);
}

// Each run in turn, to prove the mapping is per-id and not positional luck.
for (const [id, want, absent] of [[1, 'FIRST-RUN', 'THIRD-RUN'], [5, 'THIRD-RUN', 'FIRST-RUN']]) {
  const { md } = pipeline(THREE_RUNS, [id]);
  check(`three-runs / id ${id} selects ${want}`,
    md.includes(want) && !md.includes(absent), true);
}

// ── 2. child-range, with a stage-2-removed sibling shifting the indices ────
// The <script> is dropped by stage 2 but still present in the live DOM, so an
// anchor indexed against stage 2's internal tree would point one slot short and
// slice in the wrong element.
const RANGE_WITH_SCRIPT =
  '<html><body><div id="host">' +
  '<script>var x=1;</script>' +
  '<span>ALPHA</span> mid <span>BETA</span>' +
  '<p>flush</p>' +
  '</div></body></html>';

{
  const { blocks } = pipeline(RANGE_WITH_SCRIPT, []);
  const run = blocks.find((b) => b.anchor.kind === 'child-range');
  check('child-range / anchor present', Boolean(run), true);
  // Live children are [script, span, span, p] -> the run is 1..2, not 0..1.
  check('child-range / indices are live-DOM indices',
    run && `${run.anchor.startIndex}..${run.anchor.endIndex}`, '1..2');

  const { md } = pipeline(RANGE_WITH_SCRIPT, [run.item_id]);
  check('child-range / keeps both span texts',
    md.includes('ALPHA') && md.includes('BETA'), true);
  check('child-range / drops the unlabeled block', md.includes('flush'), false);
}

// ── 3. Multi-id attribute is split, not keyed whole ────────────────────────
// The original defect: getAttribute("1 3 5") was used as a Map key, so
// get("3") missed and every shared-parent block vanished.
{
  const doc = new JSDOM(THREE_RUNS, { virtualConsole: quiet }).window.document;
  simplify({ root: doc.documentElement });
  const attr = doc.getElementById('host').getAttribute('data-pulpie-id');
  check('multi-id / attribute holds a list', attr, '1 3 5');
  const { md } = pipeline(THREE_RUNS, [1, 3, 5]);
  check('multi-id / all three ids resolve',
    md.includes('FIRST-RUN') && md.includes('SECOND-RUN') && md.includes('THIRD-RUN'), true);
}

// ── 4. Unresolvable anchors degrade to the whole element, never to nothing ──
{
  const doc = new JSDOM(THREE_RUNS, { virtualConsole: quiet }).window.document;
  const { blocks } = simplify({ root: doc.documentElement });
  const labels = {}; for (const b of blocks) labels[String(b.item_id)] = b.item_id === 3 ? 'main' : 'other';
  const bogus = { 3: { kind: 'child-tail', childIndex: 99 } };
  const md = P.extractMainMarkdown(doc, labels, { anchors: bogus });
  check('bad anchor / falls back to whole element', md.includes('SECOND-RUN'), true);
}

console.log(`\n${checks - failures}/${checks} checks pass`);
process.exit(failures ? 1 : 0);
