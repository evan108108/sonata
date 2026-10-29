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
/// Two barewords keep their meaning: an uppercase `OR` between terms stays the
/// FTS5 operator, so `A OR B` is a union (quoted as a literal it meant
/// `A AND B AND or*`, and an OR-joined dedup check came back empty on 10/28), and
/// an uppercase `AND` is dropped because juxtaposition already ANDs. A leading,
/// trailing or repeated `OR` is dropped. `NOT`/`NEAR` and lowercase words stay literal.
///
/// Returns `""` when the input has no usable tokens; callers MUST treat an empty
/// result as "no query" and return no rows rather than running `MATCH ''` (which
/// is itself a syntax error in FTS5).
func ftsEscape(_ input: String) -> String {
    var parts: [String] = []
    for token in ftsTokenize(input) where token != "AND" {
        if token == "OR" {
            if let last = parts.last, last != "OR" { parts.append("OR") }
        } else {
            parts.append(ftsQuoteToken(token))
        }
    }
    if parts.last == "OR" { parts.removeLast() }
    return parts.joined(separator: " ")
}

/// Like ``ftsEscape(_:)`` but ORs the tokens instead of ANDing them. Bareword
/// `OR`/`AND` are dropped rather than searched as literal terms.
func ftsEscapeOR(_ input: String) -> String {
    ftsTokenize(input).filter { $0 != "OR" && $0 != "AND" }.map(ftsQuoteToken).joined(separator: " OR ")
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
