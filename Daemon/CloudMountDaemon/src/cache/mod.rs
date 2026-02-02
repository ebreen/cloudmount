//! Metadata caching layer
//! 
//! Provides high-performance caching for file and directory metadata using Moka.
//! Reduces B2 API calls by 80%+ through TTL-based caching.

pub mod metadata;

pub use metadata::MetadataCache;
