import Foundation
import WebKit

/// The Webview Driver + the bridge the MCP layer calls. @MainActor because it
/// drives WKWebView and InteractiveSessionsViewModel (both main-actor). Every
/// drive verb transparently resumes a suspended session first. Session id used
/// over MCP == InteractiveSessionTab.id UUID string (the persistence PK).
@MainActor
final class WebviewSessionService {
    static let shared = WebviewSessionService()
    private init() {}

    private var vm: InteractiveSessionsViewModel { .shared }

    enum DriveError: Error, CustomStringConvertible {
        case sessionNotFound(String)
        case noWebView
        case js(String)
        case badArgs(String)
        var description: String {
            switch self {
            case .sessionNotFound(let s): return "webview session not found: \(s)"
            case .noWebView: return "session has no live WKWebView"
            case .js(let m): return "javascript error: \(m)"
            case .badArgs(let m): return "bad arguments: \(m)"
            }
        }
    }

    struct SessionInfo: Encodable {
        let sessionId: String
        let ownerAgentId: String?
        let status: String       // live | suspended
        let background: Bool
        let url: String?
        let title: String?
        let partition: String?
        let lastActivityAt: Int64
    }

    // MARK: - Lifecycle

    /// Create a session. Returns its public session id (tab.id UUID string).
    func create(ownerAgentId: String?, url: String?, partition: String?, background: Bool) -> String {
        let parsed = url.flatMap { URL(string: $0) }
        let tab = vm.addWebviewSession(
            ownerAgentId: ownerAgentId, url: parsed, partition: partition, background: background)
        return tab.id.uuidString.lowercased()
    }

    func close(sessionId: String) throws {
        guard let tab = vm.webviewTab(id: sessionId) else { throw DriveError.sessionNotFound(sessionId) }
        vm.closeTab(id: tab.id)
    }

    func list() -> [SessionInfo] {
        vm.tabs.filter { $0.kind == .webview }.map { tab in
            SessionInfo(
                sessionId: tab.id.uuidString.lowercased(),
                ownerAgentId: tab.ownerAgentId,
                status: tab.lifecycle.rawValue,
                background: tab.background,
                url: tab.webView?.url?.absoluteString ?? tab.url?.absoluteString,
                title: tab.webView?.title,
                partition: tab.partition,
                lastActivityAt: tab.lastActivityAt)
        }
    }

    /// Spy/peek: bring the session into the foreground panel. Resumes if
    /// suspended, then selects it so the rail mounts its WKWebView NSView.
    func focus(sessionId: String) throws {
        guard let tab = vm.webviewTab(id: sessionId) else { throw DriveError.sessionNotFound(sessionId) }
        if tab.lifecycle == .suspended { vm.resumeTab(id: tab.id) }
        vm.selectTab(id: tab.id)
    }

    // MARK: - Drive verbs (all resume-on-demand + touch activity)

    private func liveWebView(_ sessionId: String) throws -> (InteractiveSessionTab, WKWebView) {
        guard let tab = vm.webviewTab(id: sessionId) else { throw DriveError.sessionNotFound(sessionId) }
        if tab.lifecycle == .suspended { vm.resumeTab(id: tab.id) }
        guard let wv = tab.webView else { throw DriveError.noWebView }
        return (tab, wv)
    }

    private func touch(_ tab: InteractiveSessionTab) {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        tab.lastActivityAt = ms
        vm.recordWebviewActivity(tabId: tab.id, lastURL: tab.webView?.url?.absoluteString, at: ms)
    }

    func navigate(sessionId: String, url: String) async throws {
        let (tab, wv) = try liveWebView(sessionId)
        guard let u = URL(string: url) else { throw DriveError.badArgs("invalid url: \(url)") }
        wv.load(URLRequest(url: u))
        touch(tab)
    }

    func evaluate(sessionId: String, js: String) async throws -> String {
        let (tab, wv) = try liveWebView(sessionId)
        let result = try await runJS(wv, js)
        touch(tab)
        return result
    }

