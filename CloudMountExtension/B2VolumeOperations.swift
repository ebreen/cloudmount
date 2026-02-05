//
//  B2VolumeOperations.swift
//  CloudMountExtension
//
//  Extension on B2Volume implementing FSVolume.Operations methods.
//  Replaces stubs from Plan 02 with real B2-backed implementations.
//
//  Read-only operations: lookupItem, enumerateDirectory, getAttributes, setAttributes, reclaimItem
//  Mutation operations: createItem, removeItem, renameItem
//

import FSKit
import CloudMountKit
import os

// MARK: - Read-Only Operations

extension B2Volume {

    // MARK: - Lookup

    func lookupItemImpl(
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard let parentItem = directory as? B2Item else {
            replyHandler(nil, nil, fs_errorForPOSIXError(EINVAL))
            return
        }

        guard let nameString = extractFileName(name) else {
            replyHandler(nil, nil, fs_errorForPOSIXError(EINVAL))
            return
        }

        // Suppress macOS metadata — return ENOENT without B2 API call
        if MetadataBlocklist.isSuppressed(nameString) {
            replyHandler(nil, nil, fs_errorForPOSIXError(ENOENT))
            return
        }

        // Build the full B2 path for this name in the parent directory
        let parentPath = parentItem.b2Path
        let childPath = parentPath.isEmpty ? nameString : parentPath + nameString

        // Check item cache first (try both file and directory paths)
        if let cached = cachedItem(for: childPath) {
            replyHandler(cached, cached.itemName, nil)
            return
        }
        if let cached = cachedItem(for: childPath + "/") {
            replyHandler(cached, cached.itemName, nil)
            return
        }

        // Fall back to B2 listing
        let reply = UncheckedSendableBox(replyHandler)
        let volume = UncheckedSendableBox(self)
        let client = self.b2Client
        let bucket = self.bucketId
        let dirPath = parentPath

        // Capture Sendable locals before Task to satisfy Swift 6
        let searchName = nameString

        Task {
            do {
                let files = try await client.listDirectory(bucketId: bucket, path: dirPath)

                // Find the matching file or directory
                for info in files {
                    let entryName = volume.value.nameFromB2FileInfo(info)
                    if entryName == searchName {
                        let item = B2Item.fromB2FileInfo(info, identifier: volume.value.allocateItemId())
                        volume.value.cacheItem(item)
                        reply.value(item, item.itemName, nil)
                        return
                    }
                }

                // Not found
                reply.value(nil, nil, fs_errorForPOSIXError(ENOENT))
            } catch {
                reply.value(nil, nil, fs_errorForPOSIXError(EIO))
            }
        }
    }

    // MARK: - Enumerate Directory

    func enumerateDirectoryImpl(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        replyHandler: @escaping (FSDirectoryVerifier, (any Error)?) -> Void
    ) {
        guard let parentItem = directory as? B2Item else {
            replyHandler(.initial, fs_errorForPOSIXError(EINVAL))
            return
        }

        let reply = UncheckedSendableBox(replyHandler)
        let packerBox = UncheckedSendableBox(packer)
        let volume = UncheckedSendableBox(self)
        let client = self.b2Client
        let bucket = self.bucketId
        let dirPath = parentItem.b2Path
        let startIndex = Int(cookie.rawValue)

        Task {
            do {
                let files = try await client.listDirectory(bucketId: bucket, path: dirPath)

                // Filter suppressed metadata entries
                let filtered = files.filter { info in
                    let entryName = volume.value.nameFromB2FileInfo(info)
                    return !MetadataBlocklist.isSuppressed(entryName)
                }

                let entries = filtered

                for i in startIndex..<entries.count {
                    let info = entries[i]
                    let item = B2Item.fromB2FileInfo(info, identifier: volume.value.allocateItemId())
                    volume.value.cacheItem(item)

                    let attrs = volume.value.makeAttributes(for: item)
                    let nextCookie = FSDirectoryCookie(rawValue: UInt64(i + 1))
                    let itemType: FSItem.ItemType = item.isDirectory ? .directory : .file

                    let packed = packerBox.value.packEntry(
                        name: item.itemName,
                        itemType: itemType,
                        itemID: item.itemIdentifier,
                        nextCookie: nextCookie,
                        attributes: attrs
                    )

                    if !packed {
                        // Packer is full — return current verifier for next call
                        reply.value(.initial, nil)
                        return
                    }
                }

                // All entries packed
                reply.value(.initial, nil)
            } catch {
                reply.value(.initial, fs_errorForPOSIXError(EIO))
            }
        }
    }

