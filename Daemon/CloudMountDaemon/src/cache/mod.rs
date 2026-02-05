//! Caching layer
//!
//! Provides high-performance caching for file metadata (Moka) and
//! file content (local disk cache). Reduces B2 API calls by 80%+.

pub mod file_cache;
pub mod metadata;

pub use file_cache::FileCache;
pub use metadata::MetadataCache;
