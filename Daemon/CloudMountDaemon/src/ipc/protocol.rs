//! IPC protocol definitions for Swift-Rust communication
//!
//! This module defines the JSON protocol used for communication between
//! the Swift UI and the Rust daemon via Unix domain socket.

use serde::{Deserialize, Serialize};

/// Protocol version for future compatibility
pub const PROTOCOL_VERSION: u32 = 1;

/// Socket path for IPC communication
pub const SOCKET_PATH: &str = "/tmp/cloudmount.sock";

/// Commands sent from Swift UI to Rust daemon
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Command {
    /// Mount a bucket
    #[serde(rename_all = "camelCase")]
    Mount {
        /// Bucket name to mount
        bucket_name: String,
        /// Mount point path
        mountpoint: String,
        /// B2 key ID
        key_id: String,
        /// B2 application key
        key: String,
    },
    /// Unmount a bucket
    #[serde(rename_all = "camelCase")]
    Unmount {
        /// Bucket ID to unmount
        bucket_id: String,
    },
    /// Get daemon status and list of mounts
    GetStatus,
    /// List available buckets for the given credentials
    #[serde(rename_all = "camelCase")]
    ListBuckets {
        /// B2 key ID
        key_id: String,
        /// B2 application key
        key: String,
    },
}

/// Responses sent from Rust daemon to Swift UI
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Response {
    /// Success response
    #[serde(rename_all = "camelCase")]
    Success {
        /// Optional success message
        message: Option<String>,
    },
    /// Error response
    #[serde(rename_all = "camelCase")]
    Error {
        /// Error message
        error: String,
    },
    /// Status response with daemon state
    #[serde(rename_all = "camelCase")]
    Status {
        /// Protocol version
        version: u32,
        /// Whether daemon is healthy
        healthy: bool,
        /// List of active mounts
        mounts: Vec<MountInfo>,
        /// Connection health status ("healthy", "degraded", "unhealthy")
        #[serde(default = "default_health")]
        connection_health: String,
        /// Recent errors
        #[serde(default)]
        recent_errors: Vec<ErrorInfo>,
    },
    /// List of available buckets
    #[serde(rename_all = "camelCase")]
    BucketList {
        /// Available buckets
        buckets: Vec<BucketInfo>,
    },
}

/// Information about an available bucket (from B2 API)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BucketInfo {
    /// Bucket ID
    pub bucket_id: String,
    /// Bucket name
    pub bucket_name: String,
    /// Bucket type (allPublic, allPrivate, etc.)
    pub bucket_type: String,
}

/// Information about a mounted bucket (for status response)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MountInfo {
    /// Bucket ID
    pub bucket_id: String,
    /// Bucket name
    pub bucket_name: String,
    /// Mount point path
    pub mountpoint: String,
    /// Number of pending file uploads
    #[serde(default)]
    pub pending_uploads: u32,
    /// Last error message (if any)
    #[serde(default)]
    pub last_error: Option<String>,
    /// Total bytes used by the bucket (None when not yet calculated)
    #[serde(default)]
    pub total_bytes_used: Option<u64>,
}

/// Information about a recent error
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorInfo {
    /// Unix timestamp of the error
    pub timestamp: u64,
    /// What operation was attempted
    pub operation: String,
    /// File path involved (if any)
    pub path: String,
    /// Error description
    pub error: String,
}

/// Default health value for deserialization
fn default_health() -> String {
    "healthy".to_string()
}

/// Parse a JSON command from bytes
pub fn parse_command(data: &[u8]) -> Result<Command, serde_json::Error> {
    serde_json::from_slice(data)
}

/// Serialize a response to JSON bytes
pub fn serialize_response(response: &Response) -> Result<Vec<u8>, serde_json::Error> {
    let mut json = serde_json::to_vec(response)?;
    json.push(b'\n'); // Add newline delimiter
    Ok(json)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_mount_command() {
        let json = r#"{"type":"mount","bucketName":"my-bucket","mountpoint":"/Volumes/MyBucket","keyId":"004xxx","key":"K004xxx"}"#;
        let cmd = parse_command(json.as_bytes()).unwrap();
        match cmd {
            Command::Mount {
                bucket_name,
                mountpoint,
                key_id,
                key,
            } => {
                assert_eq!(bucket_name, "my-bucket");
                assert_eq!(mountpoint, "/Volumes/MyBucket");
                assert_eq!(key_id, "004xxx");
                assert_eq!(key, "K004xxx");
            }
            _ => panic!("Expected Mount command"),
        }
    }

    #[test]
    fn test_parse_unmount_command() {
        let json = r#"{"type":"unmount","bucketId":"bucket-123"}"#;
        let cmd = parse_command(json.as_bytes()).unwrap();
        match cmd {
            Command::Unmount { bucket_id } => {
                assert_eq!(bucket_id, "bucket-123");
            }
            _ => panic!("Expected Unmount command"),
        }
    }

    #[test]
    fn test_parse_get_status_command() {
        let json = r#"{"type":"getStatus"}"#;
        let cmd = parse_command(json.as_bytes()).unwrap();
        match cmd {
            Command::GetStatus => {}
            _ => panic!("Expected GetStatus command"),
        }
    }

    #[test]
    fn test_serialize_success_response() {
        let response = Response::Success {
            message: Some("Mounted successfully".to_string()),
        };
        let json = serialize_response(&response).unwrap();
        let json_str = String::from_utf8(json).unwrap();
        assert!(json_str.contains("success"));
        assert!(json_str.contains("Mounted successfully"));
    }

    #[test]
    fn test_serialize_error_response() {
        let response = Response::Error {
            error: "Bucket not found".to_string(),
        };
        let json = serialize_response(&response).unwrap();
        let json_str = String::from_utf8(json).unwrap();
        assert!(json_str.contains("error"));
        assert!(json_str.contains("Bucket not found"));
    }

    #[test]
    fn test_serialize_status_response() {
        let response = Response::Status {
            version: 1,
            healthy: true,
            mounts: vec![MountInfo {
                bucket_id: "b123".to_string(),
                bucket_name: "my-bucket".to_string(),
                mountpoint: "/Volumes/MyBucket".to_string(),
                pending_uploads: 0,
                last_error: None,
                total_bytes_used: None,
            }],
            connection_health: "healthy".to_string(),
            recent_errors: vec![],
        };
        let json = serialize_response(&response).unwrap();
        let json_str = String::from_utf8(json).unwrap();
        assert!(json_str.contains("status"));
        assert!(json_str.contains("my-bucket"));
    }

    #[test]
    fn test_serialize_status_with_usage() {
        let response = Response::Status {
            version: 1,
            healthy: true,
            mounts: vec![MountInfo {
                bucket_id: "b456".to_string(),
                bucket_name: "data-bucket".to_string(),
                mountpoint: "/Volumes/DataBucket".to_string(),
                pending_uploads: 2,
                last_error: None,
                total_bytes_used: Some(1_073_741_824), // 1 GiB
            }],
            connection_health: "healthy".to_string(),
            recent_errors: vec![],
        };
        let json = serialize_response(&response).unwrap();
        let json_str = String::from_utf8(json).unwrap();
        assert!(json_str.contains("totalBytesUsed"));
        assert!(json_str.contains("1073741824"));
    }
}
