import Foundation
import CryptoKit
import Logging

/// Architecture of the running process — picks the matching binary asset.
enum BinaryArch: Sendable {
    case arm64
    case x86_64

    static var current: BinaryArch {
        #if arch(arm64)
        return .arm64
        #else
        return .x86_64
        #endif
    }
}

/// Declarative spec for an external helper binary the app manages itself —
/// discovered locally or downloaded on first run. Add a new downloadable
/// dependency by declaring one of these (see `ManagedBinary.meilisearch`).
struct ManagedBinary: Sendable {
    /// How the downloaded asset is packaged.
    enum Packaging: Sendable {
        case rawBinary                              // the download IS the executable
        case tarGz(binaryPathInArchive: String)     // extract, binary at this relative path
        case zip(binaryPathInArchive: String)
        // Extract the WHOLE archive into a versioned dir and run `binaryName` in
        // place — for binaries that ship with sibling dylibs (e.g. llama-server,
        // rpath @loader_path). The dir is kept; the binary is located recursively.
        case archiveDir(binaryName: String)
    }

    struct Source: Sendable {
        let url: URL
        /// Lowercase hex SHA-256. `nil` = unpinned: trusted via HTTPS from its
        /// official host; the computed hash is logged so it can be pinned later.
        let sha256: String?
        let packaging: Packaging
    }

    /// Executable name (also the bundled/cached filename), e.g. "meilisearch".
    let name: String
    /// Pinned version, e.g. "1.42.1" — part of the cache filename so a bump re-downloads.
    let version: String
    /// Absolute paths checked before downloading (Homebrew, etc.).
    let systemPaths: [String]
    /// Per-arch download sources.
    let sources: [BinaryArch: Source]
}

