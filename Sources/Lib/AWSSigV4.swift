import Foundation
import CommonCrypto

/// AWS Signature V4 request signing.
///
/// Factored out of `BackupManager`, which had this inline for the single case of
/// PUTting a gzipped database held entirely in memory. The tree archive added a
/// second caller that cannot work that way — it is gigabytes, so its payload
/// hash has to come from disk (ADA-483).
enum AWSSigV4 {
    private static let algorithm = "AWS4-HMAC-SHA256"
    private static let terminator = "aws4_request"

    /// Returns every header the request must carry, `Authorization` included.
    ///
    /// `payloadHash` is the lowercase hex SHA-256 of the body. Callers streaming
    /// a large file compute it from disk rather than holding the body in memory.
    /// `query` is the canonical query string — sorted, URI-encoded, `key=value`
    /// pairs joined by `&`, empty for none.
    static func headers(
        method: String,
        host: String,
        path: String,
        query: String = "",
        payloadHash: String,
        extraHeaders: [String: String] = [:],
        region: String,
        service: String = "s3",
        accessKey: String,
        secretKey: String,
        now: Date = Date()
    ) -> [String: String] {
        let dateStamp = format(now, as: "yyyyMMdd")
        let amzDate = format(now, as: "yyyyMMdd'T'HHmmss'Z'")

        var signed = extraHeaders
        signed["host"] = host
        signed["x-amz-content-sha256"] = payloadHash
        signed["x-amz-date"] = amzDate

        let ordered = signed
            .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.0 < $1.0 }
        let canonicalHeaders = ordered.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaderNames = ordered.map { $0.0 }.joined(separator: ";")

        let canonicalRequest = [
            method, path, query, canonicalHeaders, signedHeaderNames, payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/\(terminator)"
        let stringToSign = [
            algorithm, amzDate, scope, sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let kDate = hmac(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        let kSigning = hmac(key: kService, data: Data(terminator.utf8))
        let signature = hex(hmac(key: kSigning, data: Data(stringToSign.utf8)))

        var result = extraHeaders
        result["Host"] = host
        result["x-amz-content-sha256"] = payloadHash
        result["x-amz-date"] = amzDate
        result["Authorization"] =
            "\(algorithm) Credential=\(accessKey)/\(scope), "
            + "SignedHeaders=\(signedHeaderNames), Signature=\(signature)"
        return result
    }

    // MARK: - Digests

    static func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return hex(Data(digest))
    }

    /// Hashes a file in chunks. The tree archive runs to gigabytes, and hashing
    /// it the obvious way would mean holding the whole thing in memory purely to
    /// compute a header.
    static func sha256Hex(fileAt path: String, chunkBytes: Int = 4 * 1_048_576) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        while true {
            let chunk = handle.readData(ofLength: chunkBytes)
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { buffer in
                _ = CC_SHA256_Update(&context, buffer.baseAddress, CC_LONG(chunk.count))
            }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return hex(Data(digest))
    }

    // MARK: - Primitives

    private static func hmac(key: Data, data: Data) -> Data {
        var result = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyBuffer in
            data.withUnsafeBytes { dataBuffer in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                       keyBuffer.baseAddress, key.count,
                       dataBuffer.baseAddress, data.count,
                       &result)
            }
        }
        return Data(result)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func format(_ date: Date, as pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
