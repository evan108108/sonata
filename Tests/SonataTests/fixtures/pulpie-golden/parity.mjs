#!/usr/bin/env node
/*
 * Parity check for Sources/Sonata/Resources/web/pulpie-markdown.js.
 *
 *   node Tests/SonataTests/fixtures/pulpie-golden/parity.mjs
 *
 * Runs offline against frozen goldens — the Python pulpie service is NOT
 * needed. The goldens were captured from `pulpie` 0.x + html2text 2025.4.15
 * (orange-small) on 2026-07-21 over the 4-page eval corpus:
 *
 *   wikipedia    en.wikipedia.org/wiki/Large_language_model
 *   usaspending  usaspending.gov/agency/department-of-defense?fy=2025
 *   anthropic    anthropic.com/news
 *   socrata      data.cityofchicago.org/Buildings/Building-Permits/ydr8-5enu
 *
 * Two checks per page:
 *   converter    parse <page>.main.html, convert, compare to <page>.expected.md.
 *                Isolates the html2text port.
 *   end-to-end   parse <page>.map.html, prune with <page>.labels.json, convert,
 *                compare. Isolates prune + convert together. (socrata has no
 *                map fixture — its map_html is 5 MB, too big to check in.)
 *
 * End-to-end runs with `stripLxmlBlanks: true`, which reproduces the
 * whitespace-only text nodes pulpie loses when it re-parses serialized HTML.
 * Default (flag off) is the intended production mode and differs from the
 * oracle only by re-inserting that whitespace — see DIVERGENCES in the module.
 *
 * Needs a DOM. jsdom is a dev-only dependency, resolved from wherever it
 * already exists on the machine; pass a package root as $JSDOM_FROM to override.
 */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import zlib from 'node:zlib';
import { createRequire } from 'node:module';

const HERE = import.meta.dirname;
const MODULE = path.resolve(HERE, '../../../../Sources/Sonata/Resources/web/pulpie-markdown.js');
const JSDOM_FROM = process.env.JSDOM_FROM || '/Users/evan/test/slider-captcha/react/package.json';

const { JSDOM, VirtualConsole } = createRequire(JSDOM_FROM)('jsdom');
const quiet = new VirtualConsole(); // corpus pages carry CSS jsdom can't parse
const parse = (html) => new JSDOM(html, { virtualConsole: quiet }).window.document;

const sandbox = { console };
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(MODULE, 'utf8'), sandbox, { filename: MODULE });
const P = sandbox.PulpieMarkdown;

const gunzip = (f) => zlib.gunzipSync(fs.readFileSync(path.join(HERE, f))).toString('utf8');
const has = (f) => fs.existsSync(path.join(HERE, f));

let failures = 0;
let checks = 0;

function check(label, got, want) {
  checks++;
  if (got === want) {
    console.log(`PASS  ${label}  (${want.length} chars)`);
    return;
  }
  failures++;
  let i = 0;
  while (i < got.length && i < want.length && got[i] === want[i]) i++;
  console.log(`FAIL  ${label}  golden=${want.length} js=${got.length} first diff @${i}`);
  console.log(`   want ${JSON.stringify(want.slice(Math.max(0, i - 80), i + 100))}`);
  console.log(`   got  ${JSON.stringify(got.slice(Math.max(0, i - 80), i + 100))}`);
}

for (const page of JSON.parse(fs.readFileSync(path.join(HERE, 'index.json'), 'utf8'))) {
  const expected = fs.readFileSync(path.join(HERE, `${page.name}.expected.md`), 'utf8');

  check(`${page.name} / converter`, P.toMarkdown(parse(gunzip(`${page.name}.main.html.gz`))), expected);

  if (!has(`${page.name}.map.html.gz`)) {
    console.log(`SKIP  ${page.name} / end-to-end  (no map fixture)`);
    continue;
  }
  const labels = JSON.parse(gunzip(`${page.name}.labels.json.gz`));
  check(
    `${page.name} / end-to-end`,
    P.extractMainMarkdown(parse(gunzip(`${page.name}.map.html.gz`)), labels, {
      idAttr: '_item_id',
      stripLxmlBlanks: true,
    }),
    expected
  );
}

// Hand-built constructs the 4 corpus pages don't exercise: <pre>, <dl>, GFM-ish
// tables, `escape_md_section` edge cases, emphasis adjacency, <hr>/<br>.
for (const c of JSON.parse(fs.readFileSync(path.join(HERE, 'micro.json'), 'utf8'))) {
  check(`micro / ${c.name}`, P.toMarkdown(parse(c.main_html)), c.markdown);
}

console.log(`\n${checks - failures}/${checks} checks pass`);
process.exit(failures ? 1 : 0);
