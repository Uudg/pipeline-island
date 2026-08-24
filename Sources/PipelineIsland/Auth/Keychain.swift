import Foundation
import Security

/// Token storage for the GitLab PAT.
public enum Keychain {
    public static let service = "com.pipelineisland.app"

    /// Previous service names, tried on read so an existing token survives a rename.
    private static let legacyServices = ["com.dan.pipeline-island"]  // pre-1.0 development identifier
    public static let account = "gitlab.com"

    public enum KeychainError: Error, LocalizedError, Sendable {
        case encodingFailed
        case writeFailed(OSStatus)
        case deleteFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Token could not be encoded as UTF-8."
            case .writeFailed(let status):
                return "Keychain write failed (OSStatus \(status))."
            case .deleteFailed(let status):
                return "Keychain delete failed (OSStatus \(status))."
            }
        }
    }

    /// Base query for every operation.
    ///
    /// Two keychain backends are in play and neither works alone:
    ///
    /// * The **data-protection keychain** (`kSecUseDataProtectionKeychain: true`)
    ///   scopes items by code identity and returns an error rather than blocking
    ///   on an approval panel — which is what we want, because an LSUIElement
    ///   accessory cannot reliably present one. But it requires the
    ///   `keychain-access-groups` / `application-identifier` entitlement, and an
    ///   ad-hoc signed binary has neither. Measured: `SecItemAdd` returns
    ///   `-34018` (`errSecMissingEntitlement`) and `SecItemCopyMatching` returns
    ///   `-25300` (`errSecItemNotFound`) for every item.
    ///
    /// * The **legacy file-based keychain** works without entitlements, which is
    ///   why the spikes used it, but its per-item ACL is keyed to the writing
    ///   binary's signature. A binary not on the ACL triggers a SecurityAgent
    ///   prompt; in a GUI session the user can approve it once, but a headless
    ///   process blocks forever.
    ///
    /// So: prefer data-protection when entitlements make it available, and fall
    /// back to legacy otherwise. This keeps `make app` working for anyone who
    /// clones the repo without a paid signing identity, and upgrades silently if
    /// the app is ever properly signed.
    private static func baseQuery(dataProtection: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: dataProtection,
        ]
    }

    /// Store the token, replacing any existing one.
    public static func store(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        var lastStatus: OSStatus = errSecSuccess
        for dataProtection in [true, false] {
            var query = baseQuery(dataProtection: dataProtection)
            // Delete-then-add keeps the accessibility attribute authoritative.
            SecItemDelete(query as CFDictionary)

            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecSuccess {
                TokenCache.shared.invalidate()
                return
            }
            lastStatus = status
        }
        throw KeychainError.writeFailed(lastStatus)
    }

    /// Read the token back.
    public static func load() -> String? {
        for dataProtection in [true, false] {
            var query = baseQuery(dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var out: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
               let data = out as? Data,
               let token = String(data: data, encoding: .utf8) {
                return token
            }
        }

        for legacy in legacyServices {
            for dataProtection in [true, false] {
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: legacy,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                query[kSecUseDataProtectionKeychain as String] = dataProtection

                var out: AnyObject?
                guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
                      let data = out as? Data,
                      let token = String(data: data, encoding: .utf8) else { continue }

                try? store(token)
                return token
            }
        }
        return nil
    }

    /// Legacy-keychain migration hook.
    @discardableResult
    public static func migrateLegacyItem() -> Bool {
        var query = baseQuery(dataProtection: false)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let token = String(data: data, encoding: .utf8) else { return false }

        return (try? store(token)) != nil
    }

    /// Remove the token from both keychains.
    public static func delete() throws {
        var lastStatus: OSStatus = errSecSuccess
        for dataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                lastStatus = status
            }
        }
        TokenCache.shared.invalidate()
        guard lastStatus == errSecSuccess else {
            throw KeychainError.deleteFailed(lastStatus)
        }
    }
}

/// Process-wide token cache.
public final class TokenCache: @unchecked Sendable {
    public static let shared = TokenCache()

    private let lock = NSLock()
    /// Double optional: `nil` is "never read", `.some(nil)` is "read, and empty".
    private var cached: String??

    private init() {}

    /// When true, the keychain is never touched and `token()` returns nil.
    public var isDisabled = false

    public func token() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if isDisabled { return nil }
        if let cached { return cached }
        let value = Keychain.load()
        cached = value
        return value
    }

    /// Forget the cached value; the next read goes back to the keychain.
    public func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
