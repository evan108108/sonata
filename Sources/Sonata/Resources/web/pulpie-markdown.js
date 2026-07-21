/*
 * pulpie-markdown.js — stage 3 of the in-webview pulpie port.
 *
 * CONTRACT
 * --------
 * Runs inside a WKWebView after stage 2 (`pulpie-simplify.js`) has tagged block
 * elements with `data-pulpie-id`, and after Swift classification has handed a
 * label back for each of those ids.
 *
 *   PulpieMarkdown.extractMainMarkdown(root, labels, options) -> string
 *
 *     root     Document or Element. The LIVE DOM. It is never mutated — the
 *              first thing this module does is take a deep clone.
 *     labels   { "<item id>": "main" | "other" }. Keys are whatever stage 2 put
 *              in `data-pulpie-id`; compared as strings. Pass null/undefined to
 *              skip pruning and convert the whole tree.
 *     options  optional:
 *                idAttr            "data-pulpie-id"
 *                anchors           null — per-id spans from stage 2; see
 *                                  TWO INPUT SHAPES
 *                tailBlockTag      "cc-alg-uc-text" — Python's loose-text-run
 *                                  wrapper, unwrapped before conversion exactly
 *                                  as pulpie's drop_tag does. Only present in
 *                                  Python-produced map_html.
 *                stripLxmlBlanks   false — see DIVERGENCES
 *
 *     returns  Markdown. Byte-identical to pulpie's Python `to_markdown()` for
 *              the same main content; see DIVERGENCES for the one exception.
 *
 * Also exported, for testing each stage in isolation:
 *   PulpieMarkdown.pruneToMain(clone, labels, options) -> Element
 *   PulpieMarkdown.toMarkdown(elementOrDocument)       -> string
 *   PulpieMarkdown.stripSpacerImages(element)          -> void
 *   PulpieMarkdown.stripLxmlBlanks(element)            -> void
 *
 * WHY NOT TURNDOWN
 * ----------------
 * pulpie's `to_markdown()` is html2text (bodywidth=0), and html2text does not
 * emit CommonMark. Its tables have no leading pipe (`a| b` over `---|---`), its
 * rules are `* * *`, its code blocks are four-space indented, its soft breaks
 * are `  \n`, and it applies its own `escape_md_section` backslash rules.
 * Configuring turndown to reproduce that means replacing every one of its rules
 * plus its whitespace collapsing — a port with a dependency bolted on. So this
 * is a direct port of html2text 2025.4.15's `HTML2Text`, with pulpie's option
 * set (bodywidth=0, links and images kept, everything else default) baked in,
 * walking the DOM instead of re-parsing serialized HTML.
 *
 * DIVERGENCES from the Python pipeline
 * ------------------------------------
 * 1. Whitespace-only text nodes. pulpie serializes the marked DOM and
 *    `extract_main_html` re-parses it with lxml's `remove_blank_text`, which
 *    silently eats some whitespace-only text nodes — welding words together
 *    (`…architecture.[3]` + ` ` + `[Generative…]` -> `[3][Generative…`). Walking
 *    a live DOM has no serialize step and so no such loss. Measured on the eval
 *    corpus: 3 of 4 pages are byte-identical either way; Wikipedia differs by
 *    exactly 199 re-inserted whitespace characters and zero non-whitespace
 *    characters. Set `stripLxmlBlanks: true` to reproduce the Python bytes
 *    exactly (see BLANK_PRESERVING_TAGS).
 * 2. Text-chunk boundaries. html2text is fed a string and splits text at every
 *    entity reference, and `escape_md_section`'s line-anchored rules restart at
 *    each chunk. `emitText` reproduces that by splitting text nodes at `&`, `<`
 *    and `>` — the only characters lxml writes as entities. A live DOM built by
 *    a *browser* parser could in principle differ from what lxml would have
 *    re-parsed for malformed markup; no such case appeared in the corpus.
 * 3. Named-entity folding. html2text's UNIFIABLE table (`&mdash;` -> `--`,
 *    `&copy;` -> `(C)`) is dead code in this pipeline; lxml writes raw UTF-8.
 *    Not implemented — see ENTITY_CHARS.
 * 4. Foreign-content tag case. SVG/MathML element names are lower-cased here to
 *    match libxml2; a browser DOM preserves `foreignObject`-style camelCase.
 *    Only reachable for markup html2text ignores anyway.
 *
 * TWO INPUT SHAPES
 * ----------------
 * This module accepts a DOM marked either by Python or by stage 2, because the
 * goldens are Python's and production is stage 2's:
 *
 *   Python `map_html`   `_item_id` holds ONE id; loose text runs are wrapped in
 *                       real `<cc-alg-uc-text>` elements. Pass
 *                       `idAttr:'_item_id'`; the wrapper unwrap step below is
 *                       what handles the runs. This is what the fixtures use.
 *   Stage 2 live DOM    `data-pulpie-id` holds a SPACE-SEPARATED id list, and no
 *                       wrapper element exists — stage 2 can't restructure a
 *                       live page. Pass `anchors` (below) so each run resolves
 *                       to its own span.
 *
 * The wrapper unwrap is therefore NOT dead code: it is the Python path. It is
 * simply a no-op against stage 2 output, where no such element is ever emitted.
 *
 *     options.anchors  { "<item id>": anchor } from stage 2's block list —
 *                      `Object.fromEntries(blocks.map(b => [b.item_id, b.anchor]))`.
 *                      Omit it and every id resolves to its whole marked
 *                      element: correct for single-id parents, over-inclusive
 *                      for shared ones (a parent's other runs ride along).
 *
 * No runtime dependencies, no network, no eval. Parity harness and goldens:
 * Tests/SonataTests/fixtures/pulpie-golden/parity.mjs
 */
