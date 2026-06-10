import Foundation

/// Extracts the list of Anthropic model IDs the user's installed `claude` CLI
/// will accept via `--model`. The Bun-packaged Claude Code binary stores its
/// model whitelist as literal UTF-8 inside the executable, so we can pull it
/// with a plain regex over the file's bytes — no Bun-section parsing needed.
///
/// Output feeds `AnthropicModelStore`, which upserts into the SQLite
/// `anthropicModels` table and drives the Sessions/Workers pickers + the
/// Settings → Anthropic Models checklist.
///
/// Re-extraction is cheap (~200 MB binary, ~50 ms regex pass), but we cache
/// by binary mtime so launching Sonata doesn't repeat the scan when the user
/// hasn't updated Claude Code.
enum AnthropicModelExtractor {
    struct Entry: Hashable, Sendable {
        let id: String         // e.g. "claude-opus-4-7" or "claude-opus-4-7-20251114"
        let tier: String       // "opus" | "sonnet" | "haiku" | "fable"
        let version: String    // "4.7", "4", "5" — dots, derived from id segments
        let isDated: Bool      // true when id ends in -YYYYMMDD
        let date: String?      // "20251114" or nil
    }

    static let tiers = ["opus", "sonnet", "haiku", "fable"]
    private static let pattern: NSRegularExpression = {
        // claude-<tier>-<digits>(-<digits>)*(-<8 digit date>)?
        // The version+date split happens in parse() — easier than encoding it
        // in the regex.
        let raw = "claude-(\(tiers.joined(separator: "|")))-(\\d+(?:-\\d+)*)"
        return try! NSRegularExpression(pattern: raw)
    }()

    /// Pull every Anthropic model ID out of the given binary, deduped and
    /// sorted (tier canonical → version desc → dated last).
    ///
    /// Reads ~200 MB into memory; called rarely (boot + Settings refresh) so
    /// not worth streaming.
    static func extract(binaryPath: String) throws -> [Entry] {
        let url = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath()
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        // Bun executables are mostly bytecode but model IDs are plain ASCII
        // strings. Decoding as latin1 is lossless for ASCII and avoids the
        // UTF-8-validation cost on the bytecode garbage between strings.
        guard let text = String(data: data, encoding: .isoLatin1) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var entries: [Entry] = []
        pattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let fullRange = Range(match.range, in: text) else { return }
            let id = String(text[fullRange])
            if seen.insert(id).inserted, let entry = parse(id: id) {
                entries.append(entry)
            }
        }
        return sorted(entries)
    }

    /// Same logic as `extract(binaryPath:)` but takes the raw text in-process —
    /// used by tests so we don't need a real Claude binary on the test runner.
    static func parse(source text: String) -> [Entry] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var entries: [Entry] = []
        pattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let fullRange = Range(match.range, in: text) else { return }
            let id = String(text[fullRange])
            if seen.insert(id).inserted, let entry = parse(id: id) {
                entries.append(entry)
            }
        }
        return sorted(entries)
    }

    /// Break `claude-<tier>-<a>-<b>-...-<YYYYMMDD?>` into structured fields.
    /// The trailing 8-digit segment, if present, is the release date; everything
    /// else after the tier is the version (joined with '.').
    static func parse(id: String) -> Entry? {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude" else { return nil }
        let tier = parts[1]
        guard tiers.contains(tier) else { return nil }
        let rest = Array(parts.dropFirst(2))
        let last = rest.last ?? ""
        let isDated = last.count == 8 && last.allSatisfy(\.isNumber)
        let date = isDated ? last : nil
        let versionParts = isDated ? Array(rest.dropLast()) : rest
        guard !versionParts.isEmpty else { return nil }
        let version = versionParts.joined(separator: ".")
        return Entry(id: id, tier: tier, version: version, isDated: isDated, date: date)
    }

    private static func sorted(_ entries: [Entry]) -> [Entry] {
        let tierOrder = Dictionary(uniqueKeysWithValues: tiers.enumerated().map { ($1, $0) })
        return entries.sorted { a, b in
            let ta = tierOrder[a.tier] ?? Int.max
            let tb = tierOrder[b.tier] ?? Int.max
            if ta != tb { return ta < tb }
            if a.version != b.version {
                return a.version.compare(b.version, options: .numeric) == .orderedDescending
            }
            // Short id (no date) sorts before dated id with same version.
            return !a.isDated && b.isDated
        }
    }

    /// mtime of the binary (following symlinks). Used to skip re-extraction
    /// when the file hasn't changed since the last cached scan.
    static func binaryMtime(_ path: String) -> Date? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }
}
