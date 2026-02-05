//
//  B2AuthManager.swift
//  CloudMountKit
//
//  Token lifecycle actor with transparent refresh on auth expiry.
//

import Foundation

/// Manages B2 authentication token lifecycle with transparent refresh.
///
/// On creation, immediately authenticates with the provided credentials.
/// Call ``refresh()`` to re-authenticate when the token expires (401 responses).
public actor B2AuthManager {
    // MARK: - Auth State

    /// Current authorization token for API requests.
    public private(set) var authToken: String

    /// Base URL for API calls (varies by account region).
    public private(set) var apiUrl: String

    /// Base URL for file downloads.
    public private(set) var downloadUrl: String

    /// The B2 account ID.
    public private(set) var accountId: String

    /// Recommended part size for large file uploads, in bytes.
    public private(set) var recommendedPartSize: Int64

    /// Absolute minimum part size for large file uploads, in bytes.
    public private(set) var absoluteMinimumPartSize: Int64

    /// Capabilities and restrictions for the authorized key.
    public private(set) var allowed: B2Allowed?

    // MARK: - Private

    private let keyId: String
    private let applicationKey: String
    private let http: B2HTTPClient

    // MARK: - Init

    /// Creates a new auth manager and immediately authenticates.
    ///
    /// - Parameters:
    ///   - keyId: The application key ID.
    ///   - applicationKey: The application key secret.
    ///   - http: The HTTP client to use for auth requests.
    /// - Throws: If initial authentication fails.
    public init(
        keyId: String,
        applicationKey: String,
        http: B2HTTPClient = B2HTTPClient()
    ) async throws {
        self.keyId = keyId
        self.applicationKey = applicationKey
        self.http = http
        // Placeholder values before async call
        self.authToken = ""
        self.apiUrl = ""
        self.downloadUrl = ""
        self.accountId = ""
        self.recommendedPartSize = 0
        self.absoluteMinimumPartSize = 0
        self.allowed = nil
        // Authenticate immediately
        try await refresh()
    }

    // MARK: - Refresh

    /// Re-authenticate to get a fresh token.
    ///
    /// Called automatically by ``B2Client`` on 401 auth-expired errors.
    /// Can also be called manually to proactively refresh.
    public func refresh() async throws {
        let response = try await http.authorizeAccount(
            keyId: keyId,
            applicationKey: applicationKey
        )
        self.authToken = response.authorizationToken
        self.apiUrl = response.apiInfo.storageApi.apiUrl
        self.downloadUrl = response.apiInfo.storageApi.downloadUrl
        self.accountId = response.accountId
        self.recommendedPartSize = response.apiInfo.storageApi.recommendedPartSize
        self.absoluteMinimumPartSize = response.apiInfo.storageApi.absoluteMinimumPartSize
        self.allowed = response.apiInfo.storageApi.allowed
    }
}
