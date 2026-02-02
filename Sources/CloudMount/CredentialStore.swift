import Foundation
import KeychainAccess

/// Secure credential storage using macOS Keychain
final class CredentialStore {
    static let shared = CredentialStore()
    
    private let keychain = Keychain(service: "com.cloudmount.credentials")
        .accessibility(.whenUnlocked)
    
    private let b2CredentialsKey = "__b2_credentials__"
    
    private init() {}
    
    // MARK: - B2 Global Credentials
    
    /// B2 account credentials (keyId + applicationKey)
    struct B2Credentials: Codable {
        let keyId: String
        let applicationKey: String
    }
    
    /// Save B2 credentials (keyId + applicationKey)
    func saveB2Credentials(keyId: String, applicationKey: String) throws {
        let credentials = B2Credentials(keyId: keyId, applicationKey: applicationKey)
        let data = try JSONEncoder().encode(credentials)
        try keychain.set(data, key: b2CredentialsKey)
    }
    
    /// Retrieve B2 credentials
    func getB2Credentials() throws -> B2Credentials? {
        guard let data = try keychain.getData(b2CredentialsKey) else {
            return nil
        }
        return try JSONDecoder().decode(B2Credentials.self, from: data)
    }
    
    /// Delete B2 credentials
    func deleteB2Credentials() throws {
        try keychain.remove(b2CredentialsKey)
    }
    
    // MARK: - Legacy Per-Bucket Credentials (for compatibility)
    
    /// Bucket credentials (legacy - kept for compatibility)
    struct BucketCredentials: Codable {
        let bucketName: String
        let keyId: String
        let applicationKey: String
    }
    
    /// Save credentials for a bucket
    func save(_ credentials: BucketCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try keychain.set(data, key: credentials.bucketName)
    }
    
    /// Retrieve credentials for a bucket
    /// Returns global B2 credentials with the bucket name if no per-bucket creds exist
    func get(bucket: String) throws -> BucketCredentials? {
        // First try bucket-specific credentials
        if let data = try keychain.getData(bucket) {
            return try JSONDecoder().decode(BucketCredentials.self, from: data)
        }
        
        // Fall back to global B2 credentials
        if let b2Creds = try getB2Credentials() {
            return BucketCredentials(
                bucketName: bucket,
                keyId: b2Creds.keyId,
                applicationKey: b2Creds.applicationKey
            )
        }
        
        return nil
    }
    
    /// Delete credentials for a bucket
    func delete(bucket: String) throws {
        try keychain.remove(bucket)
    }
    
    /// List all stored bucket names
    func listBuckets() -> [String] {
        keychain.allKeys().filter { $0 != b2CredentialsKey }
    }
}
