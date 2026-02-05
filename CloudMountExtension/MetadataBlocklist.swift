//
//  MetadataBlocklist.swift
//  CloudMountExtension
//
//  Identifies macOS metadata paths that should be silently suppressed
//  to avoid polluting B2 storage with Finder noise.
//

import Foundation

/// Static blocklist for macOS metadata path suppression.
///
/// Checked on every create, write, lookup, and enumerate to avoid
/// generating B2 API calls for system metadata files that Finder
/// constantly creates on mounted volumes.
struct MetadataBlocklist: Sendable {

    /// Exact file/directory names that are always suppressed.
    private static let blockedNames: Set<String> = [
        ".DS_Store",
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd",
        ".TemporaryItems",
        ".VolumeIcon.icns",
        ".com.apple.timemachine.donotpresent",
    ]

    /// Returns `true` if a single filename component should be suppressed.
    ///
    /// Matches against:
    /// - Exact names in the blocklist (`.DS_Store`, `.Spotlight-V100`, etc.)
    /// - AppleDouble resource fork files that start with `"._"`
    ///
    /// - Parameter name: A single filename component (not a full path).
    /// - Returns: Whether this name should be silently ignored.
    static func isSuppressed(_ name: String) -> Bool {
        // Exact match against blocklist
        if blockedNames.contains(name) { return true }
        // AppleDouble resource fork files start with "._"
        if name.hasPrefix("._") { return true }
        return false
    }

    /// Returns `true` if any component of a B2 key path is suppressed.
    ///
    /// - Parameter path: A full B2 key path (e.g., "photos/.DS_Store").
    /// - Returns: Whether this path should be silently ignored.
    static func isSuppressedPath(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.contains { isSuppressed(String($0)) }
    }
}
