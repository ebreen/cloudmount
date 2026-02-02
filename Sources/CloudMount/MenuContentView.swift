import SwiftUI

// Custom button style with hover highlight
struct MenuButtonStyle: ButtonStyle {
    @State private var isHovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered || configuration.isPressed ? Color.primary.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

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
                    .font(.subheadline)
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
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text("macFUSE Required")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Button("Download") {
                    NSWorkspace.shared.open(URL(string: "https://macfuse.io")!)
                }
                .buttonStyle(.link)
                .font(.subheadline)
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
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
            
            if appState.storedBuckets.isEmpty {
                Text("No buckets configured")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(appState.storedBuckets, id: \.self) { bucket in
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                        Text(bucket)
                            .font(.subheadline)
                        Spacer()
                        Text("Not mounted")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
    
    private var actionsSection: some View {
        VStack(spacing: 2) {
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
            .buttonStyle(MenuButtonStyle())
            
            Button {
                showAbout()
            } label: {
                HStack {
                    Image(systemName: "info.circle")
                    Text("About CloudMount")
                    Spacer()
                }
            }
            .buttonStyle(MenuButtonStyle())
            
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
            .buttonStyle(MenuButtonStyle())
        }
        .font(.subheadline)
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
