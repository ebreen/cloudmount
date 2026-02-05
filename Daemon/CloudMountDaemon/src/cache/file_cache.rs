//! Local File Cache
//!
//! Caches downloaded B2 files on local disk to avoid repeated downloads.
//! Uses LRU eviction when cache exceeds configured maximum size.

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

use anyhow::{Context, Result};
use tracing::{debug, info, warn};

/// Default maximum cache size: 1 GB
const DEFAULT_MAX_CACHE_SIZE: u64 = 1024 * 1024 * 1024;

/// Tracks a cached file's metadata for LRU eviction
#[derive(Debug, Clone)]
struct CacheEntry {
    /// Path to the cached file on disk
    local_path: PathBuf,
    /// Size of the cached file in bytes
    size: u64,
    /// Last access time (updated on each read)
    last_accessed: SystemTime,
}

/// Local disk cache for downloaded file content
pub struct FileCache {
    /// Root directory for cached files
    cache_dir: PathBuf,
    /// Maximum total cache size in bytes
    max_size: u64,
    /// Track cached files for LRU eviction
    entries: Mutex<HashMap<String, CacheEntry>>,
}

impl FileCache {
    /// Create a new file cache for a specific bucket
    ///
    /// # Arguments
    /// * `bucket_id` - B2 bucket ID (used as subdirectory name)
    pub fn new(bucket_id: &str) -> Result<Self> {
        let cache_base = dirs::cache_dir()
            .unwrap_or_else(|| PathBuf::from("/tmp"))
            .join("cloudmount")
            .join(bucket_id);

        Self::with_config(cache_base, DEFAULT_MAX_CACHE_SIZE)
    }

    /// Create a file cache with custom configuration
    ///
    /// # Arguments
    /// * `cache_dir` - Directory to store cached files
    /// * `max_size` - Maximum total cache size in bytes
    pub fn with_config(cache_dir: PathBuf, max_size: u64) -> Result<Self> {
        // Ensure cache directory exists
        fs::create_dir_all(&cache_dir)
            .with_context(|| format!("Failed to create cache directory: {:?}", cache_dir))?;

        let cache = Self {
            cache_dir,
            max_size,
            entries: Mutex::new(HashMap::new()),
        };

        // Clean up any stale temp files from previous runs
        cache.cleanup();

        info!(
            cache_dir = %cache.cache_dir.display(),
            max_size_mb = max_size / (1024 * 1024),
            "File cache initialized"
        );

        Ok(cache)
    }

    /// Get a cached file, downloading from B2 if not present
    ///
    /// # Arguments
    /// * `path` - B2 file path (relative to bucket root)
    /// * `expected_size` - Expected file size (for cache validation)
    /// * `data_fn` - Closure that downloads the file data if not cached
    ///
    /// # Returns
    /// Path to the local cached file
    pub fn get_or_fetch<F>(&self, path: &str, expected_size: u64, data_fn: F) -> Result<PathBuf>
    where
        F: FnOnce() -> Result<Vec<u8>>,
    {
        // Check if we already have it cached with correct size
        if let Some(local_path) = self.has_cached(path, expected_size) {
            // Update last access time
            self.touch(path);
            debug!(path = path, "File cache HIT");
            return Ok(local_path);
        }

        debug!(
            path = path,
            size = expected_size,
            "File cache MISS, downloading"
        );

        // Download the file
        let data = data_fn()?;

        // Store in cache
        let local_path = self.store(path, &data)?;

        // Record in entry tracker
        {
            let mut entries = self.entries.lock().unwrap();
            entries.insert(
                path.to_string(),
                CacheEntry {
                    local_path: local_path.clone(),
                    size: data.len() as u64,
                    last_accessed: SystemTime::now(),
                },
            );
        }

        // Check if we need to evict
        self.evict_if_needed();

        Ok(local_path)
    }

