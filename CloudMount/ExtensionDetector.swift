//
//  ExtensionDetector.swift
//  CloudMount
//
//  FSKit extension enablement detection and System Settings deep link.
//  Uses a heuristic probe (dry-run mount) since there is no public API
//  to query FSKit extension enablement status.
//

import AppKit
import Foundation
import os

/// Detects whether the CloudMount FSKit extension is enabled in System Settings.
///
/// Since Apple provides no public API for querying extension enablement,
/// this uses a heuristic: attempt a dry-run mount and inspect the error output.
@MainActor
final class ExtensionDetector: ObservableObject {

    // MARK: - Types

    /// The detected status of the FSKit extension.
    enum ExtensionStatus {
        /// Haven't checked yet.
        case unknown
        /// Probe in progress.
        case checking
        /// Extension is enabled and available.
        case enabled
        /// Extension not found / not enabled.
        case disabled
    }

    // MARK: - Published State

    /// Current extension enablement status.
    @Published var status: ExtensionStatus = .unknown

    // MARK: - Private

    private let logger = Logger(subsystem: "com.cloudmount.app", category: "ExtensionDetector")

    // MARK: - Public API

    /// Check whether the FSKit extension is enabled by attempting a dry-run probe.
    ///
    /// Runs: `mount -d -F -t b2 b2://probe /tmp/cloudmount-probe`
    /// The `-d` flag performs a dry run (everything except the actual mount syscall).
    /// If stderr contains "not found" or "extensionKit", the extension is not enabled.
    func checkExtensionStatus() async {
        status = .checking
        logger.info("Checking FSKit extension status via dry-run probe")

        do {
            let result = try await runProcess(
                "/sbin/mount",
                arguments: ["-d", "-F", "-t", "b2", "b2://probe", "/tmp/cloudmount-probe"]
            )

            if result.stderr.contains("not found") || result.stderr.contains("extensionKit") {
                status = .disabled
                logger.info("FSKit extension is disabled — stderr: \(result.stderr, privacy: .public)")
            } else {
                // Dry-run succeeded or failed for reasons other than missing extension
                status = .enabled
                logger.info("FSKit extension is enabled")
            }
        } catch {
            status = .unknown
            logger.error("Extension probe failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Open System Settings to the Login Items & Extensions pane
    /// where the user can enable the FSKit extension.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
            logger.info("Opened System Settings to Extensions pane")
        }
    }

    /// Whether the extension needs setup (not confirmed as enabled).
    var needsSetup: Bool {
        status == .disabled || status == .unknown
    }

    // MARK: - Private Helpers

    /// Run a process asynchronously using `terminationHandler` to avoid blocking.
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
