#if DIRECT_DISTRIBUTION
import Combine
import Sparkle

/// Owns Sparkle's updater for the lifetime of the menu-bar application.
/// Sparkle compares the appcast's build number with CFBundleVersion, verifies
/// the downloaded archive, and presents its standard update UI.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var automaticallyDownloadsUpdates = true
    @Published private(set) var canCheckForUpdates = false

    private let updaterController: SPUStandardUpdaterController
    private var hasStarted = false
    private var stateCancellables = Set<AnyCancellable>()

    private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updaterController.updater.automaticallyDownloadsUpdates
        let updater = updaterController.updater
        updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .combineLatest(
                updater.publisher(for: \.sessionInProgress, options: [.initial, .new])
            )
            .sink { [weak self] updaterCanCheck, sessionInProgress in
                guard let self else { return }
                self.canCheckForUpdates = self.hasStarted
                    && updaterCanCheck
                    && !sessionInProgress
            }
            .store(in: &stateCancellables)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        updaterController.startUpdater()
        refreshPreferences()
        refreshAvailability()
    }

    func checkForUpdates() {
        start()
        let updater = updaterController.updater
        guard updater.canCheckForUpdates, !updater.sessionInProgress else {
            refreshAvailability()
            return
        }
        updater.checkForUpdates()
        refreshAvailability()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = enabled
        refreshPreferences()
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        updaterController.updater.automaticallyDownloadsUpdates = enabled
        refreshPreferences()
    }

    func refreshPreferences() {
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updaterController.updater.automaticallyDownloadsUpdates
    }

    private func refreshAvailability() {
        let updater = updaterController.updater
        canCheckForUpdates = hasStarted
            && updater.canCheckForUpdates
            && !updater.sessionInProgress
    }
}
#endif