(function (global) {
  'use strict';

  // ── constants ────────────────────────────────────────────────────────────

  var ITEM_ID_ATTR = 'data-pulpie-id';
  var TAIL_BLOCK_TAG = 'cc-alg-uc-text';

  // Elements the HTML serializer writes without a closing tag, so html.parser
  // only ever sees a start event for them.
  var VOID_TAGS = {
    area: 1, base: 1, basefont: 1, br: 1, col: 1, embed: 1, frame: 1, hr: 1,
    img: 1, input: 1, isindex: 1, link: 1, meta: 1, param: 1, source: 1,
    track: 1, wbr: 1
  };

  // pulpie.markdown.strip_spacer_images: tracking pixels and spacers would
  // otherwise leak into the output as empty `![](...)`.
  var SPACER_SRC_RE = /trans(parent)?|spacer|blank|pixel|1x1|clear/i;

  // html2text folds named entities (&mdash; -> "--", &copy; -> "(C)", ...) via
  // its UNIFIABLE table. That table is unreachable here: pulpie serializes the
  // marked DOM with lxml, which writes every non-ASCII character as raw UTF-8
  // and only ever emits `&amp;`, `&lt;` and `&gt;`. Verified against the oracle
  // — U+00A0 arrives as a literal 0xA0, not as `&#160;`.
  var ENTITY_CHARS = { '&': 1, '<': 1, '>': 1 };

  /**
   * Tags after which lxml's `remove_blank_text` parse preserves a
   * whitespace-only text node. Everything else — `sub`, `sup`, `br`, `img`,
   * `table`, `ul`, `tr`, `script`, and every HTML5-era tag libxml2's HTML4
   * table doesn't know (`article`, `figure`, `svg`, custom elements, …) —
   * loses it.
   *
   * Only consulted when `options.stripLxmlBlanks` is on. See DIVERGENCES in the
   * header: pulpie hits this because `extract_main_html` re-parses serialized
   * HTML; walking a live DOM does not, and reproducing it welds words together
   * (`[3]` + `Generative…` -> `[3]Generative…`). The set is empirical, measured
   * against the running oracle, not derived from libxml2's documented rules.
   */
  var BLANK_PRESERVING_TAGS = {
    a: 1, abbr: 1, acronym: 1, address: 1, applet: 1, area: 1, b: 1, base: 1,
    bdo: 1, big: 1, blockquote: 1, button: 1, caption: 1, center: 1, cite: 1,
    code: 1, dd: 1, del: 1, dfn: 1, div: 1, dt: 1, em: 1, font: 1, form: 1,
    h1: 1, h2: 1, h3: 1, h4: 1, h5: 1, h6: 1, i: 1, iframe: 1, ins: 1, kbd: 1,
    label: 1, legend: 1, li: 1, noframes: 1, noscript: 1, object: 1, p: 1,
    pre: 1, q: 1, s: 1, samp: 1, small: 1, span: 1, strike: 1, strong: 1,
    td: 1, th: 1, tt: 1, u: 1, var: 1
  };

  var NODE_ELEMENT = 1;
  var NODE_TEXT = 3;
  var NODE_CDATA = 4;

  // ── DOM helpers ──────────────────────────────────────────────────────────

  function documentElementOf(root) {
    if (!root) return null;
    if (root.nodeType === NODE_ELEMENT) return root;
    if (root.documentElement) return root.documentElement;
    return null;
  }

  function tagNameOf(el) {
    return (el.localName || el.nodeName || '').toLowerCase();
  }

  /** Element-only, document-order walk including `el` itself (lxml's .iter()). */
  function eachElement(el, fn) {
    fn(el);
    var kids = el.children;
    for (var i = 0; i < kids.length; i++) eachElement(kids[i], fn);
  }

  function attrsOf(el) {
    var out = {};
    var attrs = el.attributes;
    for (var i = 0; i < attrs.length; i++) {
      out[attrs[i].name.toLowerCase()] = attrs[i].value;
    }
    return out;
  }

  /**
   * Remove an element the way lxml does: the element AND its tail text.
   *
   * In lxml a node's tail is part of the node, so `parent.remove(child)` takes
   * the text between `</child>` and the next tag with it. In the DOM that text
   * is an independent sibling, so it has to be removed explicitly or pruned
   * output picks up stray words the Python side dropped.
   */
  function removeWithTail(el, protectedText) {
    var tail = el.nextSibling;
    if (tail && tail.nodeType === NODE_TEXT
        && !(protectedText && protectedText.has(tail))) {
      tail.parentNode.removeChild(tail);
    }
    el.parentNode.removeChild(el);
  }

  // ── stage 3a: prune to main content ──────────────────────────────────────

  /**
   * Work out which nodes under `node` a single block actually covers.
   *
   * `pulpie-simplify.js` cannot splice pulpie's `<cc-alg-uc-text>` wrapper into
   * a live page, so a parent that would have hosted several wrappers carries a
   * space-separated id list and each block reports its own span as an `anchor`.
   * Resolving that span is what keeps a shared parent from dragging its
   * siblings' runs into the output.
   *
   * Anchor kinds (see stage 2's header):
   *   element                        the whole marked element
   *   child-range {start,end}        element children [start..end] + text between
   *   parent-text                    text before the first element child
   *   child-tail  {childIndex}       text after that child, before the next
   *
   * Indices are into the LIVE parent's `.children`. An absent, unknown or
   * `unresolved` anchor falls back to the whole element — the same
   * over-inclusive-but-never-lossy behavior as before anchors existed.
   *
   * @returns {{elements: Element[], textNodes: Node[], isSpan: boolean}}
   *   `isSpan` marks a sub-element anchor, i.e. one whose parent needs its
   *   other runs' loose text filtered out.
   */
  function resolveAnchor(node, anchor) {
    var whole = { elements: [node], textNodes: [], isSpan: false };
    if (!anchor || anchor.unresolved) return whole;

    var kids = node.children;

    if (anchor.kind === 'child-range') {
      var start = anchor.startIndex;
      var end = anchor.endIndex;
      if (typeof start !== 'number' || typeof end !== 'number'
          || start < 0 || end < start || end >= kids.length) {
        return whole;
      }
      var els = [];
      for (var i = start; i <= end; i++) els.push(kids[i]);

      var texts = [];
      // LEADING text. Python's wrapper takes `parent.text` when the run starts
      // at child 0, else the tail of the element before it — and on a citation
      // like `<cite>Author (2020). <i>Title</i>…</cite>` that leading run is
      // most of the block. Omitting it silently truncates the reference.
      var from = start === 0 ? node.firstChild : kids[start - 1].nextSibling;
      for (var L = from; L && L !== kids[start]; L = L.nextSibling) {
        if (L.nodeType === NODE_TEXT || L.nodeType === NODE_CDATA) texts.push(L);
      }
      // Text interleaved with the run. Text AFTER the last element is the next
      // run's, and Python likewise leaves it outside the wrapper.
      for (var c = kids[start].nextSibling; c && c !== kids[end]; c = c.nextSibling) {
        if (c.nodeType === NODE_TEXT || c.nodeType === NODE_CDATA) texts.push(c);
      }
      return { elements: els, textNodes: texts, isSpan: true };
    }

    if (anchor.kind === 'parent-text') {
      var lead = [];
      for (var t = node.firstChild; t && t.nodeType !== NODE_ELEMENT; t = t.nextSibling) {
        if (t.nodeType === NODE_TEXT || t.nodeType === NODE_CDATA) lead.push(t);
      }
      return { elements: [], textNodes: lead, isSpan: true };
    }

    if (anchor.kind === 'child-tail') {
      var idx = anchor.childIndex;
      if (typeof idx !== 'number' || idx < 0 || idx >= kids.length) return whole;
      var tail = [];
      for (var n = kids[idx].nextSibling; n && n.nodeType !== NODE_ELEMENT; n = n.nextSibling) {
        if (n.nodeType === NODE_TEXT || n.nodeType === NODE_CDATA) tail.push(n);
      }
      return { elements: [], textNodes: tail, isSpan: true };
    }

    return whole;
  }

  /**
   * Port of pulpie.reconstruct.extract_main_html.
   *
   * Keeps every element labeled "main" plus all of its ancestors and
   * descendants, re-admits `<br>` adjacent to kept content, drops everything
   * else, then unwraps the tail-block wrapper. Mutates `root` in place — call
   * it on a clone.
   */
  function pruneToMain(root, labels, options) {
    var opts = options || {};
    var idAttr = opts.idAttr || ITEM_ID_ATTR;
    var tailTag = (opts.tailBlockTag || TAIL_BLOCK_TAG).toLowerCase();

    var el = documentElementOf(root);
    if (!el || !labels) return el;

    // First element in document order per id, matching Python's single-pass map.
    //
    // Stage 2 cannot splice pulpie's <cc-alg-uc-text> wrapper into a live page,
    // so an element that would have been several wrappers' parent carries a
    // space-separated id list. Split on whitespace or those blocks are never
    // found — on the eval corpus that silently dropped 4 main-labeled blocks.
    var idToElement = new Map();
    eachElement(el, function (node) {
      var iid = node.getAttribute(idAttr);
      if (iid === null) return;
      var ids = iid.split(/\s+/);
      for (var i = 0; i < ids.length; i++) {
        if (ids[i] && !idToElement.has(ids[i])) idToElement.set(ids[i], node);
      }
    });

    // Resolve each id to the nodes it actually covers. With no anchors that is
    // always the whole marked element (Python's behavior, and what the
    // map_html fixtures need). With anchors, an id that names a sub-element
    // span covers only that span, so a parent shared by several runs keeps the
    // "main" ones and drops the rest instead of surviving whole.
    var anchors = opts.anchors || null;
    var spanParents = new Set();  // parents whose loose text must be filtered
    var keepText = new Set();     // text nodes explicitly claimed by a main span

    var keep = new Set();
    Object.keys(labels).forEach(function (id) {
      if (labels[id] !== 'main') return;
      var node = idToElement.get(String(id));
      if (!node) return;
      var covered = resolveAnchor(node, anchors ? anchors[String(id)] : null);
      for (var i = 0; i < covered.elements.length; i++) {
        eachElement(covered.elements[i], function (d) { keep.add(d); });
      }
      for (var j = 0; j < covered.textNodes.length; j++) keepText.add(covered.textNodes[j]);
      if (covered.isSpan) spanParents.add(node);
      keep.add(node);
      for (var p = node.parentElement; p; p = p.parentElement) keep.add(p);
    });

    // Within a span parent, drop the loose text belonging to its OTHER runs.
    // Only text directly under such a parent is at stake: everything else is
    // governed by element-level keep/remove below.
    spanParents.forEach(function (parent) {
      var doomed = [];
      for (var c = parent.firstChild; c; c = c.nextSibling) {
        if (c.nodeType !== NODE_TEXT && c.nodeType !== NODE_CDATA) continue;
        if (!keepText.has(c) && pyStrip(c.data) !== '') doomed.push(c);
      }
      for (var i = 0; i < doomed.length; i++) parent.removeChild(doomed[i]);
    });

    // Re-admit <br> next to kept, non-<br> content (in either direction).
    // `keep` is mutated while walking, exactly as in the Python original.
    var last = null;
    eachElement(el, function (node) {
      if (last !== null) {
        var tag = tagNameOf(node);
        var lastTag = tagNameOf(last);
        if (tag === 'br' && keep.has(last) && lastTag !== 'br') keep.add(node);
        if (lastTag === 'br' && keep.has(node) && tag !== 'br') keep.add(last);
      }
      last = node;
    });

    // Remove non-kept elements top-down, recursing only into survivors.
    //
    // `keepText` has to be honored here: in lxml a node's tail belongs to the
    // node, so dropping an "other" element drops the text after it — but under
    // stage 2 that text is frequently its own block (a `child-tail` run) with
    // its own label. Deleting an unlabeled <p> would silently take the labeled
    // run that follows it.
    (function removeRecursive(node) {
      if (!keep.has(node) && node.parentNode) {
        removeWithTail(node, keepText);
        return;
      }
      var kids = Array.prototype.slice.call(node.children);
      for (var i = 0; i < kids.length; i++) removeRecursive(kids[i]);
    })(el);

    // drop_tag() the tail-block wrappers: unwrap, keeping their children.
    var wrappers = [];
    eachElement(el, function (node) {
      if (tagNameOf(node) === tailTag) wrappers.push(node);
    });
    for (var i = 0; i < wrappers.length; i++) {
      var w = wrappers[i];
      if (!w.parentNode) continue;
      while (w.firstChild) w.parentNode.insertBefore(w.firstChild, w);
      w.parentNode.removeChild(w);
    }

    return el;
  }

  /**
   * Reproduce the whitespace-only text nodes lxml's `remove_blank_text` parse
   * drops when pulpie re-parses its serialized `map_html`. Opt-in — see
   * BLANK_PRESERVING_TAGS.
   */
  function stripLxmlBlanks(rootEl) {
    var doomed = [];
    (function walk(node) {
      for (var c = node.firstChild; c; c = c.nextSibling) {
        if (c.nodeType === NODE_TEXT) {
          if (pyStrip(c.data) !== '') continue;
          var ref = c.previousSibling;
          while (ref && ref.nodeType !== NODE_ELEMENT) ref = ref.previousSibling;
          if (!ref) ref = c.parentElement;
          if (ref && !BLANK_PRESERVING_TAGS[tagNameOf(ref)]) doomed.push(c);
        } else if (c.nodeType === NODE_ELEMENT) {
          walk(c);
        }
      }
    })(rootEl);
    for (var i = 0; i < doomed.length; i++) doomed[i].parentNode.removeChild(doomed[i]);
  }

  /**
   * Port of pulpie.markdown.strip_spacer_images, applied to a subtree.
   *
   * The Python side is a regex over the raw `<img …>` source, so its
   * "width"/"height"/"src" needles also hit `data-file-width`, `data-src` and
   * friends — reproduced here by matching on the attribute-name suffix. The
   * loose `trans(parent)?` needle likewise fires on any src merely *containing*
   * "trans"; that over-matches (it eats Wikipedia's Transformer diagrams), but
   * reproducing it is the point.
   */
  function stripSpacerImages(rootEl) {
    var imgs = [];
    eachElement(rootEl, function (node) {
      if (tagNameOf(node) === 'img') imgs.push(node);
    });
    for (var i = 0; i < imgs.length; i++) {
      var img = imgs[i];
      var attrs = img.attributes;
      var spacer = false;
      for (var j = 0; j < attrs.length && !spacer; j++) {
        var name = attrs[j].name.toLowerCase();
        var value = attrs[j].value;
        if (/(?:width|height)$/.test(name)) {
          spacer = /^\s*1(?![0-9A-Za-z_])/.test(value);
        } else if (/src$/.test(name)) {
          spacer = SPACER_SRC_RE.test(value) || /^data:image/i.test(value);
        }
      }
      if (spacer && img.parentNode) removeWithTail(img);
    }
  }

  // ── stage 3b: html2text ──────────────────────────────────────────────────

  // config.RE_MD_CHARS_MATCHER
  function escapeMd(text) {
    return text.replace(/[\\[\]()]/g, function (c) { return '\\' + c; });
  }

  var SLASH_CHARS = '`*_{}[]()#+-.!\\';

  /**
   * utils.escape_md_section with snob=False.
   *
   * The line-anchored rules are applied per `\n`-delimited line rather than
   * with a JS `m` flag, because JS treats `\r`/U+2028/U+2029 as line starts and
   * Python's re.MULTILINE does not.
   */
  function escapeMdSection(text) {
    text = text.replace(/\\/g, function (m, offset, whole) {
      var next = whole.charAt(offset + 1);
      return next && SLASH_CHARS.indexOf(next) !== -1 ? '\\\\' : '\\';
    });
    var lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      lines[i] = lines[i]
        .replace(/^(\s*\d+)(\.)(?=\s)/, '$1\\$2')
        .replace(/^(\s*)(\+)(?=\s)/, '$1\\$2')
        .replace(/^(\s*)(-)(?=\s|-)/, '$1\\$2');
    }
    return lines.join('\n');
  }

  function hn(tag) {
    if (tag.charAt(0) === 'h' && tag.length === 2) {
      var n = tag.charAt(1);
      if (n > '0' && n <= '9') return parseInt(n, 10);
    }
    return 0;
  }

  // Python `re`'s \s for str patterns, and the same set str.strip() uses.
  // Deliberately not JS \s: JS adds U+FEFF and omits U+001C-U+001F and U+0085.
  var RE_PY_SPACE = /[ \t\n\r\v\f\u001c-\u001f\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]/;

  // string.whitespace — ASCII only, which is what the emphasis-adjacency check uses.
  var ASCII_WHITESPACE = ' \t\n\r\v\f';
  // string.punctuation
  var PY_PUNCTUATION = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";

  function isPySpace(ch) { return RE_PY_SPACE.test(ch); }

  /** Python str.strip() with the default whitespace set. */
  function pyStrip(s) {
    var a = 0;
    var b = s.length;
    while (a < b && isPySpace(s.charAt(a))) a++;
    while (b > a && isPySpace(s.charAt(b - 1))) b--;
    return s.slice(a, b);
  }

  /** Python `re.sub(r"\s+", " ", s)` — Python's \s, not JavaScript's. */
  function collapseWhitespace(s) {
    var out = [];
    var inRun = false;
    for (var i = 0; i < s.length; i++) {
      var ch = s.charAt(i);
      if (isPySpace(ch)) {
        if (!inRun) { out.push(' '); inRun = true; }
      } else {
        out.push(ch);
        inRun = false;
      }
    }
    return out.join('');
  }

  /** Python `str.lstrip(chars)`. */
  function lstripChars(s, chars) {
    var i = 0;
    while (i < s.length && chars.indexOf(s.charAt(i)) !== -1) i++;
    return s.slice(i);
  }

  function HTML2Text() {
    this.outtextlist = [];
    this.quiet = 0;
    this.p_p = 0;
    this.outcount = 0;
    this.start = true;
    this.space = false;
    this.astack = [];
    this.maybe_automatic_link = null;
    this.empty_link = false;
    this.acount = 0;
    this.list = [];
    this.blockquote = 0;
    this.pre = false;
    this.startpre = false;
    this.pre_indent = '';
    this.list_code_indent = '';
    this.code = false;
    this.quote = false;
    this.br_toggle = '';
    this.lastWasNL = false;
    this.style = 0;
    this.emphasis = 0;
    this.drop_white_space = 0;
    this.inheader = false;
    this.abbr_title = null;
    this.abbr_data = null;
    this.abbr_list = [];
    this.stressed = false;
    this.preceding_stressed = false;
    this.preceding_data = '';
    this.current_tag = '';
    this.split_next_td = false;
    this.td_count = 0;
    this.table_start = false;
    this.lastWasList = false;
  }

  HTML2Text.prototype.out = function (s) {
    this.outtextlist.push(s);
    if (s) this.lastWasNL = s.charAt(s.length - 1) === '\n';
  };

  HTML2Text.prototype.pbr = function () { if (this.p_p === 0) this.p_p = 1; };
  HTML2Text.prototype.p = function () { this.p_p = 2; };
  HTML2Text.prototype.soft_br = function () { this.pbr(); this.br_toggle = '  '; };

  HTML2Text.prototype.o = function (data, puredata, force) {
    if (this.abbr_data !== null) this.abbr_data += data;
    if (this.quiet) return;

    if (puredata && !this.pre) {
      data = collapseWhitespace(data);
      if (data && data.charAt(0) === ' ') {
        this.space = true;
        data = data.slice(1);
      }
    }
    if (!data && !force) return;

    if (this.startpre) {
      if (data.indexOf('\n') !== 0 && data.indexOf('\r\n') !== 0) data = '\n' + data;
    }

    var bq = new Array(this.blockquote + 1).join('>');
    if (!(force && data && data.charAt(0) === '>') && this.blockquote) bq += ' ';

    if (this.pre) {
      if (this.list.length) bq += this.list_code_indent;
      bq += '    ';
      data = data.split('\n').join('\n' + bq);
      this.pre_indent = bq;
    }

    if (this.startpre) {
      this.startpre = false;
      // Inside a list the <pre> body already carries the list's indentation.
      if (this.list.length) data = lstripChars(data, '\n' + this.pre_indent);
    }

    if (this.start) {
      this.space = false;
      this.p_p = 0;
      this.start = false;
    }

    if (force === 'end') {
      this.p_p = 0;
      this.out('\n');
      this.space = false;
    }

    if (this.p_p) {
      this.out(new Array(this.p_p + 1).join(this.br_toggle + '\n' + bq));
      this.space = false;
      this.br_toggle = '';
    }

    if (this.space) {
      if (!this.lastWasNL) this.out(' ');
      this.space = false;
    }

    // `self.a` only fills when inline_links is off, which it never is here, so
    // the reference-link flush in the Python original is unreachable.

    if (this.abbr_list.length && force === 'end') {
      for (var i = 0; i < this.abbr_list.length; i++) {
        this.out('  *[' + this.abbr_list[i][0] + ']: ' + this.abbr_list[i][1] + '\n');
      }
    }

    this.p_p = 0;
    this.out(data);
    this.outcount += 1;
  };

  HTML2Text.prototype.handleData = function (data, entityChar) {
    if (!data) return;

    if (this.stressed) {
      data = pyStrip(data);
      this.stressed = false;
      this.preceding_stressed = true;
    } else if (this.preceding_stressed) {
      if (
        !isPySpace(data.charAt(0)) && "][(){}.!?".indexOf(data.charAt(0)) === -1 &&
        !hn(this.current_tag) &&
        this.current_tag !== 'a' &&
        this.current_tag !== 'code' &&
        this.current_tag !== 'pre'
      ) {
        data = ' ' + data;
      }
      this.preceding_stressed = false;
    }

    if (this.maybe_automatic_link !== null) {
      var href = this.maybe_automatic_link;
      if (href === data && /^[a-zA-Z+]+:\/\//.test(href)) {
        this.o('<' + data + '>');
        this.empty_link = false;
        return;
      }
      this.o('[');
      this.maybe_automatic_link = null;
      this.empty_link = false;
    }

    if (!this.code && !this.pre && !entityChar) data = escapeMdSection(data);
    this.preceding_data = data;
    this.o(data, true, false);
  };

  HTML2Text.prototype.handleTag = function (tag, attrs, start) {
    this.current_tag = tag;

    if (
      start &&
      this.maybe_automatic_link !== null &&
      tag !== 'p' && tag !== 'div' && tag !== 'style' && tag !== 'dl' && tag !== 'dt' &&
      tag !== 'img'
    ) {
      this.o('[');
      this.maybe_automatic_link = null;
      this.empty_link = false;
    }

    var level = hn(tag);
    if (level) {
      if (this.astack.length) {
        if (start) {
          this.inheader = true;
          if (this.outtextlist.length && this.outtextlist[this.outtextlist.length - 1] === '[') {
            this.outtextlist.pop();
            this.space = false;
            this.o(new Array(level + 1).join('#') + ' ');
            this.o('[');
          }
        } else {
          this.p_p = 0;
          this.inheader = false;
          return;
        }
      } else {
        this.p();
        if (start) {
          this.inheader = true;
          this.o(new Array(level + 1).join('#') + ' ');
        } else {
          this.inheader = false;
          return;
        }
      }
    }

    if (tag === 'p' || tag === 'div') {
      if (this.astack.length) {
        // inside a link name — no paragraph break
      } else if (this.split_next_td) {
        // inside a table cell — no paragraph break
      } else {
        this.p();
      }
    }

    if (tag === 'br' && start) {
      if (this.blockquote > 0) this.o('  \n> ');
      else this.o('  \n');
    }

    if (tag === 'hr' && start) {
      this.p();
      this.o('* * *');
      this.p();
    }

    if (tag === 'head' || tag === 'style' || tag === 'script') {
      if (start) this.quiet += 1;
      else this.quiet -= 1;
    }

    if (tag === 'style') {
      if (start) this.style += 1;
      else this.style -= 1;
    }

    if (tag === 'body') this.quiet = 0;

    if (tag === 'blockquote') {
      if (start) {
        this.p();
        this.o('> ', false, true);
        this.start = true;
        this.blockquote += 1;
      } else {
        this.blockquote -= 1;
        this.p();
      }
    }

    if (tag === 'em' || tag === 'i' || tag === 'u') {
      var emphasis;
      var prev = this.preceding_data.charAt(this.preceding_data.length - 1);
      if (start && this.preceding_data && ASCII_WHITESPACE.indexOf(prev) === -1 && PY_PUNCTUATION.indexOf(prev) === -1) {
        emphasis = ' _';
        this.preceding_data += ' ';
      } else {
        emphasis = '_';
      }
      this.o(emphasis);
      if (start) this.stressed = true;
    }

    if (tag === 'strong' || tag === 'b') {
      var strong;
      if (start && this.preceding_data && this.preceding_data.charAt(this.preceding_data.length - 1) === '*') {
        strong = ' **';
        this.preceding_data += ' ';
      } else {
        strong = '**';
      }
      this.o(strong);
      if (start) this.stressed = true;
    }

    if (tag === 'del' || tag === 'strike' || tag === 's') {
      var strike;
      if (start && this.preceding_data && this.preceding_data.charAt(this.preceding_data.length - 1) === '~') {
        strike = ' ~~';
        this.preceding_data += ' ';
      } else {
        strike = '~~';
      }
      this.o(strike);
      if (start) this.stressed = true;
    }

    if ((tag === 'kbd' || tag === 'code' || tag === 'tt') && !this.pre) {
      this.o('`');
      this.code = !this.code;
    }

    if (tag === 'abbr') {
      if (start) {
        this.abbr_title = null;
        this.abbr_data = '';
        if ('title' in attrs) this.abbr_title = attrs.title;
      } else {
        if (this.abbr_title !== null) this.abbr_list.push([this.abbr_data, this.abbr_title]);
        this.abbr_title = null;
        this.abbr_data = null;
      }
    }

    if (tag === 'q') {
      this.o(this.quote ? '"' : '"');
      this.quote = !this.quote;
    }

    if (tag === 'a') {
      if (start) {
        var href = attrs.href;
        if (href != null && href.indexOf('#') !== 0) {
          this.astack.push(attrs);
          this.maybe_automatic_link = href;
          this.empty_link = true;
        } else {
          this.astack.push(null);
        }
      } else if (this.astack.length) {
        var a = this.astack.pop();
        if (this.maybe_automatic_link && !this.empty_link) {
          this.maybe_automatic_link = null;
        } else if (a) {
          if (this.empty_link) {
            this.o('[');
            this.empty_link = false;
            this.maybe_automatic_link = null;
          }
          this.p_p = 0;
          var title = escapeMd(a.title || '');
          title = title.trim() ? ' "' + title + '"' : '';
          this.o('](' + escapeMd(a.href) + title + ')');
        }
      }
    }

    if (tag === 'img' && start) {
      if (attrs.src != null) {
        var alt = attrs.alt || '';
        if (this.maybe_automatic_link !== null) {
          this.o('[');
          this.maybe_automatic_link = null;
          this.empty_link = false;
        }
        this.o('![' + escapeMd(alt) + ']');
        this.o('(' + escapeMd(attrs.src) + ')');
      }
    }

    if (tag === 'dl' && start) this.p();
    if (tag === 'dt' && !start) this.pbr();
    if (tag === 'dd' && start) this.o('    ');
    if (tag === 'dd' && !start) this.pbr();

    if (tag === 'ol' || tag === 'ul') {
      if (!this.list.length && !this.lastWasList) this.p();
      if (start) {
        var numberingStart = 0;
        if ('start' in attrs) {
          var parsed = parseInt(attrs.start, 10);
          if (!isNaN(parsed)) numberingStart = parsed - 1;
        }
        this.list.push({ name: tag, num: numberingStart });
      } else if (this.list.length) {
        this.list.pop();
        if (!this.list.length) this.o('\n');
      }
      this.lastWasList = true;
    } else {
      this.lastWasList = false;
    }

    if (tag === 'li') {
      this.list_code_indent = '';
      this.pbr();
      if (start) {
        var li = this.list.length ? this.list[this.list.length - 1] : { name: 'ul', num: 0 };
        var parentList = null;
        for (var i = 0; i < this.list.length; i++) {
          this.list_code_indent += parentList === 'ol' ? '   ' : '  ';
          parentList = this.list[i].name;
        }
        this.o(this.list_code_indent);
        if (li.name === 'ul') {
          this.list_code_indent += '  ';
          this.o('* ');
        } else if (li.name === 'ol') {
          li.num += 1;
          this.list_code_indent += '   ';
          this.o(li.num + '. ');
        }
        this.start = true;
      }
    }

    if (tag === 'table' || tag === 'tr' || tag === 'td' || tag === 'th') {
      if (tag === 'table' && start) this.table_start = true;
      if ((tag === 'td' || tag === 'th') && start) {
        if (this.split_next_td) this.o('| ');
        this.split_next_td = true;
      }
      if (tag === 'tr' && start) this.td_count = 0;
      if (tag === 'tr' && !start) {
        this.split_next_td = false;
        this.soft_br();
      }
      if (tag === 'tr' && !start && this.table_start) {
        var dashes = [];
        for (var d = 0; d < this.td_count; d++) dashes.push('---');
        this.o(dashes.join('|'));
        this.soft_br();
        this.table_start = false;
      }
      if ((tag === 'td' || tag === 'th') && start) this.td_count += 1;
    }

    if (tag === 'pre') {
      if (start) {
        this.startpre = true;
        this.pre = true;
        this.pre_indent = '';
      } else {
        this.pre = false;
      }
      this.p();
    }
  };

  HTML2Text.prototype.finish = function () {
    this.pbr();
    this.o('', false, 'end');
    return this.outtextlist.join('');
  };

  // ── DOM -> parser events ─────────────────────────────────────────────────

  /**
   * Feed one text node.
   *
   * html2text is normally fed a serialized string and parses it with
   * convert_charrefs=False, so every character the serializer wrote as an
   * entity (`&`, `<`, `>`, and U+00A0) arrives as its own chunk with
   * entity_char=True — which skips markdown escaping and resets the
   * line-anchored escape rules. Splitting the text node at exactly those
   * characters reproduces the same chunking from a DOM.
   */
  function emitText(h, text) {
    var buf = '';
    for (var i = 0; i < text.length; i++) {
      var ch = text.charAt(i);
      if (ENTITY_CHARS[ch] === 1) {
        if (buf) { h.handleData(buf, false); buf = ''; }
        h.handleData(ch, true);
      } else {
        buf += ch;
      }
    }
    if (buf) h.handleData(buf, false);
  }

  function feedNode(h, node) {
    var type = node.nodeType;
    if (type === NODE_TEXT || type === NODE_CDATA) {
      emitText(h, node.data);
      return;
    }
    if (type !== NODE_ELEMENT) return; // comments are dropped by pulpie's parser

    var tag = tagNameOf(node);
    h.handleTag(tag, attrsOf(node), true);
    if (VOID_TAGS[tag]) return;
    for (var c = node.firstChild; c; c = c.nextSibling) feedNode(h, c);
    h.handleTag(tag, {}, false);
  }

  /**
   * pulpie.markdown.to_markdown — spacer-image strip, then html2text, then
   * strip(). Clones first so a caller's tree is never modified.
   */
  function toMarkdown(rootOrDocument) {
    var el = documentElementOf(rootOrDocument);
    if (!el) return '';
    return markdownOfOwnedTree(el.cloneNode(true));
  }

  /** to_markdown for a tree this module already owns — skips the extra clone. */
  function markdownOfOwnedTree(el) {
    stripSpacerImages(el);
    var h = new HTML2Text();
    feedNode(h, el);
    return pyStrip(h.finish());
  }

  // ── entry point ──────────────────────────────────────────────────────────

  function extractMainMarkdown(root, labels, options) {
    var el = documentElementOf(root);
    if (!el) return '';
    var clone = el.cloneNode(true);
    pruneToMain(clone, labels, options);
    if (options && options.stripLxmlBlanks) stripLxmlBlanks(clone);
    return markdownOfOwnedTree(clone);
  }

  global.PulpieMarkdown = {
    extractMainMarkdown: extractMainMarkdown,
    pruneToMain: pruneToMain,
    stripSpacerImages: stripSpacerImages,
    stripLxmlBlanks: stripLxmlBlanks,
    toMarkdown: toMarkdown,
    ITEM_ID_ATTR: ITEM_ID_ATTR,
    TAIL_BLOCK_TAG: TAIL_BLOCK_TAG
  };
})(typeof globalThis !== 'undefined' ? globalThis : this);
