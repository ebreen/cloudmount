//
//  B2Types.swift
//  CloudMountKit
//
//  Codable models for all B2 Native API v4 request/response types.
//  Handles B2-specific quirks like numeric fields returned as strings.
//

import Foundation

// MARK: - FlexibleInt64

/// Handles B2's inconsistent numeric encoding: some fields arrive as Int64,
/// others as String-encoded numbers, and occasionally null (defaults to 0).
public struct FlexibleInt64: Codable, Hashable, Sendable {
    public let value: Int64

    public init(_ value: Int64) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int64.self) {
            value = intValue
        } else if let stringValue = try? container.decode(String.self),
                  let parsed = Int64(stringValue) {
            value = parsed
        } else if container.decodeNil() {
            value = 0
        } else {
            throw DecodingError.typeMismatch(
                Int64.self,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected Int64, String-encoded Int64, or null"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension FlexibleInt64: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) {
        self.value = value
    }
}

extension FlexibleInt64: Comparable {
    public static func < (lhs: FlexibleInt64, rhs: FlexibleInt64) -> Bool {
        lhs.value < rhs.value
    }
}

// MARK: - Constants

/// B2 API constants used across the HTTP client.
public enum B2Constants {
    /// User-Agent header value sent with every request.
    public static let userAgent = "CloudMount/2.0 (macOS; Swift)"

    /// Base URL for the B2 authorize_account endpoint.
    public static let apiBaseUrl = "https://api.backblazeb2.com"

    /// B2 Native API version prefix.
    public static let apiVersion = "b2api/v4"

    /// SHA1 hex string for an empty (zero-byte) file.
    public static let emptySHA1 = "da39a3ee5e6b4b0d3255bfef95601890afd80709"
}

// MARK: - Authorize Account Response

/// Top-level response from `b2_authorize_account`.
public struct B2AuthResponse: Codable, Sendable {
    public let accountId: String
    public let authorizationToken: String
    public let apiInfo: B2ApiInfo
    public let applicationKeyExpirationTimestamp: FlexibleInt64?

    public init(
        accountId: String,
        authorizationToken: String,
        apiInfo: B2ApiInfo,
        applicationKeyExpirationTimestamp: FlexibleInt64? = nil
    ) {
        self.accountId = accountId
        self.authorizationToken = authorizationToken
        self.apiInfo = apiInfo
        self.applicationKeyExpirationTimestamp = applicationKeyExpirationTimestamp
    }
}

/// Groups API information by suite (storageApi, groupsApi, etc.).
public struct B2ApiInfo: Codable, Sendable {
    public let storageApi: B2StorageApiInfo

    public init(storageApi: B2StorageApiInfo) {
        self.storageApi = storageApi
    }
}

/// Storage API configuration returned from authorization.
public struct B2StorageApiInfo: Codable, Sendable {
    public let absoluteMinimumPartSize: Int64
    public let apiUrl: String
    public let downloadUrl: String
    public let recommendedPartSize: Int64
    public let s3ApiUrl: String
    public let allowed: B2Allowed?
    /// Present when the key is restricted to a specific bucket.
    public let bucketId: String?
    public let bucketName: String?
    public let namePrefix: String?

    public init(
        absoluteMinimumPartSize: Int64,
        apiUrl: String,
        downloadUrl: String,
        recommendedPartSize: Int64,
        s3ApiUrl: String,
        allowed: B2Allowed? = nil,
        bucketId: String? = nil,
        bucketName: String? = nil,
        namePrefix: String? = nil
    ) {
        self.absoluteMinimumPartSize = absoluteMinimumPartSize
        self.apiUrl = apiUrl
        self.downloadUrl = downloadUrl
        self.recommendedPartSize = recommendedPartSize
        self.s3ApiUrl = s3ApiUrl
        self.allowed = allowed
        self.bucketId = bucketId
        self.bucketName = bucketName
        self.namePrefix = namePrefix
    }
}

/// Capabilities and restrictions for the authorized key.
public struct B2Allowed: Codable, Sendable {
    public let capabilities: [String]
    public let buckets: [B2AllowedBucket]?
    public let namePrefix: String?

    public init(
        capabilities: [String],
        buckets: [B2AllowedBucket]? = nil,
        namePrefix: String? = nil
    ) {
        self.capabilities = capabilities
        self.buckets = buckets
        self.namePrefix = namePrefix
    }
}

/// A bucket the key is allowed to access.
public struct B2AllowedBucket: Codable, Sendable {
    public let id: String
    public let name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

// MARK: - File Info

/// A single file (or folder) as returned by list operations.
public struct B2FileInfo: Codable, Sendable {
    public let accountId: String?
    public let action: String
    public let bucketId: String
    public let contentLength: FlexibleInt64
    public let contentSha1: String?
    public let contentType: String?
    public let fileId: String?
    public let fileInfo: [String: String]?
    public let fileName: String
    public let uploadTimestamp: FlexibleInt64

    public init(
        accountId: String? = nil,
        action: String,
        bucketId: String,
        contentLength: FlexibleInt64,
        contentSha1: String? = nil,
        contentType: String? = nil,
        fileId: String? = nil,
        fileInfo: [String: String]? = nil,
        fileName: String,
        uploadTimestamp: FlexibleInt64
    ) {
        self.accountId = accountId
        self.action = action
        self.bucketId = bucketId
        self.contentLength = contentLength
        self.contentSha1 = contentSha1
        self.contentType = contentType
        self.fileId = fileId
        self.fileInfo = fileInfo
        self.fileName = fileName
        self.uploadTimestamp = uploadTimestamp
    }
}

// MARK: - List Files Response

/// Response from `b2_list_file_names`.
public struct B2ListFilesResponse: Codable, Sendable {
    public let files: [B2FileInfo]
    /// `nil` when there are no more files to list.
    public let nextFileName: String?

