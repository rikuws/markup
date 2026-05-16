import AppKit
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

        refreshState()

        observations.append(updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            self?.publishState(from: updater)
        })

        observations.append(updaterController.updater.observe(
            \.automaticallyChecksForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            self?.publishState(from: updater)
        })
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.checkForUpdates(sender)
            }
            return
        }

        NSApp.activate(ignoringOtherApps: true)
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

    func refreshState() {
        publishState(from: updaterController.updater)
    }

    private func publishState(from updater: SPUUpdater) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.publishState(from: updater)
            }
            return
        }

        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }
}
