# Phase 5: Build System & B2 Client - Research

**Researched:** 2026-02-05
**Domain:** Xcode multi-target project structure, Backblaze B2 Native API, Swift HTTP client, Keychain sharing
**Confidence:** HIGH

## Summary

This phase replaces the SPM build system with an Xcode multi-target project, removes all Rust/macFUSE code, and builds a complete Swift B2 API client in a shared framework. The B2 Native API (v4) is well-documented with clear REST endpoints for all required operations. The Swift B2 client should use `URLSession` with async/await, wrapped in an `actor` for thread safety, with a layered architecture: low-level HTTP mapping 1:1 to B2 endpoints, and a high-level domain API for convenience.

The Xcode project needs three targets: a host app (menu bar SwiftUI), an FSKit extension (.appex), and a shared framework. App Group entitlements enable Keychain sharing and UserDefaults sharing between the host app and extension. The existing `KeychainAccess` SPM dependency should be replaced with native Security framework APIs since the shared framework can't depend on SPM packages easily, and the native API is straightforward for the limited operations needed.

**Primary recommendation:** Build a clean Xcode project from scratch with three targets, use native `Security.framework` for Keychain (no third-party dependency), and implement the B2 client as an `actor` with transparent token refresh in the shared framework.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Foundation/URLSession | macOS 26+ | HTTP client for B2 API | Built-in, async/await native, zero dependencies |
| Security.framework | macOS 26+ | Keychain access for credentials | Native API, required for shared access groups between app and extension |
| CryptoKit | macOS 26+ | SHA-256 checksums for uploads | Apple's modern crypto framework, replaces CommonCrypto |
| os.log / Logger | macOS 26+ | Structured logging | Apple's recommended logging, low overhead |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Swift Testing | macOS 26+ | Unit tests for B2 client | All B2 response parsing, cache logic, credential models |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| URLSession | Alamofire | Unnecessary dependency; URLSession with async/await is equally ergonomic |
| Security.framework | KeychainAccess (current) | SPM packages are awkward in shared framework targets; native API is simple enough |
| CryptoKit | CommonCrypto | CryptoKit is the modern replacement, cleaner Swift API |

### Dependencies Removed
| Library | Reason |
|---------|--------|
| KeychainAccess (SPM) | Replaced by native Security.framework for shared access group support |
| Package.swift | Replaced by Xcode project |

**Installation:**
No `npm install` or `swift package` needed — all dependencies are Apple frameworks included in macOS SDK.

## Architecture Patterns

### Recommended Project Structure
```
CloudMount.xcodeproj
├── CloudMount/                      # Host app target
│   ├── CloudMountApp.swift          # @main, menu bar setup
│   ├── Views/
│   │   ├── MenuContentView.swift
│   │   └── SettingsView.swift
│   ├── AppState.swift               # Observable app state
│   ├── Info.plist
│   └── CloudMount.entitlements
├── CloudMountExtension/             # FSKit extension target (placeholder for Phase 6)
│   ├── CloudMountExtension.swift    # Extension entry point (stub)
│   ├── Info.plist                   # NSExtension dict with FSKit config
│   └── CloudMountExtension.entitlements
├── CloudMountKit/                   # Shared framework target
│   ├── B2/
│   │   ├── B2Client.swift           # Actor: high-level domain API
│   │   ├── B2HTTPClient.swift       # Low-level HTTP layer (1:1 with B2 endpoints)
│   │   ├── B2Types.swift            # Request/response Codable models
│   │   ├── B2Error.swift            # Error types and mapping
│   │   └── B2AuthManager.swift      # Token lifecycle, transparent refresh
│   ├── Cache/
│   │   ├── MetadataCache.swift      # In-memory TTL cache for listings/bucket info
│   │   └── FileCache.swift          # On-disk LRU cache for file content
│   ├── Credentials/
│   │   ├── CredentialStore.swift    # Keychain CRUD with shared access group
│   │   ├── AccountConfig.swift      # Multi-account credential model
│   │   └── MountConfig.swift        # Per-mount configuration model
│   ├── Config/
│   │   └── SharedDefaults.swift     # App Group UserDefaults wrapper
│   └── CloudMountKit.h              # Umbrella header (if needed)
└── Tests/
    ├── B2TypesTests.swift           # Response parsing tests
    ├── B2ClientTests.swift          # Client logic tests (mocked HTTP)
    ├── MetadataCacheTests.swift     # Cache TTL/invalidation tests
    └── CredentialStoreTests.swift   # Keychain model tests
```

### Pattern 1: Actor-Based B2 Client with Two Layers

