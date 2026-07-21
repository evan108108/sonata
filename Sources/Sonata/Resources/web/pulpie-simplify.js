/**
 * pulpie-simplify.js — DOM-native port of pulpie's Python `simplify()` step.
 *
 * WHY THIS EXISTS
 * ---------------
 * Sonata's `read` tool runs inside a WKWebView that already holds a live,
 * script-executed DOM. Pulpie's Python `simplify()` starts from a raw HTML
 * string (selectolax -> lxml). Re-serializing the live DOM and shipping it to
 * Python (or re-parsing it in Swift) throws away the one advantage we have —
 * the DOM is already built. This module walks that DOM directly and emits the
 * same labeled block sequence pulpie's Orange classifier was trained on.
 *
 * Upstream: pulpie/simplify.py, itself a faithful port of MinerU-HTML's
 * `simplify_html` (github.com/opendatalab/MinerU-HTML @ 73cf266, Apache-2.0).
 * The Orange models were distilled against MinerU's exact segmentation, so this
 * is a TRANSLATION, not a redesign. Where the Python has quirks (see
 * INHERITED QUIRKS) they are reproduced deliberately: "fixing" them would move
 * block boundaries away from what the model expects.
 *
 * INVARIANTS
 * ----------
 * 1. PURE w.r.t. the live DOM except for one attribute. The algorithm needs a
 *    mutable tree (it removes <script>/<nav>/hidden nodes, collapses long
 *    lists, truncates text). It gets one: `buildShadow()` mirrors the DOM into
 *    a plain-object tree in lxml's text/tail model, and every mutation happens
 *    there. Each shadow node keeps a `.live` back-pointer, which replaces
 *    Python's `data-uid` round-trip. The ONLY write to the real document is
 *    `data-pulpie-id` (see #4). No network, no eval, no style/layout reads.
 *
 * 2. lxml TEXT MODEL, not the DOM text model. lxml gives each element a `.text`
 *    (chars before its first child) and each element a `.tail` (chars after it,
 *    before the next sibling). `buildShadow()` folds DOM text nodes into that
 *    shape, because every offset, strip() and tail-merge in the algorithm is
 *    written against it. Comments are dropped during the fold, matching lxml's
 *    `HTMLParser(remove_comments=True)`.
 *
 * 3. ITEM IDS ARE 1-BASED AND DENSE, IN DOCUMENT ORDER. A paragraph that fails
 *    the `isMeaningfulContent` gate is skipped WITHOUT consuming an id, exactly
 *    as in `process_paragraphs`. The classifier keys on these ids, so an
 *    off-by-one shifts every downstream label.
 *
 * 4. `data-pulpie-id` MAY HOLD SEVERAL IDS. Python marks unwrapped text runs by
 *    splicing a `<cc-alg-uc-text _item_id="N">` wrapper into the tree. We must
 *    not restructure a live page (it would reflow layout and break rerun
 *    idempotency), so instead the id lands on the element that WOULD have been
 *    the wrapper's parent. One parent can own several runs, so the attribute is
 *    a space-separated id list, and each block additionally carries an
 *    `anchor` describing the exact child range / text slot it covered.
 *
 *    Consumers MUST split the attribute on whitespace, and MUST use `anchor` to
 *    locate content when a parent carries more than one id — the id alone
 *    resolves only to the parent, which over-selects its sibling runs. Anchors:
 *
 *      {kind:'element'}                            whole marked element
 *      {kind:'child-range', startIndex, endIndex}  element children [start..end]
 *                                                  inclusive, plus text between
 *      {kind:'parent-text'}                        text before the first child
 *      {kind:'child-tail', childIndex}             text after that child
 *
 *    All indices are into the LIVE parent's `.children` (elements only), NOT
 *    this pass's internal tree — the two differ by however many siblings were
 *    dropped as <script>/<nav>/hidden. `{kind:'element', unresolved:true}` means
 *    no live index existed (re-parsed <template>/<noscript> interiors); treat it
 *    as the whole element. No `<cc-alg-uc-text>` element is ever emitted.
 *
 * 5. RERUNNABLE. `simplify()` clears every `data-pulpie-id` it finds before it
 *    starts, so running twice on the same page yields the same result rather
 *    than accumulating ids.
 *
 * INHERITED QUIRKS (present in Python; reproduced on purpose)
 * ----------------------------------------------------------
 * - `mergeInlineContent` assigns `lastInserted = item` (the ORIGINAL node) but
 *   appends `itemCopy`. Trailing text therefore mutates the source tree and is
 *   absent from the emitted block, which already carries the pre-mutation tail
 *   via the deep copy. Faithfully reproduced.
 * - `listTypes` is filled in document order while `isContentList` consults it,
 *   so an OUTER list is judged before its nested lists are classified; the
 *   nested `<li>`s then read as block elements and disqualify the outer list.
 * - The mid-loop block emit lacks the "all text sources -> unwrapped_text"
 *   clause that the end-of-node emit has, so identical content can be typed
 *   `mixed` in one position and `unwrapped_text` in the other.
 * - Paragraph de-duplication keys on markup that embeds a per-node uid, so it
 *   only ever collapses genuinely identical emissions from the same node.
 *
 * MEASURED PARITY (4-page corpus: Wikipedia, Socrata SPA, MDN, AP News —
 * 6.2 MB of WKWebView-rendered HTML, 1508 blocks)
 * ------------------------------------------------------------------------
 *   block count      1508 / 1508  exact on every page
 *   block text       1508 / 1508  exact after whitespace normalization
 *   block markup     1466 / 1508  byte-identical (42 differ, both causes below)
 *   Orange labels    1507 / 1508  agree (99.93%)
 * Verified three ways: jsdom, a real WKWebView, and the Python service itself.
 *
 * KNOWN DIVERGENCES FROM PYTHON (documented, not accidental)
 * ---------------------------------------------------------
 * - <picture>/<source> (40 of the 42 markup diffs, and the ONLY label flip).
 *   libxml2 uses an HTML4 element table where <source> is a CONTAINER, so it
 *   nests the following <img> inside it and the block root serializes as
 *   <source>. In an HTML5 DOM <source> is void, so <img> is its sibling and the
 *   root is <picture>. Content is identical either way; only the wrapper tag
 *   name differs. Not emulated: reproducing a legacy parser's element table in
 *   JS is far more fragile than the 1-in-1508 label flip it would buy back.
 * - Block roots of <body>/<html> (2 of the 42). Python re-parses each emitted
 *   block through `lxml.html.fragment_fromstring`, which silently unwraps the
 *   body shell; we keep the tree we built, so the wrapper and its class/id
 *   survive. Ours retains strictly more information and never drops a block —
 *   the re-parse can also raise and discard a block outright.
 * - Shadow roots are not traversed. <template> IS traversed via `.content`
 *   (see buildShadow), but an attached shadow root has no lxml counterpart at
 *   all, so its content is invisible to both sides.
 * - `shouldRemoveElement` reads the inline `style` attribute only — same as
 *   Python. We deliberately do NOT consult `getComputedStyle`, even though it
 *   would be more accurate on a live page, because it would desynchronize
 *   segmentation from the trained model.
 *
 * @module pulpie-simplify
 */

