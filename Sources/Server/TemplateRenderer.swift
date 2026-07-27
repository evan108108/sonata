import Foundation

/// Dumb prompt-template renderer for the webhook_deliver `worker` destination.
///
/// Substitutes `{{ path.to.value }}` expressions against a JSON payload. NO
/// logic, NO conditionals, NO filters — this is intentional. The whole point
/// is that a route's promptTemplate is a plain string a user writes once and
/// doesn't have to reason about.
///
/// Rules:
///   - `{{ path.to.value }}` walks the payload's JSON along the dotted path.
///   - Scalars render as text: string, number, bool cast via `\(.)`.
///   - Objects and arrays render as pretty-printed JSON in a fenced code block,
///     so `{{ body.pull_request }}` attaches the whole PR object without
///     hand-listing every field.
///   - `{{ payload }}` (or `{{ . }}`) renders the ENTIRE envelope as JSON —
///     the escape hatch for "give the worker the raw webhook for reference."
///   - Unknown paths render as empty string AND append a warning to `warnings`
///     so audit shows template typos instead of mysterious blank prompts.
///
/// Whitespace inside `{{ ... }}` is trimmed. Case-sensitive path lookup.
struct TemplateRenderResult {
    let rendered: String
    let warnings: [String]
}

func renderTemplate(_ template: String, payload: [String: Any]) -> TemplateRenderResult {
    var out = ""
    var warnings: [String] = []
    var i = template.startIndex

    while i < template.endIndex {
        // Look for the next `{{`
        guard let open = template.range(of: "{{", range: i..<template.endIndex) else {
            out += template[i..<template.endIndex]
            break
        }
        out += template[i..<open.lowerBound]

        // Find matching `}}`
        guard let close = template.range(of: "}}", range: open.upperBound..<template.endIndex) else {
            // Unclosed — emit the rest as literal text and warn.
            warnings.append("unclosed '{{' at offset \(template.distance(from: template.startIndex, to: open.lowerBound)); emitting remainder as literal")
            out += template[open.lowerBound..<template.endIndex]
            break
        }

        let rawPath = String(template[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let resolved = resolvePath(rawPath, in: payload, warnings: &warnings)
        out += resolved

        i = close.upperBound
    }

    return TemplateRenderResult(rendered: out, warnings: warnings)
}

/// Resolve a template expression against the payload. Returns the string form.
private func resolvePath(_ path: String, in payload: [String: Any], warnings: inout [String]) -> String {
    // Whole-payload escape hatch: `{{ payload }}` or `{{ . }}` (or `{{  }}`).
    if path.isEmpty || path == "." || path == "payload" {
        return renderJSON(payload)
    }

    // Walk the dotted path. Support `payload.foo` and bare `foo` equivalently.
    var current: Any? = payload
    let segments = path.hasPrefix("payload.")
        ? path.dropFirst("payload.".count).split(separator: ".").map(String.init)
        : path.split(separator: ".").map(String.init)

    for seg in segments {
        if let dict = current as? [String: Any] {
            current = dict[seg]
        } else {
            current = nil
            break
        }
        if current == nil { break }
    }

    guard let value = current else {
        warnings.append("template path '\(path)' resolved to nothing (empty string substituted)")
        return ""
    }

    return renderScalarOrJSON(value)
}

/// Scalars → text; objects/arrays → pretty-printed JSON in a fenced code block.
private func renderScalarOrJSON(_ value: Any) -> String {
    switch value {
    case let s as String: return s
    case let b as Bool: return b ? "true" : "false"
    case let n as NSNumber:
        // NSNumber covers both Int and Double coming out of JSONSerialization.
        // Distinguish bool via objCType — JSONSerialization returns Bool as
        // NSNumber with type "c".
        if String(cString: n.objCType) == "c" { return n.boolValue ? "true" : "false" }
        return n.stringValue
    case is NSNull: return ""
    default: return renderJSON(value)
    }
}

private func renderJSON(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value) else {
        // Fallback: some scalar that shouldn't have hit this branch.
        return "\(value)"
    }
    guard let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let str = String(data: data, encoding: .utf8) else {
        return "\(value)"
    }
    return "```json\n\(str)\n```"
}
