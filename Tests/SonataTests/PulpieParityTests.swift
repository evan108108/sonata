import Foundation
import Testing

// Parity canary: the Swift `read` tool vs the Python pulpie reference.
//
// WHAT THIS IS
// The pulpie port replaced a Python extraction service with a Swift + CoreML
// pipeline behind the `read` MCP tool. `PulpieClassifierTests` locks the
// *classifier* against recorded fixtures (offline, deterministic). This suite
// locks the *whole tool* — DOM walk → classify → markdown — against the live
// Python service on the same four-page eval corpus, over live network. It's a
// rollout canary, not a unit test: it answers "does the shipped tool still
// agree with the reference on real pages today".
//
// GATE
// Skipped unless `PULPIE_PARITY=1` is set. It needs three things default CI
// doesn't have: internet, a running Sonata bridge (:3211), and the Python
// reference service (:8765).
//
//     PULPIE_PARITY=1 swift test --filter PulpieParity
//
// Endpoints are overridable via `SONATA_BRIDGE_URL` and `PULPIE_REFERENCE_URL`.
//
// HOW IT DRIVES
// Over the MCP bridge (`tools/call` on :3211), not in-process via
// `WebviewSessionService` under `@testable import`. That was a deliberate call
// (task #6, see below): the in-process route tests the class, not the tool, and
// interface bugs live at the bridge. It also means this suite exercises exactly
// what an agent gets when it calls `read`.
//
// Per URL: create a background webview session → navigate → wait for
// `readyState == complete` → wait for the DOM to stop growing → then, back to
// back, call `read` (Swift markdown) and `page_save_html` (rendered outerHTML)
// and POST that HTML to the Python service (reference markdown). The
// stabilization wait matters: `read` sees the live DOM while Python sees the
// snapshot, so a page still hydrating between the two calls diverges for
// reasons that have nothing to do with the port.
//
// NORMALIZATION SPEC
// Both sides are normalized before comparison. Deliberately narrow — every rule
// here is a difference we're willing to call cosmetic, and anything broader
// would hide real regressions:
//   1. Unicode → NFC (`precomposedStringWithCanonicalMapping`). WebKit and
//      Python can hand back the same glyph in different composition forms.
//   2. Line endings CRLF / lone CR → LF.
//   3. Trailing ASCII space and tab stripped per line. NBSP (U+00A0) is NOT
//      stripped — a trailing NBSP is content the extractors disagreed about.
//   4. Runs of 2+ blank lines collapsed to one.
//   5. Leading and trailing blank lines trimmed from the document.
// Everything else — punctuation, entity decoding, link targets, heading level,
// block order, whitespace *inside* a line — is compared byte for byte.
//
// `PulpieParityNormalizationTests` at the bottom of this file covers those
// rules offline and is deliberately *not* gated: `normalize` is what decides
// whether this canary can fire at all, so it needs cover that always runs.
//
// OBSERVED DIVERGENCE (2026-07-21, first green run)
// Three of the four pages are byte-identical before normalization. usaspending
// differs by exactly 2 bytes: Python emits a trailing space on two lines
// ("## Department of Defense (DOD) " and "Sub-Component ") that Swift doesn't.
// Same line count, same content — rule 3 territory, tolerated.
//
// FALSE-PASS HAZARDS
// Both extractors reading the *same* wrong DOM agree, and agreement is what
// this suite asserts — so an unloaded or half-hydrated page is a green run that
// proves nothing. Two guards, both learned the hard way on the first run (see
// `awaitSettledDOM` and the non-vacuity expectations in `parity`): the page
// must clear a content floor before it's read, and `read` must return non-empty
// markdown with at least one main block.
//
// TASK HISTORY
//   #6  (3cabd403…) scoped this harness and parked it: the port was entirely
//       uncommitted working-tree state and the installed app predated it, so
//       there was no `read` tool to test. Recorded the bridge-driven design
//       decision and flagged the corpus mismatch below.
//   #6b (this file) picked it up after the deploy landed, and after two fixes
//       that this harness depends on: `scripts/deploy-local.sh` was silently
//       skipping resource-bundle sync (the pulpie-*.js stage scripts never
//       reached the app bundle), and `WebviewSessionService` was feeding the
//       classifier `b.text` when the model was trained on `b.html` — which
//       produced 0 main blocks on every page.
//
// CORPUS
// The four URLs below are canonical: they're what the classifier fixtures under
// `fixtures/pulpie-classifier/` were built against and what every stage of the
// port has been measured on. `Tools/PulpieParity/` carries an *older,
// different* four-page set (socrata crimes ijzp-q8t2, MDN, APNews) whose README
// parity table is pinned to that set. Don't reconcile them here; consolidating
// the two corpora is its own task.
@Suite(.serialized, .enabled(if: pulpieParityGateEnabled()))
struct PulpieParityTests {

