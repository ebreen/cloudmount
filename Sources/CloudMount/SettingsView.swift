import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            BucketsPane()
                .tabItem {
                    Label("Buckets", systemImage: "folder.fill")
                }
            
            CredentialsPane()
                .tabItem {
                    Label("Credentials", systemImage: "key.fill")
                }
            
            GeneralPane()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
        }
        .frame(width: 450, height: 300)
    }
}

// MARK: - Buckets Pane

struct BucketsPane: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            
            Text("Bucket Configuration")
                .font(.headline)
            
            Text("Configure your cloud storage buckets here.\nComing in Phase 2.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Credentials Pane

struct CredentialsPane: View {
    @State private var bucketName = ""
    @State private var keyId = ""
    @State private var applicationKey = ""
    @State private var showKey = false
    @State private var isSaving = false
    @State private var saveResult: SaveResult?
    
    enum SaveResult {
        case success
        case error(String)
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Section header
                Text("BACKBLAZE B2")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                
                // Form fields
                VStack(alignment: .leading, spacing: 12) {
                    formField("Bucket Name", text: $bucketName, placeholder: "my-bucket")
                    formField("Application Key ID", text: $keyId, placeholder: "004...")
                    
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
                    Text("Find these in your Backblaze B2 account → App Keys")
                        .font(.caption)
                }
                .foregroundStyle(.blue)
                .padding(10)
                .background(.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                // Result message
                if let result = saveResult {
                    resultMessage(result)
                }
                
                Divider()
                
                // Save button
                HStack {
                    Spacer()
                    Button {
                        saveCredentials()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.horizontal, 8)
                        } else {
                            Text("Save Credentials")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid || isSaving)
                }
            }
            .padding(20)
        }
    }
    
    private func formField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
    
    private func resultMessage(_ result: SaveResult) -> some View {
        HStack(spacing: 6) {
            switch result {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Saved to Keychain")
            case .error(let message):
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
            }
        }
        .font(.subheadline)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(result.isSuccess ? .green.opacity(0.08) : .red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private var isValid: Bool {
        !bucketName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !keyId.trimmingCharacters(in: .whitespaces).isEmpty &&
        !applicationKey.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    private func saveCredentials() {
        isSaving = true
        saveResult = nil
        
        Task {
            do {
                let credentials = CredentialStore.BucketCredentials(
                    bucketName: bucketName,
                    keyId: keyId,
                    applicationKey: applicationKey
                )
                try CredentialStore.shared.save(credentials)
                
                await MainActor.run {
                    isSaving = false
                    saveResult = .success
                    bucketName = ""
                    keyId = ""
                    applicationKey = ""
                }
                
                // Clear success message after delay
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    if case .success = saveResult {
                        saveResult = nil
                    }
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveResult = .error(error.localizedDescription)
                }
            }
        }
    }
}

extension CredentialsPane.SaveResult {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
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
}

#Preview("Credentials") {
    CredentialsPane()
        .frame(width: 450, height: 300)
}