**What:** The B2 client is split into two layers — a stateless HTTP layer and a stateful domain layer. The domain layer is an `actor` for thread safety.

**When to use:** Always. This is the locked decision from CONTEXT.md.

**Low-level HTTP layer (B2HTTPClient):**
```swift
/// Stateless HTTP layer — maps 1:1 to B2 Native API endpoints
/// No caching, no token management, no retries at this level
struct B2HTTPClient {
    private let session: URLSession
    
    init(session: URLSession = .shared) {
        self.session = session
    }
    
    /// b2_authorize_account
    func authorizeAccount(keyId: String, applicationKey: String) async throws -> B2AuthResponse {
        let url = URL(string: "https://api.backblazeb2.com/b2api/v4/b2_authorize_account")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let credentials = "\(keyId):\(applicationKey)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        request.setValue("CloudMount/2.0.0 swift/6.0 macOS/26", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await session.data(for: request)
        try Self.validateResponse(response, data: data)
        return try JSONDecoder.b2Decoder.decode(B2AuthResponse.self, from: data)
    }
    
    /// b2_list_file_names
    func listFileNames(
        apiUrl: String,
        authToken: String,
        bucketId: String,
        prefix: String? = nil,
        delimiter: String? = nil,
        startFileName: String? = nil,
        maxFileCount: Int = 1000
    ) async throws -> B2ListFilesResponse {
        // ... GET with query parameters
    }
    
    /// b2_download_file_by_name
    func downloadFileByName(
        downloadUrl: String,
        authToken: String,
        bucketName: String,
        fileName: String,
        range: ClosedRange<Int64>? = nil
    ) async throws -> (Data, URLResponse) {
        // ... GET with Range header support
    }
    
    // ... other 1:1 endpoint mappings
}
```

**High-level domain layer (B2Client actor):**
```swift
/// High-level B2 client with caching, token refresh, and retry logic
actor B2Client {
    private let http: B2HTTPClient
    private let authManager: B2AuthManager
    private let metadataCache: MetadataCache
    private let fileCache: FileCache
    
    /// List directory contents with caching
    func listDirectory(bucketId: String, path: String) async throws -> [B2FileEntry] {
        // Check cache first
        if let cached = metadataCache.getDirectoryListing(bucketId: bucketId, path: path) {
            return cached
        }
        
        // Fetch with auto-retry and token refresh
        let prefix = path.isEmpty ? nil : path
        var allFiles: [B2FileInfo] = []
        var nextFileName: String? = nil
        
        repeat {
            let response = try await withAutoRefresh {
                try await self.http.listFileNames(
                    apiUrl: self.authManager.apiUrl,
                    authToken: self.authManager.authToken,
                    bucketId: bucketId,
                    prefix: prefix,
                    delimiter: "/",
                    startFileName: nextFileName
                )
            }
            allFiles.append(contentsOf: response.files)
            nextFileName = response.nextFileName
        } while nextFileName != nil
        
        let entries = allFiles.map { B2FileEntry(from: $0) }
        metadataCache.cacheDirectoryListing(bucketId: bucketId, path: path, entries: entries)
        return entries
    }
    
    /// Download with local file caching
    func downloadFile(bucketName: String, fileName: String, range: ClosedRange<Int64>? = nil) async throws -> Data {
        // Check file cache for full downloads
        if range == nil, let cached = fileCache.getCachedFile(fileName) {
            return cached
        }
        
        let (data, _) = try await withAutoRefresh {
            try await self.http.downloadFileByName(
                downloadUrl: self.authManager.downloadUrl,
                authToken: self.authManager.authToken,
                bucketName: bucketName,
                fileName: fileName,
                range: range
            )
        }
        
        if range == nil {
            fileCache.store(fileName: fileName, data: data)
        }
        return data
    }
    
    // ... upload, delete, copy, createFolder with similar patterns
}
```

### Pattern 2: Transparent Token Refresh

**What:** An `actor` manages auth state and auto-refreshes on `expired_auth_token` or `bad_auth_token` 401 responses.

**When to use:** All B2 API calls except `authorize_account`.

