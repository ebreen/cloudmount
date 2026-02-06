//
//  OnboardingView.swift
//  CloudMount
//
//  First-launch onboarding view for FSKit extension setup.
//  Guides the user to enable the extension in System Settings.
//

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            // Icon and title
            Image(systemName: "externaldrive.fill.badge.icloud")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
                .padding(.top, 8)

            Text("Enable CloudMount Extension")
                .font(.title2)
                .fontWeight(.semibold)

            Text("CloudMount needs the filesystem extension enabled to mount B2 buckets as local drives.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // Setup steps
            VStack(alignment: .leading, spacing: 12) {
                stepRow(number: 1, text: "Open System Settings")
                stepRow(number: 2, text: "Go to General \u{2192} Login Items & Extensions")
                stepRow(number: 3, text: "Find CloudMount under Extensions")
                stepRow(number: 4, text: "Toggle the switch to enable it")
            }
            .padding(.horizontal, 24)

            // Status indicator
            extensionStatusView

            Spacer()

            // Action buttons
            HStack(spacing: 12) {
                Button("Skip for Now") {
                    appState.showOnboarding = false
                }
                .buttonStyle(.bordered)

                Button("Open System Settings") {
                    appState.extensionDetector.openSystemSettings()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 8)
        }
        .frame(width: 400, height: 380)
        .padding()
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.blue))

            Text(text)
                .font(.subheadline)
        }
    }

    @ViewBuilder
    private var extensionStatusView: some View {
        HStack(spacing: 8) {
            switch appState.extensionDetector.status {
            case .enabled:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Extension enabled")
                    .foregroundStyle(.green)
            case .disabled:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Extension not enabled")
                    .foregroundStyle(.red)
            case .checking:
                ProgressView()
                    .controlSize(.small)
                Text("Checking...")
                    .foregroundStyle(.secondary)
            case .unknown:
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                Text("Status unknown")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .fontWeight(.medium)
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AppState())
}
