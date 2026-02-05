//! B2 FUSE Filesystem Implementation
//!
//! Implements the fuser::Filesystem trait to expose B2 buckets as local volumes.
//! Uses MetadataCache for high-performance directory browsing.

use std::ffi::OsStr;
use std::io::{Read, Seek, SeekFrom, Write};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use fuser::{
    FileAttr, FileType, Filesystem, ReplyAttr, ReplyCreate, ReplyData, ReplyDirectory,
    ReplyEmpty, ReplyEntry, ReplyOpen, ReplyStatfs, ReplyWrite, ReplyXattr, Request,
};
use tokio::runtime::Handle;
use tracing::{debug, error, info, trace, warn};

use super::handles::HandleTable;
use super::inode::{InodeTable, ROOT_INO};
use crate::b2::{b2_file_to_attr, directory_attr, stub_file_attr, B2Client, DirEntry, FileInfo};
use crate::cache::{FileCache, MetadataCache};

/// TTL for FUSE attribute replies (how long kernel caches)
const TTL: Duration = Duration::from_secs(1);

/// Check if a filename is a macOS metadata file that should be suppressed
///
/// Returning ENOENT for these prevents macOS from making B2 API calls
/// for files that will never exist on cloud storage.
fn is_suppressed_name(name: &str) -> bool {
    // Exact matches
    matches!(
        name,
        ".DS_Store"
            | ".localized"
            | ".hidden"
            | ".Spotlight-V100"
            | ".Trashes"
            | ".fseventsd"
            | ".TemporaryItems"
            | ".VolumeIcon.icns"
            | "Icon\r"
    ) ||
    // Prefix matches
    name.starts_with("._") ||
    name.starts_with(".com.apple.")
}

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
    /// Metadata cache for file attributes and directory listings
    metadata_cache: Arc<MetadataCache>,
    /// Local file cache for downloaded content
    file_cache: Arc<FileCache>,
    /// Open file handle table
    handle_table: Mutex<HandleTable>,
}

impl B2Filesystem {
    /// Create a new B2 filesystem for a bucket
    pub fn new(bucket_id: String, b2_client: B2Client) -> Self {
        let runtime = Handle::current();
        let file_cache = FileCache::new(&bucket_id)
            .expect("Failed to create file cache");

        Self {
            inode_table: Mutex::new(InodeTable::new()),
            b2_client,
            bucket_id,
            runtime,
            metadata_cache: Arc::new(MetadataCache::new()),
            file_cache: Arc::new(file_cache),
            handle_table: Mutex::new(HandleTable::new()),
        }
    }

    /// Create a new B2 filesystem with a custom metadata cache
    /// 
    /// Useful for testing or when you want to share a cache between filesystems.
    pub fn with_cache(bucket_id: String, b2_client: B2Client, cache: Arc<MetadataCache>) -> Self {
        let runtime = Handle::current();
        let file_cache = FileCache::new(&bucket_id)
            .expect("Failed to create file cache");

        Self {
            inode_table: Mutex::new(InodeTable::new()),
            b2_client,
            bucket_id,
            runtime,
            metadata_cache: cache,
            file_cache: Arc::new(file_cache),
            handle_table: Mutex::new(HandleTable::new()),
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
            Ok(Some(file_info)) => {
                // Cache the result
                self.metadata_cache.insert_file_info(ino, &file_info);
                Some(b2_file_to_attr(ino, &file_info))
            }
            Ok(None) | Err(()) => {
                // Return directory attrs for any known inode
                // This allows navigation to work even without full B2 data
                trace!(ino = ino, path = %path, "get_attr_for_inode: using directory fallback");
                Some(directory_attr(ino))
            }
        }
    }

    /// Fetch file info from B2 API
    ///
    /// Returns Ok(Some(info)) if found, Ok(None) if definitely not found,
    /// Err if an API/network error occurred (caller should NOT negative-cache).
    fn fetch_file_info_from_b2(&self, path: &str) -> Result<Option<FileInfo>, ()> {
        let result = self.runtime.block_on(async {
            self.b2_client.get_file_info(path).await
        });

        match result {
            Ok(file_info) => {
                debug!(path = %path, "Fetched file info from B2");
                Ok(Some(file_info))
            }
            Err(e) => {
                let err_str = e.to_string();
                if err_str.contains("File not found") {
                    // Definitive: file does not exist in B2
                    trace!(path = %path, "File not found in B2");
                    Ok(None)
                } else {
                    // API/network error — file might exist but we can't confirm
                    warn!(path = %path, error = %e, "B2 API error during file lookup");
                    Err(())
                }
            }
        }
    }

