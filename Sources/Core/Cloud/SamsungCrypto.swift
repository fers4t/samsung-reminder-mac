import CommonCrypto
import CryptoKit
import Foundation
import Security

/// The handful of primitives Samsung Account's web sign-in envelope needs.
/// System frameworks only (CommonCrypto, CryptoKit, Security); no third-party crypto.
enum SamsungCrypto {
    enum CryptoError: Error { case invalidKey, cipherFailed(Int32), badPadding, badHex }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
        return Data(bytes)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// PKCE verifier (43 chars) and S256 challenge.
    static func pkce() -> (verifier: String, challenge: String) {
        let verifier = String(base64URL(randomBytes(32)).prefix(43))
        return (verifier, base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
    }

    static func pbkdf2(password: Data, salt: Data, iterations: Int, length: Int) throws -> Data {
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { outPtr in
            password.withUnsafeBytes { passPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passPtr.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                         saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.cipherFailed(status) }
        return out
    }

    private static func aes(_ op: CCOperation, options: CCOptions, key: Data, iv: Data?, input: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw CryptoError.invalidKey }
        let capacity = input.count + kCCBlockSizeAES128
        var out = Data(count: capacity)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            key.withUnsafeBytes { keyPtr in
                input.withUnsafeBytes { inPtr in
                    (iv ?? Data()).withUnsafeBytes { ivPtr in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), options,
                                keyPtr.baseAddress, key.count, iv == nil ? nil : ivPtr.baseAddress,
                                inPtr.baseAddress, input.count,
                                outPtr.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.cipherFailed(status) }
        return out.prefix(moved)
    }

    static func aesCBCEncrypt(key: Data, iv: Data, plaintext: Data) throws -> Data {
        try aes(CCOperation(kCCEncrypt), options: CCOptions(kCCOptionPKCS7Padding), key: key, iv: iv, input: plaintext)
    }

    /// Samsung encrypts redirect values with AES-128-ECB using the first 16 bytes of a text key, zero padded.
    static func aesECBDecrypt(textKey: String, hex: String) throws -> String {
        guard let cipher = Data(hex: hex) else { throw CryptoError.badHex }
        let key = Data(textKey.utf8).prefix(16) + Data(repeating: 0, count: max(0, 16 - textKey.utf8.count))
        let plain = try aes(CCOperation(kCCDecrypt), options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                            key: key, iv: nil, input: cipher)
        guard let text = String(data: plain, encoding: .utf8) else { throw CryptoError.badPadding }
        return text
    }

    /// RSA PKCS#1 v1.5 encryption with a SubjectPublicKeyInfo DER key (as Samsung's entry point returns).
    static func rsaEncrypt(spkiDER: Data, plaintext: Data) throws -> Data {
        let pkcs1 = try unwrapSPKI(spkiDER)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error),
              let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, plaintext as CFData, &error)
        else { throw CryptoError.invalidKey }
        return encrypted as Data
    }

    /// SPKI = SEQUENCE { SEQUENCE { oid, null }, BIT STRING { 0x00, RSAPublicKey } }.
    /// Security.framework wants the inner RSAPublicKey, so walk the two outer wrappers.
    static func unwrapSPKI(_ der: Data) throws -> Data {
        let bytes = [UInt8](der)
        func header(at index: Int) throws -> (contentStart: Int, length: Int) {
            guard index + 1 < bytes.count else { throw CryptoError.invalidKey }
            var length = Int(bytes[index + 1]), cursor = index + 2
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count <= 4, cursor + count <= bytes.count else { throw CryptoError.invalidKey }
                length = bytes[cursor..<cursor + count].reduce(0) { $0 << 8 | Int($1) }
                cursor += count
            }
            guard cursor + length <= bytes.count else { throw CryptoError.invalidKey }
            return (cursor, length)
        }
        guard bytes.first == 0x30 else { throw CryptoError.invalidKey }
        let outer = try header(at: 0)
        guard bytes[outer.contentStart] == 0x30 else { throw CryptoError.invalidKey }
        let algorithm = try header(at: outer.contentStart)
        let bitStringIndex = algorithm.contentStart + algorithm.length
        guard bytes[bitStringIndex] == 0x03 else { throw CryptoError.invalidKey }
        let bitString = try header(at: bitStringIndex)
        // First BIT STRING byte is the unused-bits count (0).
        return Data(bytes[(bitString.contentStart + 1)..<(bitString.contentStart + bitString.length)])
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
