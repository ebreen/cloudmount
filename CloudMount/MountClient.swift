//
//  MountClient.swift
//  CloudMount
//
//  Process-based mount/unmount operations for B2 buckets via FSKit.
//  Uses /sbin/mount -F for mounting and diskutil/umount for unmounting.
//

import CloudMountKit
import Foundation
import os

/// Errors that can occur during mount/unmount operations.
enum MountError: LocalizedError {
    /// Mount command returned non-zero exit code.
    case mountFailed(String)
    /// Unmount command returned non-zero exit code.
    case unmountFailed(String)
    /// Could not create the mount point directory.
    case mountPointCreationFailed
    /// stderr indicates the FSKit extension is not enabled.
    case extensionNotEnabled

    var errorDescription: String? {
        switch self {
        case .mountFailed(let msg):
            return "Mount failed: \(msg)"
        case .unmountFailed(let msg):
            return "Unmount failed: \(msg)"
        case .mountPointCreationFailed:
            return "Could not create mount point directory"
        case .extensionNotEnabled:
            return "FSKit extension not enabled in System Settings"
        }
    }
}

/// Wraps Foundation `Process` to invoke `/sbin/mount -F` and `umount`/`diskutil`
/// for mounting and unmounting B2 buckets via the FSKit extension.
@MainActor
final class MountClient {

    private let logger = Logger(subsystem: "com.cloudmount.app", category: "MountClient")

    // MARK: - Mount

    /// Mount a B2 bucket using the FSKit extension.
    ///
    /// Runs: `mount -F -t b2 b2://bucketName?accountId=UUID /Volumes/bucketName`
    ///
    /// - Parameter config: The mount configuration describing the bucket and mount point.
    /// - Throws: `MountError` on failure.
    func mount(_ config: MountConfiguration) async throws {
        let mountPoint = config.mountPoint

        logger.info("Mounting \(config.bucketName, privacy: .public) at \(mountPoint, privacy: .public)")

        // Note: /Volumes/ is root-owned. The mount -F command creates the mount point
        // internally with appropriate privileges — we don't need to pre-create it.

        // Build the b2:// resource URL using URLComponents for proper encoding
        var components = URLComponents()
        components.scheme = "b2"
        components.host = config.bucketName
        components.queryItems = [
            URLQueryItem(name: "accountId", value: config.accountId.uuidString),
        ]

        guard let resourceURL = components.string else {
            logger.error("Failed to construct resource URL for \(config.bucketName, privacy: .public)")
            throw MountError.mountFailed("Could not construct resource URL")
        }

        let result = try await runProcess(
            "/sbin/mount",
            arguments: ["-F", "-t", "b2", resourceURL, mountPoint]
        )

        if result.exitCode != 0 {
            // Check for extension-not-enabled error patterns
            let stderrLower = result.stderr.lowercased()
            if stderrLower.contains("not found") || stderrLower.contains("extensionkit")
                || stderrLower.contains("invalid file system") || stderrLower.contains("unknown file system") {
                logger.error("FSKit extension not enabled — mount stderr: \(result.stderr, privacy: .public)")
                throw MountError.extensionNotEnabled
            }
            logger.error("Mount failed with exit code \(result.exitCode): \(result.stderr, privacy: .public)")
            throw MountError.mountFailed(result.stderr)
        }

        logger.info("Successfully mounted \(config.bucketName, privacy: .public)")
    }

    // MARK: - Unmount

    /// Unmount a mounted B2 bucket.
    ///
    /// Tries `diskutil unmount` first (more graceful), then falls back to `umount`.
    ///
    /// - Parameter config: The mount configuration describing the mount point.
    /// - Throws: `MountError.unmountFailed` if both diskutil and umount fail.
    func unmount(_ config: MountConfiguration) async throws {
        let mountPoint = config.mountPoint
        logger.info("Unmounting \(config.bucketName, privacy: .public) at \(mountPoint, privacy: .public)")

        // Try diskutil first (more graceful, handles busy volumes better)
        let diskutilResult = try await runProcess(
            "/usr/sbin/diskutil",
            arguments: ["unmount", mountPoint]
        )

        if diskutilResult.exitCode == 0 {
            logger.info("Successfully unmounted \(config.bucketName, privacy: .public) via diskutil")
            cleanupMountPoint(mountPoint)
            return
        }

        logger.info("diskutil unmount failed, falling back to umount: \(diskutilResult.stderr, privacy: .public)")

        // Fallback to umount
        let umountResult = try await runProcess(
            "/sbin/umount",
            arguments: [mountPoint]
        )

        if umountResult.exitCode != 0 {
            logger.error("Unmount failed with exit code \(umountResult.exitCode): \(umountResult.stderr, privacy: .public)")
            throw MountError.unmountFailed(umountResult.stderr)
        }

        logger.info("Successfully unmounted \(config.bucketName, privacy: .public) via umount")
        cleanupMountPoint(mountPoint)
    }

    // MARK: - Private Helpers

    /// Clean up mount point directory if it's empty (best-effort).
    private func cleanupMountPoint(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Run a process asynchronously using `terminationHandler` to avoid blocking.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the executable.
    ///   - arguments: Command-line arguments.
    /// - Returns: A tuple of (exitCode, stderr).
    private func runProcess(
        _ path: String,
        arguments: [String]
    ) async throws -> (exitCode: Int32, stderr: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments

            let stderrPipe = Pipe()
            let stdoutPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = stdoutPipe  // Discard stdout

            process.terminationHandler = { _ in
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(
                    returning: (process.terminationStatus, stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                )
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
