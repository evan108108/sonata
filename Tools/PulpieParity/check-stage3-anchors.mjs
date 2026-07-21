/**
 * Corpus check for the stage 2 -> stage 3 handoff.
 *
 * Runs the real pipeline over the eval corpus: stage 2 marks the DOM, the
 * pulpie service labels the blocks, stage 3 prunes and converts. Reports, per
 * page, how the three id-resolution strategies compare on the SAME labels:
 *
 *   whole-attr   getAttribute("1 3 5") used as a Map key   (the original bug)
 *   split-only   ids split, each resolving to its parent   (over-inclusive)
 *   anchors      ids split, each resolving to its own span (correct)
 *
 * NOTE ON WHAT THIS CAN AND CANNOT SHOW. Anchors only change the output when a
 * shared parent's runs are labeled DIFFERENTLY from each other. On this corpus
 * every shared parent happens to be uniformly labeled, so split-only and
 * anchors agree byte-for-byte here - this file proves no regression and
 * measures the whole-attr loss, but the mixed-label behavior is pinned down by
 * the hand-built cases in Tests/SonataTests/fixtures/pulpie-golden/anchors.mjs.
 *
 * Needs the pulpie service on :8765 for /classify.
 */
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { JSDOM, VirtualConsole } from 'jsdom';
import { simplify } from '../../Sources/Sonata/Resources/web/pulpie-simplify.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const CORPUS = join(HERE, 'corpus');

const sandbox = { console };
vm.createContext(sandbox);
vm.runInContext(
  readFileSync(join(HERE, '../../Sources/Sonata/Resources/web/pulpie-markdown.js'), 'utf8'),
  sandbox, { filename: 'pulpie-markdown.js' });
const P = sandbox.PulpieMarkdown;

const classify = async (simplifiedHtml) => {
  const r = await fetch('http://127.0.0.1:8765/classify', {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ simplified_html: simplifiedHtml }),
  });
  if (!r.ok) throw new Error(`classify ${r.status}`);
  return (await r.json()).labels;
};

/**
 * A distinctive token to probe the markdown with.
 *
 * Comparing a long slice of a block's text against markdown does not work: the
 * converter escapes `(` and `)`, and a slice spanning an element boundary picks
 * up link/emphasis syntax that was never in the text. A single long word is
 * immune to both.
 */
function probe(text) {
  const words = text.match(/[A-Za-z][A-Za-z0-9'-]{7,}/g) || [];
  return words.sort((a, b) => b.length - a.length)[0] || null;
}

let totShared = 0, totMainOnShared = 0, totFound = 0, totScored = 0, totUnreachable = 0;

for (const file of readdirSync(CORPUS).filter((f) => f.endsWith('.html')).sort()) {
  const html = readFileSync(join(CORPUS, file), 'utf8');

  /** A fresh document ALREADY MARKED by stage 2 - stage 3 needs the attributes. */
  const marked = () => {
    const doc = new JSDOM(html, { virtualConsole: new VirtualConsole() }).window.document;
    return { doc, res: simplify({ root: doc.documentElement }) };
  };

  const { doc: docA, res } = marked();
  const blocks = res.blocks;
  const labels = await classify(res.simplifiedHtml);
  const anchors = Object.fromEntries(blocks.map((b) => [String(b.item_id), b.anchor]));
  const byId = new Map(blocks.map((b) => [String(b.item_id), b]));

  const shared = [];
  for (const el of docA.querySelectorAll('[data-pulpie-id]')) {
    const ids = el.getAttribute('data-pulpie-id').split(/\s+/).filter(Boolean);
    if (ids.length > 1) shared.push(ids);
  }
  const sharedMain = shared.flat().filter((id) => labels[id] === 'main');

  const mdAnchors = P.extractMainMarkdown(marked().doc, labels, { anchors });
  const mdSplit = P.extractMainMarkdown(marked().doc, labels, {});

  // The original defect keyed on the whole attribute value, so any id sharing a
  // parent was unreachable - Map.get("3") against a "1 3 5" key. That set is
  // exactly the main-labeled ids on shared parents.
  const unreachableUnderWholeAttr = sharedMain.length;

  let found = 0, scored = 0;
  const missing = [];
  for (const id of sharedMain) {
    const p = probe(byId.get(id)?.text || '');
    if (!p) continue;                       // too short to probe unambiguously
    scored++;
    if (mdAnchors.includes(p)) found++;
    else missing.push({ id, probe: p, alsoMissingFromSplitOnly: !mdSplit.includes(p) });
  }

  totShared += shared.length; totMainOnShared += sharedMain.length;
  totFound += found; totScored += scored; totUnreachable += unreachableUnderWholeAttr;

  console.log(`${file}`);
  console.log(`  shared-parent elements=${shared.length} holding ${shared.flat().length} ids ` +
    `(${sharedMain.length} labeled main)`);
  console.log(`  main-on-shared present with anchors: ${found}/${scored} probed` +
    (missing.length ? `  MISSING ${JSON.stringify(missing)}` : ''));
  console.log(`  would be unreachable under whole-attr keying: ${unreachableUnderWholeAttr}`);
  console.log(`  markdown chars: split-only=${mdSplit.length}  anchors=${mdAnchors.length}` +
    (mdSplit.length === mdAnchors.length
      ? '  (identical - no mixed-label shared parent on this page)'
      : `  (anchors trims ${mdSplit.length - mdAnchors.length})`));
}

console.log(`\nTOTAL shared-parent elements=${totShared}  main ids on them=${totMainOnShared}  ` +
  `present with anchors=${totFound}/${totScored} probed  ` +
  `(whole-attr keying would lose ${totUnreachable})`);
process.exit(totFound === totScored ? 0 : 1);
