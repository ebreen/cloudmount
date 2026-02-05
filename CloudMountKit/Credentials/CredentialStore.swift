//
//  CredentialStore.swift
//  CloudMountKit
//
//  Native Keychain wrapper using Security.framework for storing B2 credentials.
//  Shared across host app and FSKit extension via keychain-access-groups entitlement.
//

import Foundation
import Security

// MARK: - Keychain Errors

/// Errors originating from Security.framework keychain operations.
public enum KeychainError: Error, LocalizedError {
    case duplicateItem
    case itemNotFound
    case authFailed
    case unhandledError(status: OSStatus)

    public init(status: OSStatus) {
        switch status {
        case errSecDuplicateItem:
            self = .duplicateItem
        case errSecItemNotFound:
            self = .itemNotFound
        case errSecAuthFailed:
            self = .authFailed
        default:
            self = .unhandledError(status: status)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .duplicateItem:
            return "Keychain item already exists."
        case .itemNotFound:
            return "Keychain item not found."
        case .authFailed:
            return "Keychain authentication failed."
        case .unhandledError(let status):
            return "Keychain error: OSStatus \(status)"
        }
    }
}

// MARK: - Low-level Keychain Helper

/// Low-level wrapper around SecItem* functions.
/// Stores and retrieves `Data` blobs in the keychain using
/// `kSecClassGenericPassword` items.
public struct KeychainHelper: Sendable {

    /// Shared access group for cross-process keychain sharing.
    /// Set to `"TEAMID.com.cloudmount.shared"` when the team ID is known.
    /// When `nil`, the default access group is used (sufficient for development).
    public nonisolated(unsafe) static var accessGroup: String? = nil

    // MARK: - Save

    /// Save `data` to the keychain for the given service/account pair.
    /// Uses a delete-then-add pattern to handle updates.
    public static func save(data: Data, service: String, account: String) throws {
        // Delete any existing item first (ignore "not found" errors).
        try? delete(service: service, account: account)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecValueData as String: data,
        ]

        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    // MARK: - Load

    /// Retrieve `Data` from the keychain for the given service/account pair.
    /// Returns `nil` if the item does not exist.
    public static func load(service: String, account: String) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    // MARK: - Delete

    /// Delete the keychain item for the given service/account pair.
    public static func delete(service: String, account: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    // MARK: - List Accounts

    /// List all `kSecAttrAccount` values stored under the given service.
    public static func listAccounts(service: String) -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]]
        else {
            return []
        }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

// MARK: - Credential Store (B2 Account layer)

/// Manages B2 account credentials in the system keychain.
///
/// Secrets (`keyId` + `applicationKey`) are stored as a JSON blob in the keychain,
/// keyed by the account's UUID string. Non-secret metadata (label, last-authorized, etc.)
/// lives in `SharedDefaults`.
public struct CredentialStore: Sendable {

    /// Keychain service name for all B2 credential items.
    public static let serviceName = "com.cloudmount.b2"

    /// Internal Codable wrapper for the secret parts of a B2 account.
    private struct CredentialPayload: Codable {
        let keyId: String
        let applicationKey: String
    }

    // MARK: - Public API

    /// Save the secret credentials for a B2 account.
    ///
    /// Only `keyId` and `applicationKey` are written to the keychain.
    /// Account metadata should be persisted via `SharedDefaults`.
    public static func saveAccount(_ account: B2Account, applicationKey: String) throws {
        let payload = CredentialPayload(keyId: account.keyId, applicationKey: applicationKey)
        let data = try JSONEncoder().encode(payload)
        try KeychainHelper.save(data: data, service: serviceName, account: account.id.uuidString)
    }

    /// Load the secret credentials for an account by its UUID.
    ///
    /// Returns a tuple of `(keyId, applicationKey)`, or `nil` if not found.
    public static func loadCredentials(id: UUID) -> (keyId: String, applicationKey: String)? {
        guard let data = KeychainHelper.load(service: serviceName, account: id.uuidString),
              let payload = try? JSONDecoder().decode(CredentialPayload.self, from: data)
        else {
            return nil
        }
        return (payload.keyId, payload.applicationKey)
    }

    /// List the UUIDs of all accounts that have stored credentials.
    public static func storedAccountIDs() -> [UUID] {
        KeychainHelper.listAccounts(service: serviceName)
            .compactMap { UUID(uuidString: $0) }
    }

    /// Delete the credentials for the given account.
    public static func deleteAccount(id: UUID) throws {
        try KeychainHelper.delete(service: serviceName, account: id.uuidString)
    }
}