// ── Tag sets (verbatim from pulpie/simplify.py) ─────────────────────────────

/** Inline tags — never start a new block. */
const INLINE_TAGS = new Set([
  'map', 'optgroup', 'span', 'input', 'time', 'u', 'strong', 'small', 'sub',
  'samp', 'blink', 'b', 'code', 'nobr', 'strike', 'bdo', 'basefont', 'abbr',
  'var', 'i', 'cccode-inline', 's', 'pic', 'label', 'mark', 'object',
  'ccmath-inline', 'svg', 'button', 'a', 'font', 'dfn', 'sup', 'kbd', 'q',
  'script', 'acronym', 'option', 'img', 'big', 'cite', 'em', 'marked-tail',
  'marked-text',
]);

/** Table-internal tags that may legally live inside a data table. */
const TABLE_TAGS = new Set([
  'caption', 'colgroup', 'col', 'thead', 'tbody', 'tfoot', 'tr', 'td', 'th', 'br',
]);

/** Removed wholesale before paragraph extraction. */
const TAGS_TO_REMOVE = new Set([
  'title', 'head', 'style', 'script', 'link', 'meta', 'iframe', 'frame', 'nav',
]);

/** Block-level, but assumed to contain no block children. */
const NO_BLOCK_TAGS = new Set(['math']);

/** Text inside these is excluded from truncation length accounting. */
const NO_CALC_TEXT_TAGS = new Set(['math', 'table']);

/** class/id values dropped when the element is a direct child of <body>. */
const ATTR_PATTERNS_TO_REMOVE = new Set(['nav']);

/** Inline-style declarations that mark an element invisible. */
const ATTR_INVISIBLE = {
  'display': 'none',
  'font-size': '0px',
  'color': 'transparent',
  'visibility': 'hidden',
  'opacity': '0',
};

/** Wrapper tag Python splices in for unwrapped text runs (we only name it). */
const TAIL_BLOCK_TAG = 'cc-alg-uc-text';

/** Attribute the live DOM is tagged with. */
const PULPIE_ID_ATTR = 'data-pulpie-id';

/** Default per-block text budget, matching `simplify(cutoff_length=500)`. */
const DEFAULT_CUTOFF_LENGTH = 500;

/** HTML void elements — serialized without a closing tag (lxml method="html"). */
const VOID_ELEMENTS = new Set([
  'area', 'base', 'basefont', 'br', 'col', 'command', 'embed', 'frame', 'hr',
  'img', 'input', 'isindex', 'keygen', 'link', 'meta', 'param', 'source',
  'track', 'wbr',
]);

// ── Shadow tree ─────────────────────────────────────────────────────────────

/**
 * A mirror of one DOM element in lxml's text/tail model.
 *
 * @typedef {object} ShadowNode
 * @property {number}        uid       Stable identity; stands in for `data-uid`.
 * @property {string}        tag       Lower-cased tag name.
 * @property {Array<[string,string]>} attrs Source-ordered attributes.
 * @property {?string}       text      Characters before the first child.
 * @property {?string}       tail      Characters after this node, before its sibling.
 * @property {ShadowNode[]}  children  Element children only.
 * @property {?ShadowNode}   parent    Parent, or null at the root.
 * @property {?Element}      live      The real DOM element this mirrors.
 * @property {boolean}       ccNoBlock Processing-tree marker (`cc-no-block`).
 * @property {boolean}       ccBlockType Source-tree marker (`cc-block-type`).
 */

