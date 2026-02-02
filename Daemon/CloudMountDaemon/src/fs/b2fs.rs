//! B2 FUSE Filesystem Implementation
//!
//! Implements the fuser::Filesystem trait to expose B2 buckets as local volumes.

use std::collections::HashMap;
use std::ffi::OsStr;
use std::sync::Mutex;
use std::time::Duration;

use fuser::{FileAttr, FileType, Filesystem, ReplyAttr, ReplyDirectory, ReplyEntry, Request};
use tokio::runtime::Handle;
use tracing::{debug, error, warn};

use super::inode::{InodeTable, ROOT_INO};
use crate::b2::{b2_file_to_attr, directory_attr, B2Client, DirEntry, FileInfo};

/// TTL for file attributes (how long Finder caches metadata)
const TTL: Duration = Duration::from_secs(1);

/// B2 Filesystem - mounts a Backblaze B2 bucket as a FUSE volume
pub struct B2Filesystem {
    /// Inode table for path/inode mapping
    inode_table: Mutex<InodeTable>,
    /// B2 API client
    b2_client: B2Client,
    /// Bucket ID this filesystem is mounted for
    bucket_id: String,
    /// Tokio runtime handle for async operations
    runtime: Handle,
    /// Cache of file info by path (simple in-memory cache)
    file_cache: Mutex<HashMap<String, FileInfo>>,
}

impl B2Filesystem {
    /// Create a new B2 filesystem for a bucket
    pub fn new(bucket_id: String, b2_client: B2Client) -> Self {
        // Get the current tokio runtime handle
        let runtime = Handle::current();
        
        Self {
            inode_table: Mutex::new(InodeTable::new()),
            b2_client,
            bucket_id,
            runtime,
            file_cache: Mutex::new(HashMap::new()),
        }
    }

    /// Get file attributes for an inode
    fn get_attr_for_inode(&self, ino: u64) -> Option<FileAttr> {
        if ino == ROOT_INO {
            return Some(directory_attr(ino));
        }

        // Get path for this inode
        let path = {
            let inode_table = self.inode_table.lock().unwrap();
            inode_table.get_path(ino)?.to_string()
        };

        // Check cache first
        {
            let cache = self.file_cache.lock().unwrap();
            if let Some(file_info) = cache.get(&path) {
                return Some(b2_file_to_attr(ino, file_info));
            }
        }

        // For now, return directory attrs for any known inode
        // This allows navigation to work even without full B2 data
        Some(directory_attr(ino))
    }

    /// List directory contents from B2
    fn list_directory(&self, parent_ino: u64) -> Vec<DirEntry> {
        let mut entries = Vec::new();

        // Always add . and ..
        entries.push(DirEntry {
            name: ".".to_string(),
            ino: parent_ino,
            kind: FileType::Directory,
        });

        let parent_parent_ino = {
            let inode_table = self.inode_table.lock().unwrap();
            inode_table.get_parent_ino(parent_ino)
        };
        entries.push(DirEntry {
            name: "..".to_string(),
            ino: parent_parent_ino,
            kind: FileType::Directory,
        });

        // Get the path prefix for this directory
        let prefix = {
            let inode_table = self.inode_table.lock().unwrap();
            match inode_table.get_path(parent_ino) {
                Some(p) if p.is_empty() => None, // Root - no prefix
                Some(p) => Some(format!("{}/", p)), // Add trailing slash for prefix
                None => return entries, // Unknown inode
            }
        };

        // Fetch directory listing from B2
        let files = self.runtime.block_on(async {
            self.b2_client
                .list_file_names(prefix.as_deref(), Some("/"))
                .await
        });

        match files {
            Ok(files) => {
                debug!(count = files.len(), prefix = ?prefix, "Got B2 file listing");
                
                // Process each file/folder
                for file in files {
                    let entry_name = self.extract_entry_name(&file.file_name, prefix.as_deref());
                    
                    if entry_name.is_empty() || entry_name == "." || entry_name == ".." {
                        continue;
                    }
                    
                    // Build full path for inode lookup
                    let full_path = match &prefix {
                        Some(p) => format!("{}{}", p.trim_end_matches('/'), entry_name.trim_start_matches('/')),
                        None => entry_name.clone(),
                    };
                    let full_path = full_path.trim_matches('/').to_string();
                    
                    // Get or create inode
                    let ino = {
                        let mut inode_table = self.inode_table.lock().unwrap();
                        inode_table.lookup_or_create(&full_path)
                    };
                    
                    // Cache the file info
                    {
                        let mut cache = self.file_cache.lock().unwrap();
                        cache.insert(full_path, file.clone());
                    }
                    
                    // Determine type
                    let kind = if file.is_directory() {
                        FileType::Directory
                    } else {
                        FileType::RegularFile
                    };
                    
                    entries.push(DirEntry {
                        name: entry_name.trim_end_matches('/').to_string(),
                        ino,
                        kind,
                    });
                }
            }
            Err(e) => {
                error!(error = %e, "Failed to list B2 directory");
            }
        }

        entries
    }
    
