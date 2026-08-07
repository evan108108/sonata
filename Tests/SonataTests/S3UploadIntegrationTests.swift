import XCTest
@testable import Sonata

// Opt-in roundtrip of the tree-archive upload path against the real bucket.
//
// The unit tests prove the signature is deterministic and that the chunked file
// hash matches the in-memory one, but neither proves S3 *accepts* what we sign.
// A signature can be perfectly self-consistent and still be rejected — a missing
// signed header or a mis-encoded path only shows up against the real service.
//
// Skipped unless SONATA_S3_INTEGRATION=1, because it needs live credentials and
// writes a real (small, immediately deleted) object.
//
//   AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… SONATA_S3_INTEGRATION=1 \
//     swift test --filter S3UploadIntegrationTests
final class S3UploadIntegrationTests: XCTestCase {

    func testSignedFileUploadIsAcceptedByS3() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SONATA_S3_INTEGRATION"] == "1", "set SONATA_S3_INTEGRATION=1 to run")
        let accessKey = try XCTUnwrap(env["AWS_ACCESS_KEY_ID"])
        let secretKey = try XCTUnwrap(env["AWS_SECRET_ACCESS_KEY"])

        // A scratch key under the same prefix the tree archive uses, so this
        // exercises the real path and ages out under the same lifecycle rule.
        let key = "\(LifecycleConfig.s3TreePrefix)integration-test-\(UUID().uuidString).bin"
        let host = "\(LifecycleConfig.s3Bucket).s3.\(LifecycleConfig.s3Region).amazonaws.com"

        let path = NSTemporaryDirectory() + "s3-integration-\(UUID().uuidString).bin"
        // Larger than one hash chunk, so the streaming hash is what gets signed.
        try Data((0..<(6 * 1_048_576)).map { UInt8($0 % 251) }).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let payloadHash = try XCTUnwrap(AWSSigV4.sha256Hex(fileAt: path))
        let headers = AWSSigV4.headers(
            method: "PUT", host: host, path: "/\(key)",
            payloadHash: payloadHash,
            extraHeaders: ["Content-Type": "application/gzip"],
            region: LifecycleConfig.s3Region,
            accessKey: accessKey, secretKey: secretKey
        )

        var put = URLRequest(url: try XCTUnwrap(URL(string: "https://\(host)/\(key)")), timeoutInterval: 300)
        put.httpMethod = "PUT"
        for (name, value) in headers { put.setValue(value, forHTTPHeaderField: name) }

        let (body, response) = try await URLSession.shared.upload(
            for: put, fromFile: URL(fileURLWithPath: path)
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        XCTAssertEqual(status, 200, "S3 rejected the signed upload: \(String(data: body, encoding: .utf8) ?? "")")

        // Clean up the scratch object rather than leaving it to the lifecycle.
        var delete = URLRequest(url: try XCTUnwrap(URL(string: "https://\(host)/\(key)")))
        delete.httpMethod = "DELETE"
        let emptyHash = AWSSigV4.sha256Hex(Data())
        for (name, value) in AWSSigV4.headers(
            method: "DELETE", host: host, path: "/\(key)", payloadHash: emptyHash,
            region: LifecycleConfig.s3Region, accessKey: accessKey, secretKey: secretKey
        ) { delete.setValue(value, forHTTPHeaderField: name) }
        _ = try? await URLSession.shared.data(for: delete)
    }
}