    func click(sessionId: String, selector: String?, x: Double?, y: Double?) async throws -> String {
        let (tab, wv) = try liveWebView(sessionId)
        let js: String
        if let selector { js = WebviewJS.clickSelector(selector) }
        else if let x, let y { js = WebviewJS.clickPoint(x: x, y: y) }
        else { throw DriveError.badArgs("click requires selector OR x+y") }
        let r = try await runJS(wv, js); touch(tab); return r
    }

    func type(sessionId: String, text: String, selector: String?) async throws -> String {
        let (tab, wv) = try liveWebView(sessionId)
        let r = try await runJS(wv, WebviewJS.type(text: text, selector: selector)); touch(tab); return r
    }

    func scroll(sessionId: String, x: Double?, y: Double?, selector: String?) async throws -> String {
        let (tab, wv) = try liveWebView(sessionId)
        let r = try await runJS(wv, WebviewJS.scroll(x: x ?? 0, y: y ?? 0, selector: selector)); touch(tab); return r
    }

    func look(sessionId: String) async throws -> String {
        let (tab, wv) = try liveWebView(sessionId)
        let r = try await runJS(wv, WebviewJS.look); touch(tab); return r
    }

    func getPageInfo(sessionId: String) async throws -> String {
        let (tab, wv) = try liveWebView(sessionId)
        let r = try await runJS(wv, WebviewJS.pageInfo); touch(tab); return r
    }

    /// Encoded snapshot of a webview session. `maxWidth` (points) downscales at
    /// capture time so the result fits an agent's token budget; `format` is
    /// "png" (default) or "jpeg"; `quality` is the JPEG compression factor.
    struct Snapshot {
        let data: Data
        let format: String   // "png" | "jpeg"
        let width: Int       // points
        let height: Int
    }