    /// Extract the entry name from a full B2 path given a prefix
    fn extract_entry_name(&self, file_name: &str, prefix: Option<&str>) -> String {
        let name = match prefix {
            Some(p) => file_name.strip_prefix(p).unwrap_or(file_name),
            None => file_name,
        };
        
        // For directory-style listing with delimiter, we might get "folder/" 
        // Strip any remaining path components (we only want immediate children)
        if let Some(slash_pos) = name.find('/') {
            // This is a "virtual directory" - take everything up to and including the slash
            name[..=slash_pos].to_string()
        } else {
            name.to_string()
        }
    }
}

impl Filesystem for B2Filesystem {
    /// Get file attributes
    fn getattr(&mut self, _req: &Request<'_>, ino: u64, _fh: Option<u64>, reply: ReplyAttr) {
        debug!(ino = ino, "getattr");

        match self.get_attr_for_inode(ino) {
            Some(attr) => {
                reply.attr(&TTL, &attr);
            }
            None => {
                warn!(ino = ino, "getattr: inode not found");
                reply.error(libc::ENOENT);
            }
        }
    }

    /// Look up a file by name in a directory
    fn lookup(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEntry) {
        let name_str = name.to_string_lossy();
        debug!(parent = parent, name = %name_str, "lookup");

        // Get parent path
        let parent_path = {
            let inode_table = self.inode_table.lock().unwrap();
            match inode_table.get_path(parent) {
                Some(p) => p.to_string(),
                None => {
                    reply.error(libc::ENOENT);
                    return;
                }
            }
        };

        // Build full path for the child
        let child_path = if parent_path.is_empty() {
            name_str.to_string()
        } else {
            format!("{}/{}", parent_path, name_str)
        };

        // Get or create inode for this path
        let ino = {
            let mut inode_table = self.inode_table.lock().unwrap();
            inode_table.lookup_or_create(&child_path)
        };

        // Try to get cached file info
        let attr = {
            let cache = self.file_cache.lock().unwrap();
            cache.get(&child_path).map(|f| b2_file_to_attr(ino, f))
        };

        let attr = attr.unwrap_or_else(|| directory_attr(ino));
        reply.entry(&TTL, &attr, 0);
    }

    /// Read directory contents
    fn readdir(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        _fh: u64,
        offset: i64,
        mut reply: ReplyDirectory,
    ) {
        debug!(ino = ino, offset = offset, "readdir");

        // Verify the inode exists
        {
            let inode_table = self.inode_table.lock().unwrap();
            if inode_table.get_path(ino).is_none() && ino != ROOT_INO {
                reply.error(libc::ENOENT);
                return;
            }
        }

        // Get directory entries from B2
        let entries = self.list_directory(ino);

        // Skip entries before offset and add the rest
        for (i, entry) in entries.iter().enumerate().skip(offset as usize) {
            // reply.add returns true if buffer is full
            let buffer_full = reply.add(
                entry.ino,
                (i + 1) as i64, // offset for next entry
                entry.kind,
                &entry.name,
            );

            if buffer_full {
                break;
            }
        }

        reply.ok();
    }

    /// Open a directory
    fn opendir(&mut self, _req: &Request<'_>, ino: u64, _flags: i32, reply: fuser::ReplyOpen) {
        debug!(ino = ino, "opendir");

        // Verify the inode exists and is a directory
        {
            let inode_table = self.inode_table.lock().unwrap();
            if inode_table.get_path(ino).is_none() && ino != ROOT_INO {
                reply.error(libc::ENOENT);
                return;
            }
        }

        // Return a dummy file handle (we don't track state per-open)
        reply.opened(0, 0);
    }

    /// Release (close) a directory
    fn releasedir(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        _fh: u64,
        _flags: i32,
        reply: fuser::ReplyEmpty,
    ) {
        debug!(ino = ino, "releasedir");
        reply.ok();
    }
}