    // MARK: - Get Attributes

    func getAttributesImpl(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem,
        replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        guard let b2Item = item as? B2Item else {
            replyHandler(nil, fs_errorForPOSIXError(EINVAL))
            return
        }

        let attrs = makeAttributes(for: b2Item)
        replyHandler(attrs, nil)
    }

    // MARK: - Set Attributes

    func setAttributesImpl(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem,
        replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        guard let b2Item = item as? B2Item else {
            replyHandler(nil, fs_errorForPOSIXError(EINVAL))
            return
        }

        // Update size if requested (for truncation during file creation)
        if newAttributes.isValid(.size) {
            b2Item.contentLength = Int64(newAttributes.size)
        }

        // B2 doesn't support setting most attributes — return current attributes
        let attrs = makeAttributes(for: b2Item)
        replyHandler(attrs, nil)
    }

    // MARK: - Reclaim

    func reclaimItemImpl(
        _ item: FSItem,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        if let b2Item = item as? B2Item {
            removeCachedItem(for: b2Item.b2Path)
            logger.debug("Reclaimed item: \(b2Item.b2Path, privacy: .public)")
        }
        replyHandler(nil)
    }

    // MARK: - Helpers

    /// Extract the simple filename from a B2FileInfo entry.
    ///
    /// Strips the parent directory prefix and trailing "/" for directories.
    func nameFromB2FileInfo(_ info: B2FileInfo) -> String {
        let path = info.fileName.hasSuffix("/")
            ? String(info.fileName.dropLast())
            : info.fileName
        return path.split(separator: "/").last.map(String.init) ?? path
    }
}

// MARK: - Mutation Operations

extension B2Volume {

    // MARK: - Create Item

    func createItemImpl(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes: FSItem.SetAttributesRequest,
        replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard let parentItem = directory as? B2Item else {
            replyHandler(nil, nil, fs_errorForPOSIXError(EINVAL))
            return
        }

        guard let nameString = extractFileName(name) else {
            replyHandler(nil, nil, fs_errorForPOSIXError(EINVAL))
            return
        }

        // Suppress macOS metadata — return fake item without B2 API call
        if MetadataBlocklist.isSuppressed(nameString) {
            let fakePath = parentItem.b2Path.isEmpty ? nameString : parentItem.b2Path + nameString
            let fakeItem = B2Item(
                name: name,
                identifier: allocateItemId(),
                b2Path: fakePath,
                bucketId: bucketId,
                isDirectory: type == .directory
            )
            cacheItem(fakeItem)
            replyHandler(fakeItem, fakeItem.itemName, nil)
            return
        }

        let parentPath = parentItem.b2Path

        if type == .directory {
            // Directories: upload B2 folder marker
            let dirPath = parentPath.isEmpty ? nameString + "/" : parentPath + nameString + "/"

            let reply = UncheckedSendableBox(replyHandler)
            let volume = UncheckedSendableBox(self)
            let nameBox = UncheckedSendableBox(name)
            let client = self.b2Client
            let bucket = self.bucketId
            let bucketNameVal = self.bucketName

            Task {
                do {
                    try await client.createFolder(
                        bucketId: bucket,
                        bucketName: bucketNameVal,
                        folderPath: dirPath
                    )

                    let item = B2Item(
                        name: nameBox.value,
                        identifier: volume.value.allocateItemId(),
                        b2Path: dirPath,
                        bucketId: bucket,
                        isDirectory: true
                    )
                    volume.value.cacheItem(item)
                    reply.value(item, item.itemName, nil)
                } catch {
                    reply.value(nil, nil, fs_errorForPOSIXError(EIO))
                }
            }
        } else {
            // Files: create local staging placeholder, mark dirty
            let filePath = parentPath.isEmpty ? nameString : parentPath + nameString

            let item = B2Item(
                name: name,
                identifier: allocateItemId(),
                b2Path: filePath,
                bucketId: bucketId,
                isDirectory: false
            )
            item.isDirty = true
            cacheItem(item)

            // Create staging file asynchronously
            let reply = UncheckedSendableBox(replyHandler)
            let itemBox = UncheckedSendableBox(item)
            let staging = self.stagingManager
            let itemPath = filePath

            Task {
                do {
                    let stagingURL = try await staging.createStagingFile(for: itemPath)
                    itemBox.value.localStagingURL = stagingURL
                    reply.value(itemBox.value, itemBox.value.itemName, nil)
                } catch {
                    reply.value(nil, nil, fs_errorForPOSIXError(EIO))
                }
            }
        }
    }

