// Sonata shared utilities
// Use same origin as the page was served from — works on any port
window.SONATA_API_BASE = window.SONATA_API_BASE || window.location.origin;

async function apiGet(path, params, retries = 5) {
  const url = new URL(window.SONATA_API_BASE + path);
  if (params) Object.entries(params).forEach(([k, v]) => {
    if (v !== undefined && v !== null && v !== '') url.searchParams.set(k, v);
  });
  for (let i = 0; i < retries; i++) {
    try {
      const res = await fetch(url.toString());
      if (!res.ok) throw new Error(`HTTP ${res.status} ${path}`);
      const ct = res.headers.get('content-type') || '';
      return ct.includes('application/json') ? res.json() : res.text();
    } catch (e) {
      if (i < retries - 1) {
        await new Promise(r => setTimeout(r, 1000 * (i + 1)));
        continue;
      }
      throw e;
    }
  }
}

async function apiPost(path, body) {
  const res = await fetch(window.SONATA_API_BASE + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body || {}),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status} ${path}`);
  return res.json();
}

function fmtDate(iso) {
  if (!iso) return '';
  const d = typeof iso === 'number' ? new Date(iso) : new Date(iso);
  if (isNaN(d.getTime())) return String(iso);
  const now = new Date();
  const diff = (now - d) / 1000;
  if (diff < 60) return 'just now';
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  if (diff < 86400 * 7) return `${Math.floor(diff / 86400)}d ago`;
  return d.toLocaleDateString();
}

function debounce(fn, ms) {
  let t;
  return (...args) => {
    clearTimeout(t);
    t = setTimeout(() => fn(...args), ms);
  };
}

function escapeHtml(s) {
  if (s == null) return '';
  return String(s).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c]));
}

// Markdown renderer — uses marked.js for full GFM support, plus wiki cross-links
// Strategy: extract link syntax from raw markdown into placeholder tokens BEFORE
// marked processes it, then restore them as real <a> tags after parsing. This
// avoids escaping issues and renderer-signature compatibility problems across
// marked versions.
function renderMarkdown(md) {
  if (!md) return '';

  const placeholders = [];
  const makeToken = (html) => {
    const idx = placeholders.length;
    placeholders.push(html);
    // Use a token unlikely to be mangled by markdown: letters + digits only.
    return `xSONATALINKx${idx}xENDx`;
  };

  let text = String(md);

  // 1. Extract wiki cross-links [[Page Name]]
  text = text.replace(/\[\[([^\]]+)\]\]/g, (_, name) => {
    const slug = name.trim().toLowerCase().replace(/\s+/g, '-');
    return makeToken(`<a href="#" class="wiki-link" data-slug="${escapeHtml(slug)}">${escapeHtml(name)}</a>`);
  });

  // 2. Extract standard markdown links [text](url) — skip image links ![...](...)
  text = text.replace(/(^|[^!])\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g, (_, pre, linkText, href) => {
    let html;
    const isMdLink = href.endsWith('.md') || (href.includes('/') && !/^https?:/.test(href) && !href.startsWith('#'));
    if (isMdLink) {
      const slug = href.replace(/\.md$/, '').replace(/^\.\.\//g, '');
      html = `<a href="#" class="wiki-link" data-slug="${escapeHtml(slug)}">${escapeHtml(linkText)}</a>`;
    } else if (/^https?:/.test(href)) {
      html = `<a href="${escapeHtml(href)}" class="external-link" target="_blank">${escapeHtml(linkText)}</a>`;
    } else {
      html = `<a href="${escapeHtml(href)}">${escapeHtml(linkText)}</a>`;
    }
    return pre + makeToken(html);
  });

  // 3. Run marked (or fallback) on the placeholder-ified text
  let html;
  if (typeof marked !== 'undefined') {
    marked.setOptions({ breaks: true, gfm: true });
    html = marked.parse(text);
  } else {
    html = '<pre>' + escapeHtml(text) + '</pre>';
  }

  // 4. Restore placeholders
  html = html.replace(/xSONATALINKx(\d+)xENDx/g, (_, i) => placeholders[Number(i)] || '');

  return html;
}

function showError(el, err) {
  el.innerHTML = `<div class="empty" style="color: var(--red);">Error: ${escapeHtml(String(err))}</div>`;
}

function showLoading(el, label = 'Loading') {
  el.innerHTML = `<div class="empty"><span class="spinner"></span>&nbsp; ${escapeHtml(label)}…</div>`;
}
