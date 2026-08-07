import Foundation
import GRDB
import Logging

/// Manages the nightly lifecycle run — prune, then back up, then upload.
///
/// Local DB backup uses SQLite's online backup API (no locking, safe during
/// writes). S3 upload uses raw HTTP PUT with AWS Signature V4.
///
/// The tree archive is the ADA-483 addition. Until then this covered only
/// `sonata.db`, which meant anything living in the tree but outside git — an
/// installed plugin's source above all — had no recovery path at all. A plugin
/// reinstall on 2026-08-07 destroyed a working implementation that existed
/// nowhere else, and nothing in this file could have brought it back.
actor BackupManager {
    private let dbPool: DatabasePool
    private let logger = Logger(label: "sonata.backup")
    private var timer: Task<Void, Never>?

    private let backupDir: String
    private let dataDir: String
    private let dbPath: String
    private let config: LifecycleConfig
    private let cleanup: CleanupManager

    private let s3Bucket = LifecycleConfig.s3Bucket
    private let s3Region = LifecycleConfig.s3Region

    private static let tarBinary = "/usr/bin/tar"
    private static let treeLatestName = "sonata-tree-latest.tar.gz"

    init(dbPool: DatabasePool, config: LifecycleConfig = LifecycleConfig()) {
        self.dbPool = dbPool
        self.config = config
        self.dataDir = DatabaseManager.dataDirectory
        self.dbPath = "\(DatabaseManager.dataDirectory)/sonata.db"
        self.backupDir = "\(DatabaseManager.dataDirectory)/backups"
        self.cleanup = CleanupManager(config: config)
    }

    func start() {
        logger.info("BackupManager: started (nightly at 4am UTC — prune, DB backup, tree archive, S3)")
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

    /// Run the lifecycle immediately (nightly timer, or manual trigger via API).
    ///
    /// Phase order is the point of the design: cleanup runs first so the tree
    /// archive never contains the workspaces we are about to delete. Reversed,
    /// the first archive would carry tens of gigabytes of scratch to S3.
    func runBackup(scope: BackupScope = .both) async {
        if scope.includesTree {
            _ = await cleanup.runCleanup()
        }
        if scope.includesDB {
            await runDatabaseBackup()
        }
        if scope.includesTree, config.treeBackupEnabled {
            await runTreeBackup()
        }
        logger.info("BackupManager: lifecycle run complete (scope=\(scope.rawValue))")
    }

    // MARK: - Database backup

    private func runDatabaseBackup() async {
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

        // Copy latest to dated backup. Age-based retention for these now lives in
        // CleanupManager, which prunes on the same schedule as everything else.
        try? FileManager.default.copyItem(atPath: localLatestPath, toPath: localDatedPath)

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

            // Gzip the backup. Off the cooperative pool — compressing the whole
            // database blocks for as long as that takes (SCT-4).
            do {
                let gzOutcome = await OffPoolProcess.run("/usr/bin/gzip", ["-c", localDatedPath])
                let gzData = gzOutcome?.stdout ?? Data()

                if gzOutcome == nil {
                    logger.error("BackupManager: gzip failed to spawn")
                } else if gzOutcome?.status != 0 {
                    logger.error("BackupManager: gzip exited \(gzOutcome?.status ?? -1)")
                } else if gzData.isEmpty {
                    logger.error("BackupManager: gzip produced no output")
                }

                if gzOutcome?.status == 0 && !gzData.isEmpty {
                    try gzData.write(to: URL(fileURLWithPath: gzPath))
                    let gzSizeMB = String(format: "%.1f", Double(gzData.count) / 1_048_576)

                    // Upload to S3
                    let s3Key = "\(LifecycleConfig.s3BackupsPrefix)sonata-\(dateStr).db.gz"
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

    /// Uses the sqlite3 CLI for an online backup (safe during concurrent writes).
    ///
    /// Runs off the cooperative pool: copying the whole database takes as long as
    /// it takes, and blocking a cooperative thread for that span starves the pool
    /// the HTTP server shares — the failure mode behind SCT-4.
    private func performLocalBackup(to destPath: String) async -> Bool {
        guard let outcome = await OffPoolProcess.run(
            "/usr/bin/sqlite3",
            [dbPath, ".backup '\(destPath)'"]
        ) else {
            logger.error("BackupManager: sqlite3 backup failed to spawn")
            return false
        }
        if outcome.status != 0 {
            logger.error("BackupManager: sqlite3 backup exited \(outcome.status)")
        }
        return outcome.status == 0
    }

    // MARK: - Tree backup

    /// tar+gz of the data directory minus `config.treeExcludes`, uploaded under
    /// the `tree/` prefix and kept locally as `sonata-tree-latest.tar.gz` so a
    /// restore does not have to round-trip through S3.
    ///
    /// tar writes straight to disk rather than through a pipe. The archive runs
    /// to gigabytes, and `OffPoolProcess` buffers a child's stdout in memory —
    /// fine for the bounded output it documents, ruinous here. Writing to a file
    /// also keeps the upload streaming from disk instead of from a `Data`.
    private func runTreeBackup() async {
        let dateStr = Self.dateStamp()
        let archivePath = "\(backupDir)/sonata-tree-\(dateStr).tar.gz"

        try? FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: archivePath)

        logger.info("BackupManager: archiving tree (excluding \(config.treeExcludes.count) patterns)...")
        var arguments = ["-czf", archivePath, "-C", dataDir]
        arguments.append(contentsOf: config.treeExcludes.map { "--exclude=\($0)" })
        arguments.append(".")

        guard let tar = await OffPoolProcess.run(Self.tarBinary, arguments) else {
            logger.error("BackupManager: tar failed to spawn")
            return
        }
        // bsdtar exits 1 for warnings such as a file changing while being read.
        // The archive is still valid, so warn and carry on; only a hard failure
        // aborts. Anything actively written during a run — logs — is excluded.
        if tar.status != 0 {
            logger.warning("BackupManager: tar exited \(tar.status) (warnings); continuing with the archive it produced")
        }
        guard let size = fileSize(archivePath), size > 0 else {
            logger.error("BackupManager: tree archive missing or empty — aborting tree backup")
            return
        }
        let sizeMB = String(format: "%.1f", Double(size) / 1_048_576)
        logger.info("BackupManager: tree archive written \(archivePath) (\(sizeMB) MB)")

        // Local copy for immediate recovery, replaced atomically-enough by
        // removing the previous one first.
        let latestPath = "\(backupDir)/\(Self.treeLatestName)"
        try? FileManager.default.removeItem(atPath: latestPath)
        try? FileManager.default.copyItem(atPath: archivePath, toPath: latestPath)

        let accessKey = SecretStore.get("AWS_ACCESS_KEY_ID")
        let secretKey = SecretStore.get("AWS_SECRET_ACCESS_KEY")
        guard let accessKey, let secretKey, !accessKey.isEmpty, !secretKey.isEmpty else {
            logger.info("BackupManager: tree S3 upload skipped (no AWS credentials) — local copy retained")
            return
        }

        let s3Key = "\(LifecycleConfig.s3TreePrefix)sonata-tree-\(dateStr).tar.gz"
        let uploaded = await uploadFileToS3(
            path: archivePath, key: s3Key,
            accessKey: accessKey, secretKey: secretKey
        )
        if uploaded {
            logger.info("BackupManager: tree upload complete — s3://\(s3Bucket)/\(s3Key) (\(sizeMB) MB)")
        } else {
            logger.error("BackupManager: tree upload failed — local copy retained at \(latestPath)")
        }

        // The dated archive is redundant with S3 plus the local latest copy.
        try? FileManager.default.removeItem(atPath: archivePath)
    }

    // MARK: - S3 Upload (AWS Signature V4)

    private func uploadToS3(
        data: Data, bucket: String, key: String, region: String,
        accessKey: String, secretKey: String
    ) async -> Bool {
        let host = "\(bucket).s3.\(region).amazonaws.com"
        guard let url = URL(string: "https://\(host)/\(key)") else { return false }

        let headers = AWSSigV4.headers(
            method: "PUT", host: host, path: "/\(key)",
            payloadHash: AWSSigV4.sha256Hex(data),
            extraHeaders: ["Content-Type": "application/octet-stream"],
            region: region, accessKey: accessKey, secretKey: secretKey
        )

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "PUT"
        request.httpBody = data
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

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

    /// Streams the body from disk. The gigabyte-scale tree archive must never be
    /// resident in memory, so both the payload hash and the upload read the file
    /// in chunks.
    private func uploadFileToS3(
        path: String, key: String, accessKey: String, secretKey: String
    ) async -> Bool {
        let host = "\(s3Bucket).s3.\(s3Region).amazonaws.com"
        guard let url = URL(string: "https://\(host)/\(key)") else { return false }
        guard let payloadHash = AWSSigV4.sha256Hex(fileAt: path) else {
            logger.error("BackupManager: could not hash \(path) for upload")
            return false
        }

        let headers = AWSSigV4.headers(
            method: "PUT", host: host, path: "/\(key)",
            payloadHash: payloadHash,
            extraHeaders: ["Content-Type": "application/gzip"],
            region: s3Region, accessKey: accessKey, secretKey: secretKey
        )

        var request = URLRequest(url: url, timeoutInterval: 3600)
        request.httpMethod = "PUT"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        do {
            let (_, response) = try await URLSession.shared.upload(
                for: request, fromFile: URL(fileURLWithPath: path)
            )
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            if statusCode == 200 { return true }
            logger.error("BackupManager: S3 responded with \(statusCode) for \(key)")
            return false
        } catch {
            logger.error("BackupManager: S3 file upload error — \(error)")
            return false
        }
    }

    // MARK: - Helpers

    private func fileSize(_ path: String) -> Int64? {
        try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64
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
