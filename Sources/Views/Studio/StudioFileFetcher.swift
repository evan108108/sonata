import AppKit
import CryptoKit
import Foundation

/// Errors surfaced by `StudioFileFetcher.download(block:room:authorPubHex:)`.
/// Mirrors `StudioImageError`'s structure, with one new case for the wrap
/// failure path that's specific to hybrid encryption (the unwrap of the
/// 44-byte `file_key || nonce` envelope).
enum StudioFileError: Error, Equatable {
    case allMirrorsFailed
    case integrityMismatch(host: String)
    case wrappedKeyDecryptFailed
    case fileDecryptFailed
    case missingEpochKey(epoch: Int)
    case userCancelled
    case saveFailed(reason: String)
}

/// Phase 5 file-block download path. Pulls ciphertext from Blossom, unwraps
/// the audience-epoch wrap of the (file_key || nonce) envelope, ChaCha20-
/// Poly1305-decrypts the bulk ciphertext, and writes plaintext via an
/// NSSavePanel so filename collisions don't silently overwrite.
///
/// Plumbing audit §5.3 — the wrap is bound to the epoch at the time of
/// publish, so the renderer reads the *originally-wrapped* epoch_n from
/// `decrypt_hint.epoch_n`, not the room's current epoch.
actor StudioFileFetcher {

    private let mirrorTimeoutSeconds: TimeInterval = 5 * 60
    private let maxMirrorsPerFetch = 3

    static let shared = StudioFileFetcher()

    /// Download + decrypt + prompt-save a file block. Returns the saved URL on
    /// success. The NSSavePanel runs on the main thread; the rest of the
    /// pipeline (fetch + decrypt) runs on this actor.
    func download(
        block: StudioFileBlock,
        room: String,
        authorPubHex: String
    ) async throws -> URL {
        guard !block.mirrors.isEmpty else { throw StudioFileError.allMirrorsFailed }

        let epochN = block.decryptHint.epochN
        guard let epochPriv = try await epochKey(room: room, epochN: epochN) else {
            throw StudioFileError.missingEpochKey(epoch: epochN)
        }

        let ciphertext = try await fetchCiphertext(block: block)

        // 1. Unwrap the (file_key || nonce) envelope from the epoch priv +
        //    author's pubkey via NIP-44 v2. Plaintext is exactly 44 bytes.
        let keyMaterial: Data
        do {
            guard let authorPub = Hex.decode(authorPubHex), authorPub.count == 32 else {
                throw StudioFileError.wrappedKeyDecryptFailed
            }
            let convKey = try NIP44.conversationKey(privateKey: epochPriv, publicKey: authorPub)
            keyMaterial = try NIP44.decrypt(payload: block.decryptHint.wrappedKey, conversationKey: convKey)
        } catch {
            throw StudioFileError.wrappedKeyDecryptFailed
        }
        guard keyMaterial.count == 44 else {
            throw StudioFileError.wrappedKeyDecryptFailed
        }
        let fileKey = keyMaterial.subdata(in: 0..<32)
        let nonce = keyMaterial.subdata(in: 32..<44)

        // 2. ChaCha20-Poly1305 decrypt with file_key + nonce. The plugin
        //    appends the Poly1305 tag to ciphertext (RFC 8439 layout); split
        //    the last 16 bytes for the SealedBox.
        guard ciphertext.count >= 16 else {
            throw StudioFileError.fileDecryptFailed
        }
        let tag = ciphertext.subdata(in: (ciphertext.count - 16)..<ciphertext.count)
        let ctOnly = ciphertext.subdata(in: 0..<(ciphertext.count - 16))
        let plaintext: Data
        do {
            let cpNonce = try ChaChaPoly.Nonce(data: nonce)
            let sealed = try ChaChaPoly.SealedBox(nonce: cpNonce, ciphertext: ctOnly, tag: tag)
            plaintext = try ChaChaPoly.open(sealed, using: SymmetricKey(data: fileKey))
        } catch {
            throw StudioFileError.fileDecryptFailed
        }

        // 3. Prompt for save location. The brief asks for NSSavePanel rather
        //    than dropping into ~/Downloads silently because filenames in
        //    file-blocks can easily collide.
        let savedURL = try await promptAndSave(filename: block.filename, data: plaintext)
        return savedURL
    }

    // MARK: - NSSavePanel

    @MainActor
    private func promptAndSave(filename: String, data: Data) async throws -> URL {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            panel.directoryURL = downloads
        }
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            throw StudioFileError.userCancelled
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw StudioFileError.saveFailed(reason: error.localizedDescription)
        }
        return url
    }

    // MARK: - Ciphertext fetch

    private func fetchCiphertext(block: StudioFileBlock) async throws -> Data {
        var attempted = 0
        for mirrorString in block.mirrors {
            if attempted >= maxMirrorsPerFetch {
                NSLog("[StudioFileFetcher] mirror cap reached for sha256=\(block.sha256.prefix(8))…")
                break
            }
            guard let url = URL(string: mirrorString) else {
                NSLog("[StudioFileFetcher] malformed mirror URL: \(mirrorString)")
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
                    NSLog("[StudioFileFetcher] mirror \(url.host ?? "?") returned \(http.statusCode) for sha256=\(block.sha256.prefix(8))…")
                    continue
                }
                if sha256Hex(data) != block.sha256.lowercased() {
                    NSLog("[StudioFileFetcher] sha256 mismatch from \(url.host ?? "?")")
                    continue
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                NSLog("[StudioFileFetcher] mirror \(url.host ?? "?") failed: \(error)")
                continue
            }
        }
        throw StudioFileError.allMirrorsFailed
    }

    // MARK: - Epoch key lookup (mirrors StudioImageFetcher)

    private func epochKey(room slug: String, epochN: Int) async throws -> Data? {
        let secretName = "studio:room:\(slug):epoch_keys"
        guard let url = URL(string: "http://127.0.0.1:3211/api/secrets/\(secretName)") else {
            return nil
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let valueStr = envelope["value"] as? String,
              let valueData = valueStr.data(using: .utf8),
              let outer = (try? JSONSerialization.jsonObject(with: valueData)) as? [String: Any],
              let epochs = outer["epochs"] as? [String: Any],
              let entry = epochs[String(epochN)] as? [String: Any],
              let priv = entry["priv_hex"] as? String,
              let bytes = Hex.decode(priv), bytes.count == 32 else {
            return nil
        }
        return bytes
    }

    private nonisolated func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
