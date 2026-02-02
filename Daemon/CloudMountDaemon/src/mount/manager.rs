//! Mount Manager - Controls FUSE mount lifecycle
//!
//! Manages mounting, unmounting, and tracking of B2 buckets as FUSE volumes.

use anyhow::{anyhow, Context, Result};
use fuser::MountOption;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;
use tokio::task::JoinHandle;
use tracing::{debug, error, info, warn};

use crate::b2::B2Client;
use crate::fs::B2Filesystem;

/// Information about an active mount
#[derive(Debug)]
pub struct MountInfo {
    /// Bucket ID being mounted
    pub bucket_id: String,
    /// Bucket name
    pub bucket_name: String,
    /// Mount point path
    pub mountpoint: PathBuf,
}

/// Handle to a running mount
struct MountHandle {
    /// Bucket ID
    bucket_id: String,
    /// Bucket name
    bucket_name: String,
    /// Mount point path
    mountpoint: PathBuf,
    /// Background task running the FUSE session
    task: JoinHandle<()>,
}

/// Manages multiple FUSE mounts
pub struct MountManager {
    /// Active mounts by bucket ID
    mounts: Arc<RwLock<HashMap<String, MountHandle>>>,
}

impl MountManager {
    /// Create a new mount manager
    pub fn new() -> Self {
        Self {
            mounts: Arc::new(RwLock::new(HashMap::new())),
        }
    }
    
    /// Mount a B2 bucket at the specified path
    ///
    /// # Arguments
    /// * `b2_client` - Authenticated B2 client for the bucket
    /// * `mountpoint` - Path to mount the bucket at
    ///
    /// # Returns
    /// Ok(()) on successful mount, Err on failure
    pub async fn mount(&self, b2_client: B2Client, mountpoint: PathBuf) -> Result<()> {
        let bucket_id = b2_client.bucket_id().to_string();
        let bucket_name = b2_client.bucket_name().to_string();
        
        // Check if already mounted
        {
            let mounts = self.mounts.read().await;
            if mounts.contains_key(&bucket_id) {
                return Err(anyhow!("Bucket '{}' is already mounted", bucket_name));
            }
        }
        
        info!(
            bucket = %bucket_name,
            mountpoint = %mountpoint.display(),
            "Mounting bucket..."
        );
        
        // Create mountpoint directory if needed
        if !mountpoint.exists() {
            std::fs::create_dir_all(&mountpoint)
                .context("Failed to create mountpoint directory")?;
        }
        
        // Build the filesystem
        let filesystem = B2Filesystem::new(bucket_id.clone(), b2_client);
        
        // Configure mount options
        let options = vec![
            MountOption::FSName(format!("cloudmount-{}", bucket_name)),
            MountOption::AllowOther,  // Allow other users to access (needed for /Volumes)
            MountOption::NoAtime,     // Don't update access times (performance)
            MountOption::AutoUnmount, // Auto-unmount on process exit
        ];
        
        let mp = mountpoint.clone();
        let bid = bucket_id.clone();
        let bname = bucket_name.clone();
        
        // Spawn FUSE mount in a blocking task (fuser is sync)
        let task = tokio::task::spawn_blocking(move || {
            info!(bucket = %bname, "Starting FUSE session...");
            
            match fuser::mount2(filesystem, &mp, &options) {
                Ok(()) => {
                    info!(bucket = %bname, "FUSE session ended normally");
                }
                Err(e) => {
                    error!(bucket = %bname, error = %e, "FUSE session failed");
                }
            }
        });
        
        // Give the mount a moment to initialize
        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
        
        // Check if the mount task is still running
        if task.is_finished() {
            return Err(anyhow!("Mount failed to start - check if macFUSE is installed"));
        }
        
        // Store the mount handle
        let handle = MountHandle {
            bucket_id: bucket_id.clone(),
            bucket_name: bucket_name.clone(),
            mountpoint,
            task,
        };
        
        {
            let mut mounts = self.mounts.write().await;
            mounts.insert(bucket_id.clone(), handle);
        }
        
        info!(bucket = %bucket_name, "Mount successful");
        Ok(())
    }
    
