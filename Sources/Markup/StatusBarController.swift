import AppKit
import Combine

final class StatusBarController: NSObject {
    private let item: NSStatusItem
    private let captureItem: NSMenuItem
    private let checkForUpdatesItem: NSMenuItem
    private let settingsStore: SettingsStore
    private let appUpdater: AppUpdater
    private let capture: () -> Void
    private let openSettings: () -> Void
    private let openFeedbackFolder: () -> Void
    private let quit: () -> Void
    private var settingsCancellable: AnyCancellable?
    private var updaterCancellable: AnyCancellable?

    init(
        settingsStore: SettingsStore,
        appUpdater: AppUpdater,
        capture: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        openFeedbackFolder: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.appUpdater = appUpdater
        self.capture = capture
        self.openSettings = openSettings
        self.openFeedbackFolder = openFeedbackFolder
        self.quit = quit

        captureItem = NSMenuItem(title: "Capture Feedback", action: #selector(captureSelected), keyEquivalent: "")
        checkForUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdatesSelected), keyEquivalent: "")
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        super.init()

        item.button?.image = Self.menuBarImage()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Markup"
        item.menu = makeMenu()

        applyHotKey(settingsStore.settings.hotKey)
        settingsCancellable = settingsStore.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in
                self?.applyHotKey(settings.hotKey)
            }
        updaterCancellable = appUpdater.$canCheckForUpdates
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                self?.checkForUpdatesItem.isEnabled = canCheck
            }
    }

    private static func menuBarImage() -> NSImage? {
        let image = loadImageResource(named: "MenuBarIcon", extension: "png")
            ?? NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Markup")
        image?.isTemplate = true
        image?.size = NSSize(width: 20, height: 20)
        return image
    }

    private static func loadImageResource(named name: String, extension ext: String) -> NSImage? {
        let resourceURL = Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.module.url(forResource: name, withExtension: ext)
        guard let resourceURL else {
            return nil
        }
        return NSImage(contentsOf: resourceURL)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        captureItem.target = self
        captureItem.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        menu.addItem(captureItem)

        let openItem = NSMenuItem(title: "Open Current Feedback Folder", action: #selector(openFeedbackFolderSelected), keyEquivalent: "")
        openItem.target = self
        openItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(openItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(settingsSelected), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        checkForUpdatesItem.target = self
        checkForUpdatesItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        checkForUpdatesItem.isEnabled = appUpdater.canCheckForUpdates
        menu.addItem(checkForUpdatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Markup", action: #selector(quitSelected), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func applyHotKey(_ hotKey: HotKeySettings) {
        let normalized = hotKey.normalized
        captureItem.keyEquivalent = normalized.key.lowercased()
        captureItem.keyEquivalentModifierMask = normalized.menuModifierFlags
        item.button?.toolTip = "Markup - Capture Feedback \(normalized.displayString)"
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

    @objc private func checkForUpdatesSelected(_ sender: NSMenuItem) {
        appUpdater.checkForUpdates(sender)
    }

    @objc private func quitSelected() {
        quit()
    }
}
