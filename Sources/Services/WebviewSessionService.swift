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

    /// PNG snapshot → base64 string (matches Eyebrowse's `screenshot` field).
    func screenshot(sessionId: String) async throws -> String {
        let (tab, wv) = try liveWebView(sessionId)
        let cfg = WKSnapshotConfiguration()
        let image: NSImage = try await withCheckedThrowingContinuation { cont in
            wv.takeSnapshot(with: cfg) { img, err in
                if let img { cont.resume(returning: img) }
                else { cont.resume(throwing: DriveError.js(err?.localizedDescription ?? "snapshot failed")) }
            }
        }
        touch(tab)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw DriveError.js("png encode failed")
        }
        return png.base64EncodedString()
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
    /// JSON-encode a Swift string into a JS string literal (safe injection).
    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())   // strip the [ ] → leaves the quoted, escaped string
    }
}
