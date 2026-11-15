import XCTest
@testable import Sonata

/// The provisioner downloads executables (llama-server, meilisearch) and model
/// weights, then runs them. A pinned sha256 is the only thing tying the bytes to
/// what we reviewed, so a mismatch must be rejected, never logged-and-installed.
final class BinaryProvisionerChecksumTests: XCTestCase {
    private let payload = Data("sonata-binary-provisioner-fixture".utf8)

    func testMatchingPinnedHashIsAccepted() throws {
        let digest = BinaryProvisioner.sha256Hex(of: payload)
        XCTAssertNoThrow(try BinaryProvisioner.verifyChecksum(digest: digest, expected: digest))
        XCTAssertNoThrow(try BinaryProvisioner.verifyChecksum(digest: digest, expected: digest.uppercased()))
    }

    func testMismatchedPinnedHashIsRejected() {
        let digest = BinaryProvisioner.sha256Hex(of: payload)
        let tampered = BinaryProvisioner.sha256Hex(of: payload + Data([0x00]))
        XCTAssertNotEqual(digest, tampered)
        XCTAssertThrowsError(try BinaryProvisioner.verifyChecksum(digest: tampered, expected: digest)) { error in
            guard case BinaryProvisioner.ProvisionError.checksumMismatch = error else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
        }
    }

    func testDigestIsLowercaseHexSHA256() {
        // Known vector: SHA-256("abc").
        XCTAssertEqual(
            BinaryProvisioner.sha256Hex(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    /// Every shipped download source carries a pin; an unpinned source would
    /// install whatever the host serves.
    func testEveryShippedSourceIsPinned() {
        let specs: [ManagedBinary] = [
            .meilisearch, .llamaServer, .nomicEmbedModel, .embeddingGemmaModel, .llama31InstructModel,
        ]
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        for spec in specs {
            XCTAssertFalse(spec.sources.isEmpty, "\(spec.name) has no sources")
            for (arch, source) in spec.sources {
                guard let sha = source.sha256 else {
                    XCTFail("\(spec.name) [\(arch)] is unpinned (sha256: nil)")
                    continue
                }
                XCTAssertEqual(sha.count, 64, "\(spec.name) [\(arch)] sha256 is not 64 chars")
                XCTAssertTrue(sha.unicodeScalars.allSatisfy(hex.contains), "\(spec.name) [\(arch)] sha256 is not lowercase hex")
            }
        }
    }

    /// The embedding models resolve against a fixed Hugging Face commit, not the
    /// mutable `main` ref, so the pinned hash and the URL can't drift apart.
    func testEmbeddingModelsResolveAgainstACommit() {
        for spec in [ManagedBinary.nomicEmbedModel, .embeddingGemmaModel] {
            for (arch, source) in spec.sources {
                XCTAssertFalse(
                    source.url.absoluteString.contains("/resolve/main/"),
                    "\(spec.name) [\(arch)] uses the mutable resolve/main"
                )
            }
        }
    }
}
