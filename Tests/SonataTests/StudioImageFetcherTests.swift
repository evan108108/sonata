import XCTest
@testable import Sonata

/// Disk-cache eviction logic on `StudioImageFetcher`. The encrypt/decrypt loop
/// is exercised by `NIP44Tests`; here we cover the oldest-first trim path that
/// keeps the on-disk cache under the configured ceiling.
final class StudioImageFetcherTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUp() {
        super.setUp()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-images-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpRoot)
        super.tearDown()
    }

    private func writeBlob(name: String, bytes: Int, mtime: Date) throws -> URL {
        let url = tmpRoot.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: mtime],
            ofItemAtPath: url.path
        )
        return url
    }

    func testTrimDirectory_noopWhenUnderCap() throws {
        _ = try writeBlob(name: "a.bin", bytes: 1024, mtime: Date(timeIntervalSince1970: 100))
        _ = try writeBlob(name: "b.bin", bytes: 2048, mtime: Date(timeIntervalSince1970: 200))
        let removed = try StudioImageFetcher.trimDirectory(tmpRoot, maxBytes: 1024 * 1024)
        XCTAssertEqual(removed.count, 0)
    }

    func testTrimDirectory_evictsOldestFirst() throws {
        let oldA = try writeBlob(name: "old-a.bin", bytes: 5_000, mtime: Date(timeIntervalSince1970: 100))
        let oldB = try writeBlob(name: "old-b.bin", bytes: 5_000, mtime: Date(timeIntervalSince1970: 200))
        let newC = try writeBlob(name: "new-c.bin", bytes: 5_000, mtime: Date(timeIntervalSince1970: 999_999))

        let removed = try StudioImageFetcher.trimDirectory(tmpRoot, maxBytes: 6_000)

        let removedNames = Set(removed.map { $0.lastPathComponent })
        XCTAssertTrue(removedNames.contains("old-a.bin"))
        XCTAssertTrue(removedNames.contains("old-b.bin"))
        XCTAssertFalse(removedNames.contains("new-c.bin"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newC.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldB.path))
    }

    func testTrimDirectory_stopsAsSoonAsUnderCap() throws {
        _ = try writeBlob(name: "a.bin", bytes: 4_000, mtime: Date(timeIntervalSince1970: 100))
        _ = try writeBlob(name: "b.bin", bytes: 4_000, mtime: Date(timeIntervalSince1970: 200))
        let cKept = try writeBlob(name: "c.bin", bytes: 4_000, mtime: Date(timeIntervalSince1970: 300))

        let removed = try StudioImageFetcher.trimDirectory(tmpRoot, maxBytes: 5_000)

        // Total = 12 000, cap = 5 000. Evict oldest (a:4 000) → 8 000 still over.
        // Evict next-oldest (b:4 000) → 4 000 under cap. Stop. c.bin must remain.
        XCTAssertEqual(removed.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cKept.path))
    }

    func testTrimDirectory_missingRootReturnsEmpty() throws {
        let nonexistent = tmpRoot.appendingPathComponent("does-not-exist")
        let removed = try StudioImageFetcher.trimDirectory(nonexistent, maxBytes: 10)
        XCTAssertEqual(removed.count, 0)
    }

    func testStudioImageErrorEquatable() {
        XCTAssertEqual(StudioImageError.allMirrorsFailed, .allMirrorsFailed)
        XCTAssertEqual(
            StudioImageError.integrityMismatch(host: "x"),
            .integrityMismatch(host: "x")
        )
        XCTAssertNotEqual(
            StudioImageError.integrityMismatch(host: "x"),
            .integrityMismatch(host: "y")
        )
        XCTAssertEqual(
            StudioImageError.missingEpochKey(epoch: 1),
            .missingEpochKey(epoch: 1)
        )
        XCTAssertNotEqual(
            StudioImageError.missingEpochKey(epoch: 1),
            .missingEpochKey(epoch: 2)
        )
    }
}
