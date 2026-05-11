import XCTest
@testable import Sonata

/// Coverage for the discriminated-union JSON decoder on `StudioBlock` and the
/// renderer-local `AnyCodableValue: Encodable` extension. These are the
/// non-trivial pure paths inside Studio T3 — image decryption, view layout,
/// and disk-cache trim eviction are covered separately.
final class StudioBlockParsingTests: XCTestCase {

    private func decode(_ json: String) throws -> StudioBlock {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(StudioBlock.self, from: data)
    }

    func testDecodeText() throws {
        let block = try decode(#"{"type":"text","body":"hello **world**"}"#)
        guard case .text(let body) = block else { return XCTFail("expected .text, got \(block)") }
        XCTAssertEqual(body, "hello **world**")
    }

    func testDecodeCode_withLanguage() throws {
        let block = try decode(#"{"type":"code","language":"swift","body":"let x = 1"}"#)
        guard case .code(let lang, let body) = block else { return XCTFail("expected .code") }
        XCTAssertEqual(lang, "swift")
        XCTAssertEqual(body, "let x = 1")
    }

    func testDecodeCode_missingLanguageFallsBackToEmpty() throws {
        let block = try decode(#"{"type":"code","body":"echo hi"}"#)
        guard case .code(let lang, let body) = block else { return XCTFail("expected .code") }
        XCTAssertEqual(lang, "")
        XCTAssertEqual(body, "echo hi")
    }

    func testDecodeLink_withLabel() throws {
        let block = try decode(#"{"type":"link","href":"https://example.com","label":"PR"}"#)
        guard case .link(let href, let label) = block else { return XCTFail("expected .link") }
        XCTAssertEqual(href, "https://example.com")
        XCTAssertEqual(label, "PR")
    }

    func testDecodeLink_missingLabelIsNil() throws {
        let block = try decode(#"{"type":"link","href":"https://example.com"}"#)
        guard case .link(_, let label) = block else { return XCTFail("expected .link") }
        XCTAssertNil(label)
    }

    func testDecodeField() throws {
        let block = try decode(#"{"type":"field","key":"status","value":"open"}"#)
        guard case .field(let k, let v) = block else { return XCTFail("expected .field") }
        XCTAssertEqual(k, "status")
        XCTAssertEqual(v, "open")
    }

    func testDecodeImage() throws {
        let json = """
        {"type":"image","sha256":"abc","mirrors":["https://m.example/abc"],
         "decrypt_hint":{"kind":"audience_epoch","epoch_n":3},
         "mime_type":"image/png","blake3":"def"}
        """
        let block = try decode(json)
        guard case .image(let img) = block else { return XCTFail("expected .image") }
        XCTAssertEqual(img.sha256, "abc")
        XCTAssertEqual(img.mirrors, ["https://m.example/abc"])
        XCTAssertEqual(img.decryptHint.epochN, 3)
        XCTAssertEqual(img.mimeType, "image/png")
        XCTAssertEqual(img.blake3, "def")
    }

    func testDecodeUnknownPreservesRawAttributes() throws {
        let json = #"{"type":"future_thing","foo":"bar","n":42,"on":true}"#
        let block = try decode(json)
        guard case .unknown(let type, let raw) = block else { return XCTFail("expected .unknown") }
        XCTAssertEqual(type, "future_thing")
        XCTAssertEqual(raw["foo"], .string("bar"))
        XCTAssertEqual(raw["n"], .int(42))
        XCTAssertEqual(raw["on"], .bool(true))
        XCTAssertEqual(raw["type"], .string("future_thing"))
    }

    func testAnyCodableValueEncodeRoundTrip() throws {
        let raw: [String: AnyCodableValue] = [
            "s": .string("hello"),
            "n": .int(7),
            "d": .double(1.5),
            "b": .bool(true),
            "x": .null,
            "arr": .array([.int(1), .int(2)]),
            "obj": .object(["k": .string("v")]),
        ]
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(raw)
        let decoded = try JSONDecoder().decode([String: AnyCodableValue].self, from: data)
        XCTAssertEqual(decoded["s"], .string("hello"))
        XCTAssertEqual(decoded["n"], .int(7))
        XCTAssertEqual(decoded["d"], .double(1.5))
        XCTAssertEqual(decoded["b"], .bool(true))
        XCTAssertEqual(decoded["x"], .null)
        XCTAssertEqual(decoded["arr"], .array([.int(1), .int(2)]))
        XCTAssertEqual(decoded["obj"], .object(["k": .string("v")]))
    }

    func testUnknownBlockViewPrettyJSONIsStable() {
        let raw: [String: AnyCodableValue] = [
            "z": .int(1),
            "a": .string("first"),
        ]
        let pretty = UnknownBlockView.prettyJSON(raw)
        XCTAssertTrue(pretty.contains("\"a\""))
        XCTAssertTrue(pretty.contains("\"z\""))
        // sortedKeys → "a" key appears before "z" key.
        let aIdx = pretty.range(of: "\"a\"")!.lowerBound
        let zIdx = pretty.range(of: "\"z\"")!.lowerBound
        XCTAssertLessThan(aIdx, zIdx)
    }
}
