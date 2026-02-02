import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerSection
            
            Divider()
                .padding(.vertical, 8)
            
            // macFUSE status
            if !appState.macFUSEInstalled {
                macFUSEWarning
                Divider()
                    .padding(.vertical, 8)
            }
            
            // Buckets section (placeholder)
            bucketsSection
            
            Divider()
                .padding(.vertical, 8)
            
            // Actions
            actionsSection
        }
        .padding(12)
        .frame(width: 280)
    }
    
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("CloudMount")
                    .font(.headline)
                    .fontWeight(.semibold)
                Text("No buckets mounted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "externaldrive.fill.badge.icloud")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
    
    private var macFUSEWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("macFUSE Required")
                    .font(.caption)
                    .fontWeight(.medium)
                Button("Download") {
                    NSWorkspace.shared.open(URL(string: "https://macfuse.io")!)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Spacer()
            Button("Check") {
                appState.checkMacFUSE()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private var bucketsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BUCKETS")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
            
            if appState.storedBuckets.isEmpty {
                Text("No buckets configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(appState.storedBuckets, id: \.self) { bucket in
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                        Text(bucket)
                            .font(.caption)
                        Spacer()
                        Text("Not mounted")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
    
    private var actionsSection: some View {
        VStack(spacing: 4) {
            Button {
                openSettings()
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings...")
                    Spacer()
                    Text("⌘,")
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            
            Button {
                showAbout()
            } label: {
                HStack {
                    Image(systemName: "info.circle")
                    Text("About CloudMount")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            
            Divider()
                .padding(.vertical, 4)
            
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit")
                    Spacer()
                    Text("⌘Q")
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .font(.caption)
    }
    
    private func showAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(
            options: [
                .applicationName: "CloudMount",
                .applicationVersion: "0.1.0",
                .credits: NSAttributedString(
                    string: "Mount Backblaze B2 buckets as local drives",
                    attributes: [.font: NSFont.systemFont(ofSize: 11)]
                )
            ]
        )
    }
}

#Preview {
    MenuContentView()
        .environmentObject(AppState())
}
