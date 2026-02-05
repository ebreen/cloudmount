import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        TabView {
            CredentialsPane()
                .environmentObject(appState)
                .tabItem {
                    Label("Credentials", systemImage: "key.fill")
                }
            
            BucketsPane()
                .environmentObject(appState)
                .tabItem {
                    Label("Buckets", systemImage: "folder.fill")
                }
            
            GeneralPane()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
        }
        .frame(width: 500, height: 380)
    }
}

// MARK: - Credentials Pane

struct CredentialsPane: View {
    @EnvironmentObject var appState: AppState
    @State private var keyId = ""
    @State private var applicationKey = ""
    @State private var showKey = false
    @State private var isConnecting = false
    @State private var connectionStatus: ConnectionStatus = .notConnected
    
    enum ConnectionStatus: Equatable {
        case notConnected
        case connecting
        case connected(bucketCount: Int)
        case error(String)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            Text("BACKBLAZE B2 CREDENTIALS")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            
            // Form fields
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Application Key ID")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    TextField("004...", text: $keyId)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isConnecting)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Application Key")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    HStack(spacing: 6) {
                        Group {
                            if showKey {
                                TextField("K004...", text: $applicationKey)
                            } else {
                                SecureField("K004...", text: $applicationKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .disabled(isConnecting)
                        
                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .frame(width: 20)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            
            // Help text
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption)
                Text("Find these in Backblaze B2 → App Keys. The key determines which buckets are visible.")
                    .font(.caption)
            }
            .foregroundStyle(.blue)
            .padding(10)
            .background(.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            // Status message
            statusView
            
            Spacer()
            
            Divider()
            
            // Connect button
            HStack {
                if case .connected = connectionStatus {
                    Button("Disconnect") {
                        disconnect()
                    }
                    .buttonStyle(.bordered)
                }
                
                Spacer()
                
                Button {
                    connect()
                } label: {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 8)
                    } else {
                        Text(isConnected ? "Reconnect" : "Connect & List Buckets")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || isConnecting)
            }
        }
        .padding(20)
    }
    
    @ViewBuilder
    private var statusView: some View {
        switch connectionStatus {
        case .notConnected:
            EmptyView()
        case .connecting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting to Backblaze B2...")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        case .connected(let count):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connected - \(count) bucket\(count == 1 ? "" : "s") available")
            }
            .font(.subheadline)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .error(let message):
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
            }
            .font(.subheadline)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
    
    private var isValid: Bool {
        !keyId.trimmingCharacters(in: .whitespaces).isEmpty &&
        !applicationKey.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    private var isConnected: Bool {
        if case .connected = connectionStatus { return true }
        return false
    }
    
    private func connect() {
        // TODO: Rewire to B2 client in Plan 05
        isConnecting = true
        connectionStatus = .connecting
        
        // Stub — no-op for now
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            await MainActor.run {
                isConnecting = false
                connectionStatus = .error("Not yet connected to B2 (pending Plan 05)")
            }
        }
    }
    
    private func disconnect() {
        connectionStatus = .notConnected
        keyId = ""
        applicationKey = ""
        appState.clearAllBuckets()
    }
}

// MARK: - Buckets Pane

struct BucketsPane: View {
    @EnvironmentObject var appState: AppState
    @State private var newBucketName = ""
    @State private var newMountpoint = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CONFIGURED BUCKETS")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            
            if appState.bucketConfigs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No buckets configured")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Add a bucket name below to get started")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(appState.bucketConfigs) { bucket in
                            BucketRow(bucket: bucket) {
                                appState.removeBucket(bucket)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            
            Divider()
            
            // Add new bucket
            Text("ADD BUCKET")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bucket Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("my-bucket", text: $newBucketName)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mount Point (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("/Volumes/...", text: $newMountpoint)
                        .textFieldStyle(.roundedBorder)
                    Text("Must be an absolute path (e.g., /Volumes/my-bucket)")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
                
                Button {
                    addBucket()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(newBucketName.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.top, 16)
            }
            
            Spacer()
        }
        .padding(20)
    }
    
    private func addBucket() {
        let name = newBucketName.trimmingCharacters(in: .whitespaces)
        var mount = newMountpoint.trimmingCharacters(in: .whitespaces)
        
        // Default to /Volumes/{name} if empty
        if mount.isEmpty {
            mount = "/Volumes/\(name)"
        } else if !mount.hasPrefix("/") {
            // Ensure absolute path — prepend /Volumes/ if not absolute
            mount = "/Volumes/\(mount)"
        }
        
        appState.addBucket(name: name, mountpoint: mount)
        newBucketName = ""
        newMountpoint = ""
    }
}

struct BucketRow: View {
    let bucket: BucketConfig
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: bucket.isMounted ? "externaldrive.fill" : "folder.fill")
                .foregroundStyle(bucket.isMounted ? .green : .blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(bucket.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(bucket.mountpoint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            
            Spacer()
            
            if bucket.isMounted {
                Text("Mounted")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.1))
                    .clipShape(Capsule())
            }
            
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .disabled(bucket.isMounted)
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - General Pane

struct GeneralPane: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SYSTEM")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            
            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at Login")
                        .font(.body)
                    Text("Automatically start CloudMount when you log in")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.checkbox)
            
            Spacer()
            
            Divider()
            
            HStack {
                Spacer()
                Button("Quit CloudMount") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview("Settings") {
    SettingsView()
        .environmentObject(AppState())
}

#Preview("Credentials") {
    CredentialsPane()
        .environmentObject(AppState())
        .frame(width: 500, height: 350)
}
