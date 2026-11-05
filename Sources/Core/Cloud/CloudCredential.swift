import Foundation
import Security

/// The three values Samsung Cloud needs. Lives only in the Keychain and in
/// memory; never written to the snapshot, logs or UI (except a masked hint).
public struct CloudCredential: Codable, Sendable, Equatable {
    public var accessToken: String
    public var userId: String
    public var deviceId: String
    public var accountEmail: String?

    public init(accessToken: String, userId: String, deviceId: String, accountEmail: String? = nil) {
        self.accessToken = accessToken
        self.userId = userId
        self.deviceId = deviceId
        self.accountEmail = accountEmail
    }

    /// Allowlist validation at the trust boundary (user paste / import).
    public enum ValidationError: LocalizedError {
        case emptyField(String), badCharacters(String), tooLong(String)
        public var errorDescription: String? {
            switch self {
            case .emptyField(let f): return "\(f) is required."
            case .badCharacters(let f): return "\(f) contains unexpected characters."
            case .tooLong(let f): return "\(f) is unexpectedly long."
            }
        }
    }

    public func validated() throws -> CloudCredential {
        let tokenSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~+/="))
        let idSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        func check(_ value: String, _ name: String, _ allowed: CharacterSet, max: Int) throws -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ValidationError.emptyField(name) }
            guard trimmed.count <= max else { throw ValidationError.tooLong(name) }
            guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { throw ValidationError.badCharacters(name) }
            return trimmed
        }
        return CloudCredential(
            accessToken: try check(accessToken, "Access token", tokenSet, max: 4096),
            userId: try check(userId, "User ID", idSet, max: 128),
            deviceId: try check(deviceId, "Device ID", idSet, max: 128),
            accountEmail: accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    /// "Account ••••1234" — safe to show in the UI.
    public var maskedHint: String {
        let suffix = String(userId.suffix(4))
        return suffix.isEmpty ? "Samsung account" : "Account ••••\(suffix)"
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Generic-password item in the user's login keychain, scoped to this app's
/// bundle id. Other apps hit the standard macOS keychain prompt.
public struct KeychainStore: Sendable {
    public let service: String
    public let account = "samsung-cloud-credential"

    public init(service: String = Bundle.main.bundleIdentifier ?? "SamsungReminder") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public enum KeychainError: LocalizedError {
        case status(OSStatus)
        public var errorDescription: String? {
            if case .status(let s) = self {
                return (SecCopyErrorMessageString(s, nil) as String?) ?? "Keychain error \(s)"
            }
            return nil
        }
    }

    public func load() throws -> CloudCredential? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.status(status) }
        return try JSONDecoder().decode(CloudCredential.self, from: data)
    }

    public func save(_ credential: CloudCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
