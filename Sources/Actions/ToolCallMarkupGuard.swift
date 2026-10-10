import Foundation

/// Rejects text whose tail is the caller's own tool-call markup.
///
/// A model that closes a parameter with the wrong tag (`</description>`
/// instead of the parameter closer) makes its client read everything up to
/// the next real closer as that parameter's value. The stored text then ends
/// in `</description>\n<parameter name="attributes">{...}` or
/// `</description>\n</invoke>`, and every parameter swallowed into the tail
/// is silently lost. 2026-10-10: 6 of 1,129 entities, and both meetings had
/// attributes = null because their JSON was inside the tail.
///
/// Rejecting beats stripping. The caller retries with clean text, and the
/// swallowed parameters come back with it instead of vanishing unnoticed.
///
/// THE RULE. A fragment is one of `</description>`, `</content>`,
/// `</parameter>`, `</invoke>`, `<parameter name=` or `<invoke` (an optional
/// `ns:` prefix is allowed on each). Text is rejected at the first fragment that:
///   1. is followed, after whitespace only, by a well-formed
///      `<parameter name="x">` or by `</invoke>`, so the call structure
///      continues past it (this catches a leak however long the swallowed
///      tail is); or
///   2. starts within the final `tailWindow` characters; or
///   3. has nothing but whitespace before it, so the text opens with markup.
/// Anything else passes. A learning about this bug can quote
/// "</description>" mid-sentence: no markup follows it and it is not at the
/// end. What it cannot do is finish on the markup itself.
///
/// Rule 1 asks for the quoted, closed tag because every real leak has it
/// (`<parameter name="tags">`), while prose about the bug tends to write it
/// loosely (`</description><parameter name=attributes>`, memory 8304f340).
///
/// Apply it to long free-text bodies only (content, description). On a field
/// under `tailWindow` characters, rule 2 covers the whole value, so a short
/// summary that merely mentions the markup would be refused.
enum ToolCallMarkupGuard {

    /// How close to the end a lone fragment has to be to count as a leaked
    /// tail. The leaked `</invoke>` tails were 7–22 characters from the end.
    static let tailWindow = 200

    struct Leak: Equatable {
        let fragment: String
        /// Character offset of the fragment's first character.
        let offset: Int
    }

    private static let ns = #"(?:[A-Za-z_][A-Za-z0-9_.-]*:)?"#
    private static let fragmentPattern = try! NSRegularExpression(
        pattern: "</\(ns)(?:description|content|parameter|invoke)>|<\(ns)parameter\\s+name=|<\(ns)invoke\\b"
    )
    private static let continuationPattern = try! NSRegularExpression(
        pattern: "\\s*(?:<\(ns)parameter\\s+name=\"[^\"<>]*\">|</\(ns)invoke>)"
    )

    static func findLeak(in text: String) -> Leak? {
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        // Cheap exit for the common case: no '<' means no markup at all.
        guard nsText.range(of: "<").location != NSNotFound else { return nil }
        let total = text.count

        for match in fragmentPattern.matches(in: text, range: full) {
            guard let range = Range(match.range, in: text) else { continue }
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            let after = NSRange(location: NSMaxRange(match.range), length: nsText.length - NSMaxRange(match.range))
            let continues = continuationPattern.firstMatch(in: text, options: .anchored, range: after) != nil
            let inTail = total - offset <= tailWindow
            let leading = text[..<range.lowerBound].allSatisfy(\.isWhitespace)
            if continues || inTail || leading {
                return Leak(fragment: String(text[range]), offset: offset)
            }
        }
        return nil
    }

    /// Throws `invalidParam(field, …)` naming the fragment and its offset.
    static func check(_ text: String?, field: String) throws {
        guard let text, let leak = findLeak(in: text) else { return }
        throw ActionError.invalidParam(field, """
            contains tool-call markup '\(leak.fragment)' at character offset \(leak.offset) \
            (of \(text.count)). This looks like a malformed tool call whose parameter markup leaked \
            into the value; any parameters after it were probably swallowed too. Nothing was written. \
            Retry with the text before offset \(leak.offset) and pass the other parameters separately. \
            To quote this markup on purpose, keep it out of the last \(tailWindow) characters and do \
            not put a parameter or invoke tag right after it.
            """)
    }

    /// Checks every `description` in mem_store's inline `entities` JSON.
    /// Parse failures are left to the annotation step, which skips them.
    static func checkInlineEntities(_ entitiesJSON: String?) throws {
        guard let data = entitiesJSON?.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for (i, row) in rows.enumerated() {
            guard let description = row["description"] as? String,
                  let leak = findLeak(in: description) else { continue }
            let name = (row["name"] as? String) ?? "#\(i)"
            throw ActionError.invalidParam("entities", """
                entity '\(name)' description contains tool-call markup '\(leak.fragment)' at character \
                offset \(leak.offset) (of \(description.count)). This looks like a malformed tool call \
                whose parameter markup leaked into the value. Nothing was written, not even the memory. \
                Retry with the description before offset \(leak.offset).
                """)
        }
    }
}
