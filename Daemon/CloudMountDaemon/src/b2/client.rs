//! Backblaze B2 API Client
//!
//! Provides authenticated access to B2 cloud storage for bucket listing and file operations.

use anyhow::{anyhow, Context, Result};
use base64::Engine;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tracing::{debug, info, warn};

use super::types::{FileInfo, ListFilesResponse};

/// B2 API base URL for authorization
const B2_AUTH_URL: &str = "https://api.backblazeb2.com/b2api/v2/b2_authorize_account";

/// HTTP client timeout
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// B2 API client for making authenticated requests
#[derive(Clone)]
pub struct B2Client {
    /// HTTP client for making requests
    http_client: Client,
    /// B2 account ID
    account_id: String,
    /// Authorization token (expires after 24 hours)
    auth_token: String,
    /// API URL for this account (varies by region)
    api_url: String,
    /// Bucket ID to operate on
    bucket_id: String,
    /// Bucket name (for display purposes)
    bucket_name: String,
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
}

/// Response from b2_list_buckets API
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ListBucketsResponse {
    buckets: Vec<BucketInfo>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BucketInfo {
    bucket_id: String,
    bucket_name: String,
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
        debug!(api_url = %api_url, "B2 authorization successful");
        
        // Now look up the bucket ID
        let mut client = Self {
            http_client,
            account_id: auth_response.account_id,
            auth_token: auth_response.authorization_token,
            api_url,
            bucket_id: String::new(),
            bucket_name: bucket_name.to_string(),
        };
        
        // Get bucket ID from bucket name
        let bucket_id = client.get_bucket_id(bucket_name).await?;
        client.bucket_id = bucket_id;
        
        info!(bucket_name = bucket_name, bucket_id = %client.bucket_id, "B2 client ready");
        Ok(client)
    }
    
    /// Look up bucket ID from bucket name
    async fn get_bucket_id(&self, bucket_name: &str) -> Result<String> {
        let url = format!("{}/b2api/v2/b2_list_buckets", self.api_url);
        
        let response = self.http_client
            .post(&url)
            .header("Authorization", &self.auth_token)
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
        let url = format!("{}/b2api/v2/b2_list_file_names", self.api_url);
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
                .header("Authorization", &self.auth_token)
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
