import XCTest
@testable import Sonata

// Regression tests for `resolveTranscriptPath` — finding the transcript at all,
// which is upstream of every number `SweeperTranscriptUsageTests` asserts on.
//
// WHY THIS FILE EXISTS
//
// The sweeper used to build one path from a hardcoded cwd of `~/.sonata/worker`.
// That was true of every session in existence when it was written, and became
// false the moment a session ran somewhere else. Sidecars run in
// `~/.sonata/sidecar-memory`, so the memory sidecar's transcript sat under a
// project directory the sweeper never looked in, and the lookup missed on every
// one of the four ticks per minute, forever.
//
// What made it expensive is that a miss is indistinguishable from a fresh
// session: both report nil, which reads as "no turns yet." Nothing threw,
// nothing logged, and two shipped features were silently inert underneath it —
// `currentContextTokens` never populated, so the sidecar could not compute a
// context percentage and so could never post rotate_me; and the spend feeder is
// gated on a non-nil reading, so the ledger stayed at zero and throttling could
// never fire. It was caught by enqueueing a live event post-deploy and noticing
// the columns stayed empty after a completed turn, not by any test.
//
// So the first case below is the one that matters: a transcript in a
// sidecar-shaped project directory must resolve. It fails against the old
// implementation.
//
// The second theme is the one the fix must not reintroduce. An earlier version
// picked the most-recently-modified `.jsonl` in the directory, which copied one
// session's totals onto every other worker's row — two live workers were
// observed holding byte-identical readings at the same instant. Several cases
// below exist purely to pin that a miss stays a miss: reporting no reading is
// recoverable, reporting someone else's reading is not.
final class SweeperTranscriptPathTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcript-path-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Create a project directory and drop a named file in it.
    @discardableResult
    private func write(_ filename: String, inProject project: String) throws -> String {
        let dir = root.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(filename)
        try "{}\n".write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    /// The two cwd shapes that actually occur: the shared pool-worker directory
    /// and a sidecar's own. Claude Code's encoding replaces both `/` and `.`
    /// with `-`, which is why `.sonata` becomes `--sonata`.
    private let workerProject = "-Users-evan--sonata-worker"
    private let sidecarProject = "-Users-evan--sonata-sidecar-memory"

    // MARK: - The bug

    /// THE regression. A sidecar's transcript lives outside the pool-worker
    /// directory, and resolution must not care which directory it is in.
    func testTranscriptInSidecarProjectDirectoryResolves() throws {
        let session = "a4b73b43-9e84-4008-9854-f3576c0e83d7"
        let expected = try write("\(session).jsonl", inProject: sidecarProject)

        // A populated pool-worker directory alongside it, so the test would
        // still pass trivially if resolution merely defaulted to "the other
        // one." It has to find the right file, not the only file.
        try write("11111111-1111-1111-1111-111111111111.jsonl", inProject: workerProject)

        XCTAssertEqual(
            resolveTranscriptPath(projectsRoot: root.path, sessionId: session),
            expected
        )
    }

    /// The case that already worked keeps working — the fix widens the search,
    /// it does not move it.
    func testTranscriptInPoolWorkerProjectDirectoryStillResolves() throws {
        let session = "988344f1-6c08-453c-aae8-25db368a36c7"
        let expected = try write("\(session).jsonl", inProject: workerProject)
        try write("22222222-2222-2222-2222-222222222222.jsonl", inProject: sidecarProject)

        XCTAssertEqual(
            resolveTranscriptPath(projectsRoot: root.path, sessionId: session),
            expected
        )
    }

    /// Sidecars are not a closed set. A directory shape nobody has written down
    /// yet must resolve on the same rule, or this bug simply recurs under a new
    /// name the next time something runs in a new cwd.
    func testUnknownProjectDirectoryShapeResolves() throws {
        let session = "deadbeef-0000-4000-8000-000000000000"
        let expected = try write("\(session).jsonl", inProject: "-Users-evan--sonata-sidecar-future")

        XCTAssertEqual(
            resolveTranscriptPath(projectsRoot: root.path, sessionId: session),
            expected
        )
    }

    // MARK: - A miss must stay a miss

    /// The anti-borrowing property, stated directly. Other transcripts exist,
    /// one of them is strictly newer, and the answer is still nil — never the
    /// most-recently-modified file.
    func testUnknownSessionReadsNilRatherThanBorrowingTheNewestTranscript() throws {
        let other = try write("33333333-3333-3333-3333-333333333333.jsonl", inProject: workerProject)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: other
        )

        XCTAssertNil(
            resolveTranscriptPath(
                projectsRoot: root.path,
                sessionId: "44444444-4444-4444-4444-444444444444"
            )
        )
    }

    /// A session with no transcript yet reads nil even when its own directory
    /// exists and holds other sessions' files.
    func testSessionWithoutATranscriptReadsNil() throws {
        try write("55555555-5555-5555-5555-555555555555.jsonl", inProject: sidecarProject)

        XCTAssertNil(
            resolveTranscriptPath(
                projectsRoot: root.path,
                sessionId: "66666666-6666-6666-6666-666666666666"
            )
        )
    }

    /// Match on the whole filename, not a substring. Backups and renamed
    /// captures sit next to live transcripts and carry stale numbers.
    func testFilenameMatchIsExact() throws {
        let session = "77777777-7777-7777-7777-777777777777"
        try write("\(session)-backup.jsonl", inProject: workerProject)
        try write("old-\(session).jsonl", inProject: workerProject)
        try write("\(session).jsonl.bak", inProject: workerProject)

        XCTAssertNil(resolveTranscriptPath(projectsRoot: root.path, sessionId: session))
    }

    /// A directory that happens to be named like a transcript is not one.
    func testDirectoryNamedLikeATranscriptIsNotResolved() throws {
        let session = "88888888-8888-8888-8888-888888888888"
        let dir = root
            .appendingPathComponent(workerProject)
            .appendingPathComponent("\(session).jsonl")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertNil(resolveTranscriptPath(projectsRoot: root.path, sessionId: session))
    }

    /// An empty session id cannot identify anything, and must not be allowed to
    /// match a file literally named `.jsonl`.
    func testEmptySessionIdReadsNil() throws {
        try write(".jsonl", inProject: workerProject)

        XCTAssertNil(resolveTranscriptPath(projectsRoot: root.path, sessionId: ""))
    }

    /// A missing projects root is a normal state on a fresh machine, not an
    /// error to propagate out of a 15s timer.
    func testMissingProjectsRootReadsNil() {
        XCTAssertNil(
            resolveTranscriptPath(
                projectsRoot: root.appendingPathComponent("does-not-exist").path,
                sessionId: "99999999-9999-9999-9999-999999999999"
            )
        )
    }

    // MARK: - Cache

    /// The hot path reads this every tick, so the cache has to return the same
    /// answer the scan would.
    func testCachedPathIsReturnedForTheSameSession() {
        var cache = TranscriptPathCache()
        cache.store(workerId: "sidecar-memory", sessionId: "session-a", path: "/tmp/a.jsonl")

        XCTAssertEqual(
            cache.cached(workerId: "sidecar-memory", sessionId: "session-a"),
            "/tmp/a.jsonl"
        )
    }

    /// Rotation is exactly when a stale path would do damage: the old session's
    /// transcript still exists on disk and still parses, so a stale hit would
    /// report a dead session's totals as the live one's — the borrowing bug
    /// again, arriving through the cache instead of through the scan.
    func testStaleEntryIsNotServedAfterSessionIdChanges() {
        var cache = TranscriptPathCache()
        cache.store(workerId: "sidecar-memory", sessionId: "session-a", path: "/tmp/a.jsonl")

        XCTAssertNil(cache.cached(workerId: "sidecar-memory", sessionId: "session-b"))
    }

    /// Storing under a new session replaces the entry rather than accumulating
    /// one per rotation — a long-lived sidecar rotates many times.
    func testStoringANewSessionReplacesThePreviousEntry() {
        var cache = TranscriptPathCache()
        cache.store(workerId: "sidecar-memory", sessionId: "session-a", path: "/tmp/a.jsonl")
        cache.store(workerId: "sidecar-memory", sessionId: "session-b", path: "/tmp/b.jsonl")

        XCTAssertNil(cache.cached(workerId: "sidecar-memory", sessionId: "session-a"))
        XCTAssertEqual(
            cache.cached(workerId: "sidecar-memory", sessionId: "session-b"),
            "/tmp/b.jsonl"
        )
    }

    /// Workers do not share entries. Two sidecars with the same session id
    /// would be a bug elsewhere, but the cache must not be the thing that
    /// merges them.
    func testEntriesAreScopedPerWorker() {
        var cache = TranscriptPathCache()
        cache.store(workerId: "sidecar-memory", sessionId: "session-a", path: "/tmp/a.jsonl")

        XCTAssertNil(cache.cached(workerId: "worker-1", sessionId: "session-a"))
    }

    /// `forget` is what the caller uses when a cached path stops existing, so a
    /// vanished transcript costs one rescan rather than permanent silence.
    func testForgetClearsTheEntry() {
        var cache = TranscriptPathCache()
        cache.store(workerId: "sidecar-memory", sessionId: "session-a", path: "/tmp/a.jsonl")
        cache.forget(workerId: "sidecar-memory")

        XCTAssertNil(cache.cached(workerId: "sidecar-memory", sessionId: "session-a"))
    }
}
