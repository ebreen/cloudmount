import Combine
import SwiftUI
import CloudMountKit

@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State

    @Published var accounts: [B2Account] = []
    @Published var mountConfigs: [MountConfiguration] = []
    @Published var lastError: String?
    @Published var isConnected: Bool = false
    @Published var mountStatuses: [UUID: MountStatus] = [:]
    @Published var showOnboarding = false

    // MARK: - Mount Status

    enum MountStatus: Equatable {
        case unmounted
        case mounting
        case mounted
        case unmounting
        case error(String)
    }

    // MARK: - Dependencies

    let sharedDefaults = SharedDefaults.shared
    let mountClient = MountClient()
    let mountMonitor = MountMonitor()
    let extensionDetector = ExtensionDetector()

    private var mountPathCancellable: AnyCancellable?

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

    // MARK: - Mount/Unmount

    /// Mount a configured bucket via the FSKit extension.
    func mount(_ config: MountConfiguration) {
        mountStatuses[config.id] = .mounting
        lastError = nil

        Task {
            do {
                try await mountClient.mount(config)
                mountStatuses[config.id] = .mounted
            } catch let error as MountError {
                if case .extensionNotEnabled = error {
                    showOnboarding = true
                }
                mountStatuses[config.id] = .error(error.localizedDescription)
                lastError = error.localizedDescription
            } catch {
                mountStatuses[config.id] = .error(error.localizedDescription)
                lastError = error.localizedDescription
            }
        }
    }

    /// Unmount a mounted bucket.
    func unmount(_ config: MountConfiguration) {
        mountStatuses[config.id] = .unmounting
        lastError = nil

        Task {
            do {
                try await mountClient.unmount(config)
                mountStatuses[config.id] = .unmounted
            } catch {
                mountStatuses[config.id] = .error(error.localizedDescription)
                lastError = error.localizedDescription
            }
        }
    }

    /// Get the current mount status for a configuration.
    func mountStatus(for config: MountConfiguration) -> MountStatus {
        mountStatuses[config.id] ?? .unmounted
    }

    // MARK: - Monitoring

    /// Start mount monitoring, sync initial status, and check extension enablement.
    func startMonitoring() {
        mountMonitor.startMonitoring(configs: mountConfigs)

        for config in mountConfigs {
            if mountMonitor.isMounted(config) {
                mountStatuses[config.id] = .mounted
            }
        }

        mountPathCancellable = mountMonitor.$mountedPaths
            .receive(on: RunLoop.main)
            .sink { [weak self] mountedPaths in
                guard let self else { return }
                for config in self.mountConfigs {
                    let isCurrentlyMounted = mountedPaths.contains(config.mountPoint)
                    let currentStatus = self.mountStatuses[config.id] ?? .unmounted
                    if isCurrentlyMounted && currentStatus != .mounted {
                        self.mountStatuses[config.id] = .mounted
                    } else if !isCurrentlyMounted && currentStatus == .mounted {
                        self.mountStatuses[config.id] = .unmounted
                    }
                }
            }

        Task {
            await extensionDetector.checkExtensionStatus()
            if extensionDetector.needsSetup {
                showOnboarding = true
            }
        }
    }

    // MARK: - Clear All

    /// Disconnect: remove all accounts, mount configs, and credentials.
    func clearAll() {
        mountMonitor.stopMonitoring()
        mountPathCancellable?.cancel()
        mountPathCancellable = nil

        for account in accounts {
            try? CredentialStore.deleteAccount(id: account.id)
        }
        accounts = []
        mountConfigs = []
        mountStatuses = [:]
        isConnected = false
        lastError = nil
        sharedDefaults.saveAccounts([])
        sharedDefaults.saveMountConfigurations([])
    }
}
