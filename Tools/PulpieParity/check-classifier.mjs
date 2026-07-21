/**
 * End-to-end check: does the Orange classifier label the JS port's simplified
 * HTML the same way it labels Python's?
 *
 * String parity is necessary but not sufficient — what matters is that the
 * blocks tokenize and classify identically. Any label disagreement here is a
 * real behavioral difference, regardless of how close the markup looked.
 */
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';
import { simplify } from '../../Sources/Sonata/Resources/web/pulpie-simplify.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const CORPUS = join(HERE, 'corpus');

const post = async (path, body) => {
  const r = await fetch(`http://127.0.0.1:8765${path}`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`${path} ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return r.json();
};

let totAgree = 0, totBlocks = 0;

for (const file of readdirSync(CORPUS).filter((f) => f.endsWith('.html')).sort()) {
  const html = readFileSync(join(CORPUS, file), 'utf8');
  const dom = new JSDOM(html);
  const js = simplify({ root: dom.window.document.documentElement });

  const py = await post('/simplify', { html, cutoff_length: 500 });

  const jsLabels = await post('/classify', { simplified_html: js.simplifiedHtml });
  const pyLabels = await post('/classify', { simplified_html: py.simplified_html });

  const ids = new Set([...Object.keys(jsLabels.labels), ...Object.keys(pyLabels.labels)]);
  let agree = 0; const disagreements = [];
  for (const id of ids) {
    if (jsLabels.labels[id] === pyLabels.labels[id]) agree++;
    else disagreements.push({ id, js: jsLabels.labels[id], py: pyLabels.labels[id] });
  }
  totAgree += agree; totBlocks += ids.size;

  const identicalHtml = js.simplifiedHtml === py.simplified_html;
  console.log(`${file}`);
  console.log(`  simplified html identical: ${identicalHtml}` +
    (identicalHtml ? '' : `  (js ${js.simplifiedHtml.length}B vs py ${py.simplified_html.length}B)`));
  console.log(`  labels  js main=${jsLabels.n_main}/${jsLabels.n_blocks}  ` +
    `py main=${pyLabels.n_main}/${pyLabels.n_blocks}  agree=${agree}/${ids.size}`);
  if (disagreements.length) {
    console.log(`  disagreements (${disagreements.length}):`,
      JSON.stringify(disagreements.slice(0, 10)));
  }
}

console.log(`\nCLASSIFIER AGREEMENT: ${totAgree}/${totBlocks} ` +
  `(${(totAgree / totBlocks * 100).toFixed(2)}%)`);