/// Resolves `ManagedBinary` specs to an on-disk executable path:
/// app bundle → known system paths → versioned cache in `~/.sonata/bin` →
/// download + verify + install. Keeps heavyweight required dependencies off the
/// user's setup checklist (download-on-first-run instead of bundling/Homebrew).
actor BinaryProvisioner {
    static let shared = BinaryProvisioner()

    enum Status: Sendable {
        case downloading
        case installed
        case failed(String)
    }

    enum ProvisionError: Error {
        case noSourceForArch
        case badResponse
        case checksumMismatch
        case extractionFailed
        case binaryNotFoundInArchive
    }

    private let logger: Logger
    private var installDir: String { SonataInstance.dataDirectory + "/bin" }

    init() {
        var log = Logger(label: "sonata.binaryprovisioner")
        log.logLevel = .info
        self.logger = log
    }

    /// Fast, network-free resolution: bundle → system paths → versioned cache.
    /// Returns nil if the binary would have to be downloaded.
    func cachedPath(of spec: ManagedBinary) -> String? {
        let fm = FileManager.default
        if let bundled = bundledPath(name: spec.name), fm.isExecutableFile(atPath: bundled) {
            return bundled
        }
        for path in spec.systemPaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        if case .archiveDir(let binName)? = spec.sources[BinaryArch.current]?.packaging {
            let dir = cacheURL(for: spec).path
            if let found = findFile(named: binName, under: dir), fm.isExecutableFile(atPath: found) { return found }
        } else {
            let cached = cacheURL(for: spec).path
            if fm.isExecutableFile(atPath: cached) { return cached }
        }
        return nil
    }

    /// Full resolution: a cached/system path if present, else download + verify +
    /// install. Returns the executable path, or nil on failure.
    func provision(_ spec: ManagedBinary, onStatus: (@Sendable (Status) -> Void)? = nil) async -> String? {
        if let path = cachedPath(of: spec) { return path }
        guard let source = spec.sources[BinaryArch.current] else {
            logger.error("\(spec.name): no download source for this architecture")
            onStatus?(.failed("unsupported architecture"))
            return nil
        }
        do {
            onStatus?(.downloading)
            let path = try await downloadAndInstall(spec: spec, source: source)
            logger.info("\(spec.name) \(spec.version) installed at \(path)")
            onStatus?(.installed)
            return path
        } catch {
            logger.error("\(spec.name): provisioning failed: \(error)")
            onStatus?(.failed("\(error)"))
            return nil
        }
    }

    // MARK: - Internals

    private func cacheURL(for spec: ManagedBinary) -> URL {
        URL(fileURLWithPath: installDir).appendingPathComponent("\(spec.name)-\(spec.version)")
    }

    /// `<App>.app/Contents/Resources/bin/<name>` — populated by the packaging
    /// step for builds that choose to bundle rather than download.
    private func bundledPath(name: String) -> String? {
        guard let exec = Bundle.main.executablePath else { return nil }
        let contents = (exec as NSString).deletingLastPathComponent + "/.."
        return (contents as NSString).standardizingPath + "/Resources/bin/\(name)"
    }

    private func downloadAndInstall(spec: ManagedBinary, source: ManagedBinary.Source) async throws -> String {
        let fm = FileManager.default
        logger.info("\(spec.name) \(spec.version): downloading \(source.url.absoluteString)")
        let (tempURL, response) = try await URLSession.shared.download(from: source.url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProvisionError.badResponse
        }
        let data = try Data(contentsOf: tempURL)

        // Checksum: enforce when pinned; otherwise log the computed hash to pin later.
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let expected = source.sha256?.lowercased() {
            guard digest == expected else {
                logger.error("\(spec.name): checksum mismatch (expected \(expected), got \(digest))")
                throw ProvisionError.checksumMismatch
            }
        } else {
            logger.info("\(spec.name): unpinned download — sha256=\(digest) (pin this in the spec)")
        }

        try fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)
        let finalURL = cacheURL(for: spec)
        try? fm.removeItem(at: finalURL)

        // archiveDir: extract the WHOLE archive into the versioned dir and run the
        // binary in place — it keeps its sibling dylibs (rpath @loader_path).
        if case .archiveDir(let binName) = source.packaging {
            try fm.createDirectory(at: finalURL, withIntermediateDirectories: true)
            try extractArchive(data: data, ext: archiveExt(source.url), into: finalURL)
            guard let binPath = findFile(named: binName, under: finalURL.path) else {
                throw ProvisionError.binaryNotFoundInArchive
            }
            try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: binPath)
            stripQuarantine(binPath)
            cleanStaleVersions(spec: spec, keeping: finalURL.lastPathComponent)
            return binPath
        }

        switch source.packaging {
        case .rawBinary:
            try data.write(to: finalURL)
        case .tarGz(let inner):
            try extract(data: data, ext: "tar.gz", innerPath: inner, to: finalURL)
        case .zip(let inner):
            try extract(data: data, ext: "zip", innerPath: inner, to: finalURL)
        case .archiveDir:
            break // handled above
        }

        try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: finalURL.path)
        stripQuarantine(finalURL.path)
        cleanStaleVersions(spec: spec, keeping: finalURL.lastPathComponent)
        return finalURL.path
    }

    /// Extract an entire archive into `dir` (vs plucking one binary).
    private func extractArchive(data: Data, ext: String, into dir: URL) throws {
        let fm = FileManager.default
        let archive = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: archive)
        defer { try? fm.removeItem(at: archive) }
        let proc = Process()
        if ext == "zip" {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-x", "-k", archive.path, dir.path]
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            proc.arguments = ["-xzf", archive.path, "-C", dir.path]
        }
        proc.standardError = FileHandle.nullDevice
        try proc.run(); proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw ProvisionError.extractionFailed }
    }

    private func archiveExt(_ url: URL) -> String { url.path.hasSuffix(".zip") ? "zip" : "tar.gz" }

    /// Recursively find the first regular file named `name` under `dir`.
    private func findFile(named name: String, under dir: String) -> String? {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return nil }
        for case let rel as String in en where (rel as NSString).lastPathComponent == name {
            let full = dir + "/" + rel
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue { return full }
        }
        return nil
    }

    private func extract(data: Data, ext: String, innerPath: String, to finalURL: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let archive = tmp.appendingPathComponent("archive.\(ext)")
        try data.write(to: archive)
        let outDir = tmp.appendingPathComponent("out")
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        let proc = Process()
        if ext == "zip" {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-x", "-k", archive.path, outDir.path]
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            proc.arguments = ["-xzf", archive.path, "-C", outDir.path]
        }
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw ProvisionError.extractionFailed }

        let binary = outDir.appendingPathComponent(innerPath)
        guard fm.fileExists(atPath: binary.path) else { throw ProvisionError.binaryNotFoundInArchive }
        try? fm.removeItem(at: finalURL)
        try fm.moveItem(at: binary, to: finalURL)
    }

    /// Downloaded files don't normally carry `com.apple.quarantine` (only
    /// browser/Finder downloads do), but strip it defensively so the binary
    /// isn't Gatekeeper-blocked from launching as a subprocess.
    private func stripQuarantine(_ path: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        proc.arguments = ["-d", "com.apple.quarantine", path]
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    /// Remove older cached versions of the same binary so a version bump doesn't
    /// leave the previous (often large) copy behind.
    private func cleanStaleVersions(spec: ManagedBinary, keeping keepName: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: installDir) else { return }
        for entry in entries where entry.hasPrefix("\(spec.name)-") && entry != keepName {
            try? fm.removeItem(atPath: installDir + "/" + entry)
        }
    }
}

// MARK: - Specs

