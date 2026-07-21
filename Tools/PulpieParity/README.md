# Pulpie simplify() — JS/Python parity harness

Validates `Sources/Sonata/Resources/web/pulpie-simplify.js` (the DOM-native port
of pulpie's `simplify()` step) against the Python original.

The port exists so Sonata's `read` tool can segment a page from the live
WKWebView DOM instead of re-serializing it and re-parsing the HTML. Because the
Orange classifier was distilled against MinerU's exact segmentation, "close
enough" is not a useful state: block boundaries have to land where Python puts
them, or the model's labels stop meaning what they meant in training. Hence a
harness rather than a handful of unit tests.

## Results (last run)

| page | blocks js/py | text match | markup byte-identical | classifier agreement |
|---|---|---|---|---|
| wikipedia-rag | 399 / 399 | 100% | 396 / 399 | 399 / 399 |
| socrata-chicago (4.8 MB SPA) | 198 / 198 | 100% | 198 / 198 | 198 / 198 |
| mdn-mutationobserver | 36 / 36 | 100% | 36 / 36 | 36 / 36 |
| apnews-hub | 875 / 875 | 100% | 836 / 875 | 874 / 875 |
| **total** | **1508 / 1508** | **100%** | **1466 / 1508** | **1507 / 1508 (99.93%)** |

Purity and idempotency hold on all four pages, under both jsdom and a real
WKWebView: the only write to the live document is `data-pulpie-id`, and a second
run reproduces the first exactly.

**Tolerance.** Whitespace is normalized before text comparison — the two
serializers differ on insignificant whitespace only. Block *count* and block
*text* must match exactly; they do. The 42 markup differences and the single
label flip trace to two named HTML-parser differences, documented at the top of
`pulpie-simplify.js` (`<source>` being a container in libxml2 but void in HTML5,
and lxml's fragment re-parse unwrapping `<body>` block roots).

## Running

```bash
# 1. Reference service (pulpie + FastAPI) on :8765, exposing /simplify + /classify.
#    See scratchpad/pulpie-service/server.py.
curl -s http://127.0.0.1:8765/health

# 2. Corpus — rendered DOM captured from a live WKWebView, not curl output.
node capture-corpus.mjs           # writes ./corpus/*.html (~6 MB, gitignored)

# 3. Checks
npm install jsdom
node run-parity.mjs [--verbose]   # block count + text parity, LCS-aligned
node check-html-and-purity.mjs    # markup parity + DOM purity + idempotency
node check-classifier.mjs         # do the blocks LABEL the same? (the real test)
node check-stage3-anchors.mjs     # stage 2 -> stage 3 handoff over the corpus
```

`run-parity.mjs` writes `out-<page>.json` (both sides' blocks plus the
alignment), which the other scripts read.

## Why four scripts

Each answers a question the previous one can't:

1. **Text parity** — did we find the same content, split the same way?
2. **Markup parity + purity** — is the serialized block identical, and did we
   keep our hands off the live DOM?
3. **Classifier agreement** — string-equal markup is a proxy; identical *labels*
   from the actual Orange model is the property that matters downstream.
4. **Stage 2 -> stage 3** — do the marked ids and their `anchor` spans actually
   survive into markdown? Stage 2 can be byte-perfect and still hand stage 3
   something it mis-reads.

Step 3 caught nothing on its own here, but it is the check that would catch a
tokenization-level regression that steps 1 and 2 are blind to. Step 4 exists
because stage 3's own goldens run against Python-marked DOM, so they were 22/22
green while every block on a shared parent was being dropped in production; on
this corpus that was 4 main-labeled Wikipedia blocks. Mixed-label shared parents
never occur in the corpus, so the behavior itself is pinned down by
`Tests/SonataTests/fixtures/pulpie-golden/anchors.mjs`.

## A note on the corpus

Not committed (6.2 MB, and it goes stale as the sites change). Regenerate with
`capture-corpus.mjs`. The four pages are chosen for structural variety —
data tables and `<noscript>`; a JS-rendered SPA; definition lists and compat
tables; 241 `<template>` elements and heavy `<picture>` use. The `<template>`
and `<noscript>` cases each exposed a real bug during the port, so keep them.