/**
 * Mirror a live DOM subtree into a shadow tree.
 *
 * Text nodes are folded into the lxml text/tail model; comments, CDATA and
 * processing instructions are dropped (lxml parses with remove_comments=True).
 *
 * @param {Element} liveEl
 * @param {?ShadowNode} parent
 * @param {{next: number}} counter Mutable uid source.
 * @param {Map<number, ShadowNode>} uidMap Populated with uid -> node.
 * @returns {ShadowNode}
 */
function buildShadow(liveEl, parent, counter, uidMap) {
  const attrs = [];
  for (const attr of liveEl.attributes) attrs.push([attr.name, attr.value]);

  const node = {
    uid: counter.next++,
    tag: liveEl.tagName.toLowerCase(),
    attrs,
    text: null,
    tail: null,
    children: [],
    parent,
    live: liveEl,
    ccNoBlock: false,
    ccBlockType: false,
  };
  uidMap.set(node.uid, node);

  // Two places where a live DOM's shape differs from lxml's parse of the same
  // bytes. Both are resolved toward lxml, because the classifier was trained on
  // lxml's segmentation.
  //
  //   <template>  — parks its children in a detached DocumentFragment. lxml
  //                 parses them as ordinary children. (AP News alone hides 241
  //                 blocks in templates.)
  //   <noscript>  — with scripting ENABLED, the HTML5 parser keeps the content
  //                 as one raw TEXT node; lxml always parses it as markup.
  //                 Left alone, a tracking-pixel <noscript> feeds ~200 chars of
  //                 literal "<img src=...>" to the model as if it were prose.
  let childSource = liveEl.childNodes;
  if (node.tag === 'template' && liveEl.content) {
    childSource = liveEl.content.childNodes;
  } else if (node.tag === 'noscript') {
    const reparsed = reparseNoscript(liveEl);
    if (reparsed) childSource = reparsed;
  }

  let cursor = null; // last element child appended — owns subsequent text
  for (const child of childSource) {
    if (child.nodeType === 3 || child.nodeType === 4) {
      // Text / CDATA: append to .text if no element child yet, else to .tail.
      if (cursor === null) node.text = (node.text ?? '') + child.data;
      else cursor.tail = (cursor.tail ?? '') + child.data;
    } else if (child.nodeType === 1) {
      const shadowChild = buildShadow(child, node, counter, uidMap);
      node.children.push(shadowChild);
      cursor = shadowChild;
    }
    // Comments (8) and everything else: dropped, mirroring remove_comments.
  }
  return node;
}

/**
 * Re-parse a scripting-enabled `<noscript>`'s raw text back into elements.
 *
 * Parsing happens in a DETACHED element, so nothing is added to the live
 * document, and per spec markup inserted via innerHTML never executes — this
 * stays within the "no eval, no side effects" invariant.
 *
 * @returns {?NodeList} Parsed children, or null if this noscript was already
 *   parsed as markup (scripting disabled) and needs no help.
 */
function reparseNoscript(liveEl) {
  const kids = liveEl.childNodes;
  if (kids.length !== 1 || kids[0].nodeType !== 3) return null;
  try {
    const holder = liveEl.ownerDocument.createElement('div');
    holder.innerHTML = kids[0].data;
    return holder.childNodes;
  } catch {
    return null;
  }
}

/** Deep-copy a shadow node, preserving uid and `.live` (lxml's deepcopy keeps data-uid). */
function deepClone(node, parent = null) {
  const copy = {
    uid: node.uid,
    tag: node.tag,
    attrs: node.attrs.map((pair) => [pair[0], pair[1]]),
    text: node.text,
    tail: node.tail,
    children: [],
    parent,
    live: node.live,
    ccNoBlock: node.ccNoBlock,
    ccBlockType: node.ccBlockType,
  };
  for (const child of node.children) copy.children.push(deepClone(child, copy));
  return copy;
}

/** `html.Element(tag)` + `attrib.update(src.attrib)` — a childless, textless shell. */
function shellFrom(node) {
  return {
    uid: node.uid,
    tag: node.tag,
    attrs: node.attrs.map((pair) => [pair[0], pair[1]]),
    text: null,
    tail: null,
    children: [],
    parent: null,
    live: node.live,
    ccNoBlock: false,
    ccBlockType: false,
  };
}

/** Depth-first descendants in document order, excluding `node` itself. */
function* iterDescendants(node) {
  for (const child of node.children) {
    yield child;
    yield* iterDescendants(child);
  }
}

/** Depth-first, including `node` itself. */
function* iterSelfAndDescendants(node) {
  yield node;
  yield* iterDescendants(node);
}

/** Detach `child` from its parent, dropping its tail (lxml's `parent.remove`). */
function removeChild(parent, child) {
  const idx = parent.children.indexOf(child);
  if (idx === -1) return;
  parent.children.splice(idx, 1);
  child.parent = null;
}

function getAttr(node, name) {
  for (const pair of node.attrs) if (pair[0] === name) return pair[1];
  return null;
}

