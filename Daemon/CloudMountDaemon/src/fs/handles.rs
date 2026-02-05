//! File Handle Tracking
//!
//! Manages open file handles for the FUSE filesystem.
//! Each open() call creates a handle, read()/write() use it, release() removes it.

use std::collections::HashMap;
use std::fs::File;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use tracing::debug;

/// Represents an open file handle
pub struct FileHandle {
    /// Inode number of the open file
    pub ino: u64,
    /// B2 path of the file (relative to bucket root)
    pub path: String,
    /// Path to the local cached copy
    pub local_path: PathBuf,
    /// Open file descriptor for the local copy
    pub file: File,
    /// Whether the file has been written to (dirty)
    pub is_dirty: bool,
    /// Whether the file was opened for writing
    pub is_write: bool,
}

/// Manages all open file handles
pub struct HandleTable {
    /// Map from file handle ID to FileHandle
    handles: HashMap<u64, FileHandle>,
    /// Next file handle ID to assign
    next_fh: AtomicU64,
}

impl HandleTable {
    /// Create a new empty handle table
    pub fn new() -> Self {
        Self {
            handles: HashMap::new(),
            // Start at 1 (0 is sometimes special in FUSE)
            next_fh: AtomicU64::new(1),
        }
    }

    /// Open a file for reading and return a file handle ID
    ///
    /// # Arguments
    /// * `ino` - Inode number of the file
    /// * `path` - B2 path of the file
    /// * `local_path` - Path to the local cached copy
    ///
    /// # Returns
    /// File handle ID
    pub fn open_read(
        &mut self,
        ino: u64,
        path: String,
        local_path: PathBuf,
    ) -> std::io::Result<u64> {
        let file = File::open(&local_path)?;
        let fh = self.next_fh.fetch_add(1, Ordering::Relaxed);

        debug!(fh = fh, ino = ino, path = %path, "Opened file handle for reading");

        self.handles.insert(
            fh,
            FileHandle {
                ino,
                path,
                local_path,
                file,
                is_dirty: false,
                is_write: false,
            },
        );

        Ok(fh)
    }

    /// Open a file for writing and return a file handle ID
    ///
    /// # Arguments
    /// * `ino` - Inode number of the file
    /// * `path` - B2 path of the file
    /// * `local_path` - Path to the local cached copy
    ///
    /// # Returns
    /// File handle ID
    pub fn open_write(
        &mut self,
        ino: u64,
        path: String,
        local_path: PathBuf,
    ) -> std::io::Result<u64> {
        let file = File::options().read(true).write(true).open(&local_path)?;

        let fh = self.next_fh.fetch_add(1, Ordering::Relaxed);

        debug!(fh = fh, ino = ino, path = %path, "Opened file handle for writing");

        self.handles.insert(
            fh,
            FileHandle {
                ino,
                path,
                local_path,
                file,
                is_dirty: false,
                is_write: true,
            },
        );

        Ok(fh)
    }

    /// Get a reference to a file handle
    pub fn get(&self, fh: u64) -> Option<&FileHandle> {
        self.handles.get(&fh)
    }

    /// Get a mutable reference to a file handle
    pub fn get_mut(&mut self, fh: u64) -> Option<&mut FileHandle> {
        self.handles.get_mut(&fh)
    }

    /// Close a file handle and return the handle data
    ///
    /// The caller is responsible for any upload/cleanup actions.
    pub fn close(&mut self, fh: u64) -> Option<FileHandle> {
        let handle = self.handles.remove(&fh);
        if let Some(ref h) = handle {
            debug!(
                fh = fh,
                ino = h.ino,
                path = %h.path,
                is_dirty = h.is_dirty,
                "Closed file handle"
            );
        }
        handle
    }

    /// Get the number of open handles
    pub fn len(&self) -> usize {
        self.handles.len()
    }

    /// Check if there are no open handles
    pub fn is_empty(&self) -> bool {
        self.handles.is_empty()
    }
}

impl Default for HandleTable {
    fn default() -> Self {
        Self::new()
    }
}
