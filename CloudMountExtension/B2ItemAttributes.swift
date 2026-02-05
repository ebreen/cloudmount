//
//  B2ItemAttributes.swift
//  CloudMountExtension
//
//  Helper for creating FSItem.Attributes from B2Item metadata.
//

import FSKit

/// Extension on B2Volume providing attribute mapping from B2 metadata to FSKit attributes.
extension B2Volume {

    /// Creates an `FSItem.Attributes` populated from a `B2Item`'s cached metadata.
    ///
    /// Maps B2 file/directory properties to POSIX-compatible attributes that
    /// FSKit returns to the kernel. Directories get mode 0755, files get 0644.
    ///
    /// - Parameter item: The B2Item to build attributes from.
    /// - Returns: A fully populated `FSItem.Attributes`.
    func makeAttributes(for item: B2Item) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()

        if item.isDirectory {
            attrs.type = .directory
            attrs.mode = 0o755
            attrs.linkCount = 2
            attrs.size = 0
            attrs.allocSize = 0
        } else {
            attrs.type = .file
            attrs.mode = 0o644
            attrs.linkCount = 1
            attrs.size = UInt64(item.contentLength)
            attrs.allocSize = UInt64(item.contentLength)
        }

        attrs.uid = getuid()
        attrs.gid = getgid()
        attrs.fileID = item.itemIdentifier

        let modTime = item.modificationTime
        let seconds = Int(modTime.timeIntervalSince1970)
        let nanos = Int((modTime.timeIntervalSince1970 - Double(seconds)) * 1_000_000_000)
        let ts = timespec(tv_sec: seconds, tv_nsec: nanos)
        attrs.modifyTime = ts
        attrs.birthTime = ts
        attrs.accessTime = ts
        attrs.changeTime = ts

        return attrs
    }

    /// Extracts the filename string from an `FSFileName`.
    ///
    /// FSFileName wraps a byte buffer; this converts it to a Swift String.
    /// Returns `nil` if the name cannot be represented as UTF-8.
    ///
    /// - Parameter name: The FSFileName to extract.
    /// - Returns: The filename as a String, or nil if invalid.
    func extractFileName(_ name: FSFileName) -> String? {
        return name.string
    }
}