```swift
/// Manages B2 authentication state with transparent refresh
actor B2AuthManager {
    private(set) var authToken: String
    private(set) var apiUrl: String
    private(set) var downloadUrl: String
    private(set) var accountId: String
    private(set) var recommendedPartSize: Int
    
    private let keyId: String
    private let applicationKey: String
    private let http: B2HTTPClient
    
    /// Refresh token, called automatically on 401 responses
    func refreshIfNeeded() async throws {
        let response = try await http.authorizeAccount(keyId: keyId, applicationKey: applicationKey)
        self.authToken = response.authorizationToken
        self.apiUrl = response.apiInfo.storageApi.apiUrl
        self.downloadUrl = response.apiInfo.storageApi.downloadUrl
    }
}

/// Helper to retry with token refresh on auth errors
func withAutoRefresh<T>(_ operation: () async throws -> T) async throws -> T {
    do {
        return try await operation()
    } catch let error as B2Error where error.isAuthExpired {
        try await authManager.refreshIfNeeded()
        return try await operation()  // Retry once after refresh
    }
}
```

### Pattern 3: Multi-Account Credential Model

**What:** Credential and config models designed for multiple accounts and mounts from the start.

**When to use:** Always — locked decision from CONTEXT.md.

```swift
/// A stored B2 account with credentials in Keychain
struct B2Account: Identifiable, Codable {
    let id: UUID
    var label: String                    // User-friendly name ("Personal", "Work")
    var keyId: String                    // Stored in Keychain, not UserDefaults
    var applicationKey: String           // Stored in Keychain, not UserDefaults
    var accountId: String?               // Populated after first auth
    var lastAuthorized: Date?
}

/// Configuration for a single mount (bucket → volume)
struct MountConfiguration: Identifiable, Codable {
    let id: UUID
    var accountId: UUID                  // References B2Account.id
    var bucketId: String
    var bucketName: String
    var mountPoint: String               // e.g. "/Volumes/my-bucket"
    var autoMount: Bool
    var cacheSettings: CacheSettings
}

struct CacheSettings: Codable {
    var metadataTTLSeconds: Int = 300    // 5 minutes
    var maxFileCacheSizeBytes: Int64 = 1_073_741_824  // 1 GB
    var enableFileCache: Bool = true
}
```

### Pattern 4: Keychain with Shared Access Group

**What:** Use Security framework directly with a shared access group for app+extension access.

**When to use:** All credential storage.

```swift
/// Keychain wrapper with shared access group
struct KeychainHelper {
    /// Access group shared between host app and FSKit extension
    /// Format: $(TeamIdentifier).com.cloudmount.shared
    static let accessGroup = "TEAM_ID.com.cloudmount.shared"
    
    static func save(data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        
        // Delete existing, then add
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }
    
    static func load(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.loadFailed(status)
        }
        return result as? Data
    }
}
```

### Anti-Patterns to Avoid
- **Translating Rust line-by-line:** The Rust code uses `reqwest`, `moka`, `tokio` patterns. Don't mirror these. Use idiomatic Swift: `URLSession`, `actor`, `Dictionary` with `Date` for TTL cache.
- **Using `v2` or `v3` API endpoints:** The current B2 API version is v4. The Rust code used v2/v3 — the Swift client must use v4.
- **Storing auth tokens in UserDefaults:** Auth tokens go in Keychain only. UserDefaults is for non-secret config.
- **Creating a monolithic B2Client class:** Split into HTTP layer + domain layer as decided.
- **Using `KeychainAccess` SPM package:** Replace with native Security.framework for shared access group support.
- **Synchronous socket code:** The existing `DaemonClient.swift` uses raw POSIX sockets. Replace all IPC with direct B2 client calls.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| SHA-256 hashing | Custom implementation | CryptoKit `SHA256` | Secure, hardware-accelerated, maintained by Apple |
| HTTP client | Custom URLSession wrapper | `URLSession.data(for:)` async | Built-in retry, connection pooling, HTTP/2, certificate pinning |
| JSON camelCase decoding | Manual key mapping | `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` | B2 uses camelCase natively but some fields need custom decoding |
| Percent-encoding file names | Manual string manipulation | `String.addingPercentEncoding(withAllowedCharacters:)` | B2 requires percent-encoded file names in URLs |
| Base64 encoding | Custom implementation | `Data.base64EncodedString()` | Standard Foundation API |
| Keychain CRUD | Third-party library | Native Security.framework | Required for shared access group, simple enough for our use case |
| LRU cache eviction | Custom linked list | `Dictionary` with `Date` + periodic cleanup | Simple and sufficient for <10K entries |

**Key insight:** macOS SDK provides everything needed. Zero third-party dependencies for the entire shared framework.

## Common Pitfalls

