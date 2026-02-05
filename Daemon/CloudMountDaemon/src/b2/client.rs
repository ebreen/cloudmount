//! Backblaze B2 API Client
//!
//! Provides authenticated access to B2 cloud storage for bucket listing and file operations.

use anyhow::{anyhow, Context, Result};
use base64::Engine;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, RwLock};
use std::time::Duration;
use tracing::{debug, error, info, warn};

use super::errors::B2Error;
use super::types::{FileInfo, ListFilesResponse};

/// B2 API base URL for authorization (v3 for nested apiInfo structure)
const B2_AUTH_URL: &str = "https://api.backblazeb2.com/b2api/v3/b2_authorize_account";

/// HTTP client timeout
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// Maximum number of retries for retryable errors
const MAX_RETRIES: u32 = 3;

/// Maximum number of recent errors to track
const MAX_ERROR_HISTORY: usize = 10;

/// Health status values
pub const HEALTH_HEALTHY: u8 = 0;
pub const HEALTH_DEGRADED: u8 = 1;
pub const HEALTH_UNHEALTHY: u8 = 2;

/// A recent error entry for tracking
#[derive(Debug, Clone)]
pub struct ErrorEntry {
    pub timestamp: u64,
    pub operation: String,
    pub path: String,
    pub error: String,
}

/// Auth state that can be refreshed (interior mutability)
struct AuthState {
    auth_token: String,
    api_url: String,
    download_url: String,
}

/// B2 API client for making authenticated requests
#[derive(Clone)]
pub struct B2Client {
    /// HTTP client for making requests
    http_client: Client,
    /// B2 account ID
    account_id: String,
    /// Mutable auth state (refreshable on 401)
    auth_state: Arc<RwLock<AuthState>>,
    /// Stored credentials for re-authorization
    key_id: String,
    key: String,
    /// Bucket ID to operate on
    bucket_id: String,
    /// Bucket name (for display purposes)
    bucket_name: String,
    /// Connection health (0=healthy, 1=degraded, 2=unhealthy)
    health: Arc<AtomicU8>,
    /// Recent error log
    error_log: Arc<RwLock<VecDeque<ErrorEntry>>>,
}

