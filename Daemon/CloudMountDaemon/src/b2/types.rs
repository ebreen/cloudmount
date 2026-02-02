//! B2 API types and FileAttr conversion
//!
//! Defines types for Backblaze B2 API responses and conversion to FUSE attributes.

use fuser::{FileAttr, FileType};
use serde::Deserialize;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// B2 file/folder information from API responses
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileInfo {
    /// Full file path within the bucket
    pub file_name: String,
    /// File size in bytes (0 for folders)
    pub content_length: u64,
    /// Upload timestamp in milliseconds since epoch
    pub upload_timestamp: u64,
    /// Action type: "upload", "folder", "hide", "start"
    pub action: String,
    /// Optional file ID
    #[serde(default)]
    pub file_id: Option<String>,
    /// Content type (MIME type)
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
