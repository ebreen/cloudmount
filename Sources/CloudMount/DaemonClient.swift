import Foundation

/// Errors that can occur when communicating with the daemon
enum DaemonError: Error, LocalizedError {
    case connectionFailed
    case writeError
    case readError
    case invalidResponse
    case daemonNotRunning
    case daemonError(String)
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to connect to daemon"
        case .writeError:
            return "Failed to send command to daemon"
        case .readError:
            return "Failed to read response from daemon"
        case .invalidResponse:
            return "Invalid response from daemon"
        case .daemonNotRunning:
            return "Daemon is not running"
        case .daemonError(let message):
            return message
        }
    }
}

/// Information about a mounted bucket
struct DaemonMountInfo: Codable {
    let bucketId: String
    let bucketName: String
    let mountpoint: String
}

/// Response from the daemon
struct DaemonResponse: Codable {
    let type: String
    let message: String?
    let error: String?
    let version: Int?
    let healthy: Bool?
    let mounts: [DaemonMountInfo]?
}

/// Client for communicating with the Rust daemon via Unix socket
actor DaemonClient {
    static let shared = DaemonClient()
    
    private let socketPath = "/tmp/cloudmount.sock"
    
    private init() {}
    
    // MARK: - Public API
    
    /// Check if the daemon is running
    func isRunning() async -> Bool {
        do {
            _ = try await getStatus()
            return true
        } catch {
            return false
        }
    }
    
    /// Get the current status of the daemon including list of mounts
    func getStatus() async throws -> (healthy: Bool, mounts: [DaemonMountInfo]) {
        let command: [String: Any] = ["type": "getStatus"]
        let response = try await sendCommand(command)
        
        guard response.type == "status" else {
            if let error = response.error {
                throw DaemonError.daemonError(error)
            }
            throw DaemonError.invalidResponse
        }
        
        return (response.healthy ?? false, response.mounts ?? [])
    }
    
    /// Mount a bucket
    func mount(bucketName: String, mountpoint: String, keyId: String, key: String) async throws {
        let command: [String: Any] = [
            "type": "mount",
            "bucketName": bucketName,
            "mountpoint": mountpoint,
            "keyId": keyId,
            "key": key
        ]
        
        let response = try await sendCommand(command)
        
        if response.type == "error", let error = response.error {
            throw DaemonError.daemonError(error)
        }
    }
    
    /// Unmount a bucket
    func unmount(bucketId: String) async throws {
        let command: [String: Any] = [
            "type": "unmount",
            "bucketId": bucketId
        ]
        
        let response = try await sendCommand(command)
        
        if response.type == "error", let error = response.error {
            throw DaemonError.daemonError(error)
        }
    }
    
    // MARK: - Private
    
    private func sendCommand(_ command: [String: Any]) async throws -> DaemonResponse {
        // Serialize command to JSON
        let jsonData = try JSONSerialization.data(withJSONObject: command)
        var commandWithNewline = jsonData
        commandWithNewline.append(contentsOf: [0x0A]) // Add newline
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try self.sendCommandSync(commandWithNewline)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func sendCommandSync(_ data: Data) throws -> DaemonResponse {
        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DaemonError.connectionFailed
        }
        defer { close(fd) }
        
        // Set up address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        
        // Copy socket path to sun_path
        socketPath.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                _ = memcpy(dst.baseAddress!, src, min(socketPath.utf8.count, dst.count - 1))
            }
        }
        
        // Connect to socket
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                connect(fd, addrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        guard connectResult == 0 else {
            throw DaemonError.daemonNotRunning
        }
        
        // Send command
        let writeResult = data.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, ptr.count)
        }
        
        guard writeResult == data.count else {
            throw DaemonError.writeError
        }
        
        // Shutdown write side to signal we're done sending
        shutdown(fd, SHUT_WR)
        
        // Read response
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            responseData.append(contentsOf: buffer[0..<bytesRead])
        }
        
        guard !responseData.isEmpty else {
            throw DaemonError.readError
        }
        
        // Parse response
        let decoder = JSONDecoder()
        let response = try decoder.decode(DaemonResponse.self, from: responseData)
        return response
    }
}
