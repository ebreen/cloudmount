//! B2 API Error Types
//!
//! Structured error handling for Backblaze B2 API operations.
//! Maps HTTP status codes to specific error variants for retry and errno decisions.

/// B2 API error types
#[derive(Debug, thiserror::Error)]
pub enum B2Error {
    #[error("Authentication expired — token needs refresh")]
    AuthExpired,

    #[error("Rate limited — try again after backoff")]
    RateLimited,

    #[error("Not found: {0}")]
    NotFound(String),

    #[error("Forbidden: {0}")]
    Forbidden(String),

    #[error("Network error: {0}")]
    Network(String),

    #[error("Server error ({0}): {1}")]
    Server(u16, String),

    #[error("Request timeout")]
    Timeout,

    #[error("Request error: {0}")]
    Request(String),
}

impl B2Error {
    /// Map B2 error to an appropriate libc errno
    pub fn to_errno(&self) -> i32 {
        match self {
            B2Error::AuthExpired => libc::EACCES,
            B2Error::RateLimited => libc::EAGAIN,
            B2Error::NotFound(_) => libc::ENOENT,
            B2Error::Forbidden(_) => libc::EACCES,
            B2Error::Network(_) => libc::EIO,
            B2Error::Server(_, _) => libc::EIO,
            B2Error::Timeout => libc::ETIMEDOUT,
            B2Error::Request(_) => libc::EIO,
        }
    }

    /// Whether this error is retryable
    pub fn is_retryable(&self) -> bool {
        matches!(
            self,
            B2Error::RateLimited
                | B2Error::Timeout
                | B2Error::Network(_)
                | B2Error::Server(_, _)
                | B2Error::AuthExpired
        )
    }

    /// Create a B2Error from an HTTP status code and response body
    pub fn from_status(status: u16, body: &str) -> Self {
        match status {
            401 => B2Error::AuthExpired,
            403 => B2Error::Forbidden(body.to_string()),
            404 => B2Error::NotFound(body.to_string()),
            408 => B2Error::Timeout,
            429 => B2Error::RateLimited,
            500..=599 => B2Error::Server(status, body.to_string()),
            _ => B2Error::Request(format!("HTTP {}: {}", status, body)),
        }
    }
}
