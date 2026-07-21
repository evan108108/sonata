/**
 * Capture the eval corpus: rendered HTML straight out of a Sonata WKWebView.
 *
 * The corpus deliberately holds POST-RENDER DOM, not `curl` output — the whole
 * point of the JS port is that it runs after scripts have built the page, and a
 * pre-render snapshot would not exercise that (the Socrata page is 1.4% of its
 * rendered size before hydration).
 *
 * Requires Sonata running with the MCP bridge on :8787. Usage:
 *   node capture-corpus.mjs [--token <mcp token>]
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const CORPUS = join(HERE, 'corpus');

/** Chosen for structural variety, not topic: each stresses a different branch. */
const PAGES = [
  // Tables, infobox, deep nav lists, <noscript> tracking pixel, <picture> footer.
  { name: '01-wikipedia-rag', url: 'https://en.wikipedia.org/wiki/Retrieval-augmented_generation' },
  // JS-rendered SPA: 4.8 MB of markup over only ~1400 elements.
  { name: '02-socrata-chicago', url: 'https://data.cityofchicago.org/Public-Safety/Crimes-2001-to-Present/ijzp-q8t2/about_data' },
  // Clean semantic docs: <dl> definition lists, code blocks, compat tables.
  { name: '03-mdn-mutationobserver', url: 'https://developer.mozilla.org/en-US/docs/Web/API/MutationObserver' },
  // News hub: 241 <template> elements, heavy <picture> use, custom elements.
  { name: '04-apnews-hub', url: 'https://apnews.com/hub/artificial-intelligence' },
];

const BRIDGE = process.env.SONATA_MCP_URL ?? 'http://127.0.0.1:8787';

async function rpc(method, params) {
  const res = await fetch(`${BRIDGE}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: Date.now(), method, params }),
  });
  if (!res.ok) throw new Error(`${method} -> ${res.status}`);
  return res.json();
}

const call = async (name, args) => {
  const r = await rpc('tools/call', { name, arguments: args });
  return r.result?.content?.[0]?.text ?? '';
};

mkdirSync(CORPUS, { recursive: true });

const { sessionId } = JSON.parse(await call('session_create', { background: true, url: 'about:blank' }));
console.log('webview session', sessionId);

for (const page of PAGES) {
  await call('navigate', { sessionId, url: page.url });
  // Let late hydration settle; the SPA in particular fills in after load.
  await new Promise((r) => setTimeout(r, 6000));
  const html = await call('evaluate', { sessionId, script: 'document.documentElement.outerHTML' });
  writeFileSync(join(CORPUS, `${page.name}.html`), html);
  console.log(`${page.name}: ${(html.length / 1024).toFixed(0)} KB`);
}

await call('session_close', { sessionId });
console.log('done ->', CORPUS);
