import Foundation

/// Sanitizes arbitrary user input for safe use with SQLite FTS5 `MATCH`.
///
/// FTS5's `MATCH` is a query mini-language: `-`, `:`, `"`, `*`, `(`, `)` and the
/// bareword keywords `OR`/`AND`/`NOT`/`NEAR` are operators. Passing raw user text
/// straight to `MATCH` makes FTS5 parse that punctuation as syntax and throw — e.g.
/// `world-watch OR strategic-signal` resolves to a column filter and fails with
/// `no such column: watch` instead of searching for the literal terms.
///
/// We neutralize this by tokenizing on whitespace/comma/semicolon, escaping any
/// embedded double-quote (FTS5 doubles `"` → `""`), then wrapping each token in
/// double quotes (a literal phrase) with a trailing `*` for prefix matching.
/// Tokens are ANDed implicitly. This mirrors the long-standing behavior `mem_recall`
/// relies on via the former `recallBuildFTSQuery`.
///
/// Returns `""` when the input has no usable tokens; callers MUST treat an empty
/// result as "no query" and return no rows rather than running `MATCH ''` (which
/// is itself a syntax error in FTS5).
func ftsEscape(_ input: String) -> String {
    ftsTokenize(input).map(ftsQuoteToken).joined(separator: " ")
}

/// Like ``ftsEscape(_:)`` but ORs the tokens instead of ANDing them.
func ftsEscapeOR(_ input: String) -> String {
    ftsTokenize(input).map(ftsQuoteToken).joined(separator: " OR ")
}

private func ftsTokenize(_ input: String) -> [String] {
    input.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
        .map(String.init)
        .filter { !$0.isEmpty }
}

private func ftsQuoteToken(_ token: String) -> String {
    let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
    return "\"\(escaped)\"*"
}
