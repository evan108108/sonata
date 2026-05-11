import XCTest
@testable import Sonata

final class NIP44Tests: XCTestCase {
    struct Vectors: Decodable {
        struct ConvKey: Decodable {
            let sec1: String
            let pub2: String
            let conversation_key: String
        }
        struct EncDec: Decodable {
            let sec1: String
            let sec2: String
            let conversation_key: String
            let nonce: String
            let plaintext: String
            let payload: String
        }
        struct PaddedLen: Decodable {
            let len: Int
            let padded: Int
        }
        struct Valid: Decodable {
            let get_conversation_key: [ConvKey]
            let encrypt_decrypt: [EncDec]
            let calc_padded_len: [[Int]]
        }
        let v2: V2
        struct V2: Decodable { let valid: Valid }
    }

    private func loadVectors() throws -> Vectors {
        let candidates = [
            Bundle.module.url(forResource: "nip44.vectors", withExtension: "json"),
            Bundle.module.url(forResource: "nip44.vectors", withExtension: "json", subdirectory: "fixtures"),
        ].compactMap { $0 }
        guard let url = candidates.first else {
            XCTFail("Missing nip44.vectors.json in test bundle")
            throw NSError(domain: "NIP44Tests", code: -1)
        }
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testConversationKeyVectors() throws {
        let v = try loadVectors()
        let toRun = v.v2.valid.get_conversation_key.prefix(10)
        XCTAssertGreaterThanOrEqual(toRun.count, 5, "need >=5 conversation_key vectors")
        for entry in toRun {
            guard let priv = Hex.decode(entry.sec1), let pub = Hex.decode(entry.pub2) else {
                XCTFail("hex decode failed for sec1/pub2")
                continue
            }
            let key = try NIP44.conversationKey(privateKey: priv, publicKey: pub)
            XCTAssertEqual(
                Hex.encode(key),
                entry.conversation_key.lowercased(),
                "conversation_key mismatch for sec1=\(entry.sec1.prefix(8))…"
            )
        }
    }

    func testDecryptVectors() throws {
        let v = try loadVectors()
        let toRun = v.v2.valid.encrypt_decrypt.prefix(10)
        XCTAssertGreaterThanOrEqual(toRun.count, 5, "need >=5 encrypt_decrypt vectors")
        for entry in toRun {
            guard let cKey = Hex.decode(entry.conversation_key) else {
                XCTFail("hex decode failed for conversation_key")
                continue
            }
            let plain = try NIP44.decrypt(payload: entry.payload, conversationKey: cKey)
            let expected = Data(entry.plaintext.utf8)
            XCTAssertEqual(plain, expected, "decrypt plaintext mismatch for nonce=\(entry.nonce.prefix(8))…")
        }
    }

    func testCalcPaddedLenVectors() throws {
        let v = try loadVectors()
        for pair in v.v2.valid.calc_padded_len.prefix(60) {
            guard pair.count == 2 else { continue }
            XCTAssertEqual(NIP44.calcPaddedLen(pair[0]), pair[1],
                           "calcPaddedLen(\(pair[0])) expected \(pair[1])")
        }
    }
}
