import SwiftUI
import CloudMountKit

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
            
            // Mounts section
            mountsSection
            
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
                        .fill(appState.isConnected ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(appState.isConnected ? "Connected" : "Not connected")
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
    
    private var mountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MOUNTS")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
            
            if appState.mountConfigs.isEmpty {
                Text("No mounts configured")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(appState.mountConfigs) { config in
                    let status = appState.mountStatus(for: config)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            mountIcon(for: status)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(config.bucketName)
                                    .font(.subheadline)
                                Text(config.mountPoint)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            mountButton(for: config, status: status)
                        }
                        if case .error(let message) = status {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
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
    
    @ViewBuilder
    private func mountIcon(for status: AppState.MountStatus) -> some View {
        switch status {
        case .mounted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .mounting, .unmounting:
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .unmounted:
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.blue)
        }
    }

    @ViewBuilder
    private func mountButton(for config: MountConfiguration, status: AppState.MountStatus) -> some View {
        switch status {
        case .unmounted, .error:
            Button("Mount") {
                appState.mount(config)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        case .mounted:
            Button("Unmount") {
                appState.unmount(config)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        case .mounting:
            Button("Mounting…") {}
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(true)
        case .unmounting:
            Button("Unmounting…") {}
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(true)
        }
    }

    private func showAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(
            options: [
                .applicationName: "CloudMount",
                .applicationVersion: "2.0.0",
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