    // MARK: - Remove Item

    func removeItemImpl(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let b2Item = item as? B2Item else {
            replyHandler(fs_errorForPOSIXError(EINVAL))
            return
        }

        let nameString = extractFileName(name)

        // Suppress macOS metadata — remove from cache without B2 API call
        if let n = nameString, MetadataBlocklist.isSuppressed(n) {
            removeCachedItem(for: b2Item.b2Path)
            replyHandler(nil)
            return
        }

        // Need a B2 file ID to delete from B2
        guard let fileId = b2Item.b2FileId else {
            // Locally created file that was never uploaded — just clean up
            removeCachedItem(for: b2Item.b2Path)
            let staging = self.stagingManager
            let itemPath = b2Item.b2Path
            Task { await staging.removeStagingFile(for: itemPath) }
            replyHandler(nil)
            return
        }

        let reply = UncheckedSendableBox(replyHandler)
        let volume = UncheckedSendableBox(self)
        let client = self.b2Client
        let bucket = self.bucketId
        let fileName = b2Item.b2Path
        let staging = self.stagingManager

        Task {
            do {
                try await client.deleteFile(
                    bucketId: bucket,
                    fileName: fileName,
                    fileId: fileId
                )

                // Clean up staging
                await staging.removeStagingFile(for: fileName)

                // Remove from cache
                volume.value.removeCachedItem(for: fileName)

                reply.value(nil)
            } catch {
                reply.value(fs_errorForPOSIXError(EIO))
            }
        }
    }

    // MARK: - Rename Item

    func renameItemImpl(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        replyHandler: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        guard let b2Item = item as? B2Item,
              let destDir = destinationDirectory as? B2Item else {
            replyHandler(nil, fs_errorForPOSIXError(EINVAL))
            return
        }

        guard let destNameString = extractFileName(destinationName) else {
            replyHandler(nil, fs_errorForPOSIXError(EINVAL))
            return
        }

        // Directories: B2 has no native rename for dirs — return ENOTSUP
        if b2Item.isDirectory {
            replyHandler(nil, fs_errorForPOSIXError(ENOTSUP))
            return
        }

        let destPath = destDir.b2Path.isEmpty ? destNameString : destDir.b2Path + destNameString
        let oldPath = b2Item.b2Path

        // Files without b2FileId (newly created, not yet uploaded): just update local cache
        guard let fileId = b2Item.b2FileId else {
            let volume = UncheckedSendableBox(self)
            volume.value.removeCachedItem(for: oldPath)
            b2Item.b2Path = destPath
            volume.value.cacheItem(b2Item)
            replyHandler(destinationName, nil)
            return
        }

        // Files with b2FileId: server-side copy + delete via B2
        let reply = UncheckedSendableBox(replyHandler)
        let volume = UncheckedSendableBox(self)
        let itemBox = UncheckedSendableBox(b2Item)
        let destNameBox = UncheckedSendableBox(destinationName)
        let client = self.b2Client
        let bucket = self.bucketId

        Task {
            do {
                try await client.rename(
                    bucketId: bucket,
                    sourceFileName: oldPath,
                    sourceFileId: fileId,
                    destinationFileName: destPath
                )

                // Update local cache
                volume.value.removeCachedItem(for: oldPath)
                itemBox.value.b2Path = destPath
                itemBox.value.b2FileId = nil  // Invalidate old fileId — new copy has different ID
                volume.value.cacheItem(itemBox.value)

                reply.value(destNameBox.value, nil)
            } catch {
                reply.value(nil, fs_errorForPOSIXError(EIO))
            }
        }
    }
}