    func screenshot(sessionId: String, maxWidth: Double? = nil,
                    format: String = "png", quality: Double = 0.7) async throws -> Snapshot {
        let (tab, wv) = try liveWebView(sessionId)
        let cfg = WKSnapshotConfiguration()
        // snapshotWidth (points) scales the capture down preserving aspect —
        // cheaper and sharper than re-sampling the full retina image after.
        if let maxWidth, maxWidth > 0 { cfg.snapshotWidth = NSNumber(value: maxWidth) }
        let image: NSImage = try await withCheckedThrowingContinuation { cont in
            wv.takeSnapshot(with: cfg) { img, err in
                if let img { cont.resume(returning: img) }
                else { cont.resume(throwing: DriveError.js(err?.localizedDescription ?? "snapshot failed")) }
            }
        }
        touch(tab)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            throw DriveError.js("image encode failed")
        }
        let isJpeg = format.lowercased() == "jpeg" || format.lowercased() == "jpg"
        let encoded: Data? = isJpeg
            ? rep.representation(using: .jpeg, properties: [.compressionFactor: max(0, min(1, quality))])
            : rep.representation(using: .png, properties: [:])
        guard let out = encoded else { throw DriveError.js("\(isJpeg ? "jpeg" : "png") encode failed") }
        return Snapshot(data: out, format: isJpeg ? "jpeg" : "png",
                        width: Int(image.size.width), height: Int(image.size.height))
    }

    /// Result of `saveHTML` — everything the caller needs *except* the HTML,
    /// which stayed on disk.
    struct SavedPage {
        let path: String
        let bytes: Int
        let url: String
        let title: String
    }

    /// Serialize the rendered DOM and write it straight to `path`. The HTML
    /// never crosses the MCP boundary — that's the whole point: a real page's
    /// outerHTML is 250 KB–5 MB, which the caller would otherwise pay for in
    /// tokens. Parent directories are created; an existing file is overwritten.
    func saveHTML(sessionId: String, path: String) async throws -> SavedPage {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw DriveError.badArgs("path must be absolute: \(path)") }
        let (tab, wv) = try liveWebView(sessionId)
        let page = try await serializePage(wv)
        touch(tab)

        let dest = URL(fileURLWithPath: expanded)
        let data = Data(page.html.utf8)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest)
        return SavedPage(path: dest.path, bytes: data.count, url: page.url, title: page.title)
    }

    // MARK: - read (pulpie main-content extraction)

    /// What `read` reports back. `markdown` is the payload; the two counts say
    /// how much of the page survived classification.
    struct PageRead: Sendable {
        let url: String
        let title: String
        let markdown: String
        let extractionMs: Int
        let blockCount: Int
        let mainBlockCount: Int
    }

    /// Run the three-stage pulpie pipeline against a session's live DOM and
    /// return the page's main content as markdown.
    ///
    ///   1. `pulpie-simplify.js` walks the DOM, tags contributing elements with
    ///      `data-pulpie-id` and returns one block per text run.
    ///   2. `PulpieClassifier` (CoreML) labels every block main | other.
    ///   3. `pulpie-markdown.js` prunes the tree to the main-labeled spans and
    ///      converts what's left with a port of pulpie's html2text.
    ///
    /// The per-block `anchor`s stage 2 emits never enter Swift — they are
    /// parked on the page (`globalThis.__pulpieRead`) between the two
    /// injections, because only stage 3 knows how to resolve them. Swift moves
    /// texts down and labels back, nothing else.
    ///
    /// Deliberately NO fallback: if the classifier can't load, the caller gets
    /// the error rather than a silent whole-page dump that looks like a
    /// successful extraction.
    ///
    /// macOS 15+ only — the package targets 14, but the classifier's CoreML
    /// model is built with `minimum_deployment_target=macOS15`.
    @available(macOS 15, *)
    func readPage(sessionId: String) async throws -> PageRead {
        let started = Date()
        let (tab, wv) = try liveWebView(sessionId)

        let pass = try await simplifyPass(wv)

        // Empty page (or a subtree with no meaningful content) — no blocks to
        // classify, so don't pay a model load to learn that. blockCount: 0
        // tells the caller exactly what happened.
        let labels: [PulpieClassifier.Label] = pass.texts.isEmpty
            ? []
            : try await PulpieClassifier.shared.classify(blocks: pass.texts)
        guard labels.count == pass.ids.count else {
            throw DriveError.js(
                "pulpie classifier returned \(labels.count) labels for \(pass.ids.count) blocks")
        }

        // labelMap is one entry per item_id, straight from block order — stage
        // 2 ids are dense and 1-based, so this is a positional zip.
        var labelMap: [String: String] = [:]
        for (id, label) in zip(pass.ids, labels) { labelMap[id] = label.rawValue }

        let markdown = try await markdownPass(wv, labels: labelMap)
        touch(tab)

        return PageRead(
            url: pass.url,
            title: pass.title,
            markdown: markdown,
            extractionMs: Int((Date().timeIntervalSince(started) * 1000).rounded()),
            blockCount: pass.ids.count,
            mainBlockCount: labels.filter { $0 == .main }.count)
    }

    /// Stage 2's output, minus the anchors (which stay on the page).
    private struct SimplifyPass: Sendable {
        let ids: [String]
        let texts: [String]
        let url: String
        let title: String
    }

    private func simplifyPass(_ wv: WKWebView) async throws -> SimplifyPass {
        let source = try Self.pulpieScript("pulpie-simplify")
        // url/title ride along in this batch rather than a second round trip,
        // so they describe the page the blocks were actually taken from.
        // PulpieClassifier expects each block's simplified HTML, not plaintext.
        // The Orange model was distilled on MinerU's segmentation, where blocks
        // are HTML fragments carrying `_item_id` and their element/class shape —
        // the tokenizer's per-sep window is what encodes "this is <nav>" vs
        // "this is <article>". Stripping to `b.text` deletes exactly that signal
        // and drops every block to `other` (verified 2026-07-21: newsroom went
        // 21/49 main -> 0/49). Task #4's classifier fixtures store `html` per
        // block for the same reason.
        let js = """
        \(source)
        ;(() => {
          const r = globalThis.__pulpieSimplify({ includeHtml: true });
          globalThis.__pulpieRead = {
            anchors: Object.fromEntries(r.blocks.map(b => [String(b.item_id), b.anchor]))
          };
          return {
            ids: r.blocks.map(b => String(b.item_id)),
            texts: r.blocks.map(b => b.html),
            url: location.href,
            title: document.title
          };
        })()
        """
        return try await withCheckedThrowingContinuation { cont in
            wv.evaluateJavaScript(js, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    guard let d = value as? [String: Any],
                          let ids = d["ids"] as? [String],
                          let texts = d["texts"] as? [String] else {
                        cont.resume(throwing: DriveError.js("pulpie simplify returned no block list"))
                        return
                    }
                    cont.resume(returning: SimplifyPass(
                        ids: ids, texts: texts,
                        url: d["url"] as? String ?? "", title: d["title"] as? String ?? ""))
                case .failure(let err):
                    cont.resume(throwing: DriveError.js(err.localizedDescription))
                }
            }
        }
    }

    private func markdownPass(_ wv: WKWebView, labels: [String: String]) async throws -> String {
        let source = try Self.pulpieScript("pulpie-markdown")
        let labelsJSON = (try? JSONSerialization.data(withJSONObject: labels, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // `stripLxmlBlanks` stays off: it exists to reproduce a lossy re-parse
        // in the Python pipeline that welds words together across dropped
        // whitespace nodes. Turn it on only when diffing against the oracle.
        let js = """
        \(source)
        ;(() => {
          const state = globalThis.__pulpieRead || {};
          delete globalThis.__pulpieRead;
          return globalThis.PulpieMarkdown.extractMainMarkdown(
            document, \(labelsJSON), { anchors: state.anchors || null });
        })()
        """
        return try await withCheckedThrowingContinuation { cont in
            wv.evaluateJavaScript(js, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    guard let md = value as? String else {
                        cont.resume(throwing: DriveError.js("pulpie markdown returned no string"))
                        return
                    }
                    cont.resume(returning: md)
                case .failure(let err):
                    cont.resume(throwing: DriveError.js(err.localizedDescription))
                }
            }
        }
    }

    /// Load a pulpie stage script from the bundle and make it injectable.
    ///
    /// Two transforms, both forced by `evaluateJavaScript`, which runs classic
    /// scripts in the page's global scope:
    ///   * top-level `export` is a SyntaxError in a classic script, so the
    ///     module syntax is stripped;
    ///   * the file is wrapped in an IIFE, so a second `read` on the same page
    ///     doesn't collide with the first's top-level `const` declarations.
    /// Both stages install themselves onto `globalThis`, which survives the
    /// wrap — that global is the handle the orchestration calls.
    private static func pulpieScript(_ name: String) throws -> String {
        guard let url = Bundle.module.url(
                forResource: name, withExtension: "js", subdirectory: "web"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw DriveError.js("pulpie stage script missing from bundle: \(name).js")
        }
        let classic = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                if line.hasPrefix("export default") { return "// " + line }
                if line.hasPrefix("export ") { return String(line.dropFirst("export ".count)) }
                return String(line)
            }
            .joined(separator: "\n")
        return "(function () {\n\(classic)\n})();"
    }

    // MARK: - WKWebView async bridge

    /// evaluateJavaScript in the page content world (unsandboxed, per spec §9 —
    /// Sonata owns the renderer). Serializes the result to a string.
    private func runJS(_ wv: WKWebView, _ js: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            wv.evaluateJavaScript(js, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    cont.resume(returning: WebviewSessionService.stringify(value))
                case .failure(let err):
                    cont.resume(throwing: DriveError.js(err.localizedDescription))
                }
            }
        }
    }

    private struct PageSerialization: Sendable {
        let html: String
        let url: String
        let title: String
    }

    /// One eval batch → typed value. Deliberately *not* built on `runJS`: that
    /// would JSON-encode the multi-megabyte html only for us to decode it back.
    /// Unpacking inside the completion handler also keeps a non-Sendable `Any`
    /// off the continuation.
    private func serializePage(_ wv: WKWebView) async throws -> PageSerialization {
        try await withCheckedThrowingContinuation { cont in
            wv.evaluateJavaScript(WebviewJS.serializePage, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    guard let d = value as? [String: Any], let html = d["html"] as? String else {
                        cont.resume(throwing: DriveError.js("page serialization returned no html"))
                        return
                    }
                    cont.resume(returning: PageSerialization(
                        html: html, url: d["url"] as? String ?? "", title: d["title"] as? String ?? ""))
                case .failure(let err):
                    cont.resume(throwing: DriveError.js(err.localizedDescription))
                }
            }
        }
    }

    private static func stringify(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default:
            if let data = try? JSONSerialization.data(withJSONObject: value as Any, options: [.fragmentsAllowed, .sortedKeys]),
               let s = String(data: data, encoding: .utf8) { return s }
            return String(describing: value!)
        }
    }
}

