//! B2 API types and FileAttr conversion
//!
//! Defines types for Backblaze B2 API responses and conversion to FUSE attributes.

use fuser::{FileAttr, FileType};
use serde::{Deserialize, Deserializer};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Deserialize a number that might be encoded as a string or null.
/// B2 API sometimes returns numeric fields as strings (e.g. "1536964279000")
/// and may return null for folder/hide entries.
fn deserialize_flexible_u64<'de, D>(deserializer: D) -> Result<u64, D::Error>
where
    D: Deserializer<'de>,
{
    use serde::de;

    struct FlexibleU64Visitor;

    impl<'de> de::Visitor<'de> for FlexibleU64Visitor {
        type Value = u64;

        fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
            formatter.write_str("a u64, a string containing a u64, or null")
        }

        fn visit_u64<E: de::Error>(self, value: u64) -> Result<u64, E> {
            Ok(value)
        }

        fn visit_i64<E: de::Error>(self, value: i64) -> Result<u64, E> {
            u64::try_from(value).map_err(|_| de::Error::custom("negative value for u64"))
        }

        fn visit_str<E: de::Error>(self, value: &str) -> Result<u64, E> {
            value.parse::<u64>().map_err(de::Error::custom)
        }

        fn visit_none<E: de::Error>(self) -> Result<u64, E> {
            Ok(0)
        }

        fn visit_unit<E: de::Error>(self) -> Result<u64, E> {
            Ok(0)
        }
    }

    deserializer.deserialize_any(FlexibleU64Visitor)
}

/// B2 file/folder information from API responses
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileInfo {
    /// Full file path within the bucket
    pub file_name: String,
    /// File size in bytes (0 for folders)
    #[serde(deserialize_with = "deserialize_flexible_u64")]
    pub content_length: u64,
    /// Upload timestamp in milliseconds since epoch
    #[serde(deserialize_with = "deserialize_flexible_u64")]
    pub upload_timestamp: u64,
    /// Action type: "upload", "folder", "hide", "start"
    pub action: String,
    /// Optional file ID (null for folder entries)
    #[serde(default)]
    pub file_id: Option<String>,
    /// Content type (MIME type, null for folder entries)
    #[serde(default)]
    pub content_type: Option<String>,
}

/// Response from b2_list_file_names API
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListFilesResponse {
    /// List of files in the response
    pub files: Vec<FileInfo>,
    /// Next file name for pagination (None if no more files)
    pub next_file_name: Option<String>,
}

/// Directory entry for readdir results
#[derive(Debug, Clone)]
pub struct DirEntry {
    /// File/folder name (not full path)
    pub name: String,
    /// Inode number
    pub ino: u64,
    /// File type (directory or regular file)
    pub kind: FileType,
}

impl FileInfo {
    /// Check if this entry represents a directory
    pub fn is_directory(&self) -> bool {
        self.action == "folder" || self.file_name.ends_with('/')
    }

    /// Get the base name (last component of path)
    pub fn base_name(&self) -> &str {
        let name = self.file_name.trim_end_matches('/');
        name.rsplit('/').next().unwrap_or(name)
    }
}

/// Convert a B2 FileInfo to FUSE FileAttr
pub fn b2_file_to_attr(ino: u64, file: &FileInfo) -> FileAttr {
    let is_dir = file.is_directory();
    let kind = if is_dir {
        FileType::Directory
    } else {
        FileType::RegularFile
    };

    // Convert B2 timestamp (milliseconds) to SystemTime
    let upload_time = UNIX_EPOCH + Duration::from_millis(file.upload_timestamp);

    // Permissions: 755 for directories, 644 for files
    let perm = if is_dir { 0o755 } else { 0o644 };

    // Get current user/group (typical macOS values)
    let uid = unsafe { libc::getuid() };
    let gid = unsafe { libc::getgid() };

    // Calculate blocks (512-byte blocks as per POSIX)
    let size = file.content_length;
    let blocks = (size + 511) / 512;

    FileAttr {
        ino,
        size,
        blocks,
        atime: upload_time,
        mtime: upload_time,
        ctime: upload_time,
        crtime: upload_time,
        kind,
        perm,
        nlink: if is_dir { 2 } else { 1 },
        uid,
        gid,
        rdev: 0,
        blksize: 4096,
        flags: 0,
    }
}

