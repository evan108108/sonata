import XCTest
import GRDB
@testable import Sonata

final class WebviewSessionConfigTests: XCTestCase {
    private func migratedPool() throws -> DatabasePool {
        let tmp = NSTemporaryDirectory() + "sonata-webcfg-\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let pool = try DatabasePool(path: tmp)
        var m = DatabaseMigrator(); m.registerSonataSchema(); try m.migrate(pool)
        return pool
    }

    func testV19SeedsDefaults() throws {
        let pool = try migratedPool()
        let row = try pool.read { db in try Row.fetchOne(db, sql: "SELECT * FROM webviewSessionConfig WHERE id='singleton'") }
        XCTAssertEqual(row?["idleSuspendSec"] as Int64?, 300)
        XCTAssertEqual(row?["hardCloseSec"] as Int64?, 1800)
        XCTAssertEqual(row?["maxLiveSessions"] as Int64?, 8)
    }
}
