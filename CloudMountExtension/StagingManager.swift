//
//  StagingManager.swift
//  CloudMountExtension
//
//  Manages local temporary files for the download-on-open /
//  write-on-close pattern used by the FSKit volume.
//

import Foundation
import CryptoKit

/// Thread-safe manager for local staging files.
///
/// Each mounted volume gets its own `StagingManager` instance keyed by
/// a mount identifier. Files are staged into a deterministic local path
/// derived from the B2 key, allowing reads and writes to happen against
/// the local filesystem while B2 uploads happen asynchronously on close.
actor StagingManager {

    // MARK: - Properties

    /// Base directory for all staging files belonging to this mount.
    private let stagingDirectory: URL

    /// Maps B2 path → local staging file URL for currently active files.
    private var activeFiles: [String: URL] = [:]

    // MARK: - Initialization

    /// Creates a staging manager for a specific mount.
    ///
    /// - Parameter mountId: A unique identifier for this mount session
    ///   (e.g., bucket ID or UUID). Used to isolate staging files between
    ///   different mounts.
    init(mountId: String) {
        let cacheDir = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        self.stagingDirectory = cacheDir
            .appendingPathComponent("CloudMount", isDirectory: true)
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(mountId, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Public API

    /// Returns the deterministic staging URL for a B2 path.
    ///
    /// Uses a SHA-256 hash of the B2 path to produce a safe, fixed-length
    /// filename that avoids filesystem path issues with long or special-character
    /// B2 keys.
    ///
    /// - Parameter b2Path: The full B2 key path.
    /// - Returns: A local file URL in the staging directory.
    func stagingURL(for b2Path: String) -> URL {
        if let existing = activeFiles[b2Path] {
            return existing
        }
        let url = makeURL(for: b2Path)
        activeFiles[b2Path] = url
        return url
    }

    /// Creates a new staging file with optional initial content.
    ///
    /// - Parameters:
    ///   - b2Path: The full B2 key path.
    ///   - initialData: Optional data to write as initial content.
    /// - Returns: The local file URL where the staging file was created.
    /// - Throws: File I/O errors if the file cannot be created.
    @discardableResult
    func createStagingFile(for b2Path: String,
                           initialData: Data? = nil) throws -> URL {
        let url = makeURL(for: b2Path)
        activeFiles[b2Path] = url

        if let data = initialData {
            try data.write(to: url)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    /// Writes data at a specific offset in the staging file.
    ///
    /// - Parameters:
    ///   - b2Path: The full B2 key path.
    ///   - data: The bytes to write.
    ///   - offset: The byte offset to begin writing at.
    /// - Throws: If the staging file does not exist or seek/write fails.
    func writeTo(b2Path: String, data: Data, offset: Int64) throws {
        let url = stagingURL(for: b2Path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StagingError.fileNotFound(b2Path)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        handle.write(data)
    }

    /// Reads data from a specific offset in the staging file.
    ///
    /// - Parameters:
    ///   - b2Path: The full B2 key path.
    ///   - offset: The byte offset to begin reading from.
    ///   - length: The maximum number of bytes to read.
    /// - Returns: The bytes read (may be fewer than `length` at EOF).
    /// - Throws: If the staging file does not exist or seek/read fails.
    func readFrom(b2Path: String, offset: Int64, length: Int) throws -> Data {
        let url = stagingURL(for: b2Path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StagingError.fileNotFound(b2Path)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return handle.readData(ofLength: length)
    }

    /// Removes the staging file and its tracking entry.
    ///
    /// - Parameter b2Path: The full B2 key path.
    func removeStagingFile(for b2Path: String) {
        guard let url = activeFiles.removeValue(forKey: b2Path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Returns whether a staging file currently exists for the given path.
    ///
    /// - Parameter b2Path: The full B2 key path.
    /// - Returns: `true` if the staging file is tracked and exists on disk.
    func hasStagingFile(for b2Path: String) -> Bool {
        guard let url = activeFiles[b2Path] else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Removes all staging files and the mount-specific staging directory.
    func cleanupAll() {
        activeFiles.removeAll()
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    // MARK: - Private Helpers

    /// Generates a deterministic local URL for a B2 path using SHA-256.
    private func makeURL(for b2Path: String) -> URL {
        let hash = SHA256.hash(data: Data(b2Path.utf8))
        let hex = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        return stagingDirectory.appendingPathComponent(hex)
    }
}

// MARK: - Errors

/// Errors specific to staging file operations.
enum StagingError: Error, CustomStringConvertible {
    /// The staging file for the given B2 path does not exist on disk.
    case fileNotFound(String)

    var description: String {
        switch self {
        case .fileNotFound(let path):
            return "Staging file not found for B2 path: \(path)"
        }
    }
}
