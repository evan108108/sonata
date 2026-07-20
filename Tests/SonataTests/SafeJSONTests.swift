import XCTest
@testable import Sonata

/// Regression tests for the 2026-07-17 crash class: feeding a scalar top-level
/// value to `JSONSerialization.data(withJSONObject:)` raises an uncatchable
/// Objective-C `NSInvalidArgumentException` that `try?` does NOT catch, killing
/// the process. `SafeJSON.data` must return `nil` for those inputs instead of
/// crashing. The fact that each of these test methods *returns* (rather than
/// aborting the whole test process) is itself the proof that no NSException was
/// raised — a raw `JSONSerialization.data(withJSONObject:)` on the same inputs
/// would terminate the test runner.
final class SafeJSONTests: XCTestCase {

    // MARK: scalars that would crash the raw API must return nil, not crash

    func testStringScalarReturnsNilWithoutCrashing() {
        XCTAssertNil(SafeJSON.data(withJSONObject: "hello"))
    }

    func testIntScalarReturnsNilWithoutCrashing() {
        XCTAssertNil(SafeJSON.data(withJSONObject: 42))
    }

    func testDoubleScalarReturnsNilWithoutCrashing() {
        XCTAssertNil(SafeJSON.data(withJSONObject: 3.14))
    }

    func testBoolScalarReturnsNilWithoutCrashing() {
        XCTAssertNil(SafeJSON.data(withJSONObject: true))
    }

    func testNSNullScalarReturnsNilWithoutCrashing() {
        XCTAssertNil(SafeJSON.data(withJSONObject: NSNull()))
    }

    func testNSNumberScalarReturnsNilWithoutCrashing() {
        // JSONSerialization decodes JSON numbers/bools as NSNumber — the exact
        // shape a plugin/task response delivers.
        XCTAssertNil(SafeJSON.data(withJSONObject: NSNumber(value: 7)))
    }

    func testNonJSONLeafReturnsNilWithoutCrashing() {
        // A container whose leaf is a non-JSON type (Date) also raises on the
        // raw API; isValidJSONObject rejects it, so SafeJSON returns nil.
        XCTAssertNil(SafeJSON.data(withJSONObject: ["when": Date()]))
    }

    // MARK: valid containers still serialize exactly as before

    func testDictionaryContainerSerializes() throws {
        let data = try XCTUnwrap(SafeJSON.data(withJSONObject: ["k": "v"]))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(parsed, ["k": "v"])
    }

    func testArrayContainerSerializes() throws {
        let data = try XCTUnwrap(SafeJSON.data(withJSONObject: ["a", "b"]))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String]
        XCTAssertEqual(parsed, ["a", "b"])
    }

    func testArrayOfDictsSerializes() throws {
        // Mirrors the `anyJSONResponse(schemas)` shape (`[[String: Any]]`).
        let value: [[String: Any]] = [["name": "tool", "n": 1]]
        let data = try XCTUnwrap(SafeJSON.data(withJSONObject: value, options: [.sortedKeys]))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?.first?["name"] as? String, "tool")
    }

    func testScalarInsideContainerStillSerializes() throws {
        // The nested-scalar case that crashed the plugin-forward path
        // (staleness_notes[] = ["a string"]) is fine when the *top level* is a
        // container.
        let value: [String: Any] = ["staleness_notes": ["stale"], "in_flight": false]
        let data = try XCTUnwrap(SafeJSON.data(withJSONObject: value))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(parsed?["staleness_notes"] as? [String], ["stale"])
    }
}
