//
//  B2Client.swift
//  CloudMountKit
//
//  High-level B2 client actor providing convenient domain operations
//  with transparent token refresh, metadata caching, and file caching.
//

import Foundation
import CryptoKit

/// High-level B2 client that wires together HTTP, auth, and caching layers.
///
/// Provides convenient operations (list, download, upload, delete, copy,
/// create folder, rename) with:
/// - Transparent token refresh on 401 auth expiry
/// - In-memory metadata caching with TTL
/// - On-disk file caching with LRU eviction
/// - Automatic pagination for directory listings
public actor B2Client {

    // MARK: - Dependencies

    private let http: B2HTTPClient
    private let authManager: B2AuthManager
    private let metadataCache: MetadataCache
    private let fileCache: FileCache

    // MARK: - Auth Context

    /// Snapshot of auth state for passing to operations.
    private struct AuthContext {
        let token: String
        let apiUrl: String
        let downloadUrl: String
        let accountId: String
    }

    // MARK: - Init

    /// Create a B2Client by authenticating with the given credentials.
    ///
    /// Immediately authenticates; throws if authentication fails.
    ///
    /// - Parameters:
    ///   - keyId: The application key ID.
    ///   - applicationKey: The application key secret.
    ///   - cacheSettings: Cache behavior configuration.
    public init(
        keyId: String,
        applicationKey: String,
        cacheSettings: CacheSettings = CacheSettings()
    ) async throws {
        self.http = B2HTTPClient()
        self.authManager = try await B2AuthManager(
            keyId: keyId,
            applicationKey: applicationKey,
            http: http
        )
        self.metadataCache = MetadataCache(
            ttl: TimeInterval(cacheSettings.metadataTTLSeconds)
        )
        self.fileCache = FileCache(
            maxSizeBytes: cacheSettings.maxFileCacheSizeBytes
        )
    }

    // MARK: - Bucket Operations

    /// List all accessible buckets.
    public func listBuckets() async throws -> [B2BucketInfo] {
        try await withAutoRefresh { auth in
            let response = try await self.http.listBuckets(
                apiUrl: auth.apiUrl,
                authToken: auth.token,
                accountId: auth.accountId
            )
            return response.buckets
        }
    }

    // MARK: - Directory Listing

    /// List directory contents with caching and automatic pagination.
    ///
    /// Checks the metadata cache first. On miss, fetches all pages from B2
    /// and caches the result.
    ///
    /// - Parameters:
    ///   - bucketId: The bucket to list.
    ///   - path: Directory path prefix (e.g. "photos/" or "").
    /// - Returns: All file entries at the given path.
    public func listDirectory(bucketId: String, path: String) async throws -> [B2FileInfo] {
        // Check cache first
        if let cached = await metadataCache.getDirectoryListing(bucketId: bucketId, path: path) {
            return cached
        }

        // Fetch with pagination
        var allFiles: [B2FileInfo] = []
        var nextFileName: String? = nil

        repeat {
            let startName = nextFileName  // Capture current value for Sendable closure
            let response: B2ListFilesResponse = try await withAutoRefresh { auth in
                try await self.http.listFileNames(
                    apiUrl: auth.apiUrl,
                    authToken: auth.token,
                    bucketId: bucketId,
                    prefix: path,
                    delimiter: "/",
                    startFileName: startName,
                    maxFileCount: 1000
                )
            }
            allFiles.append(contentsOf: response.files)
            nextFileName = response.nextFileName
        } while nextFileName != nil

        // Cache the result
        await metadataCache.cacheDirectoryListing(
            bucketId: bucketId,
            path: path,
            entries: allFiles
        )

        return allFiles
    }

    // MARK: - Download

    /// Download a file, with optional byte range.
    ///
    /// Full downloads (no range) are cached on disk. Range requests
    /// always hit the server.
    ///
    /// - Parameters:
    ///   - bucketName: The bucket name.
    ///   - fileName: The full file path within the bucket.
    ///   - range: Optional byte range for partial downloads.
    /// - Returns: The file data.
    public func downloadFile(
        bucketName: String,
        fileName: String,
        range: ClosedRange<Int64>? = nil
    ) async throws -> Data {
        // Check file cache for full downloads
        if range == nil, let cached = await fileCache.get(bucketName: bucketName, fileName: fileName) {
            return cached
        }

        // Build range header string if needed
        let rangeHeader: String? = range.map { "bytes=\($0.lowerBound)-\($0.upperBound)" }

        let (data, _) = try await withAutoRefresh { auth in
            try await self.http.downloadFileByName(
                downloadUrl: auth.downloadUrl,
                authToken: auth.token,
                bucketName: bucketName,
                fileName: fileName,
                range: rangeHeader
            )
        }

        // Cache full downloads on disk
        if range == nil {
            await fileCache.store(bucketName: bucketName, fileName: fileName, data: data)
        }

        return data
    }

    // MARK: - Upload

    /// Upload a file to B2. Calculates SHA-1 checksum automatically.
    ///
    /// Uses the two-step upload process (get upload URL, then upload).
    /// On upload failure, retries once with a fresh upload URL.
    ///
    /// - Parameters:
    ///   - bucketId: The bucket to upload to.
    ///   - bucketName: The bucket name (for cache invalidation).
    ///   - fileName: The file path within the bucket.
    ///   - data: The file content.
    ///   - contentType: MIME type (default: "b2/x-auto" for auto-detection).
    ///   - lastModifiedMillis: Optional source file timestamp.
    /// - Returns: Metadata about the uploaded file.
    @discardableResult
    public func uploadFile(
        bucketId: String,
        bucketName: String,
        fileName: String,
        data: Data,
        contentType: String = "b2/x-auto",
        lastModifiedMillis: Int64? = nil
    ) async throws -> B2UploadFileResponse {
        // Calculate SHA-1 (B2 requires SHA-1, not SHA-256)
        let sha1 = Insecure.SHA1.hash(data: data)
        let sha1Hex = sha1.compactMap { String(format: "%02x", $0) }.joined()

        // Get upload URL
        let uploadUrl = try await withAutoRefresh { auth in
            try await self.http.getUploadUrl(
                apiUrl: auth.apiUrl,
                authToken: auth.token,
                bucketId: bucketId
            )
        }

        // Upload file (uses upload-specific auth token, NOT account token)
        let response: B2UploadFileResponse
        do {
            response = try await http.uploadFile(
                uploadUrl: uploadUrl.uploadUrl,
                uploadAuthToken: uploadUrl.authorizationToken,
                fileName: fileName,
                contentType: contentType,
                data: data,
                sha1Hex: sha1Hex,
                lastModifiedMillis: lastModifiedMillis
            )
        } catch let error as B2Error where error.isRetryable {
            // On upload failure (401, 408, 500+), get a NEW upload URL and retry
            let newUploadUrl = try await withAutoRefresh { auth in
                try await self.http.getUploadUrl(
                    apiUrl: auth.apiUrl,
                    authToken: auth.token,
                    bucketId: bucketId
                )
            }
            response = try await http.uploadFile(
                uploadUrl: newUploadUrl.uploadUrl,
                uploadAuthToken: newUploadUrl.authorizationToken,
                fileName: fileName,
                contentType: contentType,
                data: data,
                sha1Hex: sha1Hex,
                lastModifiedMillis: lastModifiedMillis
            )
        }

        // Invalidate caches
        await invalidateCachesForPath(bucketId: bucketId, fileName: fileName)
        await fileCache.remove(bucketName: bucketName, fileName: fileName)

        return response
    }

    // MARK: - Delete

    /// Delete a file version.
    ///
    /// Both fileName AND fileId are required by the B2 API.
    ///
    /// - Parameters:
    ///   - bucketId: The bucket ID (for cache invalidation).
    ///   - fileName: The file name.
    ///   - fileId: The specific file version ID.
    public func deleteFile(bucketId: String, fileName: String, fileId: String) async throws {
        _ = try await withAutoRefresh { auth in
            try await self.http.deleteFileVersion(
                apiUrl: auth.apiUrl,
                authToken: auth.token,
                fileName: fileName,
                fileId: fileId
            )
        }

        // Invalidate caches
        await invalidateCachesForPath(bucketId: bucketId, fileName: fileName)
    }

    // MARK: - Copy

    /// Copy a file server-side (max 5 GB).
    ///
    /// - Parameters:
    ///   - sourceFileId: The file ID of the source file.
    ///   - destinationFileName: The name for the copy.
    ///   - destinationBucketId: Target bucket (nil = same bucket).
    /// - Returns: Metadata about the copied file.
    @discardableResult
    public func copyFile(
        sourceFileId: String,
        destinationFileName: String,
        destinationBucketId: String? = nil
    ) async throws -> B2CopyFileResponse {
        let response = try await withAutoRefresh { auth in
            try await self.http.copyFile(
                apiUrl: auth.apiUrl,
                authToken: auth.token,
                sourceFileId: sourceFileId,
                destinationFileName: destinationFileName,
                destinationBucketId: destinationBucketId
            )
        }

        // Invalidate destination caches
        if let destBucketId = destinationBucketId {
            await invalidateCachesForPath(bucketId: destBucketId, fileName: destinationFileName)
        }

        return response
    }

    // MARK: - Create Folder

    /// Create a folder (zero-byte upload with directory content type).
    ///
    /// B2 doesn't have native folders — this creates a zero-byte marker file
    /// with the path ending in "/" and content type "application/x-directory".
    ///
    /// - Parameters:
    ///   - bucketId: The bucket to create the folder in.
    ///   - bucketName: The bucket name (for cache invalidation).
    ///   - folderPath: The folder path (will be appended with "/" if missing).
    public func createFolder(
        bucketId: String,
        bucketName: String,
        folderPath: String
    ) async throws {
        let path = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"

        // Get upload URL
        let uploadUrl = try await withAutoRefresh { auth in
            try await self.http.getUploadUrl(
                apiUrl: auth.apiUrl,
                authToken: auth.token,
                bucketId: bucketId
            )
        }

        // Upload zero-byte file with directory content type
        _ = try await http.uploadFile(
            uploadUrl: uploadUrl.uploadUrl,
            uploadAuthToken: uploadUrl.authorizationToken,
            fileName: path,
            contentType: "application/x-directory",
            data: Data(),
            sha1Hex: B2Constants.emptySHA1,
            lastModifiedMillis: nil
        )

        // Invalidate parent directory cache
        await invalidateCachesForPath(bucketId: bucketId, fileName: path)
    }

    // MARK: - Rename

    /// Rename a file (server-side copy + delete).
    ///
    /// Only works for files <= 5 GB (B2 copy limit).
    ///
    /// - Parameters:
    ///   - bucketId: The bucket containing the file.
    ///   - sourceFileName: The current file name.
    ///   - sourceFileId: The current file version ID.
    ///   - destinationFileName: The new file name.
    public func rename(
        bucketId: String,
        sourceFileName: String,
        sourceFileId: String,
        destinationFileName: String
    ) async throws {
        // Copy to new name
        _ = try await copyFile(
            sourceFileId: sourceFileId,
            destinationFileName: destinationFileName,
            destinationBucketId: bucketId
        )

        // Delete original
        try await deleteFile(
            bucketId: bucketId,
            fileName: sourceFileName,
            fileId: sourceFileId
        )

        // Invalidate caches for both paths
        await invalidateCachesForPath(bucketId: bucketId, fileName: sourceFileName)
        await invalidateCachesForPath(bucketId: bucketId, fileName: destinationFileName)
    }

    // MARK: - Private Helpers

    /// Execute an operation with automatic token refresh on auth expiry.
    ///
    /// Tries the operation once. If it throws a ``B2Error`` with
    /// ``B2Error/isAuthExpired`` == `true`, refreshes the token and retries once.
    private func withAutoRefresh<T>(
        _ operation: @Sendable (AuthContext) async throws -> T
    ) async throws -> T {
        let auth = await currentAuth()
        do {
            return try await operation(auth)
        } catch let error as B2Error where error.isAuthExpired {
            try await authManager.refresh()
            let newAuth = await currentAuth()
            return try await operation(newAuth)
        }
    }

    /// Snapshot the current auth state from the auth manager.
    private func currentAuth() async -> AuthContext {
        await AuthContext(
            token: authManager.authToken,
            apiUrl: authManager.apiUrl,
            downloadUrl: authManager.downloadUrl,
            accountId: authManager.accountId
        )
    }

    /// Invalidate metadata cache for a file path and its parent directory.
    private func invalidateCachesForPath(bucketId: String, fileName: String) async {
        await metadataCache.invalidate(bucketId: bucketId, path: fileName)
    }
}
