//
//  B2HTTPClient.swift
//  CloudMountKit
//
//  Stateless HTTP layer mapping 1:1 to B2 Native API v4 endpoints.
//  No caching, no token management, no retry logic — those live higher up.
//

import Foundation

// MARK: - B2HTTPClient

/// Low-level, stateless HTTP client for the B2 Native API v4.
///
/// Each public method maps to exactly one B2 API endpoint. The client:
/// - Constructs the correct URL and headers for each endpoint
/// - Sets the required `User-Agent` header on every request
/// - Parses successful responses into typed Swift models
/// - Maps error responses into `B2Error` values
///
/// **Thread safety:** `B2HTTPClient` is `Sendable` and safe to use from
/// any isolation context. It holds no mutable state.
public struct B2HTTPClient: Sendable {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Authentication

    /// Authorize with the B2 service using an application key.
    ///
    /// Corresponds to `GET /b2api/v4/b2_authorize_account`.
    ///
    /// - Parameters:
    ///   - keyId: The application key ID.
    ///   - applicationKey: The application key secret.
    /// - Returns: Authorization response containing the auth token and API URLs.
    public func authorizeAccount(
        keyId: String,
        applicationKey: String
    ) async throws -> B2AuthResponse {
        let urlString = "\(B2Constants.apiBaseUrl)/\(B2Constants.apiVersion)/b2_authorize_account"
        guard let url = URL(string: urlString) else {
            throw B2Error.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCommonHeaders(&request)

        // Basic auth: base64("keyId:applicationKey")
        let credentials = "\(keyId):\(applicationKey)"
        guard let credentialData = credentials.data(using: .utf8) else {
            throw B2Error.invalidURL("Failed to encode credentials")
        }
        let base64 = credentialData.base64EncodedString()
        request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")

        return try await execute(request: request)
    }

    // MARK: - Bucket Operations

    /// List all buckets visible to the authorized key.
    ///
    /// Corresponds to `POST /b2api/v4/b2_list_buckets`.
    ///
    /// - Parameters:
    ///   - apiUrl: The `apiUrl` from the authorization response.
    ///   - authToken: A valid authorization token.
    ///   - accountId: The B2 account ID.
    /// - Returns: A list of bucket metadata.
    public func listBuckets(
        apiUrl: String,
        authToken: String,
        accountId: String
    ) async throws -> B2ListBucketsResponse {
        let urlString = "\(apiUrl)/\(B2Constants.apiVersion)/b2_list_buckets"
        guard let url = URL(string: urlString) else {
            throw B2Error.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyCommonHeaders(&request)
        request.setValue(authToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["accountId": accountId]
        request.httpBody = try JSONEncoder().encode(body)

        return try await execute(request: request)
    }

    // MARK: - File Listing

    /// List file names in a bucket.
    ///
    /// Corresponds to `GET /b2api/v4/b2_list_file_names`.
    ///
    /// - Parameters:
    ///   - apiUrl: The `apiUrl` from the authorization response.
    ///   - authToken: A valid authorization token.
    ///   - bucketId: The bucket to list files from.
    ///   - prefix: Optional prefix filter.
    ///   - delimiter: Optional delimiter for folder-like listing.
    ///   - startFileName: Resume listing from this file name.
    ///   - maxFileCount: Maximum files to return (default 1000, max 10000).
    /// - Returns: A page of file info objects and an optional continuation token.
    public func listFileNames(
        apiUrl: String,
        authToken: String,
        bucketId: String,
        prefix: String? = nil,
        delimiter: String? = nil,
        startFileName: String? = nil,
        maxFileCount: Int? = nil
    ) async throws -> B2ListFilesResponse {
        var components = URLComponents(string: "\(apiUrl)/\(B2Constants.apiVersion)/b2_list_file_names")
        guard components != nil else {
            throw B2Error.invalidURL("\(apiUrl)/\(B2Constants.apiVersion)/b2_list_file_names")
        }

        var queryItems = [URLQueryItem(name: "bucketId", value: bucketId)]
        if let prefix { queryItems.append(URLQueryItem(name: "prefix", value: prefix)) }
        if let delimiter { queryItems.append(URLQueryItem(name: "delimiter", value: delimiter)) }
        if let startFileName { queryItems.append(URLQueryItem(name: "startFileName", value: startFileName)) }
        if let maxFileCount { queryItems.append(URLQueryItem(name: "maxFileCount", value: String(maxFileCount))) }
        components!.queryItems = queryItems

        guard let url = components!.url else {
            throw B2Error.invalidURL("Failed to construct list file names URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCommonHeaders(&request)
        request.setValue(authToken, forHTTPHeaderField: "Authorization")

        return try await execute(request: request)
    }

    // MARK: - Download

    /// Download a file by its bucket name and file path.
    ///
    /// Corresponds to `GET {downloadUrl}/file/{bucketName}/{fileName}`.
    ///
    /// Returns raw `(Data, HTTPURLResponse)` because download responses carry
    /// the file bytes directly — not a JSON body.
    ///
    /// - Parameters:
    ///   - downloadUrl: The `downloadUrl` from the authorization response.
    ///   - authToken: A valid authorization token.
    ///   - bucketName: The bucket name (not ID).
    ///   - fileName: The full file path within the bucket.
    ///   - range: Optional HTTP Range header value (e.g. `"bytes=0-999"`).
    /// - Returns: The file data and HTTP response (for headers, status code).
    public func downloadFileByName(
        downloadUrl: String,
        authToken: String,
        bucketName: String,
        fileName: String,
        range: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        // Percent-encode the file name for the URL path.
        guard let encodedFileName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw B2Error.invalidURL("Failed to percent-encode file name: \(fileName)")
        }
        let urlString = "\(downloadUrl)/file/\(bucketName)/\(encodedFileName)"
        guard let url = URL(string: urlString) else {
            throw B2Error.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCommonHeaders(&request)
        request.setValue(authToken, forHTTPHeaderField: "Authorization")
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }

        let (data, response) = try await perform(request: request)
        let statusCode = response.statusCode

        // 200 = full content, 206 = partial content (range request)
        guard statusCode == 200 || statusCode == 206 else {
            throw B2Error.from(
                httpResponse: response,
                data: data,
                retryAfterHeader: response.value(forHTTPHeaderField: "Retry-After")
            )
        }

        return (data, response)
    }

    // MARK: - Upload (Two-Step)

    /// Get a URL for uploading files to a bucket.
    ///
    /// Corresponds to `GET /b2api/v4/b2_get_upload_url?bucketId=X`.
    ///
    /// - Parameters:
    ///   - apiUrl: The `apiUrl` from the authorization response.
    ///   - authToken: A valid authorization token.
    ///   - bucketId: The bucket to upload to.
    /// - Returns: An upload URL and upload-specific auth token (valid 24h).
    public func getUploadUrl(
        apiUrl: String,
        authToken: String,
        bucketId: String
    ) async throws -> B2UploadUrlResponse {
        var components = URLComponents(string: "\(apiUrl)/\(B2Constants.apiVersion)/b2_get_upload_url")
        guard components != nil else {
            throw B2Error.invalidURL("\(apiUrl)/\(B2Constants.apiVersion)/b2_get_upload_url")
        }
        components!.queryItems = [URLQueryItem(name: "bucketId", value: bucketId)]

        guard let url = components!.url else {
            throw B2Error.invalidURL("Failed to construct get upload URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCommonHeaders(&request)
        request.setValue(authToken, forHTTPHeaderField: "Authorization")

        return try await execute(request: request)
    }

    /// Upload a file to B2.
    ///
    /// Corresponds to `POST {uploadUrl}` (the URL from `getUploadUrl`).
    ///
    /// Uses the upload-specific auth token (NOT the account auth token).
    /// File content is sent as raw bytes in the request body.
    ///
    /// - Parameters:
    ///   - uploadUrl: The `uploadUrl` from `getUploadUrl`.
    ///   - uploadAuthToken: The `authorizationToken` from `getUploadUrl`.
    ///   - fileName: The file path within the bucket (percent-encoded).
    ///   - contentType: MIME type, or `"b2/x-auto"` for auto-detection.
    ///   - data: The file content bytes.
    ///   - sha1Hex: The hex-encoded SHA1 hash of the file content.
    ///   - lastModifiedMillis: Optional source file last-modified timestamp (millis since epoch).
    /// - Returns: Metadata about the uploaded file.
    public func uploadFile(
        uploadUrl: String,
        uploadAuthToken: String,
        fileName: String,
        contentType: String,
        data: Data,
        sha1Hex: String,
        lastModifiedMillis: Int64? = nil
    ) async throws -> B2UploadFileResponse {
        guard let url = URL(string: uploadUrl) else {
            throw B2Error.invalidURL(uploadUrl)
        }

        // Percent-encode the file name for the header.
        guard let encodedFileName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw B2Error.invalidURL("Failed to percent-encode file name: \(fileName)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyCommonHeaders(&request)
        request.setValue(uploadAuthToken, forHTTPHeaderField: "Authorization")
        request.setValue(encodedFileName, forHTTPHeaderField: "X-Bz-File-Name")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.setValue(sha1Hex, forHTTPHeaderField: "X-Bz-Content-Sha1")

        if let lastModifiedMillis {
            request.setValue(
                String(lastModifiedMillis),
                forHTTPHeaderField: "X-Bz-Info-src_last_modified_millis"
            )
        }

        request.httpBody = data

        return try await execute(request: request)
    }

    // MARK: - Delete

    /// Delete a specific file version.
    ///
    /// Corresponds to `POST /b2api/v4/b2_delete_file_version`.
    ///
    /// - Parameters:
    ///   - apiUrl: The `apiUrl` from the authorization response.
    ///   - authToken: A valid authorization token.
    ///   - fileName: The name of the file to delete.
    ///   - fileId: The ID of the specific file version to delete.
    /// - Returns: Confirmation of the deleted file version.
    public func deleteFileVersion(
        apiUrl: String,
        authToken: String,
        fileName: String,
        fileId: String
    ) async throws -> B2DeleteFileResponse {
        let urlString = "\(apiUrl)/\(B2Constants.apiVersion)/b2_delete_file_version"
        guard let url = URL(string: urlString) else {
            throw B2Error.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyCommonHeaders(&request)
        request.setValue(authToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["fileName": fileName, "fileId": fileId]
        request.httpBody = try JSONEncoder().encode(body)

        return try await execute(request: request)
    }

    // MARK: - Copy

    /// Copy a file within or between buckets.
    ///
    /// Corresponds to `POST /b2api/v4/b2_copy_file`.
    ///
    /// - Parameters:
    ///   - apiUrl: The `apiUrl` from the authorization response.
    ///   - authToken: A valid authorization token.
    ///   - sourceFileId: The file ID of the source file.
    ///   - destinationFileName: The name for the destination file.
    ///   - destinationBucketId: Optional bucket ID for cross-bucket copy.
    ///     If `nil`, copies within the same bucket.
    /// - Returns: Metadata about the copied file.
    public func copyFile(
        apiUrl: String,
        authToken: String,
        sourceFileId: String,
        destinationFileName: String,
        destinationBucketId: String? = nil
    ) async throws -> B2CopyFileResponse {
        let urlString = "\(apiUrl)/\(B2Constants.apiVersion)/b2_copy_file"
        guard let url = URL(string: urlString) else {
            throw B2Error.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyCommonHeaders(&request)
        request.setValue(authToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = [
            "sourceFileId": sourceFileId,
            "fileName": destinationFileName,
        ]
        if let destinationBucketId {
            body["destinationBucketId"] = destinationBucketId
        }
        request.httpBody = try JSONEncoder().encode(body)

        return try await execute(request: request)
    }

    // MARK: - Private Helpers

    /// Apply common headers to every outgoing request.
    private func applyCommonHeaders(_ request: inout URLRequest) {
        request.setValue(B2Constants.userAgent, forHTTPHeaderField: "User-Agent")
    }

    /// Execute a request and decode the JSON response into the expected type.
    private func execute<T: Decodable>(request: URLRequest) async throws -> T {
        let (data, response) = try await perform(request: request)

        guard response.statusCode == 200 else {
            throw B2Error.from(
                httpResponse: response,
                data: data,
                retryAfterHeader: response.value(forHTTPHeaderField: "Retry-After")
            )
        }

        do {
            return try JSONDecoder.b2Decoder.decode(T.self, from: data)
        } catch {
            throw B2Error.decodingError(underlying: error, data: data)
        }
    }

    /// Perform the raw URLSession data task and unwrap the response.
    private func perform(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw B2Error.networkError(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw B2Error.networkError(
                underlying: URLError(.badServerResponse)
            )
        }

        return (data, httpResponse)
    }
}
