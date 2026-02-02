//! B2 FUSE Filesystem Implementation
//!
//! Implements the fuser::Filesystem trait to expose B2 buckets as local volumes.

use std::ffi::OsStr;
use std::time::Duration;

use fuser::{FileAttr, FileType, Filesystem, ReplyAttr, ReplyDirectory, ReplyEntry, Request};
use tracing::{debug, warn};

use super::inode::{InodeTable, ROOT_INO};
use crate::b2::{directory_attr, DirEntry};

/// TTL for file attributes (how long Finder caches metadata)
const TTL: Duration = Duration::from_secs(1);

/// B2 Filesystem - mounts a Backblaze B2 bucket as a FUSE volume
pub struct B2Filesystem {
    /// Inode table for path/inode mapping
    inode_table: InodeTable,
    /// Bucket ID this filesystem is mounted for
    bucket_id: String,
    // TODO: Add B2Client in 02-02
}

impl B2Filesystem {
    /// Create a new B2 filesystem for a bucket
    pub fn new(bucket_id: String) -> Self {
        Self {
            inode_table: InodeTable::new(),
            bucket_id,
        }
    }

    /// Get file attributes for an inode
    fn get_attr_for_inode(&self, ino: u64) -> Option<FileAttr> {
        if ino == ROOT_INO {
            return Some(directory_attr(ino));
        }

        // For now, return stub directory attrs for any inode
        // Real B2 integration comes in 02-02
        if self.inode_table.get_path(ino).is_some() {
            return Some(directory_attr(ino));
        }

        None
    }

    /// Get stub directory entries (placeholder until B2 integration)
    fn get_stub_entries(&mut self, parent_ino: u64) -> Vec<DirEntry> {
        let mut entries = Vec::new();

        // Always add . and ..
        entries.push(DirEntry {
            name: ".".to_string(),
            ino: parent_ino,
            kind: FileType::Directory,
        });

        let parent_parent_ino = self.inode_table.get_parent_ino(parent_ino);
        entries.push(DirEntry {
            name: "..".to_string(),
            ino: parent_parent_ino,
            kind: FileType::Directory,
        });

        // Add a stub entry for testing (will be replaced with B2 data)
        if parent_ino == ROOT_INO {
            let stub_ino = self.inode_table.lookup_or_create("example-folder");
            entries.push(DirEntry {
                name: "example-folder".to_string(),
                ino: stub_ino,
                kind: FileType::Directory,
            });
        }

        entries
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
        let parent_path = match self.inode_table.get_path(parent) {
            Some(p) => p.to_string(),
            None => {
                reply.error(libc::ENOENT);
                return;
            }
        };

        // Build full path for the child
        let child_path = if parent_path.is_empty() {
            name_str.to_string()
        } else {
            format!("{}/{}", parent_path, name_str)
        };

        // Get or create inode for this path
        let ino = self.inode_table.lookup_or_create(&child_path);

        // For now, return directory attrs (stub implementation)
        // Real B2 lookup comes in 02-02
        let attr = directory_attr(ino);
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
        if self.inode_table.get_path(ino).is_none() && ino != ROOT_INO {
            reply.error(libc::ENOENT);
            return;
        }

        // Get directory entries (stub for now)
        let entries = self.get_stub_entries(ino);

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
        if self.inode_table.get_path(ino).is_none() && ino != ROOT_INO {
            reply.error(libc::ENOENT);
            return;
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
