import SwiftUI
import CloudMountKit

@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State

    @Published var accounts: [B2Account] = []
    @Published var mountConfigs: [MountConfiguration] = []
    @Published var lastError: String?
    @Published var isConnected: Bool = false

    // MARK: - Dependencies

    let sharedDefaults = SharedDefaults.shared

    // MARK: - Init

    init() {
        loadState()
    }

    // MARK: - State Persistence

    /// Load accounts and mount configs from SharedDefaults.
    func loadState() {
        accounts = sharedDefaults.loadAccounts()
        mountConfigs = sharedDefaults.loadMountConfigurations()
        isConnected = !accounts.isEmpty
    }

    // MARK: - Account Management

    /// Add a B2 account and save its credentials to the keychain.
    func addAccount(_ account: B2Account, applicationKey: String) {
        // Skip if account with same keyId already exists
        guard !accounts.contains(where: { $0.keyId == account.keyId }) else { return }

        do {
            try CredentialStore.saveAccount(account, applicationKey: applicationKey)
            accounts.append(account)
            sharedDefaults.saveAccounts(accounts)
            isConnected = true
        } catch {
            lastError = "Failed to save credentials: \(error.localizedDescription)"
        }
    }

    /// Remove a B2 account and its credentials.
    func removeAccount(_ account: B2Account) {
        do {
            try CredentialStore.deleteAccount(id: account.id)
        } catch {
            lastError = "Failed to delete credentials: \(error.localizedDescription)"
        }

        accounts.removeAll { $0.id == account.id }
        // Remove mount configs associated with this account
        mountConfigs.removeAll { $0.accountId == account.id }

        sharedDefaults.saveAccounts(accounts)
        sharedDefaults.saveMountConfigurations(mountConfigs)
        isConnected = !accounts.isEmpty
    }

    // MARK: - Mount Configuration Management

    /// Add a mount configuration for a bucket.
    func addMountConfig(_ config: MountConfiguration) {
        guard !mountConfigs.contains(where: { $0.id == config.id }) else { return }
        mountConfigs.append(config)
        sharedDefaults.saveMountConfigurations(mountConfigs)
    }

    /// Remove a mount configuration.
    func removeMountConfig(_ config: MountConfiguration) {
        mountConfigs.removeAll { $0.id == config.id }
        sharedDefaults.saveMountConfigurations(mountConfigs)
    }

    // MARK: - Mount/Unmount Stubs (Phase 7)

    /// Mount a configured bucket. Stub — wired in Phase 7.
    func mount(_ config: MountConfiguration) {
        lastError = "Mount not yet implemented (Phase 7)"
    }

    /// Unmount a mounted bucket. Stub — wired in Phase 7.
    func unmount(_ config: MountConfiguration) {
        lastError = "Unmount not yet implemented (Phase 7)"
    }

    // MARK: - Clear All

    /// Disconnect: remove all accounts, mount configs, and credentials.
    func clearAll() {
        for account in accounts {
            try? CredentialStore.deleteAccount(id: account.id)
        }
        accounts = []
        mountConfigs = []
        isConnected = false
        lastError = nil
        sharedDefaults.saveAccounts([])
        sharedDefaults.saveMountConfigurations([])
    }
}
