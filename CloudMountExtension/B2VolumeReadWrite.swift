//
//  B2VolumeReadWrite.swift
//  CloudMountExtension
//
//  Extension on B2Volume implementing OpenCloseOperations and
//  ReadWriteOperations. Handles the download-on-open, write-to-staging,
//  upload-on-close pattern for file I/O against B2 cloud storage.
//

import FSKit
import CloudMountKit
import os

// MARK: - OpenClose Operations

extension B2Volume {

    // MARK: - Open Item

    func openItemImpl(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let b2Item = item as? B2Item else {
            replyHandler(fs_errorForPOSIXError(EINVAL))
            return
        }

        // Directories don't need download
        if b2Item.isDirectory {
            replyHandler(nil)
            return
        }

        // Suppressed metadata items: no-op
        let nameString = b2Item.itemName.string ?? ""
        if MetadataBlocklist.isSuppressed(nameString) {
            replyHandler(nil)
            return
        }

        // Already has a staging file: reuse local cache
        if b2Item.localStagingURL != nil {
            replyHandler(nil)
            return
        }

        // Empty file (newly created, no B2 content): create empty staging file
        if b2Item.b2FileId == nil && b2Item.contentLength == 0 {
            let reply = UncheckedSendableBox(replyHandler)
            let itemBox = UncheckedSendableBox(b2Item)
            let staging = self.stagingManager
            let itemPath = b2Item.b2Path

            Task {
                do {
                    let stagingURL = try await staging.createStagingFile(for: itemPath)
                    itemBox.value.localStagingURL = stagingURL
                    reply.value(nil)
                } catch {
                    reply.value(fs_errorForPOSIXError(EIO))
                }
            }
            return
        }

        // Download from B2 to staging
        let reply = UncheckedSendableBox(replyHandler)
        let itemBox = UncheckedSendableBox(b2Item)
        let client = self.b2Client
        let bucketName = self.bucketName
        let staging = self.stagingManager
        let itemPath = b2Item.b2Path

        Task {
            do {
                let data = try await client.downloadFile(
                    bucketName: bucketName,
                    fileName: itemPath
                )

                let stagingURL = try await staging.createStagingFile(
                    for: itemPath,
                    initialData: data
                )
                itemBox.value.localStagingURL = stagingURL
                reply.value(nil)
            } catch {
                reply.value(fs_errorForPOSIXError(EIO))
            }
        }
    }

    // MARK: - Close Item

    func closeItemImpl(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let b2Item = item as? B2Item else {
            replyHandler(fs_errorForPOSIXError(EINVAL))
            return
        }

        // If modes is not empty, the file still has open references — don't upload yet
        if !modes.isEmpty {
            replyHandler(nil)
            return
        }

        // Not dirty: nothing to upload
        if !b2Item.isDirty {
            replyHandler(nil)
            return
        }

        // Suppressed metadata: clear dirty flag, no upload
        let nameString = b2Item.itemName.string ?? ""
        if MetadataBlocklist.isSuppressed(nameString) {
            b2Item.isDirty = false
            replyHandler(nil)
            return
        }

        // Upload dirty file to B2
        let reply = UncheckedSendableBox(replyHandler)
        let itemBox = UncheckedSendableBox(b2Item)
        let client = self.b2Client
        let bucket = self.bucketId
        let bucketNameVal = self.bucketName
        let staging = self.stagingManager
        let itemPath = b2Item.b2Path
        let logRef = self.logger

        Task {
            do {
                // Read staged file data
                let data: Data
                if let stagingURL = itemBox.value.localStagingURL {
                    data = try Data(contentsOf: stagingURL)
                } else {
                    // Fallback: read from staging manager
                    let fileSize = Int(itemBox.value.contentLength)
                    data = try await staging.readFrom(
                        b2Path: itemPath,
                        offset: 0,
                        length: max(fileSize, 0)
                    )
                }

                // Upload to B2
                let response = try await client.uploadFile(
                    bucketId: bucket,
                    bucketName: bucketNameVal,
                    fileName: itemPath,
                    data: data
                )

                // Update B2Item metadata from upload response
                itemBox.value.b2FileId = response.fileId
                itemBox.value.contentLength = response.contentLength.value
                itemBox.value.modificationTime = Date(
                    timeIntervalSince1970: Double(response.uploadTimestamp.value) / 1000.0
                )
                itemBox.value.isDirty = false

                logRef.info("closeItem: uploaded \(itemPath, privacy: .public) (\(data.count) bytes)")
                reply.value(nil)
            } catch {
                // Upload failure: keep isDirty=true and staging file for retry
                logRef.error("closeItem: upload failed for \(itemPath, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                reply.value(fs_errorForPOSIXError(EIO))
            }
        }
    }
}

// MARK: - ReadWrite Operations

extension B2Volume {

    // MARK: - Read

    func readImpl(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer,
        replyHandler: @escaping (Int, (any Error)?) -> Void
    ) {
        guard let b2Item = item as? B2Item else {
            replyHandler(0, fs_errorForPOSIXError(EINVAL))
            return
        }

        let reply = UncheckedSendableBox(replyHandler)
        let bufferBox = UncheckedSendableBox(buffer)
        let staging = self.stagingManager
        let itemPath = b2Item.b2Path

        Task {
            do {
                let data = try await staging.readFrom(
                    b2Path: itemPath,
                    offset: Int64(offset),
                    length: length
                )

                let bytesRead = data.count
                if bytesRead > 0 {
                    bufferBox.value.withUnsafeMutableBytes { rawBuffer in
                        let copyCount = min(bytesRead, rawBuffer.count)
                        data.withUnsafeBytes { srcBuffer in
                            rawBuffer.baseAddress!.copyMemory(
                                from: srcBuffer.baseAddress!,
                                byteCount: copyCount
                            )
                        }
                    }
                }

                reply.value(bytesRead, nil)
            } catch {
                reply.value(0, fs_errorForPOSIXError(EIO))
            }
        }
    }

    // MARK: - Write

    func writeImpl(
        contents: Data,
        to item: FSItem,
        at offset: off_t,
        replyHandler: @escaping (Int, (any Error)?) -> Void
    ) {
        guard let b2Item = item as? B2Item else {
            replyHandler(0, fs_errorForPOSIXError(EINVAL))
            return
        }

        // Suppressed metadata: pretend to write
        let nameString = b2Item.itemName.string ?? ""
        if MetadataBlocklist.isSuppressed(nameString) {
            replyHandler(contents.count, nil)
            return
        }

        let reply = UncheckedSendableBox(replyHandler)
        let itemBox = UncheckedSendableBox(b2Item)
        let staging = self.stagingManager
        let itemPath = b2Item.b2Path
        let writeData = contents
        let writeOffset = Int64(offset)

        Task {
            do {
                try await staging.writeTo(
                    b2Path: itemPath,
                    data: writeData,
                    offset: writeOffset
                )

                // Mark dirty and update content length
                let newEnd = writeOffset + Int64(writeData.count)
                if newEnd > itemBox.value.contentLength {
                    itemBox.value.contentLength = newEnd
                }
                itemBox.value.isDirty = true

                reply.value(writeData.count, nil)
            } catch {
                reply.value(0, fs_errorForPOSIXError(EIO))
            }
        }
    }
}
