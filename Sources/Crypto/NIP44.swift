import Foundation
import CryptoKit
import P256K

public enum NIP44 {
    public enum Error: Swift.Error, Equatable {
        case unsupportedVersion(UInt8)
        case payloadTooShort
        case macMismatch
        case malformedPadding(reason: String)
        case invalidBase64
        case invalidPubkey
        case invalidPrivateKey
    }

    // MARK: - Public

    /// Decrypt a NIP-44 v2 base64-encoded wire string. The conversation key
    /// drives derivation; the two input keys producing it are symmetric.
    public static func decrypt(payload: String, conversationKey: Data) throws -> Data {
        guard let bytes = Data(base64Encoded: payload) else { throw Error.invalidBase64 }
        return try decryptRaw(ciphertext: bytes, conversationKey: conversationKey)
    }

    /// Decrypt NIP-44 v2 raw ciphertext bytes (no base64 wrapping).
    public static func decryptRaw(ciphertext: Data, conversationKey: Data) throws -> Data {
        // Min payload: version(1) + nonce(32) + min-ciphertext(34) + mac(32) = 99
        guard ciphertext.count >= 99 else { throw Error.payloadTooShort }
        let version = ciphertext[ciphertext.startIndex]
        guard version == 0x02 else { throw Error.unsupportedVersion(version) }

        let nonce = ciphertext.subdata(in: (ciphertext.startIndex + 1)..<(ciphertext.startIndex + 33))
        let ct = ciphertext.subdata(in: (ciphertext.startIndex + 33)..<(ciphertext.endIndex - 32))
        let mac = ciphertext.subdata(in: (ciphertext.endIndex - 32)..<ciphertext.endIndex)

        let keys = try messageKeys(conversationKey: conversationKey, nonce: nonce)
        let expectedMac = hmacSHA256(key: keys.hmacKey, data: nonce + ct)
        guard constantTimeEquals(mac, expectedMac) else { throw Error.macMismatch }

        let padded = try ChaCha20.crypt(key: keys.chachaKey, nonce: keys.chachaNonce, data: ct)
        return try unpad(padded)
    }

    /// Derive the symmetric conversation key:
    ///   conversation_key = HMAC_SHA256(salt="nip44-v2", IKM=ECDH_X(a, b))
    /// where ECDH_X is the secp256k1 shared secret's x coordinate (raw).
    public static func conversationKey(privateKey: Data, publicKey: Data) throws -> Data {
        guard privateKey.count == 32 else { throw Error.invalidPrivateKey }

        var compressed = Data([0x02])
        if publicKey.count == 32 {
            compressed.append(publicKey)
        } else if publicKey.count == 33 {
            compressed = publicKey
        } else {
            throw Error.invalidPubkey
        }

        // swift-secp256k1 (21-DOT-DEV fork, module P256K) exposes ECDH that
        // returns the raw x-coordinate (NOT SHA256(x)) when given a custom
        // hash function. The package's `sharedSecretFromKeyAgreement(with:
        // format:)` uses an identity hash internally — `.compressed` returns
        // 33 bytes (`version ‖ x`), `.uncompressed` returns 65 bytes
        // (`0x04 ‖ x ‖ y`). NIP-44 v2 wants the raw 32-byte x; we strip the
        // version prefix below.
        let priv = try P256K.KeyAgreement.PrivateKey(dataRepresentation: privateKey)
        let pub  = try P256K.KeyAgreement.PublicKey(dataRepresentation: compressed, format: .compressed)

        let shared = try priv.sharedSecretFromKeyAgreement(with: pub, format: .compressed)
        let sharedBytes = shared.bytes
        // `.compressed` returns the 33-byte compressed point (0x02/0x03 ‖ x);
        // strip the parity byte to get the raw 32-byte x-coordinate.
        let sharedX: Data
        if sharedBytes.count == 33 {
            sharedX = Data(sharedBytes.dropFirst())
        } else if sharedBytes.count == 32 {
            sharedX = Data(sharedBytes)
        } else {
            throw Error.invalidPubkey
        }

        let salt = Data("nip44-v2".utf8)
        return Data(hmacSHA256(key: salt, data: sharedX))
    }

    // MARK: - Internals

    private struct MessageKeys {
        let chachaKey: Data
        let chachaNonce: Data
        let hmacKey: Data
    }