### Pitfall 1: B2 API Returns Numeric Fields as Strings
**What goes wrong:** `contentLength` can be returned as `"7"` (string) or `7` (number) depending on the context. Standard `Codable` decoding will crash on type mismatch.
**Why it happens:** B2 API documentation shows numbers but some endpoints return string-encoded numbers, especially for folder entries.
**How to avoid:** Use a flexible decoder that accepts both:
```swift
/// Decodes a value that may be either a number or a string-encoded number
struct FlexibleInt64: Codable {
    let value: Int64
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int64.self) {
            value = intValue
        } else if let stringValue = try? container.decode(String.self),
                  let parsed = Int64(stringValue) {
            value = parsed
        } else if container.decodeNil() {
            value = 0
        } else {
            throw DecodingError.typeMismatch(Int64.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected Int64 or String"))
        }
    }
}
```
**Warning signs:** Tests pass with mock data but fail against real B2 API.

### Pitfall 2: Upload Requires Two-Step Process
**What goes wrong:** Trying to upload directly to the B2 API URL fails with 401.
**Why it happens:** B2 upload requires: (1) `b2_get_upload_url` to get a dedicated upload URL + upload auth token, (2) `b2_upload_file` to that specific URL with that specific token. The upload URL's auth token is *different* from the account auth token.
**How to avoid:** Always call `getUploadUrl` before `uploadFile`. Cache upload URLs and reuse until they fail (valid for 24 hours). On upload failure (401, 408, 500-599), get a new upload URL.
**Warning signs:** Upload works once then fails on subsequent uploads.

### Pitfall 3: b2_list_file_names Pagination
**What goes wrong:** Only the first 1000 files are listed; directories with more files appear incomplete.
**Why it happens:** `b2_list_file_names` returns at most `maxFileCount` results (max 10000). You must loop using `nextFileName` for complete results.
**How to avoid:** Always implement the pagination loop:
```swift
var allFiles: [B2FileInfo] = []
var nextFileName: String? = nil
repeat {
    let response = try await listFileNames(bucketId: bucketId, startFileName: nextFileName, ...)
    allFiles.append(contentsOf: response.files)
    nextFileName = response.nextFileName
} while nextFileName != nil
```
**Warning signs:** Directories with many files show only first batch.

### Pitfall 4: Delete Requires Both fileName AND fileId
**What goes wrong:** Attempting to delete a file with only the file name fails.
**Why it happens:** `b2_delete_file_version` requires both `fileName` and `fileId`. B2 supports file versioning, so you're deleting a specific version. The `fileId` comes from `b2_list_file_names` or `b2_upload_file` responses.
**How to avoid:** Always cache `fileId` from list operations. For rename (copy + delete), the source `fileId` is needed for both the copy and the delete.
**Warning signs:** Delete operations fail with "bad_request" or "file_not_present".

### Pitfall 5: b2_copy_file Max File Size is 5GB
**What goes wrong:** Server-side copy fails for files larger than 5GB.
**Why it happens:** `b2_copy_file` has a 5GB limit. For larger files, you must use `b2_copy_part` with the large file API.
**How to avoid:** Check file size before copying. For Phase 5, document this limit. Large file copy support can be deferred with the large file upload API.
**Warning signs:** Copy/rename fails for large files with "source_too_large" error.

### Pitfall 6: Folder Markers vs Virtual Folders
**What goes wrong:** Creating a folder doesn't make it appear in listings, or deleting files in a folder doesn't remove the folder.
**Why it happens:** B2 has two kinds of "folders": (1) Virtual folders inferred by the delimiter in `b2_list_file_names` — these appear automatically when files exist with that prefix. (2) Explicit folder markers — zero-byte files with trailing `/` and content type `application/x-directory`. Virtual folders disappear when their last file is deleted. Folder markers persist until explicitly deleted.
**How to avoid:** Use `application/x-directory` content type for folder creation. Handle both `action: "folder"` (virtual) and files ending with `/` (markers) as directories.

### Pitfall 7: Token Expiry is 24 Hours, Not Infinite
**What goes wrong:** App works fine for a day then all operations fail.
**Why it happens:** B2 auth tokens expire after 24 hours. The error codes are `bad_auth_token` or `expired_auth_token` (401).
**How to avoid:** Implement transparent retry: on 401 with these codes, call `b2_authorize_account` again, then retry the original request. Only retry once — if the second attempt also gets 401, the credentials themselves are bad.
**Warning signs:** App works after fresh launch but fails after being open for extended periods.

### Pitfall 8: Xcode Shared Framework Embedding
**What goes wrong:** App builds but crashes at launch with "Library not loaded" for the shared framework.
**Why it happens:** The shared framework must be embedded in both the host app and the extension, but with different settings. The host app embeds and signs it; the extension links against it but doesn't embed (since it's embedded in the host app's bundle).
**How to avoid:** In the host app target: Frameworks, Libraries → CloudMountKit.framework → "Embed & Sign". In the extension target: Frameworks, Libraries → CloudMountKit.framework → "Do Not Embed".
**Warning signs:** Build succeeds but app crashes on launch.

