//
//  MountConfig.swift
//  CloudMountKit
//
//  Mount configuration and cache settings models.
//  Stored in App Group UserDefaults via SharedDefaults.
//

import Foundation

/// Configuration for a single mounted B2 bucket.
///
/// Each mount references a `B2Account` by its UUID and describes
/// the bucket, mount point, and cache behavior.
public struct MountConfiguration: Identifiable, Codable, Hashable, Sendable {
    /// Stable unique identifier for this mount configuration.
    public let id: UUID

    /// The B2 account that owns this bucket (references ``B2Account/id``).
    public var accountId: UUID

    /// Backblaze B2 bucket identifier.
    public var bucketId: String

    /// Backblaze B2 bucket name (used for display and download URLs).
    public var bucketName: String

    /// Local mount point path (e.g. "/Volumes/my-bucket").
    public var mountPoint: String

    /// Whether this mount should be activated automatically on app launch.
    public var autoMount: Bool

    /// Cache behavior settings for this mount.
    public var cacheSettings: CacheSettings

    public init(
        id: UUID = UUID(),
        accountId: UUID,
        bucketId: String,
        bucketName: String,
        mountPoint: String,
        autoMount: Bool = false,
        cacheSettings: CacheSettings = CacheSettings()
    ) {
        self.id = id
        self.accountId = accountId
        self.bucketId = bucketId
        self.bucketName = bucketName
        self.mountPoint = mountPoint
        self.autoMount = autoMount
        self.cacheSettings = cacheSettings
    }
}

/// Cache behavior settings for a mounted bucket.
public struct CacheSettings: Codable, Hashable, Sendable {
    /// Time-to-live for cached directory listings and file metadata, in seconds.
    public var metadataTTLSeconds: Int

    /// Maximum total size of the local file cache, in bytes.
    public var maxFileCacheSizeBytes: Int64

    /// Whether local file caching is enabled.
    public var enableFileCache: Bool

    public init(
        metadataTTLSeconds: Int = 300,
        maxFileCacheSizeBytes: Int64 = 1_073_741_824,
        enableFileCache: Bool = true
    ) {
        self.metadataTTLSeconds = metadataTTLSeconds
        self.maxFileCacheSizeBytes = maxFileCacheSizeBytes
        self.enableFileCache = enableFileCache
    }
}