function setAttr(node, name, value) {
  for (const pair of node.attrs) {
    if (pair[0] === name) { pair[1] = value; return; }
  }
  node.attrs.push([name, value]);
}

function previousSibling(node) {
  if (!node.parent) return null;
  const idx = node.parent.children.indexOf(node);
  return idx > 0 ? node.parent.children[idx - 1] : null;
}

// ── Serialization ───────────────────────────────────────────────────────────

function escapeText(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function escapeAttr(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/**
 * Serialize a shadow subtree, mirroring `lxml.etree.tostring(method="html")`.
 *
 * @param {ShadowNode} node
 * @param {{withUid?: boolean}} [opts] Emit a synthetic `data-uid`, which the
 *   Python paragraph stage carries and which keeps de-duplication faithful.
 * @returns {string}
 */
function serialize(node, opts = {}) {
  const out = [];
  writeNode(node, out, opts, true);
  return out.join('');
}

function writeNode(node, out, opts, isRoot) {
  out.push('<', node.tag);
  for (const [name, value] of node.attrs) out.push(' ', name, '="', escapeAttr(value), '"');
  if (opts.withUid) out.push(' data-uid="', String(node.uid), '"');
  out.push('>');

  if (!VOID_ELEMENTS.has(node.tag)) {
    if (node.text) out.push(escapeText(node.text));
    for (const child of node.children) writeNode(child, out, opts, false);
    out.push('</', node.tag, '>');
  }
  if (!isRoot && node.tail) out.push(escapeText(node.tail));
}

/** Collapse whitespace runs that sit outside tags — port of `post_process_html`. */
function postProcessHtml(htmlContent) {
  if (!htmlContent) return htmlContent;
  return htmlContent.replace(/(<[^>]+>)|([^<]+)/g, (match, tagPart, textPart) => {
    if (tagPart) return tagPart;
    if (textPart) return textPart.replace(/\s+/g, ' ');
    return match;
  }).trim();
}

/** Visible text of a block, whitespace-normalized. */
function blockText(node) {
  const parts = [];
  const walk = (n, isRoot) => {
    if (n.text) parts.push(n.text);
    for (const child of n.children) walk(child, false);
    if (!isRoot && n.tail) parts.push(n.tail);
  };
  walk(node, true);
  return parts.join(' ').replace(/\s+/g, ' ').trim();
}

// ── Table / list classification ─────────────────────────────────────────────

/** True if any node descends from `tableElement` without crossing a nested table. */
function judgeTableParent(tableElement, nodeList) {
  for (const node of nodeList) {
    let ancestor = node.parent;
    while (ancestor !== null) {
      if (ancestor === tableElement) return true;
      if (ancestor.tag === 'table') break;
      ancestor = ancestor.parent;
    }
  }
  return false;
}

/** Descendants of `node` whose tag is in `tags`. */
function descendantsByTag(node, tags) {
  const found = [];
  for (const d of iterDescendants(node)) if (tags.has(d.tag)) found.push(d);
  return found;
}

/** Distinguish a data table (real content) from a layout table. */
function isDataTable(tableElement) {
  if (judgeTableParent(tableElement, descendantsByTag(tableElement, new Set(['caption'])))) return true;

  const colNodes = descendantsByTag(tableElement, new Set(['col']));
  const colgroupNodes = descendantsByTag(tableElement, new Set(['colgroup']));
  if (judgeTableParent(tableElement, colNodes) || judgeTableParent(tableElement, colgroupNodes)) return true;

  const cellNodes = descendantsByTag(tableElement, new Set(['td', 'th']))
    .filter((n) => getAttr(n, 'headers') !== null);
  if (judgeTableParent(tableElement, cellNodes)) return true;

  if (getAttr(tableElement, 'role') === 'table' || getAttr(tableElement, 'data-table') !== null) return true;

  for (const node of iterDescendants(tableElement)) {
    if (TABLE_TAGS.has(node.tag)) continue;
    if (!INLINE_TAGS.has(node.tag)) return false;
  }
  return true;
}

/** True if a list has direct children that are not its expected item tags. */
function hasNonListitemChildren(listElement) {
  let allowed;
  if (listElement.tag === 'ul' || listElement.tag === 'ol') allowed = new Set(['li']);
  else if (listElement.tag === 'dl') allowed = new Set(['dt', 'dd']);
  else allowed = new Set();

  if (allowed.size > 0) {
    for (const child of listElement.children) if (!allowed.has(child.tag)) return true;
  }
  // Direct text children — `./text()` covers .text plus every child's .tail.
  if (listElement.text && listElement.text.trim()) return true;
  for (const child of listElement.children) if (child.tail && child.tail.trim()) return true;
  return false;
}

// ── Paragraph extraction (port of `extract_paragraphs`, include_parents=False) ──

/**
 * Walk the cleaned tree and emit a flat, ordered list of content paragraphs.
 *
 * @param {ShadowNode} processingDom
 * @returns {Array<{html: string, root: ShadowNode, contentType: string, originalElement: ShadowNode}>}
 */
function extractParagraphs(processingDom) {
  /** @type {Map<number, boolean>} */
  const tableTypes = new Map();
  for (const table of iterSelfAndDescendants(processingDom)) {
    if (table.tag === 'table' && table !== processingDom) tableTypes.set(table.uid, isDataTable(table));
  }

  /** @type {Map<number, boolean>} — deliberately filled lazily, see INHERITED QUIRKS. */
  const listTypes = new Map();

  /** Climb to the nearest ancestor (self included) in `expectedTags`. */
  function judgeSpecialCase(node, expectedTags, typesMap) {
    let ancestor = node;
    while (ancestor !== null && !expectedTags.has(ancestor.tag)) ancestor = ancestor.parent;
    if (ancestor !== null) return !(typesMap.get(ancestor.uid) ?? false);
    return null;
  }

  function isBlockElement(node) {
    if (node.tag === 'td' || node.tag === 'th') {
      return judgeSpecialCase(node, new Set(['table']), tableTypes);
    }
    if (node.tag === 'li') return judgeSpecialCase(node, new Set(['ul', 'ol']), listTypes);
    if (node.tag === 'dt' || node.tag === 'dd') return judgeSpecialCase(node, new Set(['dl']), listTypes);
    if (NO_BLOCK_TAGS.has(node.tag) || INLINE_TAGS.has(node.tag)) return false;
    return true;
  }

  function hasBlockDescendants(node) {
    if (NO_BLOCK_TAGS.has(node.tag)) return false;
    for (const child of iterDescendants(node)) {
      const parent = child.parent;
      if (parent !== null && (NO_BLOCK_TAGS.has(parent.tag) || parent.ccNoBlock)) child.ccNoBlock = true;
      if (!child.ccNoBlock && isBlockElement(child)) {
        // Python marks the ORIGINAL element here; our shadow node is both.
        if (INLINE_TAGS.has(node.tag)) node.ccBlockType = true;
        return true;
      }
    }
    return false;
  }

  function isContentList(listElement) {
    const items = listElement.children.filter(
      (c) => c.tag === 'li' || c.tag === 'dt' || c.tag === 'dd');
    if (items.length === 0) return false;
    if (hasNonListitemChildren(listElement)) return false;
    return items.every((item) => !hasBlockDescendants(item));
  }

  for (const el of iterSelfAndDescendants(processingDom)) {
    if (el === processingDom) continue;
    if (el.tag === 'ul' || el.tag === 'ol' || el.tag === 'dl') {
      listTypes.set(el.uid, isContentList(el));
    }
  }

  const paragraphs = [];

  /** Port of `merge_inline_content`, quirk included (see module header). */
  function mergeInlineContent(parent, contentList) {
    let lastInserted = null;
    contentList.forEach(([itemType, item], idx) => {
      if (itemType === 'direct_text' || itemType === 'tail_text') {
        if (lastInserted === null) {
          if (!parent.text) parent.text = item;
          else parent.text += ' ' + item;
        } else if (lastInserted.tail === null || lastInserted.tail === undefined) {
          lastInserted.tail = item;
        } else {
          lastInserted.tail += ' ' + item;
        }
      } else {
        const itemCopy = deepClone(item, parent);
        if (idx === contentList.length - 1 && itemCopy.tag === 'br') itemCopy.tail = null;
        parent.children.push(itemCopy);
        lastInserted = item; // NOT itemCopy — upstream behavior, reproduced.
      }
    });
  }

  function emit(rootNode, contentType, originalElement) {
    paragraphs.push({
      html: serialize(rootNode, { withUid: true }).trim(),
      root: rootNode,
      contentType,
      originalElement,
    });
  }

  function classify(contentSources, allowTailOnly) {
    if (contentSources.every((t) => t === 'direct_text')) return 'unwrapped_text';
    if (contentSources.every((t) => t === 'element')) return 'inline_elements';
    if (allowTailOnly && contentSources.every((t) => t === 'direct_text' || t === 'tail_text')) {
      return 'unwrapped_text';
    }
    return 'mixed';
  }

  function processNode(node) {
    let inlineContent = [];
    let contentSources = [];

    if (node.text && node.text.trim()) {
      inlineContent.push(['direct_text', node.text.trim()]);
      contentSources.push('direct_text');
    }

    // Snapshot: mergeInlineContent mutates tails of nodes in this list.
    for (const child of [...node.children]) {
      if (isBlockElement(child) || hasBlockDescendants(child)) {
        if (child.tag === 'br') {
          inlineContent.push(['element', child]);
          contentSources.push('element');
        }
        if (inlineContent.length > 0) {
          const shell = shellFrom(node);
          mergeInlineContent(shell, inlineContent);
          // NOTE: the mid-loop emit lacks the tail-only clause. Quirk, kept.
          emit(shell, classify(contentSources, false), node);
          inlineContent = [];
          contentSources = [];
        }
        if (child.tag !== 'br') {
          if (tableTypes.get(child.uid) || !hasBlockDescendants(child)) {
            const shell = shellFrom(child);
            shell.text = child.text ? child.text : null;
            for (const grandchild of child.children) shell.children.push(deepClone(grandchild, shell));
            emit(shell, 'block_element', child);
          } else {
            processNode(child);
          }
        }
        if (child.tail && child.tail.trim()) {
          inlineContent.push(['tail_text', child.tail.trim()]);
          contentSources.push('tail_text');
        }
      } else {
        inlineContent.push(['element', child]);
        contentSources.push('element');
        if (child.tail && child.tail.trim()) {
          inlineContent.push(['tail_text', child.tail.trim()]);
          contentSources.push('tail_text');
        }
      }
    }

    if (inlineContent.length > 0) {
      const shell = shellFrom(node);
      mergeInlineContent(shell, inlineContent);
      emit(shell, classify(contentSources, true), node);
    }
  }

  processNode(processingDom);

  const seen = new Set();
  const unique = [];
  for (const p of paragraphs) {
    if (!seen.has(p.html)) { seen.add(p.html); unique.push(p); }
  }
  return unique;
}

// ── Cleanup helpers ─────────────────────────────────────────────────────────

/** Port of `remove_tags` — drops the node AND its tail, as lxml's remove does. */
function removeTags(dom) {
  const doomed = [];
  for (const node of iterDescendants(dom)) if (TAGS_TO_REMOVE.has(node.tag)) doomed.push(node);
  for (const node of doomed) if (node.parent) removeChild(node.parent, node);
}

function isMeaningfulContent(element) {
  if (element.text && element.text.trim()) return true;
  if (element.tag === 'img') {
    const src = getAttr(element, 'src') ?? '';
    return Boolean(src && src.trim());
  }
  for (const child of element.children) if (isMeaningfulContent(child)) return true;
  return Boolean(element.tail && element.tail.trim());
}

/** Keep only class/id (plus src/alt on <img>); drop every other attribute. */
function cleanAttributes(element) {
  const classAttr = (getAttr(element, 'class') ?? '').trim();
  const idAttr = (getAttr(element, 'id') ?? '').trim();

  if (element.tag === 'img') {
    const src = (getAttr(element, 'src') ?? '').trim();
    const alt = (getAttr(element, 'alt') ?? '').trim();
    element.attrs = [];
    if (src && !src.startsWith('data:image/')) element.attrs.push(['src', src]);
    if (alt) element.attrs.push(['alt', alt]);
  } else {
    element.attrs = [];
  }
  if (classAttr) element.attrs.push(['class', classAttr]);
  if (idAttr) element.attrs.push(['id', idAttr]);

  for (const child of element.children) cleanAttributes(child);
}

/** Collapse a long list to first item + ellipsis + last item. */
function simplifyList(element) {
  if (element.tag === 'ul' || element.tag === 'ol') {
    const items = [...element.children];
    if (items.length > 2) {
      for (const item of items.slice(1, -1)) removeChild(element, item);
      const ellipsis = makeEllipsisSpan(element);
      element.children.splice(element.children.indexOf(items[items.length - 1]), 0, ellipsis);
    }
  } else if (element.tag === 'dl') {
    const items = [...element.children];
    if (items.length > 2) {
      const dts = items.filter((i) => i.tag === 'dt');
      if (dts.length > 1) {
        const firstDtIndex = items.indexOf(dts[0]);
        const nextDtIndex = items.indexOf(dts[1]);
        const firstGroup = items.slice(firstDtIndex, nextDtIndex);
        const lastGroup = items.slice(items.indexOf(dts[dts.length - 1]));
        element.children = [];
        for (const item of firstGroup) { item.parent = element; element.children.push(item); }
        element.children.push(makeEllipsisSpan(element));
        for (const item of lastGroup) { item.parent = element; element.children.push(item); }
      }
    }
  }
  for (const child of [...element.children]) simplifyList(child);
}

function makeEllipsisSpan(parent) {
  return {
    uid: -1, tag: 'span', attrs: [], text: '...', tail: null,
    children: [], parent, live: null, ccNoBlock: false, ccBlockType: false,
  };
}

function shouldRemoveElement(element) {
  const className = getAttr(element, 'class') ?? '';
  const idName = getAttr(element, 'id') ?? '';

  if (ATTR_PATTERNS_TO_REMOVE.has(className) || ATTR_PATTERNS_TO_REMOVE.has(idName)) {
    if (element.parent !== null && element.parent.tag === 'body') return true;
  }

  const styleAttr = getAttr(element, 'style') ?? '';
  if (styleAttr) {
    for (const decl of styleAttr.split(';')) {
      if (!decl.includes(':')) continue;
      const parts = decl.split(':');
      const key = parts[0];
      const value = parts.slice(1).join(':');
      if (ATTR_INVISIBLE[key.trim()] === value.trim()) return true;
    }
  }

  const parent = element.parent;
  if (parent !== null && parent.tag === 'details') {
    if (element.tag === 'summary') return false;
    return getAttr(parent, 'open') === null;
  }
  return false;
}

/** Bottom-up removal that preserves tail text by merging it leftward. */
function removeSpecificElements(element) {
  for (const child of [...element.children]) removeSpecificElements(child);

  if (shouldRemoveElement(element)) {
    const parent = element.parent;
    if (parent !== null) {
      const tailText = element.tail ?? '';
      element.tail = null;
      const prev = previousSibling(element);
      if (prev !== null) {
        if (prev.tail !== null && prev.tail !== undefined) prev.tail += tailText;
        else if (prev.text !== null && prev.text !== undefined) prev.text += tailText;
        else prev.text = tailText;
      } else if (parent.text !== null && parent.text !== undefined) {
        parent.text += tailText;
      } else {
        parent.text = tailText;
      }
      removeChild(parent, element);
    }
  }
}

/**
 * Truncate a block's text to `maxLength` characters, ignoring text nested in
 * `excludeTags`. Port of `truncate_html_element_selective`.
 */
function truncateHtmlElementSelective(element, maxLength, ellipsis = '...', excludeTags = new Set()) {
  const isExcluded = (node) => {
    let current = node;
    while (current !== null && current !== undefined) {
      if (excludeTags.has(current.tag)) return true;
      current = current.parent;
    }
    return false;
  };
  const isInsideExcludedTag = (node) => (node.parent ? isExcluded(node.parent) : false);

  const calcLength = (node) => {
    let total = 0;
    if (node.text && !isExcluded(node)) total += node.text.length;
    for (const child of node.children) total += calcLength(child);
    if (node.tail) total += node.tail.length;
    return total;
  };

  if (calcLength(element) <= maxLength) return element;

  const nodesToProcess = [];
  const collect = (node) => {
    if (node.text && !isExcluded(node)) {
      nodesToProcess.push({ type: 'text', node, originalText: node.text, canModify: !isInsideExcludedTag(node) });
    }
    for (const child of node.children) collect(child);
    if (node.tail) {
      nodesToProcess.push({ type: 'tail', node, originalText: node.tail, canModify: !isInsideExcludedTag(node) });
    }
  };
  collect(element);

  const cleanAncestorsFollowingSiblings = (node) => {
    const parent = node.parent;
    if (!parent) return;
    const grandparent = parent.parent;
    if (!grandparent) return;
    const index = grandparent.children.indexOf(parent);
    if (index !== -1) grandparent.children.splice(index + 1);
    cleanAncestorsFollowingSiblings(parent);
  };

  const markTruncationPoint = (node) => {
    const parent = node.parent;
    if (parent) {
      const index = parent.children.indexOf(node);
      if (index !== -1) parent.children.splice(index + 1);
    }
    cleanAncestorsFollowingSiblings(node);
  };

  let currentLength = 0;
  let ellipsisAdded = false;
  for (const info of nodesToProcess) {
    if (ellipsisAdded) {
      if (info.type === 'text') info.node.text = null;
      else info.node.tail = null;
      continue;
    }
    const textLen = info.originalText.length;
    if (currentLength + textLen <= maxLength) {
      currentLength += textLen;
    } else if (info.canModify) {
      const remaining = maxLength - currentLength;
      const truncated = info.originalText.slice(0, remaining) + ellipsis;
      if (info.type === 'text') info.node.text = truncated;
      else info.node.tail = truncated;
      currentLength = maxLength;
      ellipsisAdded = true;
      markTruncationPoint(info.node);
    } else {
      currentLength += textLen;
    }
  }
  return element;
}

// ── Paragraph -> block + live-DOM marking ───────────────────────────────────

/**
 * Clean each paragraph, assign its `_item_id`, and tag the live DOM.
 *
 * @param {Array} paragraphs From `extractParagraphs`.
 * @param {Map<number, ShadowNode>} uidMap
 * @param {number} cutoffLength
 * @returns {{blocks: Array, simplifiedHtml: string}}
 */
function processParagraphs(paragraphs, uidMap, cutoffLength) {
  const blocks = [];
  /** liveElement -> ids, so one element can carry several runs (invariant #4). */
  const liveMarks = new Map();
  let itemId = 1;

  const mark = (node, id) => {
    if (!node || !node.live) return;
    const existing = liveMarks.get(node.live);
    if (existing) existing.push(id);
    else liveMarks.set(node.live, [id]);
  };

  /**
   * Index of a shadow child within its parent's LIVE element children.
   *
   * Anchors are resolved by stage 3 against the real DOM, so they must index
   * the real DOM. Shadow indices would be wrong by however many siblings this
   * pass deleted (<script>, <nav>, hidden nodes …) — a <script> in slot 0 shifts
   * every following anchor by one and silently mis-slices the block.
   *
   * Returns -1 when the node has no live counterpart, which happens for the
   * re-parsed interiors of <template>/<noscript>: those live in a detached tree,
   * so no live index exists and stage 3 must fall back to the whole element.
   */
  const liveIndexOf = (parentShadow, childShadow) => {
    if (!parentShadow || !childShadow || !parentShadow.live || !childShadow.live) return -1;
    return Array.prototype.indexOf.call(parentShadow.live.children, childShadow.live);
  };

  for (const para of paragraphs) {
    const root = para.root;
    const rootForXpath = deepClone(root);
    const contentType = para.contentType;

    cleanAttributes(root);
    simplifyList(root);

    if (!isMeaningfulContent(root)) continue;

    truncateHtmlElementSelective(root, cutoffLength, '...', NO_CALC_TEXT_TAGS);

    const currentId = String(itemId);
    setAttr(root, '_item_id', currentId);

    const originalParent = para.originalElement;
    /** @type {object} */
    let anchor = { kind: 'element' };

    if (contentType !== 'block_element') {
      if (originalParent !== null && originalParent !== undefined) {
        // For non-block paragraphs the xpath root IS the original parent.
        const originalElement = uidMap.get(rootForXpath.uid) ?? originalParent;

        if (rootForXpath.children.length > 0) {
          if (INLINE_TAGS.has(rootForXpath.tag)
              && originalElement.tag !== 'body'
              && !originalElement.ccBlockType) {
            mark(originalElement, currentId);
            anchor = { kind: 'element' };
          } else {
            // Python splices a <cc-alg-uc-text> wrapper around this child run.
            // We tag the run's parent and record the range instead.
            const childrenToWrap = [];
            for (const child of rootForXpath.children) {
              const resolved = uidMap.get(child.uid);
              if (resolved) childrenToWrap.push(resolved);
            }
            if (childrenToWrap.length > 0) {
              const first = childrenToWrap[0];
              const last = childrenToWrap[childrenToWrap.length - 1];
              const startIdx = liveIndexOf(originalParent, first);
              const endIdx = liveIndexOf(originalParent, last);
              mark(originalParent, currentId);
              anchor = (startIdx === -1 || endIdx === -1)
                ? { kind: 'element', unresolved: true }
                : { kind: 'child-range', startIndex: startIdx, endIndex: endIdx };
            }
          }
        } else if (contentType === 'inline_elements') {
          mark(originalElement, currentId);
        } else if (rootForXpath.text && rootForXpath.text.trim()) {
          const needle = rootForXpath.text.trim();
          let found = false;
          if (originalParent.text && originalParent.text.trim() === needle) {
            mark(originalParent, currentId);
            anchor = { kind: 'parent-text' };
            found = true;
          }
          if (!found) {
            for (const child of originalParent.children) {
              if (child.tail && child.tail.trim() === needle) {
                const liveIdx = liveIndexOf(originalParent, child);
                mark(originalParent, currentId);
                anchor = (liveIdx === -1)
                  ? { kind: 'element', unresolved: true }
                  : { kind: 'child-tail', childIndex: liveIdx };
                break;
              }
            }
          }
        }
      }
    } else {
      mark(originalParent, currentId);
      anchor = { kind: 'element' };
    }

    itemId += 1;

    const cleanedHtml = postProcessHtml(serialize(root).trim());
    blocks.push({
      item_id: Number(currentId),
      text: blockText(root),
      html: cleanedHtml,
      content_type: contentType,
      anchor,
    });
  }

  for (const [liveEl, ids] of liveMarks) liveEl.setAttribute(PULPIE_ID_ATTR, ids.join(' '));

  const simplifiedHtml = postProcessHtml(
    '<html><head><meta charset="utf-8"></head><body>'
    + blocks.map((b) => b.html).join('')
    + '</body></html>');

  return { blocks, simplifiedHtml };
}

// ── Public API ──────────────────────────────────────────────────────────────

/**
 * Extract pulpie's labeled block sequence from the live DOM.
 *
 * Tags each contributing element with `data-pulpie-id` (space-separated when an
 * element owns more than one block) and returns the blocks in document order.
 *
 * @param {object}  [options]
 * @param {Element} [options.root=document.documentElement] Subtree to simplify.
 * @param {number}  [options.cutoffLength=500] Per-block text budget.
 * @param {boolean} [options.includeHtml=true] Include per-block simplified markup.
 * @returns {{blocks: Array<{item_id: number, text: string, html?: string,
 *            content_type: string, anchor: object}>,
 *           simplifiedHtml: string, stats: object}}
 */
export function simplify(options = {}) {
  const root = options.root ?? document.documentElement;
  const cutoffLength = options.cutoffLength ?? DEFAULT_CUTOFF_LENGTH;
  const includeHtml = options.includeHtml !== false;

  // Invariant #5: never accumulate ids across runs.
  for (const stale of root.querySelectorAll(`[${PULPIE_ID_ATTR}]`)) {
    stale.removeAttribute(PULPIE_ID_ATTR);
  }
  if (root.hasAttribute && root.hasAttribute(PULPIE_ID_ATTR)) root.removeAttribute(PULPIE_ID_ATTR);

  const t0 = (typeof performance !== 'undefined' && performance.now) ? performance.now() : 0;

  const uidMap = new Map();
  const processingDom = buildShadow(root, null, { next: 0 }, uidMap);
  const nodeCount = uidMap.size;

  removeTags(processingDom);
  removeSpecificElements(processingDom);

  const paragraphs = extractParagraphs(processingDom);
  const { blocks, simplifiedHtml } = processParagraphs(paragraphs, uidMap, cutoffLength);

  if (!includeHtml) for (const b of blocks) delete b.html;

  const t1 = (typeof performance !== 'undefined' && performance.now) ? performance.now() : 0;
  return {
    blocks,
    simplifiedHtml,
    stats: {
      nodeCount,
      paragraphCount: paragraphs.length,
      blockCount: blocks.length,
      elapsedMs: Math.round(t1 - t0),
    },
  };
}

export default simplify;

// Injection convenience: WKWebView `evaluateJavaScript` has no module loader, so
// the build step that inlines this file can call `window.__pulpieSimplify(...)`.
if (typeof globalThis !== 'undefined') globalThis.__pulpieSimplify = simplify;