/// JS snippets the drive verbs inject. Kept here so the verb→DOM mapping is in
/// one place. Each returns a JSON-serializable value the page world hands back.
enum WebviewJS {
    static func clickSelector(_ sel: String) -> String { """
        (() => { const el = document.querySelector(\(jsString(sel)));
          if (!el) return { ok:false, error:'no element for selector' };
          el.click(); return { ok:true, tag: el.tagName, text:(el.innerText||'').slice(0,200) }; })()
        """ }
    static func clickPoint(x: Double, y: Double) -> String { """
        (() => { const el = document.elementFromPoint(\(x), \(y));
          if (!el) return { ok:false, error:'no element at point' };
          el.click(); return { ok:true, tag: el.tagName }; })()
        """ }
    static func type(text: String, selector: String?) -> String {
        let target = selector.map { "document.querySelector(\(jsString($0)))" } ?? "document.activeElement"
        return """
        (() => { const el = \(target);
          if (!el) return { ok:false, error:'no target element' };
          el.focus();
          const set = Object.getOwnPropertyDescriptor(el.__proto__, 'value')?.set;
          if (set) set.call(el, \(jsString(text))); else el.value = \(jsString(text));
          el.dispatchEvent(new Event('input', {bubbles:true}));
          el.dispatchEvent(new Event('change', {bubbles:true}));
          return { ok:true, value:(el.value||'').slice(0,200) }; })()
        """
    }
    static func scroll(x: Double, y: Double, selector: String?) -> String {
        if let selector { return "(() => { const el = document.querySelector(\(jsString(selector))); if(el) el.scrollIntoView({behavior:'instant',block:'center'}); return { ok: !!el }; })()" }
        return "(() => { window.scrollBy(\(x), \(y)); return { ok:true, scrollX: window.scrollX, scrollY: window.scrollY }; })()"
    }
    static let look = """
        (() => ({ url: location.href, title: document.title,
          text: (document.body?.innerText || '').slice(0, 4000),
          links: [...document.querySelectorAll('a[href]')].slice(0,50).map(a => ({ text:(a.innerText||'').trim().slice(0,80), href:a.href })),
          inputs: [...document.querySelectorAll('input,textarea,button,select')].slice(0,50).map(e => ({ tag:e.tagName, type:e.type||'', name:e.name||'', placeholder:e.placeholder||'', text:(e.innerText||e.value||'').slice(0,60) })) }))()
        """
    static let pageInfo = """
        (() => ({ url: location.href, title: document.title, readyState: document.readyState,
          scrollX: window.scrollX, scrollY: window.scrollY,
          viewport: { w: window.innerWidth, h: window.innerHeight } }))()
        """
    /// Full serialized DOM plus the metadata `page_save_html` reports back, in
    /// one round trip. The html half is consumed natively, never returned.
    static let serializePage = """
        (() => ({ html: document.documentElement.outerHTML,
          url: location.href, title: document.title }))()
        """
    /// JSON-encode a Swift string into a JS string literal (safe injection).
    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())   // strip the [ ] → leaves the quoted, escaped string
    }
}
