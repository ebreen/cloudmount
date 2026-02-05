import SwiftUI
import CloudMountKit

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
        .onAppear {
            // Pre-fill from first saved account if available
            if let account = appState.accounts.first,
               let creds = CredentialStore.loadCredentials(id: account.id) {
                keyId = creds.keyId
                applicationKey = creds.applicationKey
                connectionStatus = .connected(bucketCount: appState.mountConfigs.count)
            }
        }
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
                Text("Connected — \(count) bucket\(count == 1 ? "" : "s") available")
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
        isConnecting = true
        connectionStatus = .connecting
        
        let trimmedKeyId = keyId.trimmingCharacters(in: .whitespaces)
        let trimmedKey = applicationKey.trimmingCharacters(in: .whitespaces)
        
        Task {
            do {
                // Validate credentials by creating a B2Client and listing buckets
                let client = try await B2Client(
                    keyId: trimmedKeyId,
                    applicationKey: trimmedKey
                )
                let buckets = try await client.listBuckets()
                
                await MainActor.run {
                    // Save account
                    let account = B2Account(
                        label: "Default",
                        keyId: trimmedKeyId,
                        lastAuthorized: Date()
                    )
                    appState.addAccount(account, applicationKey: trimmedKey)
                    
                    // Update status
                    connectionStatus = .connected(bucketCount: buckets.count)
                    isConnecting = false
                }
            } catch {
                await MainActor.run {
                    connectionStatus = .error(error.localizedDescription)
                    isConnecting = false
                }
            }
        }
    }
    
    private func disconnect() {
        connectionStatus = .notConnected
        keyId = ""
        applicationKey = ""
        appState.clearAll()
    }
}

// MARK: - Buckets Pane

struct BucketsPane: View {
    @EnvironmentObject var appState: AppState
    @State private var availableBuckets: [B2BucketInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CONFIGURED MOUNTS")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            
            if appState.mountConfigs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No mounts configured")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Connect your B2 account first, then fetch buckets to add mounts")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(appState.mountConfigs) { config in
                            MountConfigRow(config: config) {
                                appState.removeMountConfig(config)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            
            Divider()
            
            // Fetch & add buckets
            Text("ADD MOUNT FROM B2")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            
            if !availableBuckets.isEmpty {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(availableBuckets, id: \.bucketId) { bucket in
                            let alreadyAdded = appState.mountConfigs.contains { $0.bucketId == bucket.bucketId }
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.blue)
                                Text(bucket.bucketName)
                                    .font(.subheadline)
                                Spacer()
                                Button(alreadyAdded ? "Added" : "Add Mount") {
                                    addMount(for: bucket)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(alreadyAdded)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 100)
            }
            
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            
            HStack {
                Spacer()
                Button {
                    fetchBuckets()
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Fetch Buckets")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.accounts.isEmpty || isLoading)
            }
            
            Spacer()
        }
        .padding(20)
    }
    
    private func fetchBuckets() {
        guard let account = appState.accounts.first,
              let creds = CredentialStore.loadCredentials(id: account.id)
        else {
            errorMessage = "No account credentials found. Connect first."
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let client = try await B2Client(
                    keyId: creds.keyId,
                    applicationKey: creds.applicationKey
                )
                let buckets = try await client.listBuckets()
                
                await MainActor.run {
                    availableBuckets = buckets
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to fetch buckets: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }
    
    private func addMount(for bucket: B2BucketInfo) {
        guard let account = appState.accounts.first else { return }
        
        let config = MountConfiguration(
            accountId: account.id,
            bucketId: bucket.bucketId,
            bucketName: bucket.bucketName,
            mountPoint: "/Volumes/\(bucket.bucketName)"
        )
        appState.addMountConfig(config)
    }
}

struct MountConfigRow: View {
    let config: MountConfiguration
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(config.bucketName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(config.mountPoint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            
            Spacer()
            
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
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