### Pitfall 9: App Group ID Format
**What goes wrong:** Keychain sharing doesn't work between app and extension.
**Why it happens:** The Keychain access group format is `$(AppIdentifierPrefix)com.yourcompany.sharedgroup` where `AppIdentifierPrefix` is your team ID. The App Group for UserDefaults is `group.com.yourcompany.appname`. These are DIFFERENT formats.
**How to avoid:** 
- Keychain access group: `$(AppIdentifierPrefix)com.cloudmount.shared` (in entitlements as `keychain-access-groups`)
- App Group for UserDefaults: `group.com.cloudmount.shared` (in entitlements as `com.apple.security.application-groups`)
- Both the host app and extension must have BOTH entitlements.
**Warning signs:** Credentials saved in host app are not visible from extension.

## B2 Native API Reference (v4)

### Authentication Flow

**Endpoint:** `GET https://api.backblazeb2.com/b2api/v4/b2_authorize_account`
**Auth:** HTTP Basic (`base64(keyId:applicationKey)`)
**Key response fields:**
```json
{
  "accountId": "ACCOUNT_ID",
  "authorizationToken": "TOKEN",          // Valid for 24 hours
  "apiInfo": {
    "storageApi": {
      "apiUrl": "https://apiNNN.backblazeb2.com",       // Base for API calls
      "downloadUrl": "https://fNNN.backblazeb2.com",    // Base for downloads
      "recommendedPartSize": 100000000,                  // 100MB
      "absoluteMinimumPartSize": 5000000,                // 5MB
      "allowed": {
        "capabilities": ["listFiles", "readFiles", ...],
        "buckets": [{"id": "...", "name": "..."}],
        "namePrefix": null
      }
    }
  }
}
```

### Endpoints Summary

| Operation | Method | URL Pattern | Key Notes |
|-----------|--------|-------------|-----------|
| Authorize | GET | `https://api.backblazeb2.com/b2api/v4/b2_authorize_account` | Basic auth, returns apiUrl + downloadUrl |
| List Buckets | POST | `{apiUrl}/b2api/v4/b2_list_buckets` | Body: `{accountId}`, needs `listBuckets` capability |
| List Files | GET | `{apiUrl}/b2api/v4/b2_list_file_names?bucketId=...&prefix=...&delimiter=/` | Pagination via `nextFileName`, max 10000/request |
| Download | GET | `{downloadUrl}/file/{bucketName}/{fileName}` | Range header supported, 206 for partial content |
| Get Upload URL | GET | `{apiUrl}/b2api/v4/b2_get_upload_url?bucketId=...` | Returns unique uploadUrl + authorizationToken |
| Upload File | POST | `{uploadUrl}` (from get_upload_url) | Body is raw file bytes, metadata in headers |
| Delete File | POST | `{apiUrl}/b2api/v4/b2_delete_file_version` | Requires both `fileName` AND `fileId` |
| Copy File | POST | `{apiUrl}/b2api/v4/b2_copy_file` | Server-side, max 5GB, same account only |
| Hide File | POST | `{apiUrl}/b2api/v4/b2_hide_file` | Soft delete (creates hide marker) |

### Error Handling Strategy

| HTTP Status | B2 Code | Action |
|-------------|---------|--------|
| 401 | `bad_auth_token` / `expired_auth_token` | Refresh token via `b2_authorize_account`, retry once |
| 401 | `unauthorized` | Don't retry — credentials lack required capability |
| 403 | `cap_exceeded` | Don't retry — inform user to check B2 account caps |
| 408 | `request_timeout` | Retry with backoff |
| 429 | `too_many_requests` | Respect `Retry-After` header, exponential backoff |
| 500 | (any) | Retry with exponential backoff |
| 503 | `service_unavailable` | Respect `Retry-After`, retry with backoff |

### Upload Flow Detail

```
1. GET b2_get_upload_url(bucketId) → {uploadUrl, authorizationToken}
2. POST uploadUrl with:
   - Authorization: {authorizationToken from step 1, NOT the account token}
   - X-Bz-File-Name: percent-encoded file name
   - Content-Type: MIME type (or "b2/x-auto")
   - Content-Length: exact byte count (required, no chunked encoding)
   - X-Bz-Content-Sha1: SHA-1 hex digest of file content
   - X-Bz-Info-src_last_modified_millis: source file mtime (recommended)
   - Body: raw file bytes
```

