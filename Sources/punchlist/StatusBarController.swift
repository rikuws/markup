import AppKit

final class StatusBarController {
    private let item: NSStatusItem
    private let settingsStore: SettingsStore
    private let capture: () -> Void
    private let openSettings: () -> Void
    private let openFeedbackFolder: () -> Void
    private let quit: () -> Void

    init(
        settingsStore: SettingsStore,
        capture: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        openFeedbackFolder: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.capture = capture
        self.openSettings = openSettings
        self.openFeedbackFolder = openFeedbackFolder
        self.quit = quit

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "P"
        item.button?.toolTip = "punchlist"
        item.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let captureItem = NSMenuItem(title: "Capture Feedback", action: #selector(captureSelected), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)

        let openItem = NSMenuItem(title: "Open Current Feedback Folder", action: #selector(openFeedbackFolderSelected), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(settingsSelected), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit punchlist", action: #selector(quitSelected), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func captureSelected() {
        capture()
    }

    @objc private func settingsSelected() {
        openSettings()
    }

    @objc private func openFeedbackFolderSelected() {
        openFeedbackFolder()
    }

    @objc private func quitSelected() {
        quit()
    }
}
