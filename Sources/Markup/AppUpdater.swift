import Combine
import Foundation
import Sparkle

final class AppUpdater: NSObject, ObservableObject {
    private let updaterController: SPUStandardUpdaterController
    private var observations: [NSKeyValueObservation] = []

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        super.init()

        observations.append(updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            DispatchQueue.main.async {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        })

        observations.append(updaterController.updater.observe(
            \.automaticallyChecksForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            DispatchQueue.main.async {
                self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            }
        })
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setAutomaticallyChecksForUpdates(enabled)
            }
            return
        }

        updaterController.updater.automaticallyChecksForUpdates = enabled
    }
}
