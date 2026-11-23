import XCTest
@testable import Sonata

/// WebCryptoMasterKey runs against an in-memory store here; never the live
/// SecretStore, which holds the key every Sonata webview depends on.
final class WebCryptoMasterKeyTests: XCTestCase {
    private final class Store {
        var values: [String: String] = [:]
        var writes = 0
        func get(_ name: String) -> String? { values[name] }
        func set(_ name: String, _ value: String) { values[name] = value; writes += 1 }
    }

    func testGeneratesOnceThenReturnsTheSameKey() {
        let store = Store()
        var draws = 0
        let random: () -> Data? = { draws += 1; return WebCryptoMasterKey.randomKey() }

        let first = WebCryptoMasterKey.loadOrCreate(get: store.get, set: store.set, random: random)
        let second = WebCryptoMasterKey.loadOrCreate(get: store.get, set: store.set, random: random)

        XCTAssertEqual(first?.count, WebCryptoMasterKey.sizeInBytes)
        XCTAssertEqual(first, second, "a second load must return the stored key, not a new one")
        XCTAssertEqual(draws, 1)
        XCTAssertEqual(store.writes, 1)
    }

    func testMalformedStoredKeyIsReplaced() {
        let store = Store()
        store.values[WebCryptoMasterKey.secretName] = Data(repeating: 7, count: 32).base64EncodedString()

        let key = WebCryptoMasterKey.loadOrCreate(get: store.get, set: store.set)

        XCTAssertEqual(key?.count, WebCryptoMasterKey.sizeInBytes)
        XCTAssertEqual(store.values[WebCryptoMasterKey.secretName], key?.base64EncodedString())
    }

    func testRandomFailureReturnsNilAndStoresNothing() {
        let store = Store()
        let key = WebCryptoMasterKey.loadOrCreate(get: store.get, set: store.set, random: { nil })
        XCTAssertNil(key)
        XCTAssertEqual(store.writes, 0)
    }
}