    /// Check if a path is a directory in B2
    ///
    /// B2 virtual directories may not have an explicit folder marker file.
    /// This checks for: (1) a folder marker "path/", or (2) any children under "path/".
    fn is_b2_directory(&self, path: &str) -> bool {
        let prefix = if path.ends_with('/') {
            path.to_string()
        } else {
            format!("{}/", path)
        };

        let result = self.runtime.block_on(async {
            self.b2_client.list_file_names(Some(&prefix), Some("/")).await
        });

        match result {
            Ok(files) => {
                let is_dir = !files.is_empty();
                if is_dir {
                    debug!(path = %path, children = files.len(), "Path confirmed as B2 directory");
                }
                is_dir
            }
            Err(e) => {
                trace!(path = %path, error = %e, "Could not check if path is B2 directory");
                false
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
                        Some(p) => format!("{}/{}", p.trim_end_matches('/'), entry_name.trim_start_matches('/')),
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
                error!(error = %e, prefix = ?prefix, ino = parent_ino, "Failed to list B2 directory — files may appear missing");
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

    /// Clean up local state after a file/directory is deleted
    fn cleanup_after_delete(&self, path: &str, parent_ino: u64) {
        // Remove inode
        {
            let mut inode_table = self.inode_table.lock().unwrap();
            if let Some(ino) = inode_table.remove_by_path(path) {
                self.metadata_cache.invalidate(ino);
            }
        }
        // Invalidate parent directory cache
        self.metadata_cache.invalidate(parent_ino);
        // Remove from file cache
        self.file_cache.invalidate(path);
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

        // Suppress macOS metadata files to minimize B2 API calls
        if is_suppressed_name(&name_str) {
            trace!(name = %name_str, "lookup: suppressed macOS metadata file");
            // Also add to negative cache to prevent repeat lookups
            let parent_path = {
                let inode_table = self.inode_table.lock().unwrap();
                inode_table.get_path(parent).unwrap_or("").to_string()
            };
            let child_path = if parent_path.is_empty() {
                name_str.to_string()
            } else {
                format!("{}/{}", parent_path, name_str)
            };
            self.metadata_cache.insert_negative(&child_path);
            reply.error(libc::ENOENT);
            return;
        }

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

        // Check negative cache before making API call
        if self.metadata_cache.is_negative_cached(&child_path) {
            trace!(path = %child_path, "lookup: negative cache hit");
            reply.error(libc::ENOENT);
            return;
        }

        // Get or create inode for this path
        let ino = {
            let mut inode_table = self.inode_table.lock().unwrap();
            inode_table.lookup_or_create(&child_path)
        };

        // Try to get cached file info first
        let attr = self.metadata_cache.get_attr(ino)
            .or_else(|| {
                // Try to fetch from B2 as a file
                match self.fetch_file_info_from_b2(&child_path) {
                    Ok(Some(file_info)) => {
                        self.metadata_cache.insert_file_info(ino, &file_info);
                        Some(b2_file_to_attr(ino, &file_info))
                    }
                    Ok(None) => {
                        // Definitively not found as a file — check if it's a virtual directory
                        // B2 virtual directories don't have an exact file entry;
                        // they exist implicitly via child file paths or folder markers
                        if self.is_b2_directory(&child_path) {
                            let attr = directory_attr(ino);
                            self.metadata_cache.insert_attr(ino, attr);
                            Some(attr)
                        } else {
                            // Truly not found — add to negative cache
                            self.metadata_cache.insert_negative(&child_path);
                            None
                        }
                    }
                    Err(()) => {
                        // API error — don't add to negative cache since file might exist.
                        // Return directory fallback to allow navigation to continue.
                        debug!(path = %child_path, "lookup: B2 API error, using directory fallback");
                        Some(directory_attr(ino))
                    }
                }
            });

        match attr {
            Some(attr) => reply.entry(&TTL, &attr, 0),
            None => reply.error(libc::ENOENT),
        }
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
        reply: ReplyEmpty,
    ) {
        debug!(ino = ino, "releasedir");
        reply.ok();
    }

    /// Open a file
    fn open(&mut self, _req: &Request<'_>, ino: u64, flags: i32, reply: ReplyOpen) {
        debug!(ino = ino, flags = flags, "open");

        // Get path for this inode
        let path = {
            let inode_table = self.inode_table.lock().unwrap();
            match inode_table.get_path(ino) {
                Some(p) => p.to_string(),
                None => {
                    warn!(ino = ino, "open: inode not found");
                    reply.error(libc::ENOENT);
                    return;
                }
            }
        };

        let is_write = (flags & libc::O_ACCMODE) != libc::O_RDONLY;
        let is_trunc = (flags & libc::O_TRUNC) != 0;

        // For truncate mode, create an empty temp file instead of downloading
        let local_path = if is_trunc {
            // Create empty temp file for overwrite
            let cache_dir = self.file_cache.cache_dir().join("tmp");
            let _ = std::fs::create_dir_all(&cache_dir);
            match tempfile::NamedTempFile::new_in(&cache_dir) {
                Ok(tmp) => match tmp.keep() {
                    Ok((_, path)) => path,
                    Err(e) => {
                        error!(error = %e, "Failed to persist temp file for truncate");
                        reply.error(libc::EIO);
                        return;
                    }
                },
                Err(e) => {
                    error!(error = %e, "Failed to create temp file for truncate");
                    reply.error(libc::EIO);
                    return;
                }
            }
        } else {
            // Get file size from cache or B2
            let size = self
                .metadata_cache
                .get_attr(ino)
                .map(|a| a.size)
                .unwrap_or_else(|| {
                    self.fetch_file_info_from_b2(&path)
                        .ok()
                        .flatten()
                        .map(|fi| fi.content_length)
                        .unwrap_or(0)
                });

            // Download file to local cache
            let b2_client = self.b2_client.clone();
            let runtime = self.runtime.clone();
            let file_path = path.clone();

            match self.file_cache.get_or_fetch(&path, size, move || {
                runtime.block_on(async { b2_client.download_file(&file_path, None).await })
            }) {
                Ok(p) => p,
                Err(e) => {
                    error!(path = %path, error = %e, "Failed to download file for open");
                    reply.error(libc::EIO);
                    return;
                }
            }
        };

        // Create file handle
        let mut handle_table = self.handle_table.lock().unwrap();
        let fh = if is_write {
            handle_table.open_write(ino, path.clone(), local_path)
        } else {
            handle_table.open_read(ino, path.clone(), local_path)
        };

        match fh {
            Ok(fh) => {
                info!(fh = fh, path = %path, is_write = is_write, "File opened");
                reply.opened(fh, 0);
            }
            Err(e) => {
                error!(path = %path, error = %e, "Failed to open local cached file");
                reply.error(libc::EIO);
            }
        }
    }

    /// Create and open a new file
    fn create(
        &mut self,
        _req: &Request<'_>,
        parent: u64,
        name: &OsStr,
        _mode: u32,
        _umask: u32,
        flags: i32,
        reply: ReplyCreate,
    ) {
        let name_str = name.to_string_lossy();
        debug!(parent = parent, name = %name_str, "create");

        // Suppress macOS metadata files
        if is_suppressed_name(&name_str) {
            reply.error(libc::EACCES);
            return;
        }

        // Build full path
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

        let child_path = if parent_path.is_empty() {
            name_str.to_string()
        } else {
            format!("{}/{}", parent_path, name_str)
        };

        // Create temp file
        let cache_dir = self.file_cache.cache_dir().join("tmp");
        let _ = std::fs::create_dir_all(&cache_dir);
        let local_path = match tempfile::NamedTempFile::new_in(&cache_dir) {
            Ok(tmp) => match tmp.keep() {
                Ok((_, path)) => path,
                Err(e) => {
                    error!(error = %e, "create: failed to persist temp file");
                    reply.error(libc::EIO);
                    return;
                }
            },
            Err(e) => {
                error!(error = %e, "create: failed to create temp file");
                reply.error(libc::EIO);
                return;
            }
        };

        // Create inode
        let ino = {
            let mut inode_table = self.inode_table.lock().unwrap();
            inode_table.lookup_or_create(&child_path)
        };

        // Remove from negative cache if present
        self.metadata_cache.remove_negative(&child_path);

        // Create file handle
        let mut handle_table = self.handle_table.lock().unwrap();
        let fh = match handle_table.open_write(ino, child_path.clone(), local_path) {
            Ok(fh) => fh,
            Err(e) => {
                error!(error = %e, "create: failed to open file handle");
                reply.error(libc::EIO);
                return;
            }
        };

        let attr = stub_file_attr(ino, 0);
        self.metadata_cache.insert_attr(ino, attr);

        // Invalidate parent directory cache
        self.metadata_cache.invalidate(parent);

        let _ = flags; // unused but required by trait
        info!(path = %child_path, fh = fh, "File created");
        reply.created(&TTL, &attr, 0, fh, 0);
    }

    /// Write data to an open file
    fn write(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        fh: u64,
        offset: i64,
        data: &[u8],
        _write_flags: u32,
        _flags: i32,
        _lock_owner: Option<u64>,
        reply: ReplyWrite,
    ) {
        trace!(ino = ino, fh = fh, offset = offset, size = data.len(), "write");

        let mut handle_table = self.handle_table.lock().unwrap();
        let handle = match handle_table.get_mut(fh) {
            Some(h) => h,
            None => {
                warn!(fh = fh, "write: invalid file handle");
                reply.error(libc::EBADF);
                return;
            }
        };

        // Seek to offset
        if let Err(e) = handle.file.seek(SeekFrom::Start(offset as u64)) {
            error!(fh = fh, offset = offset, error = %e, "write: seek failed");
            reply.error(libc::EIO);
            return;
        }

        // Write data
        match handle.file.write_all(data) {
            Ok(()) => {
                handle.is_dirty = true;
                reply.written(data.len() as u32);
            }
            Err(e) => {
                error!(fh = fh, error = %e, "write: write failed");
                reply.error(libc::EIO);
            }
        }
    }

    /// Read data from an open file
    fn read(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        fh: u64,
        offset: i64,
        size: u32,
        _flags: i32,
        _lock_owner: Option<u64>,
        reply: ReplyData,
    ) {
        trace!(ino = ino, fh = fh, offset = offset, size = size, "read");

        let mut handle_table = self.handle_table.lock().unwrap();
        let handle = match handle_table.get_mut(fh) {
            Some(h) => h,
            None => {
                warn!(fh = fh, "read: invalid file handle");
                reply.error(libc::EBADF);
                return;
            }
        };

        // Seek to offset
        if let Err(e) = handle.file.seek(SeekFrom::Start(offset as u64)) {
            error!(fh = fh, offset = offset, error = %e, "read: seek failed");
            reply.error(libc::EIO);
            return;
        }

        // Read data
        let mut buf = vec![0u8; size as usize];
        match handle.file.read(&mut buf) {
            Ok(bytes_read) => {
                buf.truncate(bytes_read);
                reply.data(&buf);
            }
            Err(e) => {
                error!(fh = fh, error = %e, "read: read failed");
                reply.error(libc::EIO);
            }
        }
    }

    /// Flush is called on each close() of a file descriptor
    fn flush(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        fh: u64,
        _lock_owner: u64,
        reply: ReplyEmpty,
    ) {
        trace!(ino = ino, fh = fh, "flush");
        // No-op for MVP — we upload on release() (last close), not flush()
        reply.ok();
    }

    /// Release (close) an open file — uploads dirty files to B2
    fn release(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        fh: u64,
        _flags: i32,
        _lock_owner: Option<u64>,
        _flush: bool,
        reply: ReplyEmpty,
    ) {
        debug!(ino = ino, fh = fh, "release");

        let mut handle_table = self.handle_table.lock().unwrap();
        match handle_table.close(fh) {
            Some(handle) => {
                if handle.is_dirty {
                    // Read temp file content and upload to B2
                    let upload_path = handle.path.clone();
                    let local_path = handle.local_path.clone();
                    drop(handle); // Close the file handle before reading

                    match std::fs::read(&local_path) {
                        Ok(data) => {
                            let b2_client = self.b2_client.clone();
                            let result = self.runtime.block_on(async {
                                b2_client
                                    .upload_file(
                                        &upload_path,
                                        &data,
                                        "application/octet-stream",
                                    )
                                    .await
                            });

                            match result {
                                Ok(file_info) => {
                                    info!(
                                        path = %upload_path,
                                        size = data.len(),
                                        "File uploaded to B2 on close"
                                    );
                                    // Update caches with new file info
                                    self.metadata_cache.insert_file_info(ino, &file_info);
                                    // Invalidate parent directory cache
                                    let parent_ino = {
                                        let inode_table = self.inode_table.lock().unwrap();
                                        inode_table.get_parent_ino(ino)
                                    };
                                    self.metadata_cache.invalidate(parent_ino);
                                    // Update file cache with new content
                                    self.file_cache.invalidate(&upload_path);
                                }
                                Err(e) => {
                                    error!(
                                        path = %upload_path,
                                        error = %e,
                                        "Failed to upload file to B2 on close"
                                    );
                                    // Keep the local file so data isn't lost
                                }
                            }
                        }
                        Err(e) => {
                            error!(
                                path = %upload_path,
                                error = %e,
                                "Failed to read temp file for upload"
                            );
                        }
                    }
                }
                reply.ok();
            }
            None => {
                warn!(fh = fh, "release: unknown file handle");
                reply.ok();
            }
        }
    }

    /// Set file attributes (handles truncate)
    fn setattr(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        _mode: Option<u32>,
        _uid: Option<u32>,
        _gid: Option<u32>,
        size: Option<u64>,
        _atime: Option<fuser::TimeOrNow>,
        _mtime: Option<fuser::TimeOrNow>,
        _ctime: Option<SystemTime>,
        _fh: Option<u64>,
        _crtime: Option<SystemTime>,
        _chgtime: Option<SystemTime>,
        _bkuptime: Option<SystemTime>,
        _flags: Option<u32>,
        reply: ReplyAttr,
    ) {
        debug!(ino = ino, size = ?size, "setattr");

        // Handle truncate
        if let Some(new_size) = size {
            if new_size == 0 {
                // Truncate to zero — if there's an open write handle, truncate the file
                let mut handle_table = self.handle_table.lock().unwrap();
                // Find any open handle for this inode
                // (we don't have a by-ino lookup, so check _fh parameter)
                if let Some(fh) = _fh {
                    if let Some(handle) = handle_table.get_mut(fh) {
                        if let Err(e) = handle.file.set_len(0) {
                            error!(ino = ino, error = %e, "setattr: truncate failed");
                        }
                        let _ = handle.file.seek(SeekFrom::Start(0));
                        handle.is_dirty = true;
                    }
                }
            }
        }

        // Return current (or updated) attributes
        match self.get_attr_for_inode(ino) {
            Some(mut attr) => {
                if let Some(new_size) = size {
                    attr.size = new_size;
                    attr.blocks = (new_size + 511) / 512;
                    attr.mtime = SystemTime::now();
                    self.metadata_cache.insert_attr(ino, attr);
                }
                reply.attr(&TTL, &attr);
            }
            None => {
                reply.error(libc::ENOENT);
            }
        }
    }

    /// Delete a file
    fn unlink(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEmpty) {
        let name_str = name.to_string_lossy();
        debug!(parent = parent, name = %name_str, "unlink");

        // Build full path
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

        let child_path = if parent_path.is_empty() {
            name_str.to_string()
        } else {
            format!("{}/{}", parent_path, name_str)
        };

        // Get file info (need file_id for delete)
        let file_info = match self.fetch_file_info_from_b2(&child_path) {
            Ok(Some(fi)) => fi,
            Ok(None) => {
                // File might only exist locally (newly created, not yet uploaded)
                // Clean up local state
                let mut inode_table = self.inode_table.lock().unwrap();
                inode_table.remove_by_path(&child_path);
                self.metadata_cache.invalidate(parent);
                self.file_cache.invalidate(&child_path);
                reply.ok();
                return;
            }
            Err(()) => {
                error!(path = %child_path, "unlink: B2 API error looking up file");
                reply.error(libc::EIO);
                return;
            }
        };

        let file_id = match &file_info.file_id {
            Some(id) => id.clone(),
            None => {
                // No file_id — use hide instead
                let result = self.runtime.block_on(async {
                    self.b2_client.hide_file(&child_path).await
                });
                match result {
                    Ok(_) => {
                        self.cleanup_after_delete(&child_path, parent);
                        reply.ok();
                    }
                    Err(e) => {
                        error!(path = %child_path, error = %e, "unlink: hide_file failed");
                        reply.error(libc::EIO);
                    }
                }
                return;
            }
        };

        // Delete file from B2
        let result = self.runtime.block_on(async {
            self.b2_client.delete_file(&child_path, &file_id).await
        });

        match result {
            Ok(()) => {
                self.cleanup_after_delete(&child_path, parent);
                info!(path = %child_path, "File deleted");
                reply.ok();
            }
            Err(e) => {
                error!(path = %child_path, error = %e, "unlink: delete failed");
                reply.error(libc::EIO);
            }
        }
    }

    /// Remove a directory
    fn rmdir(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEmpty) {
        let name_str = name.to_string_lossy();
        debug!(parent = parent, name = %name_str, "rmdir");

        // Build full path
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

        let dir_path = if parent_path.is_empty() {
            name_str.to_string()
        } else {
            format!("{}/{}", parent_path, name_str)
        };

        // Check if directory is empty
        let prefix = format!("{}/", dir_path);
        let files = self.runtime.block_on(async {
            self.b2_client.list_file_names(Some(&prefix), None).await
        });

        match files {
            Ok(files) => {
                // Filter out the folder marker itself
                let real_files: Vec<_> = files
                    .iter()
                    .filter(|f| f.file_name != prefix)
                    .collect();
                if !real_files.is_empty() {
                    reply.error(libc::ENOTEMPTY);
                    return;
                }
            }
            Err(e) => {
                error!(path = %dir_path, error = %e, "rmdir: failed to check dir contents");
                reply.error(libc::EIO);
                return;
            }
        }

        // Delete the folder marker if it exists
        let folder_marker = format!("{}/", dir_path);
        if let Some(fi) = self.fetch_file_info_from_b2(&folder_marker).ok().flatten() {
            if let Some(file_id) = &fi.file_id {
                let _ = self.runtime.block_on(async {
                    self.b2_client.delete_file(&folder_marker, file_id).await
                });
            }
        }

        self.cleanup_after_delete(&dir_path, parent);
        info!(path = %dir_path, "Directory removed");
        reply.ok();
    }

    /// Create a directory
    fn mkdir(
        &mut self,
        _req: &Request<'_>,
        parent: u64,
        name: &OsStr,
        _mode: u32,
        _umask: u32,
        reply: ReplyEntry,
    ) {
        let name_str = name.to_string_lossy();
        debug!(parent = parent, name = %name_str, "mkdir");

        // Build full path
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

        let dir_path = if parent_path.is_empty() {
            name_str.to_string()
        } else {
            format!("{}/{}", parent_path, name_str)
        };

        // Create folder marker in B2
        let result = self.runtime.block_on(async {
            self.b2_client.create_folder(&dir_path).await
        });

        match result {
            Ok(_file_info) => {
                let ino = {
                    let mut inode_table = self.inode_table.lock().unwrap();
                    inode_table.lookup_or_create(&dir_path)
                };

                let attr = directory_attr(ino);
                self.metadata_cache.insert_attr(ino, attr);
                self.metadata_cache.invalidate(parent);
                self.metadata_cache.remove_negative(&dir_path);

                info!(path = %dir_path, "Directory created");
                reply.entry(&TTL, &attr, 0);
            }
            Err(e) => {
                error!(path = %dir_path, error = %e, "mkdir: failed to create folder");
                reply.error(libc::EIO);
            }
        }
    }

    /// Rename/move a file or directory
    fn rename(
        &mut self,
        _req: &Request<'_>,
        parent: u64,
        name: &OsStr,
        newparent: u64,
        newname: &OsStr,
        _flags: u32,
        reply: ReplyEmpty,
    ) {
        let old_name = name.to_string_lossy();
        let new_name = newname.to_string_lossy();
        debug!(parent = parent, name = %old_name, newparent = newparent, newname = %new_name, "rename");

        // Build old path
        let old_parent_path = {
            let inode_table = self.inode_table.lock().unwrap();
            match inode_table.get_path(parent) {
                Some(p) => p.to_string(),
                None => {
                    reply.error(libc::ENOENT);
                    return;
                }
            }
        };
        let old_path = if old_parent_path.is_empty() {
            old_name.to_string()
        } else {
            format!("{}/{}", old_parent_path, old_name)
        };

        // Build new path
        let new_parent_path = {
            let inode_table = self.inode_table.lock().unwrap();
            match inode_table.get_path(newparent) {
                Some(p) => p.to_string(),
                None => {
                    reply.error(libc::ENOENT);
                    return;
                }
            }
        };
        let new_path = if new_parent_path.is_empty() {
            new_name.to_string()
        } else {
            format!("{}/{}", new_parent_path, new_name)
        };

        // Get source file info
        let file_info = match self.fetch_file_info_from_b2(&old_path) {
            Ok(Some(fi)) => fi,
            Ok(None) => {
                // Check if it's a directory
                if self.fetch_file_info_from_b2(&format!("{}/", old_path)).ok().flatten().is_some() {
                    // Directory rename — not supported for MVP
                    warn!(path = %old_path, "rename: directory rename not supported");
                    reply.error(libc::ENOSYS);
                    return;
                }
                reply.error(libc::ENOENT);
                return;
            }
            Err(()) => {
                error!(path = %old_path, "rename: B2 API error looking up source file");
                reply.error(libc::EIO);
                return;
            }
        };

        let source_file_id = match &file_info.file_id {
            Some(id) => id.clone(),
            None => {
                error!(path = %old_path, "rename: no file_id for source");
                reply.error(libc::EIO);
                return;
            }
        };

        // Server-side copy to new location
        let result = self.runtime.block_on(async {
            self.b2_client.copy_file(&source_file_id, &new_path).await
        });

        match result {
            Ok(_new_fi) => {
                // Delete the original
                let delete_result = self.runtime.block_on(async {
                    self.b2_client.delete_file(&old_path, &source_file_id).await
                });

                if let Err(e) = delete_result {
                    warn!(
                        old_path = %old_path,
                        error = %e,
                        "rename: copy succeeded but delete of original failed"
                    );
                }

                // Update inode table
                {
                    let mut inode_table = self.inode_table.lock().unwrap();
                    if let Some(ino) = inode_table.get_ino(&old_path) {
                        inode_table.rename(ino, &new_path);
                    }
                }

                // Invalidate caches
                self.metadata_cache.invalidate(parent);
                self.metadata_cache.invalidate(newparent);
                self.file_cache.invalidate(&old_path);

                info!(old = %old_path, new = %new_path, "File renamed");
                reply.ok();
            }
            Err(e) => {
                error!(old = %old_path, new = %new_path, error = %e, "rename: copy failed");
                reply.error(libc::EIO);
            }
        }
    }

    /// Get extended attributes — suppress all to avoid B2 API calls
    fn getxattr(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        name: &OsStr,
        _size: u32,
        reply: ReplyXattr,
    ) {
        trace!(ino = ino, name = ?name, "getxattr: suppressed");
        reply.error(libc::ENODATA);
    }

    /// List extended attributes — return empty to avoid B2 API calls
    fn listxattr(&mut self, _req: &Request<'_>, ino: u64, size: u32, reply: ReplyXattr) {
        trace!(ino = ino, size = size, "listxattr: suppressed");
        if size == 0 {
            reply.size(0);
        } else {
            reply.data(&[]);
        }
    }

    /// Return filesystem statistics
    fn statfs(&mut self, _req: &Request<'_>, _ino: u64, reply: ReplyStatfs) {
        trace!("statfs");
        // Return generous static values — B2 doesn't have traditional filesystem limits
        reply.statfs(
            u64::MAX / 4096, // blocks (virtually unlimited)
            u64::MAX / 4096, // bfree
            u64::MAX / 4096, // bavail
            0,               // files (unknown)
            0,               // ffree
            4096,            // bsize
            255,             // namelen
            4096,            // frsize (fragment size)
        );
    }
}
