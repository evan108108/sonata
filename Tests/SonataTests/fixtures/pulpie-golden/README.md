# pulpie markdown goldens

Frozen output of the Python `pulpie` pipeline, used to prove that
`Sources/Sonata/Resources/web/pulpie-markdown.js` reproduces it.

```
node Tests/SonataTests/fixtures/pulpie-golden/parity.mjs    # vs frozen Python output
node Tests/SonataTests/fixtures/pulpie-golden/anchors.mjs   # vs live stage 2 output
```

`parity.mjs` feeds stage 3 the **Python** pipeline's `map_html`: one `_item_id`
per element, loose text runs wrapped in real `<cc-alg-uc-text>` elements.
`anchors.mjs` feeds it **stage 2's** output, which has neither — one element can
carry a space-separated id list, and runs are located by each block's `anchor`.
Both shapes are supported on purpose (see TWO INPUT SHAPES in the module), and
the goldens alone cannot catch a break in the production path: they were 22/22
green while stage 3 was dropping every block on a shared parent.

Runs offline — no Python, no model. Needs jsdom (dev-only); it resolves from an
existing checkout on the machine, override with `JSDOM_FROM=/path/to/package.json`.

## Provenance

Captured 2026-07-21 from `pulpie` (model `orange-small`) + `html2text` 2025.4.15,
via a `POST /extract_debug` endpoint added to the pulpie FastAPI service, over
four browser-rendered pages:

| fixture | source |
| --- | --- |
| `wikipedia` | en.wikipedia.org/wiki/Large_language_model |
| `usaspending` | usaspending.gov/agency/department-of-defense?fy=2025 |
| `anthropic` | anthropic.com/news |
| `socrata` | data.cityofchicago.org/Buildings/Building-Permits/ydr8-5enu |

Per page: `<name>.map.html.gz` (the full DOM with `_item_id` markers),
`<name>.labels.json.gz` (classifier verdicts), `<name>.main.html.gz` (what
pulpie feeds to html2text) and `<name>.expected.md` (what it gets back).

`socrata` ships without a map/labels pair — its `map_html` is 5 MB, too large to
check in, so it covers the converter only.

`micro.json` holds fifteen small hand-built cases for constructs the four pages
never hit: `<pre>`, `<dl>`, tables, `escape_md_section` edges, emphasis
adjacency, `<hr>`/`<br>`.

## Regenerating

Only needed if pulpie or html2text is upgraded. Re-render the four URLs with a
real browser, POST each to the pulpie service's `/extract_debug`, and write the
four artifacts per page. A byte diff in `<name>.expected.md` is the signal that
the JS port needs to follow the upstream change.