    public init(files: [B2FileInfo], nextFileName: String? = nil) {
        self.files = files
        self.nextFileName = nextFileName
    }
}

// MARK: - Upload URL

/// Response from `b2_get_upload_url`.
public struct B2UploadUrlResponse: Codable, Sendable {
    public let bucketId: String
    public let uploadUrl: String
    public let authorizationToken: String

    public init(bucketId: String, uploadUrl: String, authorizationToken: String) {
        self.bucketId = bucketId
        self.uploadUrl = uploadUrl
        self.authorizationToken = authorizationToken
    }
}

// MARK: - Upload File Response

/// Response from `b2_upload_file`.
public struct B2UploadFileResponse: Codable, Sendable {
    public let accountId: String
    public let action: String
    public let bucketId: String
    public let contentLength: FlexibleInt64
    public let contentSha1: String
    public let contentType: String
    public let fileId: String
    public let fileInfo: [String: String]?
    public let fileName: String
    public let uploadTimestamp: FlexibleInt64

    public init(
        accountId: String,
        action: String,
        bucketId: String,
        contentLength: FlexibleInt64,
        contentSha1: String,
        contentType: String,
        fileId: String,
        fileInfo: [String: String]? = nil,
        fileName: String,
        uploadTimestamp: FlexibleInt64
    ) {
        self.accountId = accountId
        self.action = action
        self.bucketId = bucketId
        self.contentLength = contentLength
        self.contentSha1 = contentSha1
        self.contentType = contentType
        self.fileId = fileId
        self.fileInfo = fileInfo
        self.fileName = fileName
        self.uploadTimestamp = uploadTimestamp
    }
}

// MARK: - Copy File Response

/// Response from `b2_copy_file`.
public struct B2CopyFileResponse: Codable, Sendable {
    public let accountId: String
    public let action: String
    public let bucketId: String
    public let contentLength: FlexibleInt64
    public let contentSha1: String?
    public let contentType: String
    public let fileId: String
    public let fileInfo: [String: String]?
    public let fileName: String
    public let uploadTimestamp: FlexibleInt64

    public init(
        accountId: String,
        action: String,
        bucketId: String,
        contentLength: FlexibleInt64,
        contentSha1: String? = nil,
        contentType: String,
        fileId: String,
        fileInfo: [String: String]? = nil,
        fileName: String,
        uploadTimestamp: FlexibleInt64
    ) {
        self.accountId = accountId
        self.action = action
        self.bucketId = bucketId
        self.contentLength = contentLength
        self.contentSha1 = contentSha1
        self.contentType = contentType
        self.fileId = fileId
        self.fileInfo = fileInfo
        self.fileName = fileName
        self.uploadTimestamp = uploadTimestamp
    }
}

// MARK: - Delete File Response

/// Response from `b2_delete_file_version`.
public struct B2DeleteFileResponse: Codable, Sendable {
    public let fileId: String
    public let fileName: String

    public init(fileId: String, fileName: String) {
        self.fileId = fileId
        self.fileName = fileName
    }
}

// MARK: - Bucket Types

/// Response from `b2_list_buckets`.
public struct B2ListBucketsResponse: Codable, Sendable {
    public let buckets: [B2BucketInfo]

    public init(buckets: [B2BucketInfo]) {
        self.buckets = buckets
    }
}

/// A single bucket as returned by list/create operations.
public struct B2BucketInfo: Codable, Sendable {
    public let accountId: String
    public let bucketId: String
    public let bucketName: String
    public let bucketType: String
    public let bucketInfo: [String: String]?
    public let lifecycleRules: [B2LifecycleRule]?
    public let revision: Int?

    public init(
        accountId: String,
        bucketId: String,
        bucketName: String,
        bucketType: String,
        bucketInfo: [String: String]? = nil,
        lifecycleRules: [B2LifecycleRule]? = nil,
        revision: Int? = nil
    ) {
        self.accountId = accountId
        self.bucketId = bucketId
        self.bucketName = bucketName
        self.bucketType = bucketType
        self.bucketInfo = bucketInfo
        self.lifecycleRules = lifecycleRules
        self.revision = revision
    }
}

/// Lifecycle rule for automatic file cleanup.
public struct B2LifecycleRule: Codable, Sendable {
    public let fileNamePrefix: String
    public let daysFromHidingToDeleting: Int?
    public let daysFromUploadingToHiding: Int?

    public init(
        fileNamePrefix: String,
        daysFromHidingToDeleting: Int? = nil,
        daysFromUploadingToHiding: Int? = nil
    ) {
        self.fileNamePrefix = fileNamePrefix
        self.daysFromHidingToDeleting = daysFromHidingToDeleting
        self.daysFromUploadingToHiding = daysFromUploadingToHiding
    }
}

// MARK: - Error Response

/// JSON body returned by B2 for all error responses.
public struct B2ErrorResponse: Codable, Sendable {
    public let status: Int
    public let code: String
    public let message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }
}

// MARK: - JSONDecoder Extension

public extension JSONDecoder {
    /// Pre-configured decoder for B2 API responses.
    /// Uses default key decoding (B2 uses camelCase matching Swift conventions).
    static var b2Decoder: JSONDecoder {
        let decoder = JSONDecoder()
        // B2 uses camelCase keys natively — no key strategy override needed.
        // Date decoding is not used; timestamps are Int64 millis-since-epoch.
        return decoder
    }
}
