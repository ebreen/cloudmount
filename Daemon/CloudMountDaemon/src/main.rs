//! CloudMount Daemon - FUSE filesystem for Backblaze B2
//!
//! This daemon mounts B2 buckets as local volumes using macFUSE.

mod b2;
mod cache;
mod fs;
mod ipc;
mod mount;

use anyhow::{anyhow, Result};
use std::env;
use std::path::PathBuf;
use std::sync::Arc;
use tracing::{error, info, Level};
use tracing_subscriber::FmtSubscriber;

use b2::B2Client;
use ipc::IpcServer;
use mount::MountManager;

/// CLI command
#[derive(Debug)]
enum Command {
    /// Run IPC server mode (default)
    Server,
    /// Mount a bucket (CLI mode)
    Mount {
        bucket_name: String,
        mountpoint: PathBuf,
        key_id: String,
        key: String,
    },
    /// List active mounts (CLI mode)
    List,
    /// Show help
    Help,
}

fn print_help() {
    eprintln!(
        r#"CloudMount Daemon - Mount Backblaze B2 buckets as local drives

USAGE:
    cloudmount-daemon                    # Run IPC server (default)
    cloudmount-daemon mount <bucket_name> <mountpoint> <key_id> <key>
    cloudmount-daemon list
    cloudmount-daemon help

COMMANDS:
    (none)  Run IPC server mode (waits for commands from Swift UI)
    mount   Mount a B2 bucket at the specified path (CLI mode)
    list    List currently mounted buckets (CLI mode)
    help    Show this help message

EXAMPLES:
    # Run IPC server (default)
    cloudmount-daemon

    # Mount a bucket (CLI mode for testing)
    cloudmount-daemon mount my-bucket /Volumes/MyBucket 004xxx K004xxx

    # List mounts (CLI mode)
    cloudmount-daemon list

ENVIRONMENT:
    B2_KEY_ID        B2 application key ID (alternative to CLI arg)
    B2_KEY           B2 application key (alternative to CLI arg)
    RUST_LOG         Log level (trace, debug, info, warn, error)

NOTE:
    IPC server mode is the normal operation. CLI commands are for testing.
"#
    );
}

fn parse_args() -> Result<Command> {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        return Ok(Command::Server);
    }

    match args[1].as_str() {
        "mount" => {
            if args.len() < 6 {
                return Err(anyhow!(
                    "Usage: cloudmount-daemon mount <bucket_name> <mountpoint> <key_id> <key>"
                ));
            }
            Ok(Command::Mount {
                bucket_name: args[2].clone(),
                mountpoint: PathBuf::from(&args[3]),
                key_id: args[4].clone(),
                key: args[5].clone(),
            })
        }
        "list" => Ok(Command::List),
        "help" | "--help" | "-h" => Ok(Command::Help),
        _ => {
            eprintln!("Unknown command: {}", args[1]);
            Ok(Command::Help)
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    let log_level = env::var("RUST_LOG")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(Level::INFO);

    let subscriber = FmtSubscriber::builder()
        .with_max_level(log_level)
        .finish();
    tracing::subscriber::set_global_default(subscriber)?;

    // Parse command
    let command = match parse_args() {
        Ok(cmd) => cmd,
        Err(e) => {
            eprintln!("Error: {}", e);
            print_help();
            std::process::exit(1);
        }
    };

    // Create mount manager wrapped in Arc for sharing
    let manager = Arc::new(MountManager::new());

    match command {
        Command::Server => {
            info!("Starting CloudMount daemon in IPC server mode");

            // Create and start IPC server
            let mut ipc_server = IpcServer::new(Arc::clone(&manager));
            if let Err(e) = ipc_server.start().await {
                error!(error = %e, "Failed to start IPC server");
                return Err(e);
            }

            info!("Daemon ready. Waiting for commands from Swift UI...");

            // Run IPC server in a separate task
            let ipc_handle = tokio::spawn(async move {
                if let Err(e) = ipc_server.run().await {
                    error!(error = %e, "IPC server error");
                }
            });

            // Wait for Ctrl+C
            tokio::signal::ctrl_c().await?;

            info!("Received shutdown signal, unmounting all buckets...");
            manager.unmount_all().await;

            info!("Shutdown complete.");
        }
        Command::Mount {
            bucket_name,
            mountpoint,
            key_id,
            key,
        } => {
            info!(bucket = %bucket_name, mountpoint = %mountpoint.display(), "Starting mount...");

            // Authorize with B2
            let b2_client = match B2Client::authorize(&key_id, &key, &bucket_name).await {
                Ok(client) => client,
                Err(e) => {
                    error!(error = %e, "Failed to authorize with B2");
                    return Err(e);
                }
            };

            // Mount the bucket
            if let Err(e) = manager.mount(b2_client, mountpoint.clone()).await {
                error!(error = %e, "Failed to mount bucket");
                return Err(e);
            }

            info!(
                bucket = %bucket_name,
                mountpoint = %mountpoint.display(),
                "Bucket mounted successfully. Press Ctrl+C to unmount."
            );

            // Wait for Ctrl+C
            tokio::signal::ctrl_c().await?;

            info!("Received shutdown signal, unmounting...");
            manager.unmount_all().await;

            info!("Shutdown complete.");
        }
        Command::List => {
            let mounts = manager.list_mounts().await;
            if mounts.is_empty() {
                println!("No buckets currently mounted.");
            } else {
                println!("Mounted buckets:");
                for mount in mounts {
                    println!(
                        "  {} -> {} (ID: {})",
                        mount.bucket_name,
                        mount.mountpoint.display(),
                        mount.bucket_id
                    );
                }
            }
        }
        Command::Help => {
            print_help();
        }
    }

    Ok(())
}
