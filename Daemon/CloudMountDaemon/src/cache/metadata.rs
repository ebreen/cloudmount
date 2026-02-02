//! Metadata Cache Implementation
//!
//! High-performance cache for file and directory metadata using Moka.
//! Uses synchronous cache to match FUSE callback semantics.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use fuser::FileAttr;
use moka::sync::Cache;
use tracing::{debug, trace};

use crate::b2::FileInfo;

/// Cache entry for file attributes with metadata
#[derive(Clone, Debug)]
pub struct CachedAttr {
    /// The file attributes
    pub attr: FileAttr,
    /// When this entry was cached
    pub cached_at: std::time::Instant,
}

/// Cache entry for directory listings
#[derive(Clone, Debug)]
pub struct CachedDir {
    /// The directory entries (name, ino, kind)
    pub entries: Vec<(String, u64, fuser::FileType)>,
    /// When this entry was cached
    pub cached_at: std::time::Instant,
}

/// Metadata cache with TTL support
///
/// Provides separate caches for:
/// - File attributes (10 minute TTL)
/// - Directory listings (5 minute TTL)
pub struct MetadataCache {
    /// Cache for file attributes by inode
    attr_cache: Cache<u64, CachedAttr>,
    /// Cache for directory listings by inode
    dir_cache: Cache<u64, CachedDir>,
    /// Cache hit counter
    hits: AtomicU64,
    /// Cache miss counter
    misses: AtomicU64,
}

impl MetadataCache {
    /// Create a new metadata cache with default TTLs
    pub fn new() -> Self {
        Self::with_ttls(
            Duration::from_secs(600), // 10 minutes for attributes
            Duration::from_secs(300), // 5 minutes for directories
        )
    }

    /// Create a cache with custom TTLs
    ///
    /// # Arguments
    /// * `attr_ttl` - TTL for file attributes
    /// * `dir_ttl` - TTL for directory listings
    pub fn with_ttls(attr_ttl: Duration, dir_ttl: Duration) -> Self {
        let attr_cache = Cache::builder()
            .time_to_live(attr_ttl)
            .name("file_attr_cache")
            .build();

        let dir_cache = Cache::builder()
            .time_to_live(dir_ttl)
            .name("dir_listing_cache")
            .build();

        Self {
            attr_cache,
            dir_cache,
            hits: AtomicU64::new(0),
            misses: AtomicU64::new(0),
        }
    }

    /// Get file attributes from cache
    ///
    /// Returns Some(attr) if found in cache, None otherwise.
    /// Updates hit/miss counters.
    pub fn get_attr(&self, ino: u64) -> Option<FileAttr> {
        match self.attr_cache.get(&ino) {
            Some(cached) => {
                self.hits.fetch_add(1, Ordering::Relaxed);
                trace!(ino = ino, "Cache HIT for file attributes");
                Some(cached.attr)
            }
            None => {
                self.misses.fetch_add(1, Ordering::Relaxed);
                trace!(ino = ino, "Cache MISS for file attributes");
                None
            }
        }
    }

    /// Insert file attributes into cache
    ///
    /// Converts FileInfo to FileAttr and stores with current timestamp.
    pub fn insert_attr(&self, ino: u64, attr: FileAttr) {
        let cached = CachedAttr {
            attr,
            cached_at: std::time::Instant::now(),
        };
        self.attr_cache.insert(ino, cached);
        debug!(ino = ino, "Cached file attributes");
    }

    /// Insert file attributes from FileInfo
    ///
    /// Convenience method that converts FileInfo to FileAttr.
    pub fn insert_file_info(&self, ino: u64, file_info: &FileInfo) {
        let attr = crate::b2::b2_file_to_attr(ino, file_info);
        self.insert_attr(ino, attr);
    }

    /// Get directory listing from cache
    ///
    /// Returns Some(entries) if found in cache, None otherwise.
    /// Updates hit/miss counters.
    pub fn get_dir(&self, ino: u64) -> Option<Vec<(String, u64, fuser::FileType)>> {
        match self.dir_cache.get(&ino) {
            Some(cached) => {
                self.hits.fetch_add(1, Ordering::Relaxed);
                trace!(
                    ino = ino,
                    entries = cached.entries.len(),
                    "Cache HIT for directory"
                );
                Some(cached.entries)
            }
            None => {
                self.misses.fetch_add(1, Ordering::Relaxed);
                trace!(ino = ino, "Cache MISS for directory");
                None
            }
        }
    }

