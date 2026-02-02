//! IPC server for Swift app communication

pub mod protocol;
pub mod server;

pub use protocol::{Command, Response, MountInfo, parse_command, serialize_response, SOCKET_PATH, PROTOCOL_VERSION};
pub use server::IpcServer;