    // MARK: - Corpus

    struct CorpusPage: CustomStringConvertible, Sendable {
        let slug: String
        let url: String
        var description: String { slug }
    }

    static let corpus: [CorpusPage] = [
        CorpusPage(
            slug: "wikipedia_rag",
            url: "https://en.wikipedia.org/wiki/Retrieval-augmented_generation"),
        CorpusPage(
            slug: "usaspending_dod",
            url: "https://www.usaspending.gov/agency/department-of-defense?fy=2025"),
        CorpusPage(
            slug: "anthropic_newsroom",
            url: "https://www.anthropic.com/news"),
        CorpusPage(
            slug: "chicago_permits",
            url: "https://data.cityofchicago.org/Buildings/Building-Permits/ydr8-5enu"),
    ]

    // MARK: - Endpoints

    struct ParityError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static var bridgeURL: URL {
        let raw =
            ProcessInfo.processInfo.environment["SONATA_BRIDGE_URL"] ?? "http://127.0.0.1:3211/mcp"
        return URL(string: raw)!
    }

    static var referenceURL: URL {
        let raw =
            ProcessInfo.processInfo.environment["PULPIE_REFERENCE_URL"]
            ?? "http://127.0.0.1:8765/extract"
        return URL(string: raw)!
    }

    /// Generous timeouts: `read` on a large page pays for a DOM walk plus a
    /// CoreML pass, and the Python service re-parses a 400 KB document.
    static let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 240
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    static func postJSON(_ url: URL, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await http.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
        else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ParityError("POST \(url.absoluteString) → HTTP \(code)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParityError("POST \(url.absoluteString) → response was not a JSON object")
        }
        return object
    }