/// Response from b2_authorize_account API
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AuthorizeAccountResponse {
    account_id: String,
    authorization_token: String,
    api_info: ApiInfo,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ApiInfo {
    storage_api: StorageApiInfo,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StorageApiInfo {
    api_url: String,
    download_url: String,
}

/// Response from b2_list_buckets API
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ListBucketsResponse {
    buckets: Vec<BucketInfo>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BucketInfo {
    bucket_id: String,
    bucket_name: String,
    bucket_type: String,
}

/// Public bucket info for returning to clients
#[derive(Debug, Clone)]
pub struct B2BucketInfo {
    pub bucket_id: String,
    pub bucket_name: String,
    pub bucket_type: String,
}

/// Request body for b2_list_file_names API
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ListFileNamesRequest {
    bucket_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    prefix: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    delimiter: Option<String>,
    max_file_count: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    start_file_name: Option<String>,
}

impl B2Client {
    /// Get current auth token
    fn auth_token(&self) -> String {
        self.auth_state.read().unwrap().auth_token.clone()
    }

    /// Get current API URL
    fn api_url(&self) -> String {
        self.auth_state.read().unwrap().api_url.clone()
    }

    /// Get current download URL
    fn download_url(&self) -> String {
        self.auth_state.read().unwrap().download_url.clone()
    }

    /// Refresh the auth token by re-authorizing with B2
    pub async fn refresh_auth(&self) -> Result<()> {
        info!("Refreshing B2 auth token...");

        let credentials = format!("{}:{}", self.key_id, self.key);
        let encoded = base64::engine::general_purpose::STANDARD.encode(credentials);
        let auth_header = format!("Basic {}", encoded);

        let response = self
            .http_client
            .get(B2_AUTH_URL)
            .header("Authorization", &auth_header)
            .send()
            .await
            .context("Failed to refresh B2 auth")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("B2 auth refresh failed ({}): {}", status, body));
        }

        let auth_response: AuthorizeAccountResponse = response
            .json()
            .await
            .context("Failed to parse B2 auth refresh response")?;

        let mut state = self.auth_state.write().unwrap();
        state.auth_token = auth_response.authorization_token;
        state.api_url = auth_response.api_info.storage_api.api_url;
        state.download_url = auth_response.api_info.storage_api.download_url;

        info!("B2 auth token refreshed successfully");
        Ok(())
    }

    /// Execute an operation with retry logic and exponential backoff
    async fn with_retry<F, Fut, T>(&self, operation: &str, path: &str, f: F) -> Result<T>
    where
        F: Fn() -> Fut,
        Fut: std::future::Future<Output = Result<T>>,
    {
        let backoff_ms = [500, 1000, 2000];

        for attempt in 0..=MAX_RETRIES {
            match f().await {
                Ok(result) => {
                    self.health.store(HEALTH_HEALTHY, Ordering::Relaxed);
                    return Ok(result);
                }
                Err(e) => {
                    // Check if this is a B2-specific error
                    let error_str = e.to_string();
                    let is_auth_expired = error_str.contains("401");
                    let is_rate_limited = error_str.contains("429");
                    let is_server_error = error_str.contains("500")
                        || error_str.contains("503")
                        || error_str.contains("408");
                    let is_network = error_str.contains("connect")
                        || error_str.contains("timeout")
                        || error_str.contains("network");

                    let is_retryable = is_auth_expired
                        || is_rate_limited
                        || is_server_error
                        || is_network;

                    if !is_retryable || attempt == MAX_RETRIES {
                        // Final failure — log error and update health
                        if is_network {
                            self.health.store(HEALTH_UNHEALTHY, Ordering::Relaxed);
                        } else if is_rate_limited {
                            self.health.store(HEALTH_DEGRADED, Ordering::Relaxed);
                        }
                        self.log_error(operation, path, &error_str);
                        return Err(e);
                    }

                    // Handle auth expiry by refreshing token
                    if is_auth_expired && attempt == 0 {
                        warn!(operation = operation, "Auth expired, refreshing token...");
                        if let Err(refresh_err) = self.refresh_auth().await {
                            error!(error = %refresh_err, "Failed to refresh auth token");
                        }
                    }

                    let delay = backoff_ms
                        .get(attempt as usize)
                        .copied()
                        .unwrap_or(2000);
                    warn!(
                        operation = operation,
                        attempt = attempt + 1,
                        max = MAX_RETRIES,
                        delay_ms = delay,
                        error = %e,
                        "Retrying B2 operation"
                    );
                    tokio::time::sleep(Duration::from_millis(delay as u64)).await;
                }
            }
        }

        unreachable!()
    }

    /// Log an error to the error history ring buffer
    fn log_error(&self, operation: &str, path: &str, error: &str) {
        let entry = ErrorEntry {
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
            operation: operation.to_string(),
            path: path.to_string(),
            error: error.to_string(),
        };

        let mut log = self.error_log.write().unwrap();
        if log.len() >= MAX_ERROR_HISTORY {
            log.pop_front();
        }
        log.push_back(entry);
    }

    /// Get connection health status string
    pub fn health_status(&self) -> &'static str {
        match self.health.load(Ordering::Relaxed) {
            HEALTH_HEALTHY => "healthy",
            HEALTH_DEGRADED => "degraded",
            _ => "unhealthy",
        }
    }

    /// Get recent errors
    pub fn recent_errors(&self) -> Vec<ErrorEntry> {
        self.error_log.read().unwrap().iter().cloned().collect()
    }

    /// Authorize with B2 and create a new client for the specified bucket
    ///
    /// # Arguments
    /// * `key_id` - B2 application key ID
    /// * `key` - B2 application key
    /// * `bucket_name` - Name of the bucket to access
    ///
    /// # Returns
    /// A new B2Client ready for API calls
    pub async fn authorize(key_id: &str, key: &str, bucket_name: &str) -> Result<Self> {
        info!(bucket = bucket_name, "Authorizing with B2 API...");
        
        let http_client = Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
            .context("Failed to create HTTP client")?;
        
        // Create Basic Auth header
        let credentials = format!("{}:{}", key_id, key);
        let encoded = base64::engine::general_purpose::STANDARD.encode(credentials);
        let auth_header = format!("Basic {}", encoded);
        
        // Authorize with B2
        let response = http_client
            .get(B2_AUTH_URL)
            .header("Authorization", &auth_header)
            .send()
            .await
            .context("Failed to connect to B2 API")?;
        
        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("B2 authorization failed ({}): {}", status, body));
        }
        
        let auth_response: AuthorizeAccountResponse = response
            .json()
            .await
            .context("Failed to parse B2 auth response")?;
        
        let api_url = auth_response.api_info.storage_api.api_url;
        let download_url = auth_response.api_info.storage_api.download_url;
        debug!(api_url = %api_url, download_url = %download_url, "B2 authorization successful");
        
        // Now look up the bucket ID
        let mut client = Self {
            http_client,
            account_id: auth_response.account_id,
            auth_state: Arc::new(RwLock::new(AuthState {
                auth_token: auth_response.authorization_token,
                api_url,
                download_url,
            })),
            key_id: key_id.to_string(),
            key: key.to_string(),
            bucket_id: String::new(),
            bucket_name: bucket_name.to_string(),
            health: Arc::new(AtomicU8::new(HEALTH_HEALTHY)),
            error_log: Arc::new(RwLock::new(VecDeque::with_capacity(MAX_ERROR_HISTORY))),
        };
        
        // Get bucket ID from bucket name
        let bucket_id = client.get_bucket_id(bucket_name).await?;
        client.bucket_id = bucket_id;
        
        info!(bucket_name = bucket_name, bucket_id = %client.bucket_id, "B2 client ready");
        Ok(client)
    }
    
    /// List all available buckets for the account
    ///
    /// # Arguments
    /// * `key_id` - B2 application key ID
    /// * `key` - B2 application key
    ///
    /// # Returns
    /// Vector of available buckets
    pub async fn list_all_buckets(key_id: &str, key: &str) -> Result<Vec<B2BucketInfo>> {
        info!("Listing all buckets from B2...");
        
        let http_client = Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
            .context("Failed to create HTTP client")?;
        
        // Create Basic Auth header
        let credentials = format!("{}:{}", key_id, key);
        let encoded = base64::engine::general_purpose::STANDARD.encode(credentials);
        let auth_header = format!("Basic {}", encoded);
        
        // Authorize with B2
        let response = http_client
            .get(B2_AUTH_URL)
            .header("Authorization", &auth_header)
            .send()
            .await
            .context("Failed to connect to B2 API")?;
        
        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("B2 authorization failed ({}): {}", status, body));
        }
        
        let auth_response: AuthorizeAccountResponse = response
            .json()
            .await
            .context("Failed to parse B2 auth response")?;
        
        let api_url = auth_response.api_info.storage_api.api_url;
        let url = format!("{}/b2api/v2/b2_list_buckets", api_url);
        
        let response = http_client
            .post(&url)
            .header("Authorization", &auth_response.authorization_token)
            .json(&serde_json::json!({
                "accountId": auth_response.account_id
            }))
            .send()
            .await
            .context("Failed to list buckets")?;
        
        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Failed to list buckets ({}): {}", status, body));
        }
        
        let list_response: ListBucketsResponse = response
            .json()
            .await
            .context("Failed to parse bucket list")?;
        
        let buckets: Vec<B2BucketInfo> = list_response.buckets
            .into_iter()
            .map(|b| B2BucketInfo {
                bucket_id: b.bucket_id,
                bucket_name: b.bucket_name,
                bucket_type: b.bucket_type,
            })
            .collect();
        
        info!(count = buckets.len(), "Listed buckets from B2");
        Ok(buckets)
    }
    
    /// Look up bucket ID from bucket name
    async fn get_bucket_id(&self, bucket_name: &str) -> Result<String> {
        let url = format!("{}/b2api/v2/b2_list_buckets", self.api_url());
        
        let response = self.http_client
            .post(&url)
            .header("Authorization", &self.auth_token())
            .json(&serde_json::json!({
                "accountId": self.account_id,
                "bucketName": bucket_name
            }))
            .send()
            .await
            .context("Failed to list buckets")?;
        
        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Failed to list buckets ({}): {}", status, body));
        }
        
        let list_response: ListBucketsResponse = response
            .json()
            .await
            .context("Failed to parse bucket list")?;
        
        list_response.buckets
            .into_iter()
            .find(|b| b.bucket_name == bucket_name)
            .map(|b| b.bucket_id)
            .ok_or_else(|| anyhow!("Bucket '{}' not found", bucket_name))
    }
    
    /// List files in the bucket with optional prefix and delimiter
    ///
    /// # Arguments
    /// * `prefix` - Optional path prefix to filter results
    /// * `delimiter` - Optional delimiter for directory-style listing (usually "/")
    ///
    /// # Returns
    /// Vector of FileInfo for matching files
    pub async fn list_file_names(
        &self,
        prefix: Option<&str>,
        delimiter: Option<&str>,
    ) -> Result<Vec<FileInfo>> {
        let url = format!("{}/b2api/v2/b2_list_file_names", self.api_url());
        let mut all_files = Vec::new();
        let mut start_file_name: Option<String> = None;
        
        loop {
            let request = ListFileNamesRequest {
                bucket_id: self.bucket_id.clone(),
                prefix: prefix.map(String::from),
                delimiter: delimiter.map(String::from),
                max_file_count: 1000,
                start_file_name: start_file_name.clone(),
            };
            
            debug!(prefix = ?prefix, delimiter = ?delimiter, start = ?start_file_name, "Listing files from B2");
            
            let response = self.http_client
                .post(&url)
                .header("Authorization", &self.auth_token())
                .json(&request)
                .send()
                .await
                .context("Failed to list files")?;
            
            if !response.status().is_success() {
                let status = response.status();
                let body = response.text().await.unwrap_or_default();
                
                // Handle specific error codes
                if status.as_u16() == 401 {
                    return Err(anyhow!("B2 authorization expired. Token needs refresh."));
                }
                if status.as_u16() == 429 {
                    warn!("B2 rate limit hit, backing off...");
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    continue;
                }
                
                return Err(anyhow!("Failed to list files ({}): {}", status, body));
            }
            
            let list_response: ListFilesResponse = response
                .json()
                .await
                .context("Failed to parse file list")?;
            
            all_files.extend(list_response.files);
            
            // Check for more pages
            match list_response.next_file_name {
                Some(next) => {
                    start_file_name = Some(next);
                }
                None => break,
            }
        }
        
        debug!(count = all_files.len(), "Listed files from B2");
        Ok(all_files)
    }
    
    /// Get the bucket ID
    pub fn bucket_id(&self) -> &str {
        &self.bucket_id
    }
    
    /// Get the bucket name
    pub fn bucket_name(&self) -> &str {
        &self.bucket_name
    }
    
    /// Download file content from B2
    ///
    /// Downloads file bytes using the B2 download URL.
    /// Supports optional byte range for partial reads.
    ///
    /// # Arguments
    /// * `file_name` - Full file path within the bucket
    /// * `range` - Optional (start, end) byte range for partial downloads
    ///
    /// # Returns
    /// File content as bytes
    pub async fn download_file(
        &self,
        file_name: &str,
        range: Option<(u64, u64)>,
    ) -> Result<Vec<u8>> {
        let encoded_name = urlencoding::encode(file_name);
        let url = format!(
            "{}/file/{}/{}",
            self.download_url(), self.bucket_name, encoded_name
        );

        debug!(file = file_name, url = %url, range = ?range, "Downloading file from B2");

        let mut request = self
            .http_client
            .get(&url)
            .header("Authorization", &self.auth_token());

        if let Some((start, end)) = range {
            request = request.header("Range", format!("bytes={}-{}", start, end));
        }

        let response = request
            .send()
            .await
            .context("Failed to download file from B2")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Failed to download file ({}): {}", status, body));
        }

        let bytes = response
            .bytes()
            .await
            .context("Failed to read file content")?;

        info!(file = file_name, size = bytes.len(), "Downloaded file from B2");
        Ok(bytes.to_vec())
    }

    /// Get file info by path
    ///
    /// Looks up a specific file by its full path in B2.
    /// Returns FileInfo if found, error otherwise.
    pub async fn get_file_info(&self, file_path: &str) -> Result<FileInfo> {
        // B2 doesn't have a direct "get file by path" API
        // We use list_file_names with the exact path as prefix and no delimiter
        let files = self.list_file_names(Some(file_path), None).await?;
        
        // Find exact match
        files.into_iter()
            .find(|f| f.file_name == file_path)
            .ok_or_else(|| anyhow!("File not found: {}", file_path))
    }

    /// Get an upload URL for uploading files to B2
    ///
    /// Upload URLs are valid for 24 hours and can be reused.
    async fn get_upload_url(&self) -> Result<UploadUrl> {
        let url = format!("{}/b2api/v2/b2_get_upload_url", self.api_url());

        let response = self
            .http_client
            .post(&url)
            .header("Authorization", &self.auth_token())
            .json(&serde_json::json!({ "bucketId": self.bucket_id }))
            .send()
            .await
            .context("Failed to get upload URL")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Failed to get upload URL ({}): {}", status, body));
        }

        let upload_url: UploadUrl = response
            .json()
            .await
            .context("Failed to parse upload URL response")?;

        debug!(url = %upload_url.upload_url, "Got B2 upload URL");
        Ok(upload_url)
    }

    /// Upload a file to B2
    ///
    /// Gets an upload URL, calculates SHA1 hash, and uploads file content.
    ///
    /// # Arguments
    /// * `file_name` - Full file path within the bucket
    /// * `data` - File content bytes
    /// * `content_type` - MIME type (e.g. "application/octet-stream")
    ///
    /// # Returns
    /// FileInfo for the newly uploaded file
    pub async fn upload_file(
        &self,
        file_name: &str,
        data: &[u8],
        content_type: &str,
    ) -> Result<FileInfo> {
        let upload_url = self.get_upload_url().await?;

        // Calculate SHA1 hash
        use sha1::{Digest, Sha1};
        let mut hasher = Sha1::new();
        hasher.update(data);
        let hash = format!("{:x}", hasher.finalize());

        let encoded_name = urlencoding::encode(file_name);

        info!(
            file = file_name,
            size = data.len(),
            content_type = content_type,
            "Uploading file to B2"
        );

        let response = self
            .http_client
            .post(&upload_url.upload_url)
            .header("Authorization", &upload_url.authorization_token)
            .header("X-Bz-File-Name", encoded_name.as_ref())
            .header("Content-Type", content_type)
            .header("Content-Length", data.len())
            .header("X-Bz-Content-Sha1", &hash)
            .body(data.to_vec())
            .send()
            .await
            .context("Failed to upload file to B2")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Failed to upload file ({}): {}", status, body));
        }

        let upload_response: UploadResponse = response
            .json()
            .await
            .context("Failed to parse upload response")?;

        info!(
            file = file_name,
            file_id = %upload_response.file_id,
            "File uploaded to B2"
        );

        Ok(FileInfo {
            file_name: upload_response.file_name,
            content_length: upload_response.content_length,
            upload_timestamp: upload_response.upload_timestamp,
            action: "upload".to_string(),
            file_id: Some(upload_response.file_id),
            content_type: Some(upload_response.content_type),
        })
    }

    /// Delete a file version from B2 (permanent delete)
    ///
    /// # Arguments
    /// * `file_name` - Full file path within the bucket
    /// * `file_id` - B2 file ID (from get_file_info or upload response)
    pub async fn delete_file(&self, file_name: &str, file_id: &str) -> Result<()> {
        let url = format!("{}/b2api/v2/b2_delete_file_version", self.api_url());

        info!(file = file_name, file_id = file_id, "Deleting file from B2");

        let response = self
            .http_client
            .post(&url)
            .header("Authorization", &self.auth_token())
            .json(&serde_json::json!({
                "fileName": file_name,
                "fileId": file_id
            }))
            .send()
            .await
            .context("Failed to delete file from B2")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Failed to delete file ({}): {}", status, body));
        }

        info!(file = file_name, "File deleted from B2");
        Ok(())
    }

    /// Hide a file in B2 (soft delete, creates hide marker)
    ///
    /// Use when file_id is not available.
    pub async fn hide_file(&self, file_name: &str) -> Result<FileInfo> {
        let url = format!("{}/b2api/v2/b2_hide_file", self.api_url());

        info!(file = file_name, "Hiding file in B2");

        let response = self
            .http_client
            .post(&url)
            .header("Authorization", &self.auth_token())
            .json(&serde_json::json!({
                "bucketId": self.bucket_id,
                "fileName": file_name
            }))
            .send()
            .await
            .context("Failed to hide file in B2")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Failed to hide file ({}): {}", status, body));
        }

        let file_info: FileInfo = response
            .json()
            .await
            .context("Failed to parse hide response")?;

        Ok(file_info)
    }

    /// Copy a file within B2 (server-side, no download/upload)
    ///
    /// # Arguments
    /// * `source_file_id` - File ID of the source file
    /// * `dest_file_name` - Destination file path within the bucket
    pub async fn copy_file(
        &self,
        source_file_id: &str,
        dest_file_name: &str,
    ) -> Result<FileInfo> {
        let url = format!("{}/b2api/v2/b2_copy_file", self.api_url());

        info!(
            source_id = source_file_id,
            dest = dest_file_name,
            "Copying file in B2"
        );

        let response = self
            .http_client
            .post(&url)
            .header("Authorization", &self.auth_token())
            .json(&serde_json::json!({
                "sourceFileId": source_file_id,
                "fileName": dest_file_name
            }))
            .send()
            .await
            .context("Failed to copy file in B2")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Failed to copy file ({}): {}", status, body));
        }

        let file_info: FileInfo = response
            .json()
            .await
            .context("Failed to parse copy response")?;

        info!(dest = dest_file_name, "File copied in B2");
        Ok(file_info)
    }

    /// Create a folder marker in B2
    ///
    /// B2 uses zero-byte files with trailing slash as folder markers.
    pub async fn create_folder(&self, folder_path: &str) -> Result<FileInfo> {
        let folder_name = if folder_path.ends_with('/') {
            folder_path.to_string()
        } else {
            format!("{}/", folder_path)
        };

        self.upload_file(&folder_name, &[], "application/x-directory")
            .await
    }
}

/// Upload URL from B2 (for uploading files)
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UploadUrl {
    upload_url: String,
    authorization_token: String,
}

/// Response from a successful file upload
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UploadResponse {
    file_id: String,
    file_name: String,
    content_length: u64,
    content_type: String,
    upload_timestamp: u64,
}

#[cfg(test)]
mod tests {
    use super::*;
    
    // Integration tests would require B2 credentials
    // These are placeholder tests for compile-time verification
    
    #[test]
    fn test_list_request_serialization() {
        let request = ListFileNamesRequest {
            bucket_id: "test-bucket".to_string(),
            prefix: Some("folder/".to_string()),
            delimiter: Some("/".to_string()),
            max_file_count: 100,
            start_file_name: None,
        };
        
        let json = serde_json::to_string(&request).unwrap();
        assert!(json.contains("bucketId"));
        assert!(json.contains("prefix"));
        assert!(json.contains("delimiter"));
    }
}