extension ManagedBinary {
    /// MeiliSearch full-text search engine (wiki/archive/docs search). ~122 MB,
    /// so it's downloaded on first run rather than bundled. Pinned to the version
    /// the on-disk index format was validated against. Existing Homebrew installs
    /// are used as-is (systemPaths) — no download needed for dev machines.
    static let meilisearch = ManagedBinary(
        name: "meilisearch",
        version: "1.42.1",
        systemPaths: ["/opt/homebrew/bin/meilisearch", "/usr/local/bin/meilisearch"],
        sources: [
            .arm64: .init(
                url: URL(string: "https://github.com/meilisearch/meilisearch/releases/download/v1.42.1/meilisearch-macos-apple-silicon")!,
                sha256: "dcfdb8c9040d82784e51e2bce0a5a3c7f696027bab5466d2e92dd6e9e23d5425",
                packaging: .rawBinary
            ),
            .x86_64: .init(
                url: URL(string: "https://github.com/meilisearch/meilisearch/releases/download/v1.42.1/meilisearch-macos-amd64")!,
                sha256: "67f301ebee2083a7d689794f42acead8b79d6e1fd7e01d95d65ae10cdf036c09",
                packaging: .rawBinary
            ),
        ]
    )

    /// llama.cpp server — runs nomic embeddings locally. Sonata manages it as an
    /// internal subprocess (like MeiliSearch), NOT a user-installed daemon. The
    /// macOS release ships `llama-server` + its dylibs flat in one dir with
    /// @loader_path rpath, so it runs in place once extracted. ~10 MB.
    /// Both arm64 (kleidiai) and x86_64 assets verified present for build b9286.
    static let llamaServer = ManagedBinary(
        name: "llama-server",
        version: "b9286",
        systemPaths: ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"],
        sources: [
            .arm64: .init(
                url: URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/b9286/llama-b9286-bin-macos-arm64-kleidiai.tar.gz")!,
                sha256: nil,
                packaging: .archiveDir(binaryName: "llama-server")
            ),
            .x86_64: .init(
                url: URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/b9286/llama-b9286-bin-macos-x64.tar.gz")!,
                sha256: nil,
                packaging: .archiveDir(binaryName: "llama-server")
            ),
        ]
    )

    /// nomic-embed-text-v1.5 (Q8_0 GGUF, 768-dim) — superseded by EmbeddingGemma.
    /// Kept for reference/rollback. Arch-independent. ~146 MB.
    static let nomicEmbedModel = ManagedBinary(
        name: "nomic-embed-text-v1.5",
        version: "Q8_0",
        systemPaths: [],
        sources: {
            let url = URL(string: "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf")!
            let src = ManagedBinary.Source(url: url, sha256: nil, packaging: .rawBinary)
            return [.arm64: src, .x86_64: src]
        }()
    )

    /// EmbeddingGemma-300m (Q8_0 GGUF, 768-dim) — the local embedding model. Chosen
    /// over nomic because nomic is highly anisotropic (random-pair cosine ~0.72,
    /// flattening recall); EmbeddingGemma is natively well-centered (~0.48, beating
    /// OpenRouter's 0.50), so cosine discriminates with no mean-centering correction.
    /// Google's purpose-built on-device retrieval model. Arch-independent. ~333 MB.
    static let embeddingGemmaModel = ManagedBinary(
        name: "embeddinggemma-300m",
        version: "Q8_0",
        systemPaths: [],
        sources: {
            let url = URL(string: "https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/main/embeddinggemma-300M-Q8_0.gguf")!
            let src = ManagedBinary.Source(url: url, sha256: nil, packaging: .rawBinary)
            return [.arm64: src, .x86_64: src]
        }()
    )

    /// Meta Llama 3.1 8B Instruct (Q4_K_M GGUF) — the local chat model that powers
    /// pith L0/L1 generation. Chosen over Qwen 2.5 3B/7B and Falcon 3 7B in a 5-way
    /// bake-off (2026-06-02) because it was the only local candidate with 5/5
    /// format-compliant JSON, zero hallucinations, and naturally-correct voice
    /// matching (first-person for reflections, third-person for technical notes).
    /// See PithRegressionTests + plans/sonata-openrouter-decoupling.md §1.
    /// Arch-independent. ~4.6 GB.
    static let llama31InstructModel = ManagedBinary(
        name: "llama-3.1-8b-instruct",
        version: "Q4_K_M",
        systemPaths: [],
        sources: {
            let url = URL(string: "https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf")!
            let src = ManagedBinary.Source(
                url: url,
                sha256: "7b064f5842bf9532c91456deda288a1b672397a54fa729aa665952863033557c",
                packaging: .rawBinary
            )
            return [.arm64: src, .x86_64: src]
        }()
    )
}
