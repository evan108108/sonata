import SwiftUI
import WebKit

struct WebDashboardView: NSViewRepresentable {
    let filename: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        // Load directly from the HTTP server — same origin as API
        let port = Int(ProcessInfo.processInfo.environment["SONATA_PORT"] ?? "") ?? 3211
        let url = URL(string: "http://localhost:\(port)/web/\(filename)")!
        webView.load(URLRequest(url: url))

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
