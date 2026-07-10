import Foundation
import Security

/// Errors thrown by KeychainStore for unexpected Security framework failures
public enum KeychainError: Error, Sendable, Equatable {
    /// The Security framework returned an unexpected status code
    case unexpectedStatus(OSStatus)
}

/// A minimal wrapper around the Keychain for storing small secrets
///
/// Items are stored as generic passwords under a shared service namespace,
/// keyed by account name. Reads distinguish "not found" (returns nil) from
/// genuine Keychain failures (throws `KeychainError`).
public struct KeychainStore: Sendable {
    /// The Keychain service namespace for all items in this store
    public let service: String

    public init(service: String = "com.jellyshark.app") {
        self.service = service
    }

    // MARK: - Data

    /// Store data for a key, replacing any existing value
    public func setData(_ data: Data, for key: String) throws {
        var query = baseQuery(for: key)
        query[kSecValueData as String] = data
        #if !os(macOS)
        // Shipping platforms (tvOS/visionOS) always set this. Guarded off only
        // on the macOS host, where JellyfinKit's Keychain tests run under
        // `swift test`: an unsigned test runner can hit the data-protection
        // keychain this attribute requires and fail with errSecMissingEntitlement.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #endif

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let attributes = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(
                baseQuery(for: key) as CFDictionary,
                attributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Read data for a key
    /// - Returns: The stored data, or nil if no item exists for the key
    public func data(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Strings

    /// Store a string for a key, replacing any existing value
    public func setString(_ value: String, for key: String) throws {
        try setData(Data(value.utf8), for: key)
    }

    /// Read a string for a key
    /// - Returns: The stored string, or nil if no item exists for the key
    public func string(for key: String) throws -> String? {
        guard let data = try data(for: key) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Deletion

    /// Delete the value for a key (no-op if the key does not exist)
    public func delete(_ key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Helpers

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