    /// HKDF_expand(prk=conversationKey, info=nonce, len=76) ⇒
    ///   chacha_key(32) ‖ chacha_nonce(12) ‖ hmac_key(32)
    private static func messageKeys(conversationKey: Data, nonce: Data) throws -> MessageKeys {
        guard nonce.count == 32 else { throw Error.malformedPadding(reason: "nonce length") }
        let prk = SymmetricKey(data: conversationKey)
        let expanded = HKDF<CryptoKit.SHA256>.expand(
            pseudoRandomKey: prk,
            info: nonce,
            outputByteCount: 76
        )
        let raw = expanded.withUnsafeBytes { Data($0) }
        return MessageKeys(
            chachaKey: raw.subdata(in: 0..<32),
            chachaNonce: raw.subdata(in: 32..<44),
            hmacKey: raw.subdata(in: 44..<76)
        )
    }

    private static func unpad(_ padded: Data) throws -> Data {
        guard padded.count >= 2 else { throw Error.malformedPadding(reason: "too short") }
        let declared = Int(padded[padded.startIndex]) << 8 | Int(padded[padded.startIndex + 1])
        guard (1...65535).contains(declared) else { throw Error.malformedPadding(reason: "declared out of range") }
        let expected = 2 + calcPaddedLen(declared)
        guard padded.count == expected else { throw Error.malformedPadding(reason: "length mismatch: expected \(expected), got \(padded.count)") }
        return padded.subdata(in: (padded.startIndex + 2)..<(padded.startIndex + 2 + declared))
    }

    /// Bucket function from the NIP-44 v2 spec: smallest power-of-2 chunk
    /// that fits the plaintext length, with minimum 32-byte bucket.
    public static func calcPaddedLen(_ len: Int) -> Int {
        if len <= 32 { return 32 }
        let nextPower = 1 << (Int(floor(log2(Double(len - 1)))) + 1)
        let chunk = nextPower <= 256 ? 32 : nextPower / 8
        return chunk * (Int((len - 1) / chunk) + 1)
    }

    // MARK: - HMAC + constant-time

    private static func hmacSHA256(key: Data, data: Data) -> Data {
        let mac = HMAC<CryptoKit.SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[a.startIndex + i] ^ b[b.startIndex + i] }
        return diff == 0
    }
}

// MARK: - Pure-Swift ChaCha20 (no Poly1305)

private enum ChaCha20 {
    static func crypt(key: Data, nonce: Data, data: Data) throws -> Data {
        guard key.count == 32, nonce.count == 12 else {
            throw NIP44.Error.malformedPadding(reason: "chacha20 key/nonce length")
        }
        var out = Data(count: data.count)
        var counter: UInt32 = 0
        var i = 0
        while i < data.count {
            let block = chacha20Block(key: key, counter: counter, nonce: nonce)
            let chunk = min(64, data.count - i)
            for j in 0..<chunk {
                out[i + j] = data[data.startIndex + i + j] ^ block[j]
            }
            i += chunk
            counter &+= 1
        }
        return out
    }

    private static func chacha20Block(key: Data, counter: UInt32, nonce: Data) -> [UInt8] {
        var state: [UInt32] = [
            0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
            load32(key, 0),  load32(key, 4),  load32(key, 8),  load32(key, 12),
            load32(key, 16), load32(key, 20), load32(key, 24), load32(key, 28),
            counter,
            load32(nonce, 0), load32(nonce, 4), load32(nonce, 8)
        ]
        let initial = state
        for _ in 0..<10 {
            qround(&state, 0, 4, 8, 12)
            qround(&state, 1, 5, 9, 13)
            qround(&state, 2, 6, 10, 14)
            qround(&state, 3, 7, 11, 15)
            qround(&state, 0, 5, 10, 15)
            qround(&state, 1, 6, 11, 12)
            qround(&state, 2, 7, 8, 13)
            qround(&state, 3, 4, 9, 14)
        }
        var out = [UInt8](repeating: 0, count: 64)
        for w in 0..<16 {
            let val = state[w] &+ initial[w]
            out[w * 4 + 0] = UInt8(truncatingIfNeeded: val)
            out[w * 4 + 1] = UInt8(truncatingIfNeeded: val >> 8)
            out[w * 4 + 2] = UInt8(truncatingIfNeeded: val >> 16)
            out[w * 4 + 3] = UInt8(truncatingIfNeeded: val >> 24)
        }
        return out
    }

    private static func qround(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 16)
        s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 12)
        s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 8)
        s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 7)
    }

    private static func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 { (v << n) | (v >> (32 - n)) }

    private static func load32(_ d: Data, _ off: Int) -> UInt32 {
        let base = d.startIndex + off
        return UInt32(d[base]) | (UInt32(d[base + 1]) << 8) | (UInt32(d[base + 2]) << 16) | (UInt32(d[base + 3]) << 24)
    }
}
