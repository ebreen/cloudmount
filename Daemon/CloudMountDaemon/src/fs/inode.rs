//! Inode table for mapping paths to stable inode numbers
//!
//! FUSE requires stable inode numbers for the lifetime of a mount.
//! This module provides path-to-inode mapping with bidirectional lookup.

use std::collections::HashMap;

/// Root inode number (always 1 per FUSE convention)
pub const ROOT_INO: u64 = 1;

/// Manages path-to-inode mapping for the filesystem
pub struct InodeTable {
    /// Map from path (relative to bucket root) to inode number
    path_to_ino: HashMap<String, u64>,
    /// Map from inode number to path
    ino_to_path: HashMap<u64, String>,
    /// Next available inode number
    next_ino: u64,
}

impl InodeTable {
    /// Create a new inode table with root inode initialized
    pub fn new() -> Self {
        let mut table = Self {
            path_to_ino: HashMap::new(),
            ino_to_path: HashMap::new(),
            next_ino: ROOT_INO + 1, // Start at 2, since 1 is root
        };

        // Initialize root inode (empty path = root directory)
        table.path_to_ino.insert(String::new(), ROOT_INO);
        table.ino_to_path.insert(ROOT_INO, String::new());

        table
    }

    /// Look up an inode for a path, creating one if it doesn't exist
    pub fn lookup_or_create(&mut self, path: &str) -> u64 {
        // Normalize path (remove trailing slashes, handle edge cases)
        let normalized = Self::normalize_path(path);

        if let Some(&ino) = self.path_to_ino.get(&normalized) {
            return ino;
        }

        // Allocate new inode
        let ino = self.next_ino;
        self.next_ino += 1;

        self.path_to_ino.insert(normalized.clone(), ino);
        self.ino_to_path.insert(ino, normalized);

        ino
    }

    /// Get the path for an inode number
    pub fn get_path(&self, ino: u64) -> Option<&str> {
        self.ino_to_path.get(&ino).map(|s| s.as_str())
    }

    /// Get the inode for a path (without creating)
    pub fn get_ino(&self, path: &str) -> Option<u64> {
        let normalized = Self::normalize_path(path);
        self.path_to_ino.get(&normalized).copied()
    }

    /// Get parent inode for a given inode
    pub fn get_parent_ino(&self, ino: u64) -> u64 {
        if ino == ROOT_INO {
            return ROOT_INO; // Root's parent is itself
        }

        if let Some(path) = self.get_path(ino) {
            if path.is_empty() {
                return ROOT_INO;
            }

            // Find parent path
            if let Some(last_slash) = path.rfind('/') {
                let parent_path = &path[..last_slash];
                if let Some(&parent_ino) = self.path_to_ino.get(parent_path) {
                    return parent_ino;
                }
            }
        }

        ROOT_INO
    }

    /// Remove an inode and return its path
    pub fn remove(&mut self, ino: u64) -> Option<String> {
        if let Some(path) = self.ino_to_path.remove(&ino) {
            self.path_to_ino.remove(&path);
            Some(path)
        } else {
            None
        }
    }

    /// Remove an inode by path and return its inode number
    pub fn remove_by_path(&mut self, path: &str) -> Option<u64> {
        let normalized = Self::normalize_path(path);
        if let Some(ino) = self.path_to_ino.remove(&normalized) {
            self.ino_to_path.remove(&ino);
            Some(ino)
        } else {
            None
        }
    }

    /// Rename an inode (update its path mapping)
    pub fn rename(&mut self, ino: u64, new_path: &str) {
        let normalized = Self::normalize_path(new_path);
        // Remove old path mapping
        if let Some(old_path) = self.ino_to_path.get(&ino) {
            self.path_to_ino.remove(old_path);
        }
        // Insert new mapping
        self.path_to_ino.insert(normalized.clone(), ino);
        self.ino_to_path.insert(ino, normalized);
    }

    /// Normalize a path for consistent lookup
    fn normalize_path(path: &str) -> String {
        let trimmed = path.trim_matches('/');
        trimmed.to_string()
    }
}

impl Default for InodeTable {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_root_inode() {
        let table = InodeTable::new();
        assert_eq!(table.get_ino(""), Some(ROOT_INO));
        assert_eq!(table.get_path(ROOT_INO), Some(""));
    }

    #[test]
    fn test_lookup_or_create() {
        let mut table = InodeTable::new();

        let ino1 = table.lookup_or_create("folder1");
        let ino2 = table.lookup_or_create("folder1/file.txt");
        let ino1_again = table.lookup_or_create("folder1");

        assert_eq!(ino1, ino1_again); // Same path = same inode
        assert_ne!(ino1, ino2); // Different paths = different inodes
        assert_ne!(ino1, ROOT_INO); // Not the root
    }

    #[test]
    fn test_path_normalization() {
        let mut table = InodeTable::new();

        let ino1 = table.lookup_or_create("folder/");
        let ino2 = table.lookup_or_create("/folder");
        let ino3 = table.lookup_or_create("folder");

        assert_eq!(ino1, ino2);
        assert_eq!(ino2, ino3);
    }
}
