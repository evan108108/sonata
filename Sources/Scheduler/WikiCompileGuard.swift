import Foundation

/// Decides whether a dirty wiki page may be structurally regenerated.
///
/// The compileWiki cron dispatches one generic recipe — "fetch the page's
/// backing memories, write synthesized prose organized by theme" — over every
/// dirty page. For a large class of pages that recipe is *destructive*: it
/// replaces a hand- or cron-curated file with a synthesis of memories that
/// never contained the file's content in the first place.
///
/// Before this guard existed the only thing standing between those pages and
/// erasure was a worker noticing by hand, mid-run, that the recipe was wrong.
/// Five separate runs (2026-06-29, 07-06 ×2, 07-13, 07-19) independently
/// re-derived the same hazard and declined to act; on 07-19 all ten dispatched
/// pages needed preservation and zero needed compiling. A hazard that is
/// re-derived every run is a missing check, not a missing memory — so the
/// measurement moved here, where it runs before dispatch instead of after.
///
/// All rules are pure functions of values the job can measure up front. The one
/// rule that cannot be pre-computed — "the proposed output is dramatically
/// smaller than the file it would replace" — is unknowable until a worker has
/// drafted the replacement, so it lives in the prompt as a worker-side stop
/// rule (see `WikiCompilationJob.buildPrompt`).
enum WikiCompileGuard {

    // MARK: - Types

    /// Everything the guard needs about one dirty page. Measured by the caller
    /// so the rules stay pure and testable without a database.
    struct Candidate: Equatable {
        /// Page slug, used for logging and collision reporting.
        let slug: String
        /// Memory project namespace the recipe would select on.
        let namespace: String?
        /// Memory topic the recipe would select on.
        let topic: String?
        /// Absolute path to the page's markdown file.
        let filePath: String
        /// `wikiPages.lastCompiled` (ms). 0 means never compiled.
        let lastCompiled: Int64
        /// How many memories the recipe's selector would actually return.
        let backingMemoryCount: Int
        /// `createdAt` (ms) of the newest memory the selector returns, nil if none.
        let newestBackingMemoryAt: Int64?
        /// Slugs of the *other* pages in this run whose (namespace, topic)
        /// selector is identical to this one's.
        let collidingSlugs: [String]
        /// Whether the file's YAML frontmatter carries `compile: preserve`.
        let hasPreserveMarker: Bool
    }

    /// What the job should do with a page.
    enum Decision: Equatable {
        /// Safe to regenerate — include in the dispatched manifest.
        case compile
        /// Do not regenerate. Clear the dirty flag in place; the file stands.
        case preserve(reason: String)

        var isPreserve: Bool {
            if case .preserve = self { return true }
            return false
        }

        /// Human-readable reason, empty for `.compile`.
        var reason: String {
            if case .preserve(let r) = self { return r }
            return ""
        }
    }

    // MARK: - Rules

    /// Apply every pre-dispatch rule to one candidate.
    ///
    /// Rules are ordered most-explicit-first so the logged reason names the
    /// strongest available justification rather than whichever heuristic
    /// happened to fire.
    static func decide(_ c: Candidate) -> Decision {
        // 1. Explicit author intent. A page that says it is curated is curated,
        //    regardless of what its memory counts look like.
        if c.hasPreserveMarker {
            return .preserve(reason: "frontmatter declares `compile: preserve`")
        }

        // 2. Nothing to compile from. The recipe's selector returns no memories,
        //    so "synthesize from memories" synthesizes nothing — regenerating
        //    empties a file that was written by hand or by another cron.
        if c.backingMemoryCount == 0 {
            return .preserve(reason: "0 backing memories — the page is externally curated, regenerating would empty it")
        }

        // 3. Ambiguous selector. Two or more pages in this run resolve to the
        //    same (namespace, topic), so the recipe would fetch one identical
        //    memory set and write identical content over unrelated pages. The
        //    manifest's own topic field is the unreliable input here, so the
        //    only safe reading is that it cannot be used as a selector at all.
        if !c.collidingSlugs.isEmpty {
            let others = c.collidingSlugs.sorted().joined(separator: ", ")
            return .preserve(reason: "topic selector \(selectorDescription(c)) is shared with \(others) — regenerating would write identical content over unrelated pages")
        }

        // 4. Dirty without new content. The dirty flag is a claim that something
        //    changed; the backing memories are the measurement. If nothing the
        //    recipe reads is newer than the last compile, a regeneration can
        //    only restate or lose what is already on disk.
        if c.lastCompiled > 0, let newest = c.newestBackingMemoryAt, newest <= c.lastCompiled {
            return .preserve(reason: "newest backing memory predates lastCompiled — dirty flag carries no new content")
        }

        return .compile
    }

    /// Partition a run's dirty pages, resolving topic collisions across the set.
    ///
    /// Collision detection is a property of the *run*, not of a page in
    /// isolation, so it is computed here and folded into each candidate before
    /// the per-page rules see it.
    static func partition(_ candidates: [Candidate]) -> (compile: [Candidate], preserve: [(Candidate, String)]) {
        var bySelector: [String: [String]] = [:]
        for c in candidates {
            bySelector[selectorKey(c), default: []].append(c.slug)
        }

        var toCompile: [Candidate] = []
        var toPreserve: [(Candidate, String)] = []

        for c in candidates {
            let siblings = (bySelector[selectorKey(c)] ?? []).filter { $0 != c.slug }
            let resolved = Candidate(
                slug: c.slug,
                namespace: c.namespace,
                topic: c.topic,
                filePath: c.filePath,
                lastCompiled: c.lastCompiled,
                backingMemoryCount: c.backingMemoryCount,
                newestBackingMemoryAt: c.newestBackingMemoryAt,
                collidingSlugs: siblings,
                hasPreserveMarker: c.hasPreserveMarker
            )
            switch decide(resolved) {
            case .compile:
                toCompile.append(resolved)
            case .preserve(let reason):
                toPreserve.append((resolved, reason))
            }
        }

        return (toCompile, toPreserve)
    }

    // MARK: - Frontmatter

    /// Value that marks a page as never-structurally-regenerated.
    static let preserveMarkerValue = "preserve"
    /// Frontmatter key the marker lives under.
    static let preserveMarkerKey = "compile"

    /// Read `compile: preserve` out of a file's YAML frontmatter.
    ///
    /// Frontmatter is already an established convention in this wiki (the
    /// tool-trials candidate pages use it, and `WikiFileWatcher` parses it for
    /// titles), so the flag travels with the content: it survives a database
    /// rebuild, and a human editing the file can set it without touching SQL.
    static func hasPreserveMarker(atPath path: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return hasPreserveMarker(inContent: content)
    }

    /// Frontmatter-only parse, split out so it is testable without a file.
    static func hasPreserveMarker(inContent content: String) -> Bool {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---" else { return false }

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { return false }  // end of frontmatter, key absent
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == preserveMarkerKey else { continue }
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .lowercased()
            return value == preserveMarkerValue
        }
        return false
    }

    // MARK: - Helpers

    private static func selectorKey(_ c: Candidate) -> String {
        "\(c.namespace ?? "")\u{1F}\(c.topic ?? "")"
    }

    private static func selectorDescription(_ c: Candidate) -> String {
        "(namespace: \(c.namespace ?? "none"), topic: \(c.topic ?? "none"))"
    }
}
