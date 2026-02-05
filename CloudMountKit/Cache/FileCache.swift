//
//  FileCache.swift
//  CloudMountKit
//
//  On-disk LRU file cache for downloaded B2 files.
//  Stores files in ~/Library/Caches/CloudMount/ with automatic eviction.
//

import Foundation
import CryptoKit

/// On-disk LRU file cache for downloaded B2 files.
///
/// Uses SHA-256 hashing for safe file names on disk. Automatically evicts
/// least-recently-accessed entries when the cache exceeds its size limit.
public actor FileCache {

    // MARK: - Types

    private struct FileCacheEntry {
        let localPath: URL
        let sizeBytes: Int64
        var lastAccessed: Date
    }

    // MARK: - State

    private let cacheDirectory: URL
    private let maxSizeBytes: Int64
    private var entries: [String: FileCacheEntry] = [:]

    // MARK: - Init

    /// Creates a new file cache.
    /// - Parameter maxSizeBytes: Maximum cache size in bytes (default: 1 GB).
    public init(maxSizeBytes: Int64 = 1_073_741_824) {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CloudMount", isDirectory: true)
        self.cacheDirectory = cacheDir
        self.maxSizeBytes = maxSizeBytes
        // Create directory if needed
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Get cached file data.
    /// - Returns: The file data, or `nil` if not cached.
    public func get(bucketName: String, fileName: String) -> Data? {
        let key = cacheKey(bucketName: bucketName, fileName: fileName)
        guard var entry = entries[key] else { return nil }

        guard FileManager.default.fileExists(atPath: entry.localPath.path) else {
            entries.removeValue(forKey: key)
            return nil
        }

        // Update access time for LRU tracking
        entry.lastAccessed = Date()
        entries[key] = entry

        return try? Data(contentsOf: entry.localPath)
    }

    /// Store file data in the cache, evicting LRU entries if over size limit.
    public func store(bucketName: String, fileName: String, data: Data) {
        let key = cacheKey(bucketName: bucketName, fileName: fileName)
        let localPath = localURL(for: key)

        let newSize = Int64(data.count)

        // Don't cache files larger than the entire cache limit
        guard newSize <= maxSizeBytes else { return }

        // Evict if needed to make room
        evictIfNeeded(forNewSize: newSize)

        do {
            try data.write(to: localPath, options: .atomic)
            entries[key] = FileCacheEntry(
                localPath: localPath,
                sizeBytes: newSize,
                lastAccessed: Date()
            )
        } catch {
            // Cache is best-effort — silently ignore write failures
        }
    }

    /// Remove a specific cached file.
    public func remove(bucketName: String, fileName: String) {
        let key = cacheKey(bucketName: bucketName, fileName: fileName)
        if let entry = entries.removeValue(forKey: key) {
            try? FileManager.default.removeItem(at: entry.localPath)
        }
    }

    /// Clear the entire cache.
    public func clearAll() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Current total cache size in bytes.
    public var currentSizeBytes: Int64 {
        entries.values.reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: - Private Helpers

    private func cacheKey(bucketName: String, fileName: String) -> String {
        "\(bucketName)/\(fileName)"
    }

    private func localURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8))
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(hashString)
    }

    private func evictIfNeeded(forNewSize newSize: Int64) {
        var totalSize = currentSizeBytes + newSize
        guard totalSize > maxSizeBytes else { return }

        // Sort by last accessed — evict oldest first (LRU)
        let sorted = entries.sorted { $0.value.lastAccessed < $1.value.lastAccessed }

        for (key, entry) in sorted {
            guard totalSize > maxSizeBytes else { break }
            try? FileManager.default.removeItem(at: entry.localPath)
            entries.removeValue(forKey: key)
            totalSize -= entry.sizeBytes
        }
    }
}
