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
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerSection
            
            Divider()
                .padding(.vertical, 8)
            
            // Buckets section
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
                HStack(spacing: 4) {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 8, height: 8)
                    Text("Not connected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "externaldrive.fill.badge.icloud")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
    
    private var bucketsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BUCKETS")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
            
            if appState.bucketConfigs.isEmpty {
                Text("No buckets configured")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(appState.bucketConfigs) { bucket in
                    HStack {
                        Image(systemName: bucket.isMounted ? "externaldrive.fill" : "folder.fill")
                            .foregroundStyle(bucket.isMounted ? .green : .blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bucket.name)
                                .font(.subheadline)
                            if bucket.isMounted {
                                HStack(spacing: 0) {
                                    Text(bucket.mountpoint)
                                    if let bytes = bucket.totalBytesUsed {
                                        Text(" · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        // TODO: Re-enable mount/unmount in Plan 05
                        Button(bucket.isMounted ? "Unmount" : "Mount") {
                            // Stub — will be rewired in Plan 05
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(true)
                    }
                    .padding(.vertical, 2)
                }
            }
            
            // Show error if any
            if let error = appState.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(.top, 4)
            }
        }
    }
    
    private var actionsSection: some View {
        VStack(spacing: 2) {
            Button {
                openWindow(id: "settings")
                NSApplication.shared.activate(ignoringOtherApps: true)
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
