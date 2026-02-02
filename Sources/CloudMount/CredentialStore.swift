import Foundation
import KeychainAccess

/// Secure credential storage using macOS Keychain
final class CredentialStore {
    static let shared = CredentialStore()
    
    private let keychain = Keychain(service: "com.cloudmount.credentials")
        .accessibility(.whenUnlocked)
    
    private init() {}
    
    /// Bucket credentials
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
    func get(bucket: String) throws -> BucketCredentials? {
        guard let data = try keychain.getData(bucket) else {
            return nil
        }
        return try JSONDecoder().decode(BucketCredentials.self, from: data)
    }
    
    /// Delete credentials for a bucket
    func delete(bucket: String) throws {
        try keychain.remove(bucket)
    }
    
    /// List all stored bucket names
    func listBuckets() -> [String] {
        keychain.allKeys()
    }
}
