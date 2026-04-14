import SwiftUI
import WebKit

// MARK: - File Tree Node

private struct FileNode: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    let children: [FileNode]?

    var icon: String {
        if isDirectory { return "folder.fill" }
        if name.hasSuffix(".md") { return "doc.text" }
        if name.hasSuffix(".png") || name.hasSuffix(".jpg") { return "photo" }
        if name.hasSuffix(".json") { return "doc.badge.gearshape" }
        return "doc"
    }

    var sizeString: String {
        if isDirectory { return "" }
        if size < 1024 { return "\(size) B" }
        if size < 1_048_576 { return String(format: "%.1f KB", Double(size) / 1024) }
        return String(format: "%.1f MB", Double(size) / 1_048_576)
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - View

struct PrivateFilesView: View {
    @State private var tree: [FileNode] = []
    @State private var selectedNodeId: String?
    @State private var fileContent: String?
    @State private var selectedFileName: String?
    @State private var selectedFilePath: String?
    @State private var isLoading = false

    private let privateDir = "\(DatabaseManager.dataDirectory)/private"

    var body: some View {
        NavigationSplitView {
            // Sidebar — file tree
            VStack(spacing: 0) {
                HStack {
                    Text("Private Files")
                        .font(.headline)
                    Spacer()
                    Button {
                        loadTree()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
                .padding()

                Divider()

                List(tree, children: \.children, selection: $selectedNodeId) { node in
                    HStack(spacing: 6) {
                        Image(systemName: node.icon)
                            .foregroundStyle(node.isDirectory ? .blue : .secondary)
                            .frame(width: 16)
                        Text(node.name)
                            .lineLimit(1)
                        Spacer()
                        if !node.isDirectory {
                            Text(node.sizeString)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: selectedNodeId) { _, newId in
                    guard let newId else { return }
                    if let node = findNode(id: newId, in: tree), !node.isDirectory {
                        selectedFileName = node.name
                        selectedFilePath = node.path
                        loadFile(at: node.path)
                    }
                }
            }
        } detail: {
            // Content pane
            if isLoading {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let content = fileContent, let name = selectedFileName {
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                                .font(.title2.bold())
                            if let path = selectedFilePath {
                                Text(path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    .padding()

                    Divider()

                    // Rendered content
                    if name.hasSuffix(".md") {
                        PrivateMarkdownWebView(markdown: content)
                    } else {
                        ScrollView {
                            Text(content)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.text.rectangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Select a file to view")
                        .foregroundStyle(.secondary)
                    Text("Journal, personality, interests, self-dialogues")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { loadTree() }
    }

    // MARK: - Tree Loading

    private func loadTree() {
        tree = buildTree(at: privateDir)
    }

    private func buildTree(at path: String) -> [FileNode] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: path) else { return [] }

        var nodes: [FileNode] = []
        for item in items.sorted() {
            if item.hasPrefix(".") { continue }
            if item == "journal.md" { continue }  // Private — Sona only
            let fullPath = "\(path)/\(item)"
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)

            let attrs = try? fm.attributesOfItem(atPath: fullPath)
            let size = attrs?[.size] as? Int64 ?? 0
            let modified = attrs?[.modificationDate] as? Date ?? Date()

            if isDir.boolValue {
                let children = buildTree(at: fullPath)
                nodes.append(FileNode(
                    id: fullPath, name: item, path: fullPath,
                    isDirectory: true, size: 0, modified: modified,
                    children: children.isEmpty ? nil : children
                ))
            } else {
                nodes.append(FileNode(
                    id: fullPath, name: item, path: fullPath,
                    isDirectory: false, size: size, modified: modified,
                    children: nil
                ))
            }
        }
        return nodes
    }

    private func findNode(id: String, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.id == id { return node }
            if let children = node.children, let found = findNode(id: id, in: children) {
                return found
            }
        }
        return nil
    }

    // MARK: - File Loading

    private func loadFile(at path: String) {
        isLoading = true
        defer { isLoading = false }
        fileContent = try? String(contentsOfFile: path, encoding: .utf8)
    }
}

// MARK: - Markdown WebView (reuse pattern from WikiView)

private struct PrivateMarkdownWebView: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let escaped = markdown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 14px;
                line-height: 1.6;
                color: #e0e0e0;
                background: transparent;
                padding: 16px 24px;
                max-width: 100%;
                word-wrap: break-word;
            }
            h1 { font-size: 1.8em; border-bottom: 1px solid #333; padding-bottom: 8px; }
            h2 { font-size: 1.4em; border-bottom: 1px solid #2a2a2a; padding-bottom: 6px; margin-top: 24px; }
            h3 { font-size: 1.15em; margin-top: 20px; }
            a { color: #58a6ff; text-decoration: none; }
            a:hover { text-decoration: underline; }
            code {
                background: #1a1a2e;
                padding: 2px 6px;
                border-radius: 4px;
                font-family: 'SF Mono', Menlo, monospace;
                font-size: 0.9em;
            }
            pre {
                background: #1a1a2e;
                padding: 12px 16px;
                border-radius: 8px;
                overflow-x: auto;
            }
            pre code { background: none; padding: 0; }
            table { border-collapse: collapse; width: 100%; margin: 12px 0; }
            th, td { border: 1px solid #333; padding: 6px 10px; text-align: left; }
            th { background: #1a1a2e; font-weight: 600; }
            blockquote { border-left: 3px solid #444; margin: 12px 0; padding: 4px 16px; color: #999; }
            ul, ol { padding-left: 24px; }
            li { margin: 4px 0; }
            hr { border: none; border-top: 1px solid #333; margin: 20px 0; }
        </style>
        <script src="http://127.0.0.1:\(sonataPort)/web/marked.min.js"></script>
        </head>
        <body>
        <div id="content"></div>
        <script>
            const md = `\(escaped)`;
            document.getElementById('content').innerHTML = marked.parse(md);
        </script>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }
            // External links open in browser
            if let url = navigationAction.request.url, url.absoluteString.hasPrefix("http") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
