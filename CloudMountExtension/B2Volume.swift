//
//  B2Volume.swift
//  CloudMountExtension
//
//  FSVolume subclass representing a mounted B2 bucket.
//  Implements the full set of volume operation protocols with
//  stubs for operations that Plans 03 and 04 will fill in.
//

import FSKit
import CloudMountKit
import os

/// FSVolume subclass for a Backblaze B2 bucket mounted as a local volume.
///
/// Conforms to:
/// - `FSVolume.Operations`: mount/unmount, activate/deactivate, lookup, enumerate, create, remove, rename, attributes
/// - `FSVolume.PathConfOperations`: pathconf limits
/// - `FSVolume.OpenCloseOperations`: open/close lifecycle per item
/// - `FSVolume.ReadWriteOperations`: read/write file data
///
/// **Concurrency note:** FSKit calls volume methods from its own dispatch queue.
/// B2Client is an actor. Use `Task {}` inside methods that need async B2Client calls.
/// The volume itself is NOT an actor (it's an NSObject subclass via FSVolume).
class B2Volume: FSVolume,
                FSVolume.Operations,
                FSVolume.PathConfOperations,
                FSVolume.OpenCloseOperations,
                FSVolume.ReadWriteOperations {

    // MARK: - Properties

    /// The B2 API client (actor, thread-safe).
    let b2Client: B2Client

    /// The B2 bucket ID for this volume.
    let bucketId: String

    /// The B2 bucket name for this volume.
    let bucketName: String

    /// Manages local temporary staging files for the write-on-close pattern.
    private let stagingManager: StagingManager

    private let logger = Logger(subsystem: "com.cloudmount.extension", category: "Volume")

    /// B2 path → cached B2Item — maps B2 key paths to their filesystem items.
    private var itemCache: [String: B2Item] = [:]

    /// Monotonically increasing item IDs (1 reserved for root).
    private var nextItemId: UInt64 = 2

    /// The root directory item for this volume.
    let rootItem: B2Item

    // MARK: - Init

    init(
        volumeID: FSVolume.Identifier,
        volumeName: FSFileName,
        b2Client: B2Client,
        bucketId: String,
        bucketName: String,
        mountId: String
    ) {
        self.b2Client = b2Client
        self.bucketId = bucketId
        self.bucketName = bucketName
        self.stagingManager = StagingManager(mountId: mountId)

        self.rootItem = B2Item(
            name: FSFileName(string: bucketName),
            identifier: .rootDirectory,
            b2Path: "",
            bucketId: bucketId,
            isDirectory: true
        )

        super.init(volumeID: volumeID, volumeName: volumeName)

        itemCache[""] = rootItem
    }

    // MARK: - Item ID Allocation

    /// Generate a unique item ID for a new filesystem item.
    func allocateItemId() -> FSItem.Identifier {
        let id = nextItemId
        nextItemId += 1
        return FSItem.Identifier(rawValue: id)!
    }

    // MARK: - Item Cache Helpers

    /// Look up a cached B2Item by its B2 key path.
    func cachedItem(for b2Path: String) -> B2Item? {
        return itemCache[b2Path]
    }

    /// Store a B2Item in the cache keyed by its B2 path.
    func cacheItem(_ item: B2Item) {
        itemCache[item.b2Path] = item
    }

    /// Remove a cached B2Item by its B2 key path.
    func removeCachedItem(for b2Path: String) {
        itemCache.removeValue(forKey: b2Path)
    }

    // MARK: - FSVolume.Operations — Mount / Unmount / Activate / Deactivate

    func mount(
        options: FSTaskOptions,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        logger.info("Volume mount: \(self.bucketName, privacy: .public)")
        replyHandler(nil)
    }

    func unmount(
        replyHandler: @escaping () -> Void
    ) {
        logger.info("Volume unmount: \(self.bucketName, privacy: .public)")
        let staging = self.stagingManager
        Task { await staging.cleanupAll() }
        replyHandler()
    }

    func activate(
        options: FSTaskOptions,
        replyHandler: @escaping (FSItem?, (any Error)?) -> Void
    ) {
        logger.info("Volume activate: \(self.bucketName, privacy: .public)")
        replyHandler(rootItem, nil)
    }

    func deactivate(
        options: FSDeactivateOptions,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        logger.info("Volume deactivate: \(self.bucketName, privacy: .public)")
        replyHandler(nil)
    }

    // MARK: - Volume Statistics

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "b2fs")
        result.blockSize = 4096
        result.ioSize = 131072  // 128 KB optimal I/O size for cloud storage
        // Report 10 TB of virtual space (cloud storage is effectively unlimited)
        let totalBytes: UInt64 = 10 * 1024 * 1024 * 1024 * 1024
        result.totalBytes = totalBytes
        result.availableBytes = totalBytes
        result.freeBytes = totalBytes
        result.usedBytes = 0
        result.totalFiles = UInt64.max
        result.freeFiles = UInt64.max - 1
        return result
    }

    // MARK: - Supported Capabilities

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsFastStatFS = true
        caps.supports2TBFiles = true
        caps.supports64BitObjectIDs = true
        caps.doesNotSupportImmutableFiles = true
        caps.doesNotSupportSettingFilePermissions = true
        caps.doesNotSupportRootTimes = true
        caps.caseFormat = .sensitive
        return caps
    }

    // MARK: - PathConf Operations

    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 1024 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { 5 * 1024 * 1024 * 1024 * 1024 } // 5 TB (B2 max)

    // MARK: - OpenClose Operations

    var isOpenCloseInhibited: Bool { false }

    func openItem(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        // TODO: Plan 04 implementation — download file to staging on open
        logger.debug("openItem stub called")
        replyHandler(nil)
    }

    func closeItem(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        // TODO: Plan 04 implementation — upload staged file to B2 on close if dirty
        logger.debug("closeItem stub called")
        replyHandler(nil)
    }

    // MARK: - ReadWrite Operations

    func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer,
        replyHandler: @escaping (Int, (any Error)?) -> Void
    ) {
        // TODO: Plan 04 implementation — read from staging file
        logger.debug("read stub called")
        replyHandler(0, fs_errorForPOSIXError(ENOSYS))
    }

    func write(
        contents: Data,
        to item: FSItem,
        at offset: off_t,
        replyHandler: @escaping (Int, (any Error)?) -> Void
    ) {
        // TODO: Plan 04 implementation — write to staging file
        logger.debug("write stub called")
        replyHandler(0, fs_errorForPOSIXError(ENOSYS))
    }

    // MARK: - Synchronize

    func synchronize(
        flags: FSSyncFlags,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        // TODO: Plan 03/04 — flush dirty items to B2
        logger.debug("synchronize stub called")
        replyHandler(nil)
    }

    // MARK: - Lookup

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        // TODO: Plan 03 implementation — lookup item in B2 directory listing
        logger.debug("lookupItem stub called")
        replyHandler(nil, nil, fs_errorForPOSIXError(ENOENT))
    }

    // MARK: - Enumerate Directory

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        replyHandler: @escaping (FSDirectoryVerifier, (any Error)?) -> Void
    ) {
        // TODO: Plan 03 implementation — list B2 directory contents
        logger.debug("enumerateDirectory stub called")
        replyHandler(.initial, fs_errorForPOSIXError(ENOSYS))
    }

    // MARK: - Create Item

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes: FSItem.SetAttributesRequest,
        replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        // TODO: Plan 03 implementation — create file/directory in B2
        logger.debug("createItem stub called")
        replyHandler(nil, nil, fs_errorForPOSIXError(ENOSYS))
    }

    // MARK: - Create Symbolic Link

    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName,
        replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        // B2 doesn't support symlinks
        logger.debug("createSymbolicLink: not supported")
        replyHandler(nil, nil, fs_errorForPOSIXError(ENOTSUP))
    }

    // MARK: - Create Link

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        // B2 doesn't support hard links
        logger.debug("createLink: not supported")
        replyHandler(nil, fs_errorForPOSIXError(ENOTSUP))
    }

    // MARK: - Remove Item

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        // TODO: Plan 03 implementation — delete file from B2
        logger.debug("removeItem stub called")
        replyHandler(fs_errorForPOSIXError(ENOSYS))
    }

    // MARK: - Rename Item

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        replyHandler: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        // TODO: Plan 03 implementation — rename via B2 copy + delete
        logger.debug("renameItem stub called")
        replyHandler(nil, fs_errorForPOSIXError(ENOSYS))
    }

    // MARK: - Read Symbolic Link

    func readSymbolicLink(
        _ item: FSItem,
        replyHandler: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        // B2 doesn't support symlinks
        logger.debug("readSymbolicLink: not supported")
        replyHandler(nil, fs_errorForPOSIXError(ENOTSUP))
    }

    // MARK: - Get Attributes

    func getAttributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem,
        replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        // TODO: Plan 03 implementation — return item attributes from cache/B2
        guard let b2Item = item as? B2Item else {
            replyHandler(nil, fs_errorForPOSIXError(EINVAL))
            return
        }

        let attrs = FSItem.Attributes()
        attrs.uid = getuid()
        attrs.gid = getgid()
        attrs.type = b2Item.isDirectory ? .directory : .file
        attrs.mode = b2Item.isDirectory ? 0o755 : 0o644
        attrs.linkCount = b2Item.isDirectory ? 2 : 1
        attrs.size = UInt64(b2Item.contentLength)
        attrs.allocSize = UInt64(b2Item.contentLength)
        attrs.fileID = b2Item.itemIdentifier

        let ts = b2Item.modificationTime.timeIntervalSince1970
        let sec = Int(ts)
        let nsec = Int((ts - Double(sec)) * 1_000_000_000)
        let timespec = timespec(tv_sec: sec, tv_nsec: nsec)
        attrs.modifyTime = timespec
        attrs.changeTime = timespec
        attrs.accessTime = timespec
        attrs.birthTime = timespec

        replyHandler(attrs, nil)
    }

    // MARK: - Set Attributes

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem,
        replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        // TODO: Plan 03 implementation — limited attribute setting for B2
        // For now, acknowledge the request and return current attributes
        guard let b2Item = item as? B2Item else {
            replyHandler(nil, fs_errorForPOSIXError(EINVAL))
            return
        }

        // Update size if requested (for truncation during file creation)
        if newAttributes.isValid(.size) {
            b2Item.contentLength = Int64(newAttributes.size)
        }

        // Return current attributes
        getAttributes(FSItem.GetAttributesRequest(), of: item, replyHandler: replyHandler)
    }

    // MARK: - Reclaim Item

    func reclaimItem(
        _ item: FSItem,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        // Clean up cached references when FSKit releases an item
        if let b2Item = item as? B2Item {
            removeCachedItem(for: b2Item.b2Path)
            logger.debug("Reclaimed item: \(b2Item.b2Path, privacy: .public)")
        }
        replyHandler(nil)
    }
}
