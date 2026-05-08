import Foundation
import GRDB
import Logging
import CommonCrypto

/// Manages nightly SQLite backups — local copy + S3 upload.
/// Local backup uses SQLite's online backup API (no locking, safe during writes).
/// S3 upload uses raw HTTP PUT with AWS Signature V4.
actor BackupManager {
    private let dbPool: DatabasePool
    private let logger = Logger(label: "sonata.backup")
    private var timer: Task<Void, Never>?

    private let backupDir: String
    private let dbPath: String

    /// S3 config — read from SecretStore at backup time
    private let s3Bucket = "enginable-sonata-backups"
    private let s3Region = "us-east-1"

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
        self.dbPath = "\(DatabaseManager.dataDirectory)/sonata.db"
        self.backupDir = "\(DatabaseManager.dataDirectory)/backups"
    }

    func start() {
        logger.info("BackupManager: started (nightly at 4am UTC, local + S3)")
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let secondsUntilNext = await self.secondsUntil4amUTC()
                logger.info("BackupManager: next backup in \(Int(secondsUntilNext / 3600))h \(Int(secondsUntilNext.truncatingRemainder(dividingBy: 3600) / 60))m")
                try? await Task.sleep(for: .seconds(secondsUntilNext))
                if Task.isCancelled { return }
                await self.runBackup()
            }
        }
    }

    func shutdown() {
        logger.info("BackupManager: shutting down")
        timer?.cancel()
        timer = nil
    }

    /// Run a backup immediately (called by nightly timer or manual trigger via API).
    func runBackup() async {
        let dateStr = Self.dateStamp()
        let localLatestPath = "\(backupDir)/sonata-latest.db"
        let localDatedPath = "\(backupDir)/sonata-\(dateStr).db"

        // Step 1: SQLite online backup to local file
        logger.info("BackupManager: starting local backup...")
        let localSuccess = await performLocalBackup(to: localLatestPath)
        guard localSuccess else {
            logger.error("BackupManager: local backup failed")
            return
        }

        // Copy latest to dated backup (keep last 7 locally)
        try? FileManager.default.copyItem(atPath: localLatestPath, toPath: localDatedPath)
        cleanupLocalBackups(keepLast: 7)

        // sonar-dm v0: 7-day TTL on delivered DM rows. Best-effort; logged but
        // never fails the backup itself.
        let dmDeleted = await dmMessagesCleanupOld(dbPool: dbPool)
        if dmDeleted > 0 {
            logger.info("BackupManager: dm_messages TTL pruned \(dmDeleted) delivered rows older than 7 days")
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localLatestPath)[.size] as? Int64) ?? 0
        let sizeMB = String(format: "%.1f", Double(fileSize) / 1_048_576)
        logger.info("BackupManager: local backup complete (\(sizeMB) MB)")

        // Step 2: Gzip and upload to S3
        let accessKey = SecretStore.get("AWS_ACCESS_KEY_ID")
        let secretKey = SecretStore.get("AWS_SECRET_ACCESS_KEY")

        if let accessKey, let secretKey, !accessKey.isEmpty, !secretKey.isEmpty {
            logger.info("BackupManager: uploading to S3...")
            let gzPath = "\(backupDir)/sonata-\(dateStr).db.gz"

            // Gzip the backup
            let gzipProcess = Process()
            gzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            gzipProcess.arguments = ["-c", localDatedPath]
            let gzipPipe = Pipe()
            gzipProcess.standardOutput = gzipPipe
            gzipProcess.standardError = FileHandle.nullDevice
            do {
                try gzipProcess.run()
                let gzData = gzipPipe.fileHandleForReading.readDataToEndOfFile()
                gzipProcess.waitUntilExit()

                if gzipProcess.terminationStatus == 0 && !gzData.isEmpty {
                    try gzData.write(to: URL(fileURLWithPath: gzPath))
                    let gzSizeMB = String(format: "%.1f", Double(gzData.count) / 1_048_576)

                    // Upload to S3
                    let s3Key = "backups/sonata-\(dateStr).db.gz"
                    let uploaded = await uploadToS3(
                        data: gzData,
                        bucket: s3Bucket,
                        key: s3Key,
                        region: s3Region,
                        accessKey: accessKey,
                        secretKey: secretKey
                    )

                    if uploaded {
                        logger.info("BackupManager: S3 upload complete — \(s3Key) (\(gzSizeMB) MB)")
                    } else {
                        logger.error("BackupManager: S3 upload failed")
                    }

                    // Clean up local gz file
                    try? FileManager.default.removeItem(atPath: gzPath)
                }
            } catch {
                logger.error("BackupManager: gzip failed — \(error)")
            }
        } else {
            logger.info("BackupManager: S3 skipped (no AWS credentials)")
        }

        // Clean up dated local backup (only keep gz in S3, latest locally)
        try? FileManager.default.removeItem(atPath: localDatedPath)

        logger.info("BackupManager: backup cycle complete")
    }

    // MARK: - Local Backup

    private func performLocalBackup(to destPath: String) async -> Bool {
        // Use sqlite3 CLI for online backup (safe during concurrent writes)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, ".backup '\(destPath)'"]
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            logger.error("BackupManager: sqlite3 backup failed — \(error)")
            return false
        }
    }

    // MARK: - S3 Upload (AWS Signature V4)

    private func uploadToS3(
        data: Data, bucket: String, key: String, region: String,
        accessKey: String, secretKey: String
    ) async -> Bool {
        let host = "\(bucket).s3.\(region).amazonaws.com"
        let urlStr = "https://\(host)/\(key)"
        guard let url = URL(string: urlStr) else { return false }

        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let dateStamp = dateFormatter.string(from: now)

        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        isoFormatter.timeZone = TimeZone(identifier: "UTC")
        let amzDate = isoFormatter.string(from: now)

        // Content hash
        let payloadHash = sha256Hex(data)

        // Canonical request
        let canonicalHeaders = "content-type:application/octet-stream\nhost:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
        let signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = "PUT\n/\(key)\n\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"

        // String to sign
        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n\(sha256Hex(Data(canonicalRequest.utf8)))"

        // Signing key
        let kDate = hmacSHA256(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data("s3".utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))

        let signature = hmacSHA256(key: kSigning, data: Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()

        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            if statusCode == 200 { return true }
            logger.error("BackupManager: S3 responded with \(statusCode)")
            return false
        } catch {
            logger.error("BackupManager: S3 upload error — \(error)")
            return false
        }
    }

    // MARK: - Crypto Helpers

    private func sha256Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        var result = [UInt8](repeating: 0, count: 32)
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

    // MARK: - Helpers

    private func cleanupLocalBackups(keepLast: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: backupDir) else { return }
        let backupFiles = files
            .filter { $0.hasPrefix("sonata-") && $0.hasSuffix(".db") && $0 != "sonata-latest.db" }
            .sorted()
        if backupFiles.count > keepLast {
            for file in backupFiles.prefix(backupFiles.count - keepLast) {
                try? fm.removeItem(atPath: "\(backupDir)/\(file)")
            }
        }
    }

    private func secondsUntil4amUTC() -> Double {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 4
        components.minute = 0
        components.second = 0
        var target = calendar.date(from: components)!
        if target <= now {
            target = calendar.date(byAdding: .day, value: 1, to: target)!
        }
        return target.timeIntervalSince(now)
    }

    private static func dateStamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: Date())
    }
}
