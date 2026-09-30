import Foundation
import Security

protocol TokenStore: Sendable {
    func token(for accountID: String) -> String?
    func setToken(_ token: String, for accountID: String) throws
    func removeToken(for accountID: String)
}

/// Generic-password Keychain items, readable after the first unlock (so background work,
/// such as notifications later, can use them) and never synced or backed up to other
/// devices.
struct KeychainTokenStore: TokenStore {
    static let defaultService = (Bundle.main.bundleIdentifier ?? "hibari") + ".token"

    var service = Self.defaultService

    private func query(_ accountID: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountID,
        ]
    }

    func token(for accountID: String) -> String? {
        var query = query(accountID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the item in place, so that a failed write leaves the previous token.
    func setToken(_ token: String, for accountID: String) throws {
        let attributes: [CFString: Any] = [
            kSecValueData: Data(token.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(accountID) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(accountID).merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func removeToken(for accountID: String) {
        SecItemDelete(query(accountID) as CFDictionary)
    }
}

final class InMemoryTokenStore: TokenStore {
    private let tokens = Locked<[String: String]>([:])

    func token(for accountID: String) -> String? {
        tokens.withLock { $0[accountID] }
    }

    func setToken(_ token: String, for accountID: String) throws {
        tokens.withLock { $0[accountID] = token }
    }

    func removeToken(for accountID: String) {
        tokens.withLock { _ = $0.removeValue(forKey: accountID) }
    }
}