    /// Check if a file is cached with matching size
    ///
    /// # Returns
    /// Some(path) if cached and size matches, None otherwise
    pub fn has_cached(&self, path: &str, expected_size: u64) -> Option<PathBuf> {
        let local_path = self.path_to_local(path);

        if local_path.exists() {
            // Verify size matches
            if let Ok(metadata) = fs::metadata(&local_path) {
                if metadata.len() == expected_size {
                    return Some(local_path);
                }
                // Size mismatch - stale cache, remove it
                debug!(
                    path = path,
                    cached_size = metadata.len(),
                    expected_size = expected_size,
                    "Cache size mismatch, invalidating"
                );
                let _ = fs::remove_file(&local_path);
            }
        }

        None
    }

    /// Store file data in the cache
    fn store(&self, path: &str, data: &[u8]) -> Result<PathBuf> {
        let local_path = self.path_to_local(path);

        // Ensure parent directory exists
        if let Some(parent) = local_path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("Failed to create cache subdirectory: {:?}", parent))?;
        }

        // Write atomically using tempfile
        let parent = local_path.parent().unwrap_or(Path::new("/tmp"));
        let mut tmp = tempfile::NamedTempFile::new_in(parent)
            .context("Failed to create temp file for cache")?;

        tmp.write_all(data).context("Failed to write cache file")?;

        tmp.persist(&local_path)
            .with_context(|| format!("Failed to persist cache file: {:?}", local_path))?;

        debug!(
            path = path,
            local = %local_path.display(),
            size = data.len(),
            "Stored file in cache"
        );

        Ok(local_path)
    }

    /// Update last access time for a cached entry
    fn touch(&self, path: &str) {
        let mut entries = self.entries.lock().unwrap();
        if let Some(entry) = entries.get_mut(path) {
            entry.last_accessed = SystemTime::now();
        }
    }

    /// Evict least recently used files if cache exceeds max size
    fn evict_if_needed(&self) {
        let mut entries = self.entries.lock().unwrap();

        // Calculate total size
        let total_size: u64 = entries.values().map(|e| e.size).sum();
        if total_size <= self.max_size {
            return;
        }

        info!(
            total_mb = total_size / (1024 * 1024),
            max_mb = self.max_size / (1024 * 1024),
            "Cache exceeds max size, evicting LRU entries"
        );

        // Sort by last accessed (oldest first)
        let mut sorted: Vec<(String, CacheEntry)> = entries
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        sorted.sort_by(|a, b| a.1.last_accessed.cmp(&b.1.last_accessed));

        let mut freed: u64 = 0;
        let target = total_size - self.max_size;

        for (path, entry) in sorted {
            if freed >= target {
                break;
            }
            // Remove from disk
            if let Err(e) = fs::remove_file(&entry.local_path) {
                warn!(path = %entry.local_path.display(), error = %e, "Failed to evict cached file");
            } else {
                debug!(path = %path, size = entry.size, "Evicted cached file");
                freed += entry.size;
                entries.remove(&path);
            }
        }
    }

    /// Clean up stale temp files on startup
    pub fn cleanup(&self) {
        // Remove any .tmp files left from interrupted operations
        if let Ok(read_dir) = fs::read_dir(&self.cache_dir) {
            for entry in read_dir.flatten() {
                let path = entry.path();
                if let Some(ext) = path.extension() {
                    if ext == "tmp" {
                        debug!(path = %path.display(), "Removing stale temp file");
                        let _ = fs::remove_file(&path);
                    }
                }
            }
        }
    }

    /// Invalidate a specific cached file
    pub fn invalidate(&self, path: &str) {
        let local_path = self.path_to_local(path);
        if local_path.exists() {
            let _ = fs::remove_file(&local_path);
        }
        let mut entries = self.entries.lock().unwrap();
        entries.remove(path);
        debug!(path = path, "Invalidated cached file");
    }

    /// Convert a B2 file path to a local cache path
    fn path_to_local(&self, path: &str) -> PathBuf {
        // Replace any problematic characters for the filesystem
        let safe_path = path.replace(':', "_");
        self.cache_dir.join(&safe_path)
    }

    /// Get the cache directory path
    pub fn cache_dir(&self) -> &Path {
        &self.cache_dir
    }
}