    /// Insert directory listing into cache
    ///
    /// Stores the directory entries with current timestamp.
    pub fn insert_dir(&self, ino: u64, entries: Vec<(String, u64, fuser::FileType)>) {
        let cached = CachedDir {
            entries: entries.clone(),
            cached_at: std::time::Instant::now(),
        };
        self.dir_cache.insert(ino, cached);
        debug!(
            ino = ino,
            entries = entries.len(),
            "Cached directory listing"
        );
    }

    /// Invalidate a specific inode's cached attributes
    ///
    /// Call this when file metadata changes.
    pub fn invalidate(&self, ino: u64) {
        self.attr_cache.invalidate(&ino);
        self.dir_cache.invalidate(&ino);
        debug!(ino = ino, "Invalidated cache for inode");
    }

    /// Clear all caches
    ///
    /// Call this on unmount or when resetting state.
    pub fn clear(&self) {
        self.attr_cache.invalidate_all();
        self.dir_cache.invalidate_all();
        self.hits.store(0, Ordering::Relaxed);
        self.misses.store(0, Ordering::Relaxed);
        debug!("Cleared all metadata caches");
    }

    /// Get cache statistics
    ///
    /// Returns (hits, misses, hit_rate)
    pub fn stats(&self) -> (u64, u64, f64) {
        let hits = self.hits.load(Ordering::Relaxed);
        let misses = self.misses.load(Ordering::Relaxed);
        let total = hits + misses;
        let hit_rate = if total > 0 {
            (hits as f64 / total as f64) * 100.0
        } else {
            0.0
        };
        (hits, misses, hit_rate)
    }

    /// Log current cache metrics
    pub fn log_metrics(&self) {
        let (hits, misses, hit_rate) = self.stats();
        let attr_size = self.attr_cache.entry_count();
        let dir_size = self.dir_cache.entry_count();

        debug!(
            hits = hits,
            misses = misses,
            hit_rate = format!("{:.1}%", hit_rate),
            attr_entries = attr_size,
            dir_entries = dir_size,
            "Cache metrics"
        );
    }
}

impl Default for MetadataCache {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use fuser::FileType;
    use std::time::SystemTime;

    fn create_test_attr(ino: u64) -> FileAttr {
        FileAttr {
            ino,
            size: 1024,
            blocks: 2,
            atime: SystemTime::now(),
            mtime: SystemTime::now(),
            ctime: SystemTime::now(),
            crtime: SystemTime::now(),
            kind: FileType::RegularFile,
            perm: 0o644,
            nlink: 1,
            uid: 501,
            gid: 20,
            rdev: 0,
            flags: 0,
            blksize: 512,
        }
    }

    #[test]
    fn test_cache_hit_miss() {
        let cache = MetadataCache::new();
        let attr = create_test_attr(1);

        // Initially miss
        assert!(cache.get_attr(1).is_none());
        let (_, _, hit_rate) = cache.stats();
        assert_eq!(hit_rate, 0.0);

        // Insert and hit
        cache.insert_attr(1, attr);
        assert!(cache.get_attr(1).is_some());

        let (hits, misses, hit_rate) = cache.stats();
        assert_eq!(hits, 1);
        assert_eq!(misses, 1);
        assert!(hit_rate > 49.0 && hit_rate < 51.0); // ~50%
    }

    #[test]
    fn test_cache_invalidation() {
        let cache = MetadataCache::new();
        let attr = create_test_attr(1);

        cache.insert_attr(1, attr);
        assert!(cache.get_attr(1).is_some());

        cache.invalidate(1);
        assert!(cache.get_attr(1).is_none());
    }

    #[test]
    fn test_cache_clear() {
        let cache = MetadataCache::new();

        cache.insert_attr(1, create_test_attr(1));
        cache.insert_attr(2, create_test_attr(2));
        cache.insert_dir(1, vec![("file.txt".to_string(), 3, FileType::RegularFile)]);

        cache.clear();

        assert!(cache.get_attr(1).is_none());
        assert!(cache.get_attr(2).is_none());
        assert!(cache.get_dir(1).is_none());

        let (hits, misses, _) = cache.stats();
        assert_eq!(hits, 0);
        assert_eq!(misses, 0);
    }
}
