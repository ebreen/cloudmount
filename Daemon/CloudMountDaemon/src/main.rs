//! CloudMount Daemon - FUSE filesystem for Backblaze B2
//!
//! This daemon mounts B2 buckets as local volumes using macFUSE.

mod b2;
mod cache;
mod fs;
mod ipc;
mod mount;

use anyhow::Result;
use tracing::{info, Level};
use tracing_subscriber::FmtSubscriber;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    let subscriber = FmtSubscriber::builder()
        .with_max_level(Level::DEBUG)
        .finish();
    tracing::subscriber::set_global_default(subscriber)?;

    info!("CloudMount Daemon starting...");

    // TODO: Parse CLI args or start IPC server
    // For now, just keep running until Ctrl+C
    info!("Daemon ready. Press Ctrl+C to exit.");
    tokio::signal::ctrl_c().await?;
    
    info!("Shutting down...");
    Ok(())
}
