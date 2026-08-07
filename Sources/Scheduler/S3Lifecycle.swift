import Foundation
import Logging

/// Keeps the backup bucket's expiry rules equal to local retention.
///
/// Reconciled on every lifecycle run rather than set once by hand, so the two
/// copies cannot silently drift apart — a bucket quietly holding 30 days while
/// the local side holds 2 is the kind of mismatch nobody notices until a restore
/// (ADA-483).
enum S3Lifecycle {
    /// PUT is idempotent: it replaces the whole rule set, so re-running with the
    /// same expiry is a no-op against an already-correct bucket.
    static func reconcile(
        expiryDays: Int,
        bucket: String = LifecycleConfig.s3Bucket,
        region: String = LifecycleConfig.s3Region,
        logger: Logger
    ) async -> Bool {
        guard let accessKey = SecretStore.get("AWS_ACCESS_KEY_ID"),
              let secretKey = SecretStore.get("AWS_SECRET_ACCESS_KEY"),
              !accessKey.isEmpty, !secretKey.isEmpty
        else {
            logger.info("S3Lifecycle: skipped (no AWS credentials)")
            return false
        }

        let body = Data(configurationXML(expiryDays: expiryDays).utf8)
        let host = "\(bucket).s3.\(region).amazonaws.com"
        // Canonical form of `?lifecycle` — a valueless key still needs its `=`.
        let query = "lifecycle="

        let headers = AWSSigV4.headers(
            method: "PUT",
            host: host,
            path: "/",
            query: query,
            payloadHash: AWSSigV4.sha256Hex(body),
            extraHeaders: [
                "Content-Type": "application/xml",
                "Content-MD5": AWSSigV4.contentMD5Base64(body),
            ],
            region: region,
            accessKey: accessKey,
            secretKey: secretKey
        )

        guard let url = URL(string: "https://\(host)/?lifecycle") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "PUT"
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 200 {
                logger.info("S3Lifecycle: bucket \(bucket) rules set to expire after \(expiryDays)d (backups/ + tree/)")
                return true
            }
            let detail = String(data: data, encoding: .utf8) ?? ""
            logger.error("S3Lifecycle: PUT returned \(status) — \(detail.prefix(300))")
            return false
        } catch {
            logger.error("S3Lifecycle: PUT failed — \(error)")
            return false
        }
    }

    /// One rule per prefix. Scoping by prefix rather than applying a single
    /// bucket-wide rule leaves room for a future prefix to carry its own expiry.
    static func configurationXML(expiryDays: Int) -> String {
        let rules = [LifecycleConfig.s3BackupsPrefix, LifecycleConfig.s3TreePrefix]
            .map { prefix -> String in
                let id = "expire-after-\(expiryDays)-days-\(prefix.replacingOccurrences(of: "/", with: ""))"
                return "<Rule><ID>\(id)</ID><Filter><Prefix>\(prefix)</Prefix></Filter>"
                    + "<Status>Enabled</Status><Expiration><Days>\(expiryDays)</Days></Expiration></Rule>"
            }
            .joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<LifecycleConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">\(rules)</LifecycleConfiguration>"
    }
}
