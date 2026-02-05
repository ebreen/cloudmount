//
//  AccountConfig.swift
//  CloudMountKit
//
//  B2 account metadata model. Secrets (applicationKey) are stored in
//  Keychain via CredentialStore; this model holds non-secret fields
//  persisted in SharedDefaults (App Group UserDefaults).
//

import Foundation

/// Represents a Backblaze B2 account with metadata for display and reference.
///
/// The `keyId` is stored here for display (it's a username-like identifier, not secret).
/// The `applicationKey` (the actual secret) lives only in the Keychain.
public struct B2Account: Identifiable, Codable, Hashable, Sendable {
    /// Stable unique identifier for this account configuration.
    public let id: UUID

    /// User-friendly label (e.g. "Personal", "Work Backup").
    public var label: String

    /// B2 application key ID — stored here for display; not a secret.
    public var keyId: String

    /// B2 account ID — populated after the first successful authorization.
    public var accountId: String?

    /// Timestamp of the last successful B2 authorization.
    public var lastAuthorized: Date?

    public init(
        id: UUID = UUID(),
        label: String,
        keyId: String,
        accountId: String? = nil,
        lastAuthorized: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.keyId = keyId
        self.accountId = accountId
        self.lastAuthorized = lastAuthorized
    }
}