    /// Unmount a bucket by its ID
    pub async fn unmount(&self, bucket_id: &str) -> Result<()> {
        let handle = {
            let mut mounts = self.mounts.write().await;
            mounts.remove(bucket_id)
        };
        
        match handle {
            Some(handle) => {
                info!(
                    bucket = %handle.bucket_name,
                    mountpoint = %handle.mountpoint.display(),
                    "Unmounting bucket..."
                );
                
                // Try system unmount command
                let output = std::process::Command::new("umount")
                    .arg(&handle.mountpoint)
                    .output();
                
                match output {
                    Ok(output) if output.status.success() => {
                        debug!("umount command succeeded");
                    }
                    Ok(output) => {
                        warn!(
                            "umount command failed: {}",
                            String::from_utf8_lossy(&output.stderr)
                        );
                    }
                    Err(e) => {
                        warn!("Failed to run umount: {}", e);
                    }
                }
                
                // Wait for the task to finish with timeout
                let timeout_result = tokio::time::timeout(
                    tokio::time::Duration::from_secs(5),
                    handle.task,
                ).await;
                
                match timeout_result {
                    Ok(Ok(())) => {
                        info!(bucket = %handle.bucket_name, "Unmount completed");
                    }
                    Ok(Err(e)) => {
                        warn!(bucket = %handle.bucket_name, error = %e, "Mount task panicked");
                    }
                    Err(_) => {
                        warn!(bucket = %handle.bucket_name, "Unmount timed out, task may still be running");
                    }
                }
                
                // Clean up mountpoint if empty
                if handle.mountpoint.exists() {
                    if let Err(e) = std::fs::remove_dir(&handle.mountpoint) {
                        debug!(
                            mountpoint = %handle.mountpoint.display(),
                            error = %e,
                            "Could not remove mountpoint (may not be empty)"
                        );
                    }
                }
                
                Ok(())
            }
            None => Err(anyhow!("Bucket '{}' is not mounted", bucket_id)),
        }
    }
    
    /// Unmount a bucket by name
    pub async fn unmount_by_name(&self, bucket_name: &str) -> Result<()> {
        let bucket_id = {
            let mounts = self.mounts.read().await;
            mounts
                .values()
                .find(|h| h.bucket_name == bucket_name)
                .map(|h| h.bucket_id.clone())
        };
        
        match bucket_id {
            Some(id) => self.unmount(&id).await,
            None => Err(anyhow!("Bucket '{}' is not mounted", bucket_name)),
        }
    }
    
    /// List all active mounts
    pub async fn list_mounts(&self) -> Vec<MountInfo> {
        let mounts = self.mounts.read().await;
        mounts
            .values()
            .map(|h| MountInfo {
                bucket_id: h.bucket_id.clone(),
                bucket_name: h.bucket_name.clone(),
                mountpoint: h.mountpoint.clone(),
            })
            .collect()
    }
    
    /// Check if a bucket is mounted
    pub async fn is_mounted(&self, bucket_id: &str) -> bool {
        let mounts = self.mounts.read().await;
        mounts.contains_key(bucket_id)
    }
    
    /// Unmount all buckets
    pub async fn unmount_all(&self) {
        let bucket_ids: Vec<String> = {
            let mounts = self.mounts.read().await;
            mounts.keys().cloned().collect()
        };
        
        for bucket_id in bucket_ids {
            if let Err(e) = self.unmount(&bucket_id).await {
                warn!(bucket_id = %bucket_id, error = %e, "Failed to unmount bucket");
            }
        }
    }
}

impl Default for MountManager {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for MountManager {
    fn drop(&mut self) {
        // Note: We can't do async unmount in drop
        // The daemon's main() should call unmount_all() before exiting
    }
}