    /// One `tools/call` against the bridge.
    ///
    /// Bridge tools answer with a single text content block. Structured tools
    /// put a JSON object in it; scalar ones (`evaluate`) put a bare value. The
    /// bare case is returned as `["text": <raw>]` so callers can read it either
    /// way without a second decode path.
    static func callTool(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        let envelope = try await postJSON(
            bridgeURL,
            [
                "jsonrpc": "2.0",
                "id": UUID().uuidString,
                "method": "tools/call",
                "params": ["name": name, "arguments": arguments],
            ])

        if let error = envelope["error"] {
            throw ParityError("\(name): JSON-RPC error \(error)")
        }
        guard let result = envelope["result"] as? [String: Any],
            let content = result["content"] as? [[String: Any]],
            let text = content.first?["text"] as? String
        else {
            throw ParityError("\(name): unexpected envelope \(envelope)")
        }
        if result["isError"] as? Bool == true {
            throw ParityError("\(name) failed: \(text)")
        }

        if let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return object
        }
        return ["text": text]
    }

    // MARK: - Page capture

    struct SwiftSide {
        let markdown: String
        let extractionMs: Int
        let blockCount: Int
        let mainBlockCount: Int
    }

    struct PythonSide {
        let markdown: String
        let extractionMs: Int
        let inputBytes: Int
        let outputBytes: Int
    }

    /// An empty `about:blank` document serializes to 39 characters. Anything in
    /// that neighbourhood means the target page has not landed yet, whatever
    /// `readyState` claims.
    static let minimumSettledDOM = 2048

    /// Consecutive identical `outerHTML` length samples (one second apart)
    /// required to call a page settled, and the minimum time we keep watching
    /// regardless. Both exist because of usaspending: it *plateaus* partway
    /// through hydration, holding a stable ~106 KB DOM for several seconds
    /// before mounting the rest and finishing near ~164 KB. Two samples caught
    /// the plateau and read a page that was 1/100th of its final content — and
    /// since Python was then handed the same half-built snapshot, the two sides
    /// agreed and the run went green. Stability alone is not doneness.
    static let settleStableSamples = 4
    static let settleMinimumDwell = 8

    /// Wait for the page to finish loading *and* settle.
    ///
    /// Three separate hazards, in order:
    ///
    /// 1. `navigate` is fire-and-forget — it calls `WKWebView.load` and
    ///    returns. Poll `readyState` immediately after and you get the state of
    ///    the *outgoing* document, which for a fresh session is an empty
    ///    `about:blank` that is already `complete`. So the host check comes
    ///    first: wait until the document actually belongs to the target URL.
    /// 2. `readyState == complete` is necessary but nowhere near sufficient on
    ///    the two SPAs in the corpus (usaspending, socrata) — they mount their
    ///    real content well after load. Settling on a stable `outerHTML` length
    ///    is the cheap proxy: two consecutive identical samples a second apart.
    /// 3. A page can settle *empty* (navigation failed, network blocked). That
    ///    would make both extractors agree on nothing and hand back a green
    ///    run, so a floor of `minimumSettledDOM` is enforced as a hard failure.
    ///
    /// Returns the settled document size in characters.
    @discardableResult
    static func awaitSettledDOM(sessionId: String, page: CorpusPage) async throws -> Int {
        let host = URL(string: page.url)?.host ?? ""

        var landed = false
        for _ in 0..<120 {
            let location = try await callTool(
                "evaluate", ["sessionId": sessionId, "script": "document.location.href"])
            let href = location["text"] as? String ?? ""
            if href != "about:blank", URL(string: href)?.host == host {
                let state = try await callTool(
                    "evaluate", ["sessionId": sessionId, "script": "document.readyState"])
                if state["text"] as? String == "complete" {
                    landed = true
                    break
                }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard landed else {
            throw ParityError(
                "\(page.slug): never reached a `complete` document on host \(host) within 60s")
        }

        var previous = -1
        var stableSamples = 0
        var settled = -1
        for sample in 0..<60 {
            let result = try await callTool(
                "evaluate",
                [
                    "sessionId": sessionId,
                    "script": "String(document.documentElement.outerHTML.length)",
                ])
            let size = Int(result["text"] as? String ?? "") ?? -1
            if size > 0 && size == previous {
                stableSamples += 1
                if stableSamples >= settleStableSamples && sample >= settleMinimumDwell {
                    settled = size
                    break
                }
            } else {
                stableSamples = 0
            }
            previous = size
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        // Never settled — proceed with the last sample rather than failing on
        // page churn we can't control, and let the diff say whether it mattered.
        if settled < 0 { settled = previous }

        guard settled >= minimumSettledDOM else {
            throw ParityError(
                """
                \(page.slug): DOM settled at \(settled) chars, below the \
                \(minimumSettledDOM)-char floor — the page never loaded. Both extractors \
                would agree on an empty document, which is a vacuous pass, not parity.
                """)
        }
        return settled
    }

    static func readViaSwift(sessionId: String, page: CorpusPage) async throws -> SwiftSide {
        let result = try await callTool("read", ["sessionId": sessionId])
        guard let markdown = result["markdown"] as? String else {
            throw ParityError("\(page.slug): `read` returned no markdown — \(result)")
        }
        return SwiftSide(
            markdown: markdown,
            extractionMs: result["extractionMs"] as? Int ?? -1,
            blockCount: result["blockCount"] as? Int ?? -1,
            mainBlockCount: result["mainBlockCount"] as? Int ?? -1)
    }

    static func readViaPython(sessionId: String, page: CorpusPage) async throws -> PythonSide {
        let snapshot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulpie-parity-\(page.slug)-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: snapshot) }

        _ = try await callTool(
            "page_save_html", ["sessionId": sessionId, "path": snapshot.path])
        let html = try String(contentsOf: snapshot, encoding: .utf8)

        let result = try await postJSON(referenceURL, ["html": html])
        guard let markdown = result["markdown"] as? String else {
            throw ParityError("\(page.slug): reference service returned no markdown — \(result)")
        }
        return PythonSide(
            markdown: markdown,
            extractionMs: result["extraction_ms"] as? Int ?? -1,
            inputBytes: result["input_bytes"] as? Int ?? html.utf8.count,
            outputBytes: result["output_bytes"] as? Int ?? markdown.utf8.count)
    }

    // MARK: - Normalization

    /// See the NORMALIZATION SPEC in the file header. Kept deliberately narrow.
    static func normalize(_ input: String) -> String {
        let unified = input
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines: [String] = []
        for raw in unified.components(separatedBy: "\n") {
            var line = raw
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            // Collapse runs of blank lines to one.
            if line.isEmpty && lines.last?.isEmpty == true { continue }
            lines.append(line)
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: - Unified diff

    enum DiffOp {
        case keep(String)
        case delete(String)
        case insert(String)
    }

    /// Classic LCS diff. Quadratic, which is fine for markdown of this size;
    /// callers fall back to a first-divergence window past `diffCellBudget`.
    static let diffCellBudget = 4_000_000

    static func diffOps(_ before: [String], _ after: [String]) -> [DiffOp] {
        let n = before.count
        let m = after.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] =
                        before[i] == after[j]
                        ? lcs[i + 1][j + 1] + 1
                        : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var ops: [DiffOp] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if before[i] == after[j] {
                ops.append(.keep(before[i]))
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                ops.append(.delete(before[i]))
                i += 1
            } else {
                ops.append(.insert(after[j]))
                j += 1
            }
        }
        while i < n {
            ops.append(.delete(before[i]))
            i += 1
        }
        while j < m {
            ops.append(.insert(after[j]))
            j += 1
        }
        return ops
    }

    /// Unified diff, `-` = Python reference, `+` = Swift `read`.
    static func unifiedDiff(
        reference: [String], candidate: [String], context: Int = 3, maxLines: Int = 200
    ) -> String {
        if reference.count * candidate.count > diffCellBudget {
            return firstDivergence(reference: reference, candidate: candidate, context: context)
        }

        let ops = diffOps(reference, candidate)
        var rows: [(prefix: String, text: String, a: Int, b: Int)] = []
        var aNo = 0
        var bNo = 0
        for op in ops {
            switch op {
            case .keep(let line):
                aNo += 1
                bNo += 1
                rows.append((" ", line, aNo, bNo))
            case .delete(let line):
                aNo += 1
                rows.append(("-", line, aNo, bNo))
            case .insert(let line):
                bNo += 1
                rows.append(("+", line, aNo, bNo))
            }
        }

        var include = [Bool](repeating: false, count: rows.count)
        for (index, row) in rows.enumerated() where row.prefix != " " {
            let lower = max(0, index - context)
            let upper = min(rows.count - 1, index + context)
            for k in lower...upper { include[k] = true }
        }

        var out: [String] = []
        var index = 0
        var truncated = false
        while index < rows.count {
            guard include[index] else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < rows.count && include[end + 1] { end += 1 }

            let hunk = Array(rows[index...end])
            let aLen = hunk.filter { $0.prefix != "+" }.count
            let bLen = hunk.filter { $0.prefix != "-" }.count
            let aStart = hunk.first.map { $0.prefix == "+" ? $0.a + 1 : $0.a } ?? 0
            let bStart = hunk.first.map { $0.prefix == "-" ? $0.b + 1 : $0.b } ?? 0
            out.append("@@ -\(aStart),\(aLen) +\(bStart),\(bLen) @@")
            for row in hunk {
                if out.count >= maxLines {
                    truncated = true
                    break
                }
                out.append("\(row.prefix)\(row.text)")
            }
            if truncated { break }
            index = end + 1
        }

        if truncated { out.append("… diff truncated at \(maxLines) lines") }
        return out.joined(separator: "\n")
    }

    /// Fallback for documents too large to diff: show the neighbourhood of the
    /// first line that differs.
    static func firstDivergence(reference: [String], candidate: [String], context: Int) -> String {
        let limit = min(reference.count, candidate.count)
        var at = limit
        for index in 0..<limit where reference[index] != candidate[index] {
            at = index
            break
        }
        let lower = max(0, at - context)
        var out = [
            "(documents too large for a full diff; first divergence at line \(at + 1))"
        ]
        for index in lower..<min(at + context + 1, max(reference.count, candidate.count)) {
            let a = index < reference.count ? reference[index] : "<eof>"
            let b = index < candidate.count ? candidate[index] : "<eof>"
            if a == b {
                out.append(" \(a)")
            } else {
                out.append("-\(a)")
                out.append("+\(b)")
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Test

    @Test("`read` matches the Python reference", arguments: corpus)
    func parity(page: CorpusPage) async throws {
        // Created bare, then navigated explicitly: `session_create(url:)` and
        // `navigate` both kick off the load without waiting, but going through
        // `navigate` keeps the "started loading" edge on our side of the call
        // so `awaitSettledDOM` can't observe the pre-navigation document.
        let created = try await Self.callTool("session_create", ["background": true])
        guard let sessionId = created["sessionId"] as? String else {
            throw ParityError("\(page.slug): session_create returned no sessionId — \(created)")
        }

        let swiftSide: SwiftSide
        let pythonSide: PythonSide
        do {
            _ = try await Self.callTool(
                "navigate", ["sessionId": sessionId, "url": page.url])
            let domSize = try await Self.awaitSettledDOM(sessionId: sessionId, page: page)
            // Back to back, smallest possible window between the live DOM that
            // `read` walks and the snapshot Python is handed.
            swiftSide = try await Self.readViaSwift(sessionId: sessionId, page: page)
            pythonSide = try await Self.readViaPython(sessionId: sessionId, page: page)
            print(
                """
                [pulpie-parity] \(page.slug)
                  url            \(page.url)
                  settled DOM    \(domSize) chars
                  swift          markdown \(swiftSide.markdown.utf8.count) B  \
                extraction \(swiftSide.extractionMs) ms  \
                blocks \(swiftSide.blockCount) (main \(swiftSide.mainBlockCount))
                  python         markdown \(pythonSide.outputBytes) B  \
                extraction \(pythonSide.extractionMs) ms  \
                input \(pythonSide.inputBytes) B
                """)
        } catch {
            _ = try? await Self.callTool("session_close", ["sessionId": sessionId])
            throw error
        }
        _ = try? await Self.callTool("session_close", ["sessionId": sessionId])

        let expected = Self.normalize(pythonSide.markdown)
        let actual = Self.normalize(swiftSide.markdown)

        // Non-vacuity. Two extractors that both produce nothing are byte-equal,
        // and that is the single most likely way this canary goes green while
        // the tool is broken — the `b.text`/`b.html` bug it was written after
        // produced exactly zero main blocks on every page.
        #expect(
            !actual.isEmpty,
            "\(page.slug): `read` returned empty markdown — parity against an empty reference is not evidence the tool works")
        #expect(
            swiftSide.mainBlockCount > 0,
            "\(page.slug): `read` classified 0 of \(swiftSide.blockCount) blocks as main content")

        guard expected != actual else { return }

        let diff = Self.unifiedDiff(
            reference: expected.components(separatedBy: "\n"),
            candidate: actual.components(separatedBy: "\n"))
        print("[pulpie-parity] \(page.slug) DIVERGED\n\(diff)")

        Issue.record(
            """
            \(page.slug) diverged from the Python reference after normalization.
            \(page.url)
            python \(expected.utf8.count) B / swift \(actual.utf8.count) B \
            (\(swiftSide.blockCount) blocks, \(swiftSide.mainBlockCount) main)
            `-` is the Python reference, `+` is the Swift `read` tool:

            \(diff)
            """)
    }
}

/// Free function rather than a static on the suite so the `@Suite` attribute
/// doesn't reference the type it's attached to.
private func pulpieParityGateEnabled() -> Bool {
    ProcessInfo.processInfo.environment["PULPIE_PARITY"] == "1"
}

/// Offline cover for the pure comparison helpers. Deliberately NOT gated behind
/// `PULPIE_PARITY`: `normalize` is what decides whether the canary fires, so an
/// over-eager rule there would quietly turn the whole suite into a no-op on
/// every page. These need no network, no bridge, and no Python.
@Suite
struct PulpieParityNormalizationTests {

    typealias Parity = PulpieParityTests

    @Test("normalization erases exactly the differences it claims to")
    func normalizationScope() {
        // Rule 2: line endings.
        #expect(Parity.normalize("a\r\nb") == Parity.normalize("a\nb"))
        #expect(Parity.normalize("a\rb") == Parity.normalize("a\nb"))
        // Rule 3: trailing space/tab — the real usaspending divergence.
        #expect(Parity.normalize("## Department of Defense (DOD) ") == "## Department of Defense (DOD)")
        #expect(Parity.normalize("a\t") == "a")
        // Rule 4: blank-line runs.
        #expect(Parity.normalize("a\n\n\n\n\nb") == "a\n\nb")
        // Rule 5: document edges.
        #expect(Parity.normalize("\n\n  \na\n\n\n") == "a")
    }

    @Test("normalization preserves everything else")
    func normalizationIsNarrow() {
        // Leading indentation is markdown structure (code blocks, nesting).
        #expect(Parity.normalize("    indented") == "    indented")
        // Interior whitespace distinguishes real content.
        #expect(Parity.normalize("a  b") == "a  b")
        // A single blank line is a paragraph break, not noise.
        #expect(Parity.normalize("a\n\nb") == "a\n\nb")
        // NBSP is content the extractors disagreed about, not trailing space.
        #expect(Parity.normalize("a\u{00A0}") == "a\u{00A0}")
        // The differences that actually matter must survive.
        #expect(Parity.normalize("[x](/a)") != Parity.normalize("[x](/b)"))
        #expect(Parity.normalize("# x") != Parity.normalize("## x"))
        #expect(Parity.normalize("a\nb") != Parity.normalize("b\na"))
    }

    @Test("unified diff reports insertions, deletions, and replacements")
    func diffRendering() {
        let diff = Parity.unifiedDiff(
            reference: ["same", "python-only", "tail"],
            candidate: ["same", "swift-only", "tail"])
        #expect(diff.contains("-python-only"))
        #expect(diff.contains("+swift-only"))
        #expect(diff.contains(" same"))
        #expect(diff.hasPrefix("@@"))

        let insertion = Parity.unifiedDiff(reference: ["a"], candidate: ["a", "b"])
        #expect(insertion.contains("+b"))
        #expect(!insertion.contains("-b"))

        let deletion = Parity.unifiedDiff(reference: ["a", "b"], candidate: ["a"])
        #expect(deletion.contains("-b"))
        #expect(!deletion.contains("+b"))
    }

    @Test("identical input produces an empty diff")
    func diffOnEqualInput() {
        #expect(Parity.unifiedDiff(reference: ["a", "b", "c"], candidate: ["a", "b", "c"]).isEmpty)
    }

    @Test("diff output is bounded on a fully divergent document")
    func diffTruncation() {
        let reference = (0..<500).map { "python \($0)" }
        let candidate = (0..<500).map { "swift \($0)" }
        let diff = Parity.unifiedDiff(reference: reference, candidate: candidate, maxLines: 40)
        #expect(diff.components(separatedBy: "\n").count <= 42)
        #expect(diff.contains("truncated"))
    }
}
