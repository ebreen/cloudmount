//! IPC Server - Unix socket server for Swift app communication
//!
//! Handles incoming connections from the Swift UI and dispatches commands
//! to the MountManager.

use anyhow::{Context, Result};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::RwLock;
use tracing::{debug, error, info, warn};

use crate::b2::B2Client;
use crate::ipc::protocol::{Command, MountInfo, BucketInfo, Response, parse_command, serialize_response, SOCKET_PATH};
use crate::mount::MountManager;

/// IPC Server that listens for commands from the Swift UI
pub struct IpcServer {
    /// Mount manager for handling mount/unmount operations
    mount_manager: Arc<MountManager>,
    /// Socket listener
    listener: Option<UnixListener>,
    /// Active connections counter
    connection_count: Arc<RwLock<u32>>,
}

impl IpcServer {
    /// Create a new IPC server
    pub fn new(mount_manager: Arc<MountManager>) -> Self {
        Self {
            mount_manager,
            listener: None,
            connection_count: Arc::new(RwLock::new(0)),
        }
    }

    /// Start the IPC server
    pub async fn start(&mut self) -> Result<()> {
        // Clean up any existing socket file
        let socket_path = PathBuf::from(SOCKET_PATH);
        if socket_path.exists() {
            std::fs::remove_file(&socket_path)
                .context("Failed to remove existing socket file")?;
        }

        // Create the socket listener
        let listener = UnixListener::bind(SOCKET_PATH)
            .context("Failed to bind Unix socket")?;

        info!(socket_path = %SOCKET_PATH, "IPC server started");

        self.listener = Some(listener);
        Ok(())
    }

    /// Run the server loop, accepting connections
    pub async fn run(&self) -> Result<()> {
        let listener = self.listener.as_ref()
            .context("Server not started")?;

        loop {
            match listener.accept().await {
                Ok((stream, _)) => {
                    let mount_manager = Arc::clone(&self.mount_manager);
                    let connection_count = Arc::clone(&self.connection_count);

                    // Spawn a new task to handle this connection
                    tokio::spawn(async move {
                        if let Err(e) = handle_connection(stream, mount_manager, connection_count).await {
                            error!(error = %e, "Connection handler error");
                        }
                    });
                }
                Err(e) => {
                    error!(error = %e, "Failed to accept connection");
                }
            }
        }
    }

    /// Stop the IPC server and clean up
    pub async fn stop(&self) -> Result<()> {
        let socket_path = PathBuf::from(SOCKET_PATH);
        if socket_path.exists() {
            std::fs::remove_file(&socket_path)
                .context("Failed to remove socket file")?;
        }
        info!("IPC server stopped");
        Ok(())
    }

    /// Get the number of active connections
    pub async fn connection_count(&self) -> u32 {
        *self.connection_count.read().await
    }
}

/// Handle a single client connection
async fn handle_connection(
    stream: UnixStream,
    mount_manager: Arc<MountManager>,
    connection_count: Arc<RwLock<u32>>,
) -> Result<()> {
    // Increment connection count
    {
        let mut count = connection_count.write().await;
        *count += 1;
        debug!(count = *count, "New connection");
    }

    let (reader, mut writer) = stream.into_split();
    let mut buf_reader = BufReader::new(reader);
    let mut line = String::new();

    // Read commands line by line (newline-delimited JSON)
    loop {
        line.clear();
        match buf_reader.read_line(&mut line).await {
            Ok(0) => {
                // Connection closed
                debug!("Connection closed by client");
                break;
            }
            Ok(_) => {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }

                debug!(command = %trimmed, "Received command");

                // Parse and process the command
                match parse_command(trimmed.as_bytes()) {
                    Ok(command) => {
                        let response = process_command(command, &mount_manager).await;

                        // Send response
                        match serialize_response(&response) {
                            Ok(json) => {
                                if let Err(e) = writer.write_all(&json).await {
                                    error!(error = %e, "Failed to write response");
                                    break;
                                }
                            }
                            Err(e) => {
                                error!(error = %e, "Failed to serialize response");
                            }
                        }
                    }
                    Err(e) => {
                        error!(error = %e, command = %trimmed, "Failed to parse command");
                        let error_response = Response::Error {
                            error: format!("Invalid command: {}", e),
                        };
                        if let Ok(json) = serialize_response(&error_response) {
                            let _ = writer.write_all(&json).await;
                        }
                    }
                }
            }
            Err(e) => {
                error!(error = %e, "Failed to read from socket");
                break;
            }
        }
    }

    // Decrement connection count
    {
        let mut count = connection_count.write().await;
        *count = count.saturating_sub(1);
        debug!(count = *count, "Connection ended");
    }

    Ok(())
}

/// Process a command and return a response
async fn process_command(
    command: Command,
    mount_manager: &MountManager,
) -> Response {
    match command {
        Command::Mount { bucket_name, mountpoint, key_id, key } => {
            info!(
                bucket = %bucket_name,
                mountpoint = %mountpoint,
                "Processing mount command"
            );

            // Authorize with B2
            let b2_client = match B2Client::authorize(&key_id, &key, &bucket_name).await {
                Ok(client) => client,
                Err(e) => {
                    return Response::Error {
                        error: format!("B2 authorization failed: {}", e),
                    };
                }
            };

            // Mount the bucket
            let mountpoint_path = PathBuf::from(&mountpoint);
            match mount_manager.mount(b2_client, mountpoint_path).await {
                Ok(()) => Response::Success {
                    message: Some(format!("Mounted '{}' at {}", bucket_name, mountpoint)),
                },
                Err(e) => Response::Error {
                    error: format!("Mount failed: {}", e),
                },
            }
        }

        Command::Unmount { bucket_id } => {
            info!(bucket_id = %bucket_id, "Processing unmount command");

            match mount_manager.unmount(&bucket_id).await {
                Ok(()) => Response::Success {
                    message: Some(format!("Unmounted bucket {}", bucket_id)),
                },
                Err(e) => Response::Error {
                    error: format!("Unmount failed: {}", e),
                },
            }
        }

        Command::GetStatus => {
            debug!("Processing getStatus command");

            let mounts = mount_manager.list_mounts().await;
            let mount_infos: Vec<MountInfo> = mounts
                .into_iter()
                .map(|m| MountInfo {
                    bucket_id: m.bucket_id,
                    bucket_name: m.bucket_name,
                    mountpoint: m.mountpoint.to_string_lossy().to_string(),
                })
                .collect();

            Response::Status {
                version: crate::ipc::protocol::PROTOCOL_VERSION,
                healthy: true,
                mounts: mount_infos,
            }
        }

        Command::ListBuckets { key_id, key } => {
            info!("Processing listBuckets command");

            match B2Client::list_all_buckets(&key_id, &key).await {
                Ok(buckets) => {
                    let bucket_infos: Vec<BucketInfo> = buckets
                        .into_iter()
                        .map(|b| BucketInfo {
                            bucket_id: b.bucket_id,
                            bucket_name: b.bucket_name,
                            bucket_type: b.bucket_type,
                        })
                        .collect();
                    
                    Response::BucketList { buckets: bucket_infos }
                }
                Err(e) => {
                    Response::Error {
                        error: format!("Failed to list buckets: {}", e),
                    }
                }
            }
        }
    }
}
