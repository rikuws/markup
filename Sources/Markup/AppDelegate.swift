import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private let appUpdater = AppUpdater()
    private var statusBarController: StatusBarController?
    private var captureCoordinator: CaptureCoordinator?
    private var topNotchController: TopNotchController?
    private var settingsWindowController: SettingsWindowController?
    private var hotKeyManager: HotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = CaptureCoordinator(settingsStore: settingsStore)
        captureCoordinator = coordinator

        let status = StatusBarController(
            settingsStore: settingsStore,
            appUpdater: appUpdater,
            isAddingToCurrentFeedback: { coordinator.isAddingToCurrentFeedback },
            isRecording: { coordinator.isRecording },
            capture: { coordinator.captureFeedback() },
            cancelCurrentFeedback: { coordinator.cancelCurrentFeedback() },
            openSettings: { [weak self] in self?.showSettings() },
            openFeedbackFolder: { [weak self] in self?.openCurrentFeedbackFolder() },
            quit: { NSApp.terminate(nil) }
        )
        statusBarController = status

        let topNotch = TopNotchController(settingsStore: settingsStore)
        topNotch.start()
        topNotchController = topNotch

        coordinator.onAppendModeChanged = { [weak status] _ in
            status?.refreshCaptureItemState()
        }
        coordinator.onRecordingStateChanged = { [weak status] _ in
            status?.refreshCaptureItemState()
        }

        let hotKeys = HotKeyManager(settingsStore: settingsStore) {
            coordinator.captureFeedback()
        }
        hotKeys.start()
        hotKeyManager = hotKeys

        settingsStore.onHotKeyChange = { [weak hotKeys] in
            hotKeys?.restart()
        }
    }

    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                settingsStore: settingsStore,
                appUpdater: appUpdater
            )
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func openCurrentFeedbackFolder() {
        guard let app = NSWorkspace.shared.frontmostApplication
        else {
            showSettings()
            return
        }

        let target = RouteTargetResolver.target(for: app)
        guard let route = settingsStore.route(for: target.key) else {
            showSettings()
            return
        }

        let url = route.feedbackDirectoryURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
