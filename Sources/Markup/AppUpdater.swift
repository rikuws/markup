import Combine
import Foundation
import Sparkle

final class AppUpdater: NSObject, ObservableObject {
    private let updaterController: SPUStandardUpdaterController
    private var canCheckObservation: NSKeyValueObservation?

    @Published private(set) var canCheckForUpdates = false

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        super.init()

        canCheckObservation = updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            DispatchQueue.main.async {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }
}
