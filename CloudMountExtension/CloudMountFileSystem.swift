//
//  CloudMountFileSystem.swift
//  CloudMountExtension
//
//  FSUnaryFileSystem subclass that handles the probe/load/unload lifecycle
//  for b2:// URL resources. Creates B2Volume instances for each mount.
//

import FSKit
import CloudMountKit
import os

/// Filesystem delegate that handles resource lifecycle for b2:// URLs.
///
/// FSKit calls `probeResource` to check if a resource is recognized, then
/// `loadResource` to create a volume for it. The URL format is:
/// `b2://bucketName?accountId=<UUID>` where the UUID references a B2Account
/// in SharedDefaults/CredentialStore.
class CloudMountFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    private let logger = Logger(subsystem: "com.cloudmount.extension", category: "FileSystem")

    // MARK: - Probe

    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        guard let urlResource = resource as? FSGenericURLResource else {
            logger.info("Probe: resource is not FSGenericURLResource — not recognized")
            replyHandler(.notRecognized, nil)
            return
        }

        let url = urlResource.url
        logger.info("Probe: checking b2:// resource \(url.absoluteString, privacy: .public)")

        guard url.scheme?.lowercased() == "b2" else {
            logger.info("Probe: scheme is not b2 — not recognized")
            replyHandler(.notRecognized, nil)
            return
        }

        // Recognized b2:// URL — return usable with a random container ID
        // (URL-based filesystems don't have durable container UUIDs)
        let containerID = FSContainerIdentifier(uuid: UUID())
        let name = url.host ?? "b2"
        replyHandler(.usable(name: name, containerID: containerID), nil)
    }

    // MARK: - Load

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        guard let urlResource = resource as? FSGenericURLResource else {
            logger.error("Load: resource is not FSGenericURLResource")
            replyHandler(nil, fs_errorForPOSIXError(EINVAL))
            return
        }

        let url = urlResource.url

        // Extract bucket name from URL host
        guard let bucketName = url.host, !bucketName.isEmpty else {
            logger.error("Load: missing bucket name in URL host")
            replyHandler(nil, fs_errorForPOSIXError(EINVAL))
            return
        }

        // Extract accountId UUID from query parameter
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let accountIdString = components?.queryItems?.first(where: { $0.name == "accountId" })?.value,
              let accountId = UUID(uuidString: accountIdString) else {
            logger.error("Load: missing or invalid accountId query parameter")
            replyHandler(nil, fs_errorForPOSIXError(EINVAL))
            return
        }

        logger.info("Load: bucket=\(bucketName, privacy: .public) accountId=\(accountId.uuidString, privacy: .public)")

        // Look up mount configuration from SharedDefaults
        let mountConfigs = SharedDefaults.shared.loadMountConfigurations()
        guard let mountConfig = mountConfigs.first(where: {
            $0.bucketName == bucketName && $0.accountId == accountId
        }) else {
            logger.error("Load: no mount configuration found for bucket \(bucketName, privacy: .public)")
            replyHandler(nil, fs_errorForPOSIXError(ENOENT))
            return
        }

        // Load credentials from CredentialStore
        guard let creds = CredentialStore.loadCredentials(id: accountId) else {
            logger.error("Load: no credentials found for account \(accountId.uuidString, privacy: .public)")
            replyHandler(nil, fs_errorForPOSIXError(EACCES))
            return
        }

        // Bridge to async context for B2Client initialization.
        // The replyHandler from FSKit is safe to call from any context.
        // Bridge to async context for B2Client initialization.
        // Use a Sendable wrapper for the reply handler to satisfy Swift 6.
        let reply = UncheckedSendableBox(replyHandler)
        let log = UncheckedSendableBox(self.logger)
        let mountBucketId = mountConfig.bucketId
        let mountBucketName = bucketName
        let mountId = mountConfig.id.uuidString
        let mountConfigId = mountConfig.id
        let cacheSettings = mountConfig.cacheSettings
        let keyId = creds.keyId
        let appKey = creds.applicationKey

        Task {
            do {
                let client = try await B2Client(
                    keyId: keyId,
                    applicationKey: appKey,
                    cacheSettings: cacheSettings
                )

                let volumeID = FSVolume.Identifier(uuid: mountConfigId)
                let volumeName = FSFileName(string: mountBucketName)

                let volume = B2Volume(
                    volumeID: volumeID,
                    volumeName: volumeName,
                    b2Client: client,
                    bucketId: mountBucketId,
                    bucketName: mountBucketName,
                    mountId: mountId
                )

                log.value.info("Load: volume created for bucket \(mountBucketName, privacy: .public)")
                reply.value(volume, nil)
            } catch {
                log.value.error("Load: failed to create B2Client — \(error.localizedDescription, privacy: .public)")
                reply.value(nil, error)
            }
        }
    }

    // MARK: - Unload

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        logger.info("Unload: resource unloaded (cleanup in B2Volume.unmount)")
        replyHandler(nil)
    }

    // MARK: - Did Finish Loading

    func didFinishLoading() {
        logger.info("CloudMountFileSystem: finished loading")
    }
}

// MARK: - Sendable Wrapper

/// Wraps a non-Sendable value for safe transfer across isolation boundaries.
///
/// Used for FSKit reply handlers and Logger instances that are known to be
/// safe to use from async contexts but don't conform to Sendable.
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
