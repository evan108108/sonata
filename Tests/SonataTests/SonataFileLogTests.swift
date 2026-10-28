import XCTest
@testable import Sonata

/// Tests exercise code that calls sonataFileLog. On 2026-10-28 those lines
/// went into the live ~/Library/Logs/Sonata.log ("HTTP liveness: /api/ping
/// unanswered (3/3)", "Signal: SIGTERM from pid N (this Sonata)"), where
/// they read as a real outage. A test process now logs to Sonata-tests.log.
final class SonataFileLogTests: XCTestCase {

    private func contents(_ name: String) -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(name)")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testTestProcessLogsOutsideTheLiveAppLog() {
        XCTAssertTrue(sonataFileLogIsTestProcess)

        let marker = "sonata-file-log-test-\(UUID().uuidString)"
        sonataFileLog(marker)

        XCTAssertTrue(contents("Sonata-tests.log").contains(marker))
        XCTAssertFalse(contents("Sonata.log").contains(marker))
    }
}