Upload URL reuse:
- An upload URL+token pair is valid for 24 hours OR until the endpoint rejects an upload
- Can upload many files to same URL serially
- On 401/408/5xx: get a NEW upload URL and retry
- For parallel uploads: get one upload URL per concurrent upload thread

### Folder Creation

B2 doesn't have real folders. To create a visible folder:
```
Upload a zero-byte file with:
- fileName: "path/to/folder/"  (trailing slash required)
- contentType: "application/x-directory"  (not "b2/x-auto")
- Content-Length: 0
- X-Bz-Content-Sha1: "da39a3ee5e6b4b0d3255bfef95601890afd80709"  (SHA-1 of empty data)
```

### Rename (Copy + Delete)

B2 has no rename API. Rename is implemented as:
1. `b2_copy_file(sourceFileId, newFileName)` — server-side copy, no data transfer
2. `b2_delete_file_version(oldFileName, sourceFileId)` — delete original

For files > 5GB, this requires `b2_copy_part` with the large file API (defer to Phase 6).

## Code Examples

### B2 Response Types (Codable Models)

```swift
// Source: Backblaze B2 API docs v4, verified 2026-02-05

/// Custom JSON decoder for B2 API responses
extension JSONDecoder {
    static let b2Decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // B2 uses camelCase natively, so no key strategy needed
        return decoder
    }()
}

/// Response from b2_authorize_account
struct B2AuthResponse: Codable {
    let accountId: String
    let authorizationToken: String
    let apiInfo: B2ApiInfo
    let applicationKeyExpirationTimestamp: Int64?
}

struct B2ApiInfo: Codable {
    let storageApi: B2StorageApiInfo
}

struct B2StorageApiInfo: Codable {
    let apiUrl: String
    let downloadUrl: String
    let recommendedPartSize: Int
    let absoluteMinimumPartSize: Int
    let allowed: B2Allowed
    let s3ApiUrl: String
}

struct B2Allowed: Codable {
    let capabilities: [String]
    let buckets: [B2AllowedBucket]?
    let namePrefix: String?
}

struct B2AllowedBucket: Codable {
    let id: String
    let name: String?
}

/// File entry from b2_list_file_names
struct B2FileInfo: Codable {
    let fileName: String
    let contentLength: FlexibleInt64   // Can be Int or String in API
    let uploadTimestamp: FlexibleInt64  // Can be Int or String in API
    let action: String                 // "upload", "folder", "hide", "start"
    let fileId: String?                // null for "folder" action
    let contentType: String?           // null for "folder" action
    let contentSha1: String?
    
    var isDirectory: Bool {
        action == "folder" || fileName.hasSuffix("/")
    }
    
    var baseName: String {
        let trimmed = fileName.hasSuffix("/") ? String(fileName.dropLast()) : fileName
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}

/// Response from b2_list_file_names
struct B2ListFilesResponse: Codable {
    let files: [B2FileInfo]
    let nextFileName: String?
}

/// Response from b2_get_upload_url
struct B2UploadUrlResponse: Codable {
    let bucketId: String
    let uploadUrl: String
    let authorizationToken: String
}

/// B2 error response body
struct B2ErrorResponse: Codable {
    let status: Int
    let code: String
    let message: String
}
```

### Token Refresh Pattern

```swift
// Source: B2 Integration Checklist + API docs

enum B2Error: Error {
    case unauthorized(code: String, message: String)
    case badRequest(code: String, message: String)
    case forbidden(code: String, message: String)
    case notFound(code: String, message: String)
    case tooManyRequests(retryAfter: TimeInterval?)
    case serverError(status: Int, code: String, message: String)
    case networkError(underlying: Error)
    
    var isAuthExpired: Bool {
        if case .unauthorized(let code, _) = self {
            return code == "bad_auth_token" || code == "expired_auth_token"
        }
        return false
    }
    
    var isRetryable: Bool {
        switch self {
        case .tooManyRequests, .serverError:
            return true
        case .unauthorized(let code, _):
            return code == "bad_auth_token" || code == "expired_auth_token"
        default:
            return false
        }
    }
}
```

### In-Memory Metadata Cache with TTL

