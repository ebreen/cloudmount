//
//  MetadataCache.swift
//  CloudMountKit
//
//  In-memory TTL cache for B2 directory listings and file metadata.
//  Reduces redundant API calls by caching results for a configurable duration.
//

import Foundation

/// In-memory TTL cache for B2 directory listings and file metadata.
///
/// All cache entries expire after the configured TTL. Write operations
/// (upload, delete, copy) should call ``invalidate(bucketId:path:)``
/// to keep the cache consistent.
public actor MetadataCache {

    // MARK: - Types

    private struct CacheEntry<T> {
        let value: T
        let expiresAt: Date
        var isExpired: Bool { Date() > expiresAt }
    }

    // MARK: - State

    private var directoryListings: [String: CacheEntry<[B2FileInfo]>] = [:]
    private var fileMetadata: [String: CacheEntry<B2FileInfo>] = [:]
    private let ttl: TimeInterval

    // MARK: - Init

    /// Creates a new metadata cache.
    /// - Parameter ttl: Time-to-live in seconds (default: 300 = 5 minutes).
    public init(ttl: TimeInterval = 300) {
        self.ttl = ttl
    }

    // MARK: - Directory Listings

    /// Get a cached directory listing.
    /// - Returns: The cached entries, or `nil` if not cached or expired.
    public func getDirectoryListing(bucketId: String, path: String) -> [B2FileInfo]? {
        let key = cacheKey(bucketId: bucketId, path: path)
        guard let entry = directoryListings[key], !entry.isExpired else {
            // Clean up expired entry
            directoryListings.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    /// Cache a directory listing.
    public func cacheDirectoryListing(bucketId: String, path: String, entries: [B2FileInfo]) {
        let key = cacheKey(bucketId: bucketId, path: path)
        directoryListings[key] = CacheEntry(
            value: entries,
            expiresAt: Date().addingTimeInterval(ttl)
        )
    }

    // MARK: - File Metadata

    /// Get cached file metadata.
    /// - Returns: The cached info, or `nil` if not cached or expired.
    public func getFileMetadata(bucketId: String, fileName: String) -> B2FileInfo? {
        let key = cacheKey(bucketId: bucketId, path: fileName)
        guard let entry = fileMetadata[key], !entry.isExpired else {
            fileMetadata.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    /// Cache file metadata.
    public func cacheFileMetadata(bucketId: String, fileName: String, info: B2FileInfo) {
        let key = cacheKey(bucketId: bucketId, path: fileName)
        fileMetadata[key] = CacheEntry(
            value: info,
            expiresAt: Date().addingTimeInterval(ttl)
        )
    }

    // MARK: - Invalidation

    /// Invalidate cache entries for a path AND its parent directory.
    ///
    /// Call this after any write operation (upload, delete, copy, rename)
    /// to keep the cache consistent with the server.
    public func invalidate(bucketId: String, path: String) {
        let key = cacheKey(bucketId: bucketId, path: path)
        directoryListings.removeValue(forKey: key)
        fileMetadata.removeValue(forKey: key)

        // Also invalidate the parent directory listing
        let parentPath = parentDirectory(of: path)
        let parentKey = cacheKey(bucketId: bucketId, path: parentPath)
        directoryListings.removeValue(forKey: parentKey)
    }

    /// Invalidate all cache entries for a bucket.
    public func invalidateAll(bucketId: String) {
        let prefix = "\(bucketId):"
        directoryListings = directoryListings.filter { !$0.key.hasPrefix(prefix) }
        fileMetadata = fileMetadata.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Clear the entire cache.
    public func clearAll() {
        directoryListings.removeAll()
        fileMetadata.removeAll()
    }

    // MARK: - Private Helpers

    private func cacheKey(bucketId: String, path: String) -> String {
        "\(bucketId):\(path)"
    }

    private func parentDirectory(of path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let lastSlash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[...lastSlash])
    }
}
