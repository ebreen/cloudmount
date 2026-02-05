//
//  B2Item.swift
//  CloudMountExtension
//
//  FSItem subclass that stores B2-specific metadata for each
//  file or directory in the virtual filesystem.
//

import FSKit
import CloudMountKit

/// FSItem subclass tracking per-item B2 cloud storage metadata.
///
/// Every file and directory in the mounted volume is represented by a `B2Item`.
/// The item carries its B2 key path, file ID, cached metadata, and local staging
/// state so that volume operations can map between POSIX semantics and B2 API calls.
class B2Item: FSItem {

    // MARK: - B2 Identity

    /// Full B2 key path (e.g., "photos/vacation/img.jpg").
    let b2Path: String

    /// The B2 bucket this item belongs to.
    let bucketId: String

    /// B2 file ID — `nil` for inferred directories that have no corresponding B2 object.
    var b2FileId: String?

    /// Cached B2 metadata from list operations.
    var b2FileInfo: B2FileInfo?

    // MARK: - Local State

    /// Non-nil when the file's content has been downloaded to the local cache.
    var localCacheURL: URL?

    /// Non-nil when the file has uncommitted writes in a staging file.
    var localStagingURL: URL?

    /// `true` when local writes are pending upload to B2.
    var isDirty: Bool

    // MARK: - Filesystem Metadata

    /// Whether this item represents a directory.
    let isDirectory: Bool

    /// File size in bytes (0 for directories).
    var contentLength: Int64

    /// Modification timestamp — sourced from B2's `uploadTimestamp` or
    /// `Date()` for newly created items.
    var modificationTime: Date

    /// Unique numeric identifier used for FSItem.Attributes.fileID.
    let itemIdentifier: FSItem.Identifier

    /// The item name as an `FSFileName` (last path component).
    let itemName: FSFileName

    // MARK: - Initializers

    /// Creates a new B2Item with minimal metadata.
    ///
    /// - Parameters:
    ///   - name: The filename component for this item.
    ///   - identifier: Unique numeric identifier (inode-like).
    ///   - b2Path: Full B2 key path.
    ///   - bucketId: The bucket containing this item.
    ///   - isDirectory: Whether this item is a directory.
    init(name: FSFileName, identifier: FSItem.Identifier,
         b2Path: String, bucketId: String, isDirectory: Bool) {
        self.itemName = name
        self.itemIdentifier = identifier
        self.b2Path = b2Path
        self.bucketId = bucketId
        self.isDirectory = isDirectory
        self.isDirty = false
        self.contentLength = 0
        self.modificationTime = Date()
        super.init()
    }

    // MARK: - Factory

    /// Creates a `B2Item` from a `B2FileInfo` returned by B2 list operations.
    ///
    /// - Parameters:
    ///   - info: The B2 file metadata.
    ///   - identifier: Unique numeric identifier to assign.
    /// - Returns: A fully populated `B2Item`.
    static func fromB2FileInfo(_ info: B2FileInfo,
                               identifier: FSItem.Identifier) -> B2Item {
        let isDir = info.action == "folder" || info.fileName.hasSuffix("/")

        // Extract the last path component, stripping trailing "/" for directories.
        let trimmedPath = info.fileName.hasSuffix("/")
            ? String(info.fileName.dropLast())
            : info.fileName
        let nameString = trimmedPath.split(separator: "/").last.map(String.init) ?? trimmedPath
        let name = FSFileName(string: nameString)

        let item = B2Item(
            name: name,
            identifier: identifier,
            b2Path: info.fileName,
            bucketId: info.bucketId,
            isDirectory: isDir
        )
        item.b2FileId = info.fileId
        item.b2FileInfo = info
        item.contentLength = info.contentLength.value
        item.modificationTime = Date(
            timeIntervalSince1970: Double(info.uploadTimestamp.value) / 1000.0
        )
        return item
    }
}