/// Create a FileAttr for a directory with current time
pub fn directory_attr(ino: u64) -> FileAttr {
    let now = SystemTime::now();
    let uid = unsafe { libc::getuid() };
    let gid = unsafe { libc::getgid() };

    FileAttr {
        ino,
        size: 0,
        blocks: 0,
        atime: now,
        mtime: now,
        ctime: now,
        crtime: now,
        kind: FileType::Directory,
        perm: 0o755,
        nlink: 2,
        uid,
        gid,
        rdev: 0,
        blksize: 4096,
        flags: 0,
    }
}

/// Create a stub FileAttr for a file (used before B2 data is available)
pub fn stub_file_attr(ino: u64, size: u64) -> FileAttr {
    let now = SystemTime::now();
    let uid = unsafe { libc::getuid() };
    let gid = unsafe { libc::getgid() };

    FileAttr {
        ino,
        size,
        blocks: (size + 511) / 512,
        atime: now,
        mtime: now,
        ctime: now,
        crtime: now,
        kind: FileType::RegularFile,
        perm: 0o644,
        nlink: 1,
        uid,
        gid,
        rdev: 0,
        blksize: 4096,
        flags: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_deserialize_upload_file() {
        let json = r#"{
            "fileName": "photos/alice.jpg",
            "contentLength": 12345,
            "uploadTimestamp": 1536964279000,
            "action": "upload",
            "fileId": "4_abc123",
            "contentType": "image/jpeg"
        }"#;
        let info: FileInfo = serde_json::from_str(json).unwrap();
        assert_eq!(info.file_name, "photos/alice.jpg");
        assert_eq!(info.content_length, 12345);
        assert_eq!(info.upload_timestamp, 1536964279000);
        assert_eq!(info.action, "upload");
        assert!(!info.is_directory());
        assert_eq!(info.file_id, Some("4_abc123".to_string()));
    }

    #[test]
    fn test_deserialize_folder_entry() {
        // B2 returns folder entries with null fileId and contentType
        let json = r#"{
            "fileName": "photos/cats/",
            "contentLength": 0,
            "uploadTimestamp": 0,
            "action": "folder",
            "fileId": null,
            "contentType": null
        }"#;
        let info: FileInfo = serde_json::from_str(json).unwrap();
        assert_eq!(info.file_name, "photos/cats/");
        assert_eq!(info.content_length, 0);
        assert_eq!(info.action, "folder");
        assert!(info.is_directory());
        assert_eq!(info.file_id, None);
        assert_eq!(info.content_type, None);
    }

    #[test]
    fn test_deserialize_string_numbers() {
        // B2 API may return numeric fields as strings in some versions
        let json = r#"{
            "fileName": "test.txt",
            "contentLength": "7",
            "uploadTimestamp": "1536964279000",
            "action": "upload",
            "fileId": "4_abc123",
            "contentType": "text/plain"
        }"#;
        let info: FileInfo = serde_json::from_str(json).unwrap();
        assert_eq!(info.content_length, 7);
        assert_eq!(info.upload_timestamp, 1536964279000);
    }

    #[test]
    fn test_deserialize_extra_fields_ignored() {
        // B2 API returns many fields we don't need — they should be ignored
        let json = r#"{
            "accountId": "12345",
            "bucketId": "bucket123",
            "fileName": "test.txt",
            "contentLength": 100,
            "uploadTimestamp": 1000,
            "action": "upload",
            "fileId": "4_abc",
            "contentType": "text/plain",
            "contentSha1": "abc123",
            "fileInfo": {"key": "value"},
            "serverSideEncryption": {"mode": "none"}
        }"#;
        let info: FileInfo = serde_json::from_str(json).unwrap();
        assert_eq!(info.file_name, "test.txt");
        assert_eq!(info.content_length, 100);
    }

    #[test]
    fn test_deserialize_list_response_mixed() {
        // A realistic B2 response mixing upload files and virtual folders
        let json = r#"{
            "files": [
                {
                    "fileName": "photos/alice.jpg",
                    "contentLength": 12345,
                    "uploadTimestamp": 1536964279000,
                    "action": "upload",
                    "fileId": "4_abc123",
                    "contentType": "image/jpeg"
                },
                {
                    "fileName": "photos/cats/",
                    "contentLength": 0,
                    "uploadTimestamp": 0,
                    "action": "folder",
                    "fileId": null,
                    "contentType": null
                },
                {
                    "fileName": "photos/bob.png",
                    "contentLength": 67890,
                    "uploadTimestamp": 1536964288000,
                    "action": "upload",
                    "fileId": "4_def456",
                    "contentType": "image/png"
                }
            ],
            "nextFileName": null
        }"#;
        let resp: ListFilesResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.files.len(), 3);
        assert!(!resp.files[0].is_directory());
        assert!(resp.files[1].is_directory());
        assert!(!resp.files[2].is_directory());
        assert_eq!(resp.next_file_name, None);
    }

    #[test]
    fn test_deserialize_list_response_with_string_numbers() {
        // B2 response where numeric fields are strings
        let json = r#"{
            "files": [
                {
                    "fileName": "test.txt",
                    "contentLength": "7",
                    "uploadTimestamp": "1536964279000",
                    "action": "upload",
                    "fileId": "4_abc",
                    "contentType": "text/plain"
                }
            ],
            "nextFileName": "next.txt"
        }"#;
        let resp: ListFilesResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.files.len(), 1);
        assert_eq!(resp.files[0].content_length, 7);
        assert_eq!(resp.files[0].upload_timestamp, 1536964279000);
        assert_eq!(resp.next_file_name, Some("next.txt".to_string()));
    }

    #[test]
    fn test_is_directory() {
        let upload = FileInfo {
            file_name: "photos/alice.jpg".to_string(),
            content_length: 100,
            upload_timestamp: 1000,
            action: "upload".to_string(),
            file_id: Some("id".to_string()),
            content_type: Some("image/jpeg".to_string()),
        };
        assert!(!upload.is_directory());

        let folder = FileInfo {
            file_name: "photos/cats/".to_string(),
            content_length: 0,
            upload_timestamp: 0,
            action: "folder".to_string(),
            file_id: None,
            content_type: None,
        };
        assert!(folder.is_directory());

        // Folder marker (uploaded file with trailing slash)
        let marker = FileInfo {
            file_name: "photos/dogs/".to_string(),
            content_length: 0,
            upload_timestamp: 1000,
            action: "upload".to_string(),
            file_id: Some("id".to_string()),
            content_type: Some("application/x-directory".to_string()),
        };
        assert!(marker.is_directory());
    }

    #[test]
    fn test_base_name() {
        let file = FileInfo {
            file_name: "photos/alice.jpg".to_string(),
            content_length: 100,
            upload_timestamp: 1000,
            action: "upload".to_string(),
            file_id: None,
            content_type: None,
        };
        assert_eq!(file.base_name(), "alice.jpg");

        let folder = FileInfo {
            file_name: "photos/cats/".to_string(),
            content_length: 0,
            upload_timestamp: 0,
            action: "folder".to_string(),
            file_id: None,
            content_type: None,
        };
        assert_eq!(folder.base_name(), "cats");

        let root_file = FileInfo {
            file_name: "readme.txt".to_string(),
            content_length: 100,
            upload_timestamp: 1000,
            action: "upload".to_string(),
            file_id: None,
            content_type: None,
        };
        assert_eq!(root_file.base_name(), "readme.txt");
    }
}
