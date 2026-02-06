//
//  MountMonitor.swift
//  CloudMount
//
//  Real-time mount status monitoring via NSWorkspace notifications.
//  Observes didMountNotification / didUnmountNotification to track
//  which configured mount points are currently active.
//

import CloudMountKit
import Foundation
import os

/// Monitors mount/unmount events via NSWorkspace and tracks which
/// configured mount points are currently mounted.
@MainActor
final class MountMonitor: ObservableObject {

    // MARK: - Published State

    /// Currently mounted paths that match our configured mount points.
    @Published var mountedPaths: Set<String> = []

    // MARK: - Private

    private let logger = Logger(subsystem: "com.cloudmount.app", category: "MountMonitor")
    private var observers: [NSObjectProtocol] = []

    // MARK: - Monitoring

    /// Start monitoring for mount/unmount events.
    ///
    /// Performs an initial refresh of mount status for the given configs,
    /// then registers for NSWorkspace notifications.
    ///
    /// - Parameter configs: The mount configurations to monitor.
    func startMonitoring(configs: [MountConfiguration]) {
        // Initial scan for currently mounted volumes
        refreshMountStatus(configs: configs)

        let center = NSWorkspace.shared.notificationCenter

        // Observe mount events
        let mountObs = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                let path = volumeURL.path
                self.logger.info("Volume mounted: \(path, privacy: .public)")
                self.mountedPaths.insert(path)
            }
        }
        observers.append(mountObs)

        // Observe unmount events
        let unmountObs = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                let path = volumeURL.path
                self.logger.info("Volume unmounted: \(path, privacy: .public)")
                self.mountedPaths.remove(path)
            }
        }
        observers.append(unmountObs)

        logger.info("Mount monitoring started for \(configs.count) configurations")
    }

    /// Stop monitoring for mount/unmount events and remove all observers.
    func stopMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        logger.info("Mount monitoring stopped")
    }

    /// Check if a specific configuration's mount point is currently mounted.
    ///
    /// - Parameter config: The mount configuration to check.
    /// - Returns: `true` if the mount point is in the `mountedPaths` set.
    func isMounted(_ config: MountConfiguration) -> Bool {
        mountedPaths.contains(config.mountPoint)
    }

    /// Refresh mount status by checking which configured mount points are
    /// actually mounted (not just empty directories).
    ///
    /// Uses `stat()` to compare device IDs of the mount point and its parent
    /// directory — if they differ, it's a real mount point.
    ///
    /// - Parameter configs: The mount configurations to check.
    func refreshMountStatus(configs: [MountConfiguration]) {
        var mounted = Set<String>()

        for config in configs {
            if isMountPoint(config.mountPoint) {
                mounted.insert(config.mountPoint)
                logger.info("Detected existing mount: \(config.mountPoint, privacy: .public)")
            }
        }

        mountedPaths = mounted
        logger.info("Mount status refreshed: \(mounted.count) volumes mounted")
    }

    // MARK: - Private Helpers

    /// Check if a path is an actual mount point by comparing device IDs
    /// with the parent directory.
    ///
    /// - Parameter path: The path to check.
    /// - Returns: `true` if the path is a mount point (different device from parent).
    private func isMountPoint(_ path: String) -> Bool {
        var mountStat = stat()
        var parentStat = stat()

        let parentPath = (path as NSString).deletingLastPathComponent

        guard stat(path, &mountStat) == 0 else { return false }
        guard stat(parentPath, &parentStat) == 0 else { return false }

        // If device IDs differ, the path is a mount point
        return mountStat.st_dev != parentStat.st_dev
    }
}
