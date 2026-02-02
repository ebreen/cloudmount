//! B2 FUSE Filesystem Implementation
//!
//! Implements the fuser::Filesystem trait to expose B2 buckets as local volumes.
//! Uses MetadataCache for high-performance directory browsing.

use std::ffi::OsStr;
use std::sync::Arc;
use std::time::Duration;

use fuser::{FileAttr, FileType, Filesystem, ReplyAttr, ReplyDirectory, ReplyEntry, Request};
use tokio::runtime::Handle;
use tracing::{debug, error, trace, warn};

use super::inode::{InodeTable, ROOT_INO};
use crate::b2::{b2_file_to_attr, directory_attr, B2Client, DirEntry, FileInfo};
use crate::cache::MetadataCache;

/// TTL for FUSE attribute replies (how long kernel caches)
const TTL: Duration = Duration::from_secs(1);

/// B2 Filesystem - mounts a Backblaze B2 bucket as a FUSE volume
pub struct B2Filesystem {
    /// Inode table for path/inode mapping
    inode_table: std::sync::Mutex<InodeTable>,
    /// B2 API client
    b2_client: B2Client,
    /// Bucket ID this filesystem is mounted for
    bucket_id: String,
    /// Tokio runtime handle for async operations
    runtime: Handle,
    /// Metadata cache for file attributes and directory listings
    metadata_cache: Arc<MetadataCache>,
}

impl B2Filesystem {
    /// Create a new B2 filesystem for a bucket
    pub fn new(bucket_id: String, b2_client: B2Client) -> Self {
        // Get the current tokio runtime handle
        let runtime = Handle::current();
        
        Self {
            inode_table: std::sync::Mutex::new(InodeTable::new()),
            b2_client,
            bucket_id,
            runtime,
            metadata_cache: Arc::new(MetadataCache::new()),
        }
    }

    /// Create a new B2 filesystem with a custom cache
    /// 
    /// Useful for testing or when you want to share a cache between filesystems.
    pub fn with_cache(bucket_id: String, b2_client: B2Client, cache: Arc<MetadataCache>) -> Self {
        let runtime = Handle::current();
        
        Self {
            inode_table: std::sync::Mutex::new(InodeTable::new()),
            b2_client,
            bucket_id,
            runtime,
            metadata_cache: cache,
        }
    }

    /// Get file attributes for an inode
    fn get_attr_for_inode(&self, ino: u64) -> Option<FileAttr> {
        if ino == ROOT_INO {
            return Some(directory_attr(ino));
        }

        // Check metadata cache first
        if let Some(attr) = self.metadata_cache.get_attr(ino) {
            trace!(ino = ino, "get_attr_for_inode: cache hit");
            return Some(attr);
        }

        // Get path for this inode
        let path = {
            let inode_table = self.inode_table.lock().unwrap();
            inode_table.get_path(ino)?.to_string()
        };

        // Try to fetch file info from B2
        match self.fetch_file_info_from_b2(&path) {
            Some(file_info) => {
                // Cache the result
                self.metadata_cache.insert_file_info(ino, &file_info);
                Some(b2_file_to_attr(ino, &file_info))
            }
            None => {
                // Return directory attrs for any known inode
                // This allows navigation to work even without full B2 data
                trace!(ino = ino, path = %path, "get_attr_for_inode: using directory fallback");
                Some(directory_attr(ino))
            }
        }
    }

    /// Fetch file info from B2 API
    fn fetch_file_info_from_b2(&self, path: &str) -> Option<FileInfo> {
        // Try to get file info from B2
        let result = self.runtime.block_on(async {
            self.b2_client.get_file_info(path).await
        });

        match result {
            Ok(file_info) => {
                debug!(path = %path, "Fetched file info from B2");
                Some(file_info)
            }
            Err(e) => {
                trace!(path = %path, error = %e, "Could not fetch file info from B2");
                None
            }
        }
    }

    /// List directory contents from B2 with caching
    fn list_directory(&self, parent_ino: u64) -> Vec<DirEntry> {
        // Check directory cache first
        if let Some(cached_entries) = self.metadata_cache.get_dir(parent_ino) {
            debug!(ino = parent_ino, entries = cached_entries.len(), "list_directory: cache hit");
            return cached_entries
                .into_iter()
                .map(|(name, ino, kind)| DirEntry { name, ino, kind })
                .collect();
        }

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
                None => {
                    // Cache the result even for empty directories
                    self.cache_directory_entries(parent_ino, &entries);
                    return entries;
                }
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
                    
                    // Cache the file attributes
                    self.metadata_cache.insert_file_info(ino, &file);
                    
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

        // Cache the directory listing
        self.cache_directory_entries(parent_ino, &entries);

        entries
    }

    /// Cache directory entries for future lookups
    fn cache_directory_entries(&self, parent_ino: u64, entries: &[DirEntry]) {
        let cache_entries: Vec<(String, u64, FileType)> = entries
            .iter()
            .map(|e| (e.name.clone(), e.ino, e.kind))
            .collect();
        self.metadata_cache.insert_dir(parent_ino, cache_entries);
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

    /// Get cache statistics
    pub fn cache_stats(&self) -> (u64, u64, f64) {
        self.metadata_cache.stats()
    }

    /// Log cache metrics
    pub fn log_cache_metrics(&self) {
        self.metadata_cache.log_metrics();
    }

    /// Invalidate cache for an inode
    pub fn invalidate_cache(&self, ino: u64) {
        self.metadata_cache.invalidate(ino);
    }

    /// Clear all caches
    pub fn clear_cache(&self) {
        self.metadata_cache.clear();
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

        // Try to get cached file info first
        let attr = self.metadata_cache.get_attr(ino)
            .or_else(|| {
                // Try to fetch from B2
                self.fetch_file_info_from_b2(&child_path)
                    .map(|file_info| {
                        self.metadata_cache.insert_file_info(ino, &file_info);
                        b2_file_to_attr(ino, &file_info)
                    })
            })
            .unwrap_or_else(|| directory_attr(ino));

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

        // Get directory entries (uses cache if available)
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
