//
//  SharedDefaults.swift
//  CloudMountKit
//
//  App Group UserDefaults wrapper for non-secret configuration
//  shared between the host app and the FSKit extension.
//

import Foundation

/// Provides typed access to shared configuration stored in
/// App Group UserDefaults (`group.com.cloudmount.shared`).
///
/// Use this for non-secret data: account metadata, mount configs,
/// and general preferences. Secrets belong in ``CredentialStore``.
public final class SharedDefaults: @unchecked Sendable {

    /// Singleton instance using the shared App Group suite.
    public static let shared = SharedDefaults()

    // MARK: - Keys

    private enum Keys {
        static let accounts = "cloudmount.accounts"
        static let mounts = "cloudmount.mounts"
        static let launchAtLogin = "cloudmount.launchAtLogin"
    }

    /// The App Group suite name shared between all targets.
    public static let suiteName = "group.com.cloudmount.shared"

    private let defaults: UserDefaults

    // MARK: - Init

    private init() {
        self.defaults = UserDefaults(suiteName: SharedDefaults.suiteName) ?? .standard
    }

    /// Designated initializer for testing with a custom suite.
    internal init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - Accounts (metadata only — secrets live in Keychain)

    /// Persist the array of B2 account metadata.
    public func saveAccounts(_ accounts: [B2Account]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: Keys.accounts)
    }

    /// Load previously saved B2 account metadata.
    public func loadAccounts() -> [B2Account] {
        guard let data = defaults.data(forKey: Keys.accounts),
              let accounts = try? JSONDecoder().decode([B2Account].self, from: data)
        else {
            return []
        }
        return accounts
    }

    // MARK: - Mount Configurations

    /// Persist the array of mount configurations.
    public func saveMountConfigurations(_ configs: [MountConfiguration]) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        defaults.set(data, forKey: Keys.mounts)
    }

    /// Load previously saved mount configurations.
    public func loadMountConfigurations() -> [MountConfiguration] {
        guard let data = defaults.data(forKey: Keys.mounts),
              let configs = try? JSONDecoder().decode([MountConfiguration].self, from: data)
        else {
            return []
        }
        return configs
    }

    // MARK: - General Settings

    /// Whether the app should launch at login.
    public var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }
}