```swift
/// Simple TTL cache using actor isolation for thread safety
actor MetadataCache {
    private struct CacheEntry<T> {
        let value: T
        let expiresAt: Date
        
        var isExpired: Bool { Date() > expiresAt }
    }
    
    private var directoryListings: [String: CacheEntry<[B2FileEntry]>] = [:]
    private var fileMetadata: [String: CacheEntry<B2FileInfo>] = [:]
    private let ttl: TimeInterval  // Default: 300 seconds (5 minutes)
    
    init(ttl: TimeInterval = 300) {
        self.ttl = ttl
    }
    
    func getDirectoryListing(bucketId: String, path: String) -> [B2FileEntry]? {
        let key = "\(bucketId):\(path)"
        guard let entry = directoryListings[key], !entry.isExpired else {
            directoryListings.removeValue(forKey: key)  // Cleanup expired
            return nil
        }
        return entry.value
    }
    
    func cacheDirectoryListing(bucketId: String, path: String, entries: [B2FileEntry]) {
        let key = "\(bucketId):\(path)"
        directoryListings[key] = CacheEntry(value: entries, expiresAt: Date().addingTimeInterval(ttl))
    }
    
    /// Invalidate entries for a specific path (call on local writes)
    func invalidate(bucketId: String, path: String) {
        let key = "\(bucketId):\(path)"
        directoryListings.removeValue(forKey: key)
        fileMetadata.removeValue(forKey: key)
        
        // Also invalidate parent directory
        let parentPath = String(path.split(separator: "/").dropLast().joined(separator: "/"))
        let parentKey = "\(bucketId):\(parentPath)"
        directoryListings.removeValue(forKey: parentKey)
    }
    
    /// Clear everything (on disconnect or error)
    func clearAll() {
        directoryListings.removeAll()
        fileMetadata.removeAll()
    }
}
```

### Entitlements Configuration

**Host App entitlements (CloudMount.entitlements):**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>keychain-access-groups</key>
    <array>
        <string>$(AppIdentifierPrefix)com.cloudmount.shared</string>
    </array>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.cloudmount.shared</string>
    </array>
</dict>
</plist>
```

**Extension entitlements (CloudMountExtension.entitlements):**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>keychain-access-groups</key>
    <array>
        <string>$(AppIdentifierPrefix)com.cloudmount.shared</string>
    </array>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.cloudmount.shared</string>
    </array>
</dict>
</plist>
```

**Note on sandboxing:** FSKit extensions may require non-sandboxed operation for filesystem access. Confirm during Phase 6 integration. For Phase 5, disable sandbox to allow Keychain access group testing.

### User-Agent Header

