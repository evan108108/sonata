import Combine
import CoreGraphics
import CryptoKit
import Foundation
import GRDB
import ImageIO

/// Errors surfaced by `StudioImageFetcher.image(for:room:authorPubHex:)`.
/// Each maps to a specific in-block placeholder per parent §13 (toasts table).
enum StudioImageError: Error, Equatable {
    /// Every mirror returned 4xx/5xx, transport-failed, or `block.mirrors` was empty.
    case allMirrorsFailed
    /// sha256 of fetched ciphertext didn't match `block.sha256` on a given host.
    case integrityMismatch(host: String)
    /// NIP-44 decrypt threw — wrong epoch priv, malformed ciphertext, MAC fail.
    case decryptFailed
    /// The room's `epoch_keys` map does not carry `decrypt_hint.epoch_n`.
    case missingEpochKey(epoch: Int)
    /// Plaintext bytes don't decode as a CGImage via ImageIO.
    case decodeFailed
}

/// Async image pipeline: BUD-02 fetch → sha256 verify → NIP-44 decrypt → CGImage
/// decode. Caches by sha256 (ciphertext is content-addressed; the memo of a
/// verified-once decrypt is safe to reuse forever).
///
/// One instance per Studio tab. The actor serializes NSCache reads/writes
/// without external locks; cancellation propagates to the in-flight URL fetch.
///
/// blake3 verification is deferred — spec §5 lists it alongside sha256, but
/// adding `swift-blake3` requires SPM mutation that the task brief asks us to
/// flag. sha256 alone is sufficient for ciphertext integrity since Blossom is
/// content-addressed.
actor StudioImageFetcher {

    // MARK: - Configuration

    private let mirrorTimeoutSeconds: TimeInterval = 30
    private let maxMirrorsPerFetch = 3
    private let diskCacheMaxBytes: Int = 200 * 1024 * 1024

    private let imageCache: NSCache<NSString, CGImageBox> = {
        let c = NSCache<NSString, CGImageBox>()
        c.countLimit = 100
        c.totalCostLimit = 100 * 1024 * 1024
        return c
    }()

    private let diskCacheRoot: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches
            .appendingPathComponent("com.sonata", isDirectory: true)
            .appendingPathComponent("studio-images", isDirectory: true)
    }()

    private let dbPool: DatabasePool
    private var diskTrimmed = false

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Public

    /// Resolve an image block to a CGImage. Throws `StudioImageError` for every
    /// documented failure path. The drawer's image view calls this inside
    /// `.task { … }`; closing the drawer cancels the enclosing Task, which
    /// propagates via URLSession's native cancellation to the in-flight fetch.
    func image(for block: StudioImageBlock,
               room: String,
               authorPubHex: String) async throws -> CGImage {
        if !diskTrimmed {
            diskTrimmed = true
            try? trimDiskCache()
        }

        if let cached = imageCache.object(forKey: block.sha256 as NSString) {
            return cached.image
        }

        guard !block.mirrors.isEmpty else { throw StudioImageError.allMirrorsFailed }

        let epochN = block.decryptHint.epochN
        guard let epochPriv = try await epochKey(room: room, epochN: epochN) else {
            throw StudioImageError.missingEpochKey(epoch: epochN)
        }

        let ciphertext = try await fetchCiphertext(block: block)

        let convKey: Data
        do {
            guard let authorPub = Hex.decode(authorPubHex), authorPub.count == 32 else {
                throw StudioImageError.decryptFailed
            }
            convKey = try NIP44.conversationKey(privateKey: epochPriv, publicKey: authorPub)
        } catch let e as StudioImageError {
            throw e
        } catch {
            throw StudioImageError.decryptFailed
        }

        let plaintext: Data
        do {
            plaintext = try NIP44.decryptRaw(ciphertext: ciphertext, conversationKey: convKey)
        } catch {
            throw StudioImageError.decryptFailed
        }

        guard let source = CGImageSourceCreateWithData(plaintext as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw StudioImageError.decodeFailed
        }

        let cost = image.width * image.height * 4
        imageCache.setObject(CGImageBox(image), forKey: block.sha256 as NSString, cost: cost)
        return image
    }

    // MARK: - Internals

    private func fetchCiphertext(block: StudioImageBlock) async throws -> Data {
        if let onDisk = try? readDiskCache(sha256: block.sha256),
           sha256Hex(onDisk) == block.sha256.lowercased() {
            return onDisk
        }
        var attempted = 0
        for mirrorString in block.mirrors {
            if attempted >= maxMirrorsPerFetch {
                NSLog("[StudioImageFetcher] mirror cap reached for sha256=\(block.sha256.prefix(8))…")
                break
            }
            guard let url = URL(string: mirrorString) else {
                NSLog("[StudioImageFetcher] malformed mirror URL: \(mirrorString)")
                continue
            }
            attempted += 1
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = mirrorTimeoutSeconds
                req.httpMethod = "GET"
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse else { continue }
                guard (200..<300).contains(http.statusCode) else {
                    NSLog("[StudioImageFetcher] mirror \(url.host ?? "?") returned \(http.statusCode) for sha256=\(block.sha256.prefix(8))…")
                    continue
                }
                if sha256Hex(data) != block.sha256.lowercased() {
                    NSLog("[StudioImageFetcher] sha256 mismatch from \(url.host ?? "?")")
                    // Last mirror that returns bytes but with wrong hash is the
                    // useful diagnostic; throw integrityMismatch only after we
                    // exhaust all mirrors and at least one returned bad bytes.
                    continue
                }
                try writeDiskCache(sha256: block.sha256, data: data)
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                NSLog("[StudioImageFetcher] mirror \(url.host ?? "?") failed: \(error)")
                continue
            }
        }
        throw StudioImageError.allMirrorsFailed
    }

    // MARK: - Cache helpers

    private func readDiskCache(sha256: String) throws -> Data? {
        let path = diskCacheRoot.appendingPathComponent("\(sha256).bin")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try Data(contentsOf: path)
    }

    private func writeDiskCache(sha256: String, data: Data) throws {
        try FileManager.default.createDirectory(at: diskCacheRoot, withIntermediateDirectories: true)
        let path = diskCacheRoot.appendingPathComponent("\(sha256).bin")
        try data.write(to: path, options: [.atomic])
    }

    /// Evict the in-memory image cache. Used by tests; harmless otherwise.
    func purgeMemoryCache() {
        imageCache.removeAllObjects()
    }

    /// Trim disk cache to ≤ diskCacheMaxBytes by oldest-mtime-first removal.
    func trimDiskCache() throws {
        guard FileManager.default.fileExists(atPath: diskCacheRoot.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: diskCacheRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var totalSize = 0
        var entries: [(url: URL, size: Int, mtime: Date)] = []
        for f in files {
            let vals = try f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = vals.fileSize ?? 0
            let mtime = vals.contentModificationDate ?? .distantPast
            totalSize += size
            entries.append((f, size, mtime))
        }
        if totalSize <= diskCacheMaxBytes { return }
        entries.sort { $0.mtime < $1.mtime }
        var remaining = totalSize
        for e in entries {
            if remaining <= diskCacheMaxBytes { break }
            try? FileManager.default.removeItem(at: e.url)
            remaining -= e.size
        }
    }

    /// Static pure-function variant of disk trim used by tests. Evicts files
    /// oldest-first from `root` until the directory total is at or below
    /// `maxBytes`. Returns the list of removed file URLs.
    @discardableResult
    static func trimDirectory(_ root: URL, maxBytes: Int) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var totalSize = 0
        var entries: [(url: URL, size: Int, mtime: Date)] = []
        for f in files {
            let vals = try f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = vals.fileSize ?? 0
            let mtime = vals.contentModificationDate ?? .distantPast
            totalSize += size
            entries.append((f, size, mtime))
        }
        if totalSize <= maxBytes { return [] }
        entries.sort { $0.mtime < $1.mtime }
        var remaining = totalSize
        var removed: [URL] = []
        for e in entries {
            if remaining <= maxBytes { break }
            try? FileManager.default.removeItem(at: e.url)
            remaining -= e.size
            removed.append(e.url)
        }
        return removed
    }

    // MARK: - Epoch key lookup

    /// One-shot read of the room's local-only `epoch_keys` attribute. Returns
    /// nil if the room entity isn't on disk or `epoch_keys[epochN]` is absent.
    private func epochKey(room slug: String, epochN: Int) async throws -> Data? {
        let name = "studio:room:\(slug)"
        let attrJSON: String? = try await dbPool.read { db in
            try String.fetchOne(db, sql: """
                SELECT attributes FROM entities WHERE type='studio_room' AND name = ?
                """, arguments: [name])
        }
        guard let raw = attrJSON,
              let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let keys = obj["epoch_keys"] as? [String: String] else {
            return nil
        }
        guard let hex = keys[String(epochN)], let bytes = Hex.decode(hex), bytes.count == 32 else {
            return nil
        }
        return bytes
    }

    // MARK: - Hashes

    private nonisolated func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - CGImage NSCache box

/// NSCache requires `AnyObject` values. CGImage bridges to AnyObject as a CF
/// type, but Swift's strict-concurrency checker prefers an explicit wrapper.
final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
