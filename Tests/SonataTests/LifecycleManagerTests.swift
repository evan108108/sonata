import XCTest
@testable import Sonata

// Tests for the lifecycle manager (ADA-483) — the prune predicate, the tree
// archive's exclude resolution, local backup retention, and the S3 lifecycle
// document.
//
// The bug this feature answers was a silent gap in coverage: the backup looked
// healthy for years while never containing the tree. So these tests assert on
// what the archive CONTAINS as much as on what it drops — an exclude list that
// quietly swallowed `plugins/` would reproduce the original incident exactly,
// and a test that only checked "prstar-workspaces is absent" would pass.
//
// Nothing here touches a real bucket: every cleanup run passes
// `reconcileS3: false`, and the archive tests work in a temp fixture tree.
final class LifecycleManagerTests: XCTestCase {

    private var root: String = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "sonata-lifecycle-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: - Fixture helpers

    private func write(_ relativePath: String, _ contents: String = "x", ageDays: Double? = nil) throws {
        let path = "\(root)/\(relativePath)"
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        if let ageDays {
            let date = Date().addingTimeInterval(-ageDays * 86_400)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(root)/\(relativePath)")
    }

    // MARK: - Workspace prune predicate

    /// Staleness is judged by the newest file INSIDE the workspace. A directory
    /// whose own mtime is ancient but which holds a file written an hour ago is
    /// live — that is the case that would destroy a review in flight.
    func testStaleWorkspacesArePrunedAndFreshOnesSurvive() async throws {
        try write("prstar-workspaces/enginable/repo/pr-100-aaa/file.txt", ageDays: 30)
        try write("prstar-workspaces/enginable/repo/pr-200-bbb/file.txt", ageDays: 0)
        // Ancient container, recent content — must be kept.
        try write("prstar-workspaces/enginable/repo/pr-300-ccc/deep/nested/recent.txt", ageDays: 0)
        let ancientDir = "\(root)/prstar-workspaces/enginable/repo/pr-300-ccc"
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60 * 86_400)], ofItemAtPath: ancientDir
        )

        let summary = await CleanupManager(dataDir: root).runCleanup(reconcileS3: false)

        XCTAssertFalse(exists("prstar-workspaces/enginable/repo/pr-100-aaa"), "stale workspace should be pruned")
        XCTAssertTrue(exists("prstar-workspaces/enginable/repo/pr-200-bbb"), "fresh workspace must survive")
        XCTAssertTrue(
            exists("prstar-workspaces/enginable/repo/pr-300-ccc"),
            "a workspace with recent content must survive even when its own dir mtime is old"
        )
        XCTAssertEqual(summary.workspacesRemoved, 1)
        XCTAssertEqual(summary.workspacesKept, 2)
    }

    /// Directories that are not `pr-*` are not ours to touch.
    func testNonWorkspaceDirectoriesAreLeftAlone() async throws {
        try write("prstar-workspaces/enginable/repo/pr-100-aaa/file.txt", ageDays: 30)
        try write("prstar-workspaces/enginable/repo/scratch-notes/file.txt", ageDays: 30)

        _ = await CleanupManager(dataDir: root).runCleanup(reconcileS3: false)

        XCTAssertFalse(exists("prstar-workspaces/enginable/repo/pr-100-aaa"))
        XCTAssertTrue(exists("prstar-workspaces/enginable/repo/scratch-notes"), "only pr-* dirs are in scope")
    }

    // MARK: - Local backup retention

    func testOldLocalBackupsPrunedAndLatestPreserved() async throws {
        try write("backups/sonata-2026-05-06.db", ageDays: 90)
        try write("backups/sonata-2026-05-06.db.gz", ageDays: 90)
        try write("backups/sonata-pre-wiki-restructure-20260427-151745.db", ageDays: 100)
        try write("backups/sonata-latest.db", ageDays: 90)      // old, but live
        try write("backups/sonata-latest.db-wal", ageDays: 90)
        try write("backups/sonata-2026-08-07.db", ageDays: 0)   // inside retention

        let summary = await CleanupManager(dataDir: root).runCleanup(reconcileS3: false)

        XCTAssertFalse(exists("backups/sonata-2026-05-06.db"))
        XCTAssertFalse(exists("backups/sonata-2026-05-06.db.gz"))
        XCTAssertFalse(exists("backups/sonata-pre-wiki-restructure-20260427-151745.db"))
        XCTAssertTrue(exists("backups/sonata-latest.db"), "the live rotating backup is never pruned by age")
        XCTAssertTrue(exists("backups/sonata-latest.db-wal"), "latest's sidecars go with it")
        XCTAssertTrue(exists("backups/sonata-2026-08-07.db"), "inside the retention window")
        XCTAssertEqual(summary.localBackupsRemoved, 3)
    }

    // MARK: - Worktree safety

    /// A directory that is not a git worktree is never deleted, however old.
    func testNonWorktreeDirectoryIsSkipped() async throws {
        try write("worktrees/not-a-worktree/file.txt", ageDays: 90)

        let summary = await CleanupManager(dataDir: root).runCleanup(reconcileS3: false)

        XCTAssertTrue(exists("worktrees/not-a-worktree"))
        XCTAssertEqual(summary.worktreesRemoved, 0)
    }

    /// The safety that matters most: uncommitted work is never collected. This
    /// builds a real git worktree, dirties it, and asserts it survives.
    func testWorktreeWithUncommittedChangesIsSkipped() async throws {
        let repo = "\(root)/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main", repo])
        try "seed".write(toFile: "\(repo)/seed.txt", atomically: true, encoding: .utf8)
        try runGit(["-C", repo, "add", "."])
        try runGit(["-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "seed"])

        let worktree = "\(root)/worktrees/feature"
        try FileManager.default.createDirectory(
            atPath: "\(root)/worktrees", withIntermediateDirectories: true
        )
        try runGit(["-C", repo, "worktree", "add", "-q", "-b", "feature", worktree])
        try "dirty".write(toFile: "\(worktree)/uncommitted.txt", atomically: true, encoding: .utf8)

        let summary = await CleanupManager(dataDir: root).runCleanup(reconcileS3: false)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: "\(worktree)/uncommitted.txt"),
            "a worktree holding uncommitted work must never be pruned — this is the whole point of ADA-483"
        )
        XCTAssertEqual(summary.worktreesRemoved, 0)
        XCTAssertEqual(summary.worktreesSkipped, 1)
    }

    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
    }

    // MARK: - Tree archive exclude resolution

    /// Round-trips a real tar+gz through the configured excludes and asserts on
    /// both halves: irreplaceable state is inside, reproducible state is not.
    func testTreeArchiveKeepsIrreplaceableStateAndDropsReproducibleState() throws {
        try write("plugins/prstar/src/dispatcher.js", "the file that started all this")
        try write("session/state.json")
        try write("worker/state.json")
        try write("wiki/index.md")
        try write("documents/note.md")
        try write("sonata.db", "database")

        try write("prstar-workspaces/enginable/repo/pr-1/checkout.txt")
        try write("bin/llama-3.1-8b.gguf")
        try write("worktrees/feature/file.txt")
        try write("models/weights.mlmodel")
        try write("meili-data/index.dat")
        try write("backups/sonata-latest.db")
        try write("logs/sonata.log")
        try write("plugins/prstar/node_modules/dep/index.js")
        try write("plugins/prstar/.build/artifact.o")
        try write("plugins/prstar/debug.log")

        let archive = "\(root)-archive.tar.gz"
        defer { try? FileManager.default.removeItem(atPath: archive) }

        var arguments = ["-czf", archive, "-C", root]
        arguments.append(contentsOf: LifecycleConfig.defaultTreeExcludes.map { "--exclude=\($0)" })
        arguments.append(".")
        try runTar(arguments)

        let listing = try tarListing(archive)

        for kept in [
            "./plugins/prstar/src/dispatcher.js", "./session/state.json", "./worker/state.json",
            "./wiki/index.md", "./documents/note.md", "./sonata.db",
        ] {
            XCTAssertTrue(listing.contains(kept), "\(kept) must be in the archive — this is the state we cannot rebuild")
        }

        for dropped in [
            "prstar-workspaces", "/bin/", "worktrees", "models/", "meili-data",
            "backups", "logs", "node_modules", ".build", "debug.log",
        ] {
            XCTAssertFalse(
                listing.contains(dropped),
                "\(dropped) is reproducible or ephemeral and must not be archived"
            )
        }
    }

    private func runTar(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "tar failed")
    }

    private func tarListing(_ archive: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tzf", archive]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Backup scope

    func testScopeParsingDefaultsToBoth() {
        XCTAssertEqual(BackupScope(param: nil), .both)
        XCTAssertEqual(BackupScope(param: ""), .both)
        XCTAssertEqual(BackupScope(param: "nonsense"), .both)
        XCTAssertEqual(BackupScope(param: "TREE"), .tree)
        XCTAssertEqual(BackupScope(param: "db"), .db)

        XCTAssertTrue(BackupScope.db.includesDB)
        XCTAssertFalse(BackupScope.db.includesTree)
        XCTAssertTrue(BackupScope.tree.includesTree)
        XCTAssertFalse(BackupScope.tree.includesDB)
    }

    // MARK: - S3 lifecycle document

    func testLifecycleXMLCoversBothPrefixesWithConfiguredExpiry() {
        let xml = S3Lifecycle.configurationXML(expiryDays: 2)

        XCTAssertTrue(xml.contains("<Prefix>backups/</Prefix>"))
        XCTAssertTrue(xml.contains("<Prefix>tree/</Prefix>"), "the tree archive needs its own expiry or it accumulates forever")
        XCTAssertEqual(xml.components(separatedBy: "<Days>2</Days>").count - 1, 2)
        XCTAssertEqual(xml.components(separatedBy: "<Rule>").count - 1, 2)
        XCTAssertTrue(xml.contains("<Status>Enabled</Status>"))
    }

    // MARK: - SigV4

    /// Signing is deterministic for a fixed timestamp, and the query string and
    /// extra headers must reach the signature — the lifecycle PUT fails with a
    /// signature mismatch if `lifecycle=` or `content-md5` are dropped.
    func testSigV4SignsQueryStringAndExtraHeaders() {
        let fixedDate = Date(timeIntervalSince1970: 1_754_582_400)
        func sign(query: String, extra: [String: String]) -> String {
            AWSSigV4.headers(
                method: "PUT", host: "bucket.s3.us-east-1.amazonaws.com", path: "/",
                query: query, payloadHash: AWSSigV4.sha256Hex(Data("body".utf8)),
                extraHeaders: extra, region: "us-east-1",
                accessKey: "AKIAEXAMPLE", secretKey: "secret", now: fixedDate
            )["Authorization"] ?? ""
        }

        let base = sign(query: "lifecycle=", extra: ["Content-MD5": "abc"])
        XCTAssertEqual(base, sign(query: "lifecycle=", extra: ["Content-MD5": "abc"]), "signing must be deterministic")
        XCTAssertNotEqual(base, sign(query: "", extra: ["Content-MD5": "abc"]), "query string must be signed")
        XCTAssertNotEqual(base, sign(query: "lifecycle=", extra: ["Content-MD5": "different"]), "extra headers must be signed")
        XCTAssertTrue(base.contains("SignedHeaders=content-md5;host;x-amz-content-sha256;x-amz-date"))
        XCTAssertTrue(base.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/"))
    }

    /// The chunked file hash must agree with the in-memory one, or every large
    /// upload fails its signature check.
    func testFileHashMatchesInMemoryHashAcrossChunkBoundaries() throws {
        let path = "\(root)/payload.bin"
        let blob = Data((0..<(5 * 1_048_576)).map { UInt8($0 % 251) })
        try blob.write(to: URL(fileURLWithPath: path))

        XCTAssertEqual(
            AWSSigV4.sha256Hex(fileAt: path, chunkBytes: 1_048_576),
            AWSSigV4.sha256Hex(blob),
            "chunked hashing must match whole-buffer hashing"
        )
    }
}