```swift
// Source: B2 Integration Checklist — required for all B2 API requests
static let userAgent = "CloudMount/2.0.0+swift/6.0+macOS/26"
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| B2 API v2/v3 | B2 API v4 | April 2025 | v4 adds multi-bucket app keys, restructured `allowed` field |
| `POST` for read operations | `GET` for read operations | v4 | `b2_list_file_names`, `b2_get_upload_url`, `b2_download_file_by_name` are now GET (POST still accepted) |
| `KeychainAccess` SPM | Native `Security.framework` | N/A (project decision) | Enables shared access group without SPM dependency |
| SPM `Package.swift` | Xcode multi-target project | N/A (project decision) | Required for FSKit extension targets |
| Rust `reqwest` HTTP client | Swift `URLSession` async/await | N/A (technology pivot) | Native, zero dependencies, async/await built-in |

**Deprecated/outdated:**
- B2 API v2/v3: Still functional but v4 is current and recommended
- `b2_authorize_account` v3 response format: v4 restructured `allowed` into a different shape with `buckets` array
- The existing Rust code uses v2 for `b2_list_buckets` and v3 for `b2_authorize_account` — the Swift client should use v4 consistently

## Key Decisions for Planner

### 1. Remove Rust/macFUSE First (Plan 1)
The cleanup should happen as the FIRST plan in this phase. Delete the entire `Daemon/` directory, `Package.swift`, `MacFUSEDetector.swift`, and all macFUSE references in Swift files. This creates a clean foundation. The Xcode project is then created from scratch.

### 2. Xcode Project Created via `xcodebuild` or Manually
The Xcode project needs to be created. Options:
- **Recommended:** Use Xcode GUI or `xcodegen` to generate the project file — `.xcodeproj` files are complex binary/XML and not meant to be hand-written
- The planner should have one task that creates the Xcode project with all three targets configured
- **Alternative:** Create project structure with Swift files first, then generate `.xcodeproj` using a tool

### 3. FSKit Extension is a Stub in Phase 5
The FSKit extension target should exist in the Xcode project with correct entitlements and Info.plist, but contain only a stub implementation. Actual FSKit integration happens in Phase 6. This ensures the build system is ready.

### 4. B2 API v4 Consistently
All B2 endpoints should use v4 URL paths (`/b2api/v4/...`). The Rust code mixed v2 and v3. The Swift client should be consistent on v4.

### 5. Defer Large File Upload to Phase 6
Multi-part upload (files > 100MB recommended, required > 5GB) should be deferred. Phase 5 focuses on single-file upload which covers the common case. The `recommendedPartSize` from auth response should be stored for future use.

### 6. File Cache on Disk, Metadata Cache in Memory
- **Metadata cache:** In-memory `actor` with `Dictionary` + TTL dates. ~5 minute TTL. Cleared on app restart. Simple, no persistence needed.
- **File cache:** On-disk in `~/Library/Caches/CloudMount/{bucketId}/`. LRU eviction. 1 GB default max. Persists across app restarts.

### 7. Test Strategy
- B2 response parsing: Unit tests with JSON fixtures (from actual B2 API docs)
- Cache TTL/invalidation: Unit tests with clock injection
- Credential model: Unit tests for Codable round-trips
- B2 client operations: Integration tests that require actual B2 credentials (marked `@available` or gated by env var)
- NO mocking of URLSession for Phase 5 — focus on real API contract tests

## Open Questions

1. **Team ID for Keychain Access Group**
   - What we know: Keychain access groups require `$(AppIdentifierPrefix)` which resolves to team ID + dot
   - What's unclear: The developer's Apple team ID is needed in entitlements
   - Recommendation: Use `$(AppIdentifierPrefix)com.cloudmount.shared` which Xcode resolves automatically for development signing

2. **App Sandbox vs Non-Sandboxed**
   - What we know: FSKit extensions may need non-sandboxed operation. Menu bar apps typically run non-sandboxed.
   - What's unclear: Whether FSKit V2 on macOS 26 requires specific sandbox entitlements
   - Recommendation: Start non-sandboxed (like the current app). Revisit in Phase 6 when FSKit integration begins.

3. **b2_list_file_names GET vs POST**
   - What we know: v4 documentation describes it as GET, but POST still works
   - What's unclear: Whether query parameter encoding has length limits for complex prefix/delimiter combinations
   - Recommendation: Use GET (current standard), fall back to POST if query strings become unwieldy

## Sources

### Primary (HIGH confidence)
- Backblaze B2 API docs — `b2_authorize_account` v4 endpoint (fetched 2026-02-05)
- Backblaze B2 API docs — `b2_list_file_names` endpoint (fetched 2026-02-05)
- Backblaze B2 API docs — `b2_download_file_by_name` endpoint (fetched 2026-02-05)
- Backblaze B2 API docs — `b2_get_upload_url` + `b2_upload_file` endpoints (fetched 2026-02-05)
- Backblaze B2 API docs — `b2_delete_file_version` endpoint (fetched 2026-02-05)
- Backblaze B2 API docs — `b2_copy_file` endpoint (fetched 2026-02-05)
- Backblaze B2 API docs — `b2_list_buckets` endpoint (fetched 2026-02-05)
- Backblaze B2 Integration Checklist — error handling, upload retry, User-Agent requirements (fetched 2026-02-05)
- Existing Rust codebase — `Daemon/CloudMountDaemon/src/b2/client.rs` (890 LOC, reviewed for edge cases)
- Existing Rust codebase — `Daemon/CloudMountDaemon/src/b2/types.rs` (409 LOC, B2 response parsing patterns)
- Existing Rust codebase — `Daemon/CloudMountDaemon/src/cache/metadata.rs` (327 LOC, TTL cache design)
- Existing Rust codebase — `Daemon/CloudMountDaemon/src/cache/file_cache.rs` (279 LOC, disk cache with LRU)
- Existing Swift codebase — all 6 Swift files reviewed for macFUSE/daemon references to remove

### Secondary (MEDIUM confidence)
- Apple Security.framework Keychain APIs — patterns based on well-established API (no version-specific fetching needed)
- Apple URLSession async/await — standard Swift 5.5+ API, stable since macOS 12
- Xcode multi-target project structure — standard Apple development patterns

### Tertiary (LOW confidence)
- FSKit extension Info.plist structure — based on training data, needs validation in Phase 6
- App Sandbox requirements for FSKit — unclear, deferred to Phase 6

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all Apple frameworks, well-documented B2 API
- Architecture: HIGH — patterns verified against B2 docs and existing Rust implementation  
- B2 API reference: HIGH — all endpoints fetched from official docs on 2026-02-05
- Pitfalls: HIGH — verified against B2 docs, Integration Checklist, and existing Rust edge case handling
- Xcode project structure: MEDIUM — standard patterns but no Context7 source for Xcode-specific setup
- Keychain sharing: MEDIUM — well-known pattern but entitlement specifics depend on developer provisioning

**Research date:** 2026-02-05
**Valid until:** 2026-03-07 (B2 API is stable; Apple frameworks are stable)
