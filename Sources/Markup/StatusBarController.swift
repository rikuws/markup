import AppKit
import Combine

final class StatusBarController: NSObject {
    private let item: NSStatusItem
    private let captureItem: NSMenuItem
    private let checkForUpdatesItem: NSMenuItem
    private let settingsStore: SettingsStore
    private let appUpdater: AppUpdater
    private let feedbackInbox = FeedbackInbox()
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
        menu.autoenablesItems = false
        menu.delegate = self

        rebuildMenu(menu)

        return menu
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        captureItem.target = self
        captureItem.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        captureItem.isEnabled = true
        menu.addItem(captureItem)

        let openItem = NSMenuItem(title: "Open Current Feedback Folder", action: #selector(openFeedbackFolderSelected), keyEquivalent: "")
        openItem.target = self
        openItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        openItem.isEnabled = true
        menu.addItem(openItem)

        menu.addItem(.separator())

        menu.addItem(makeInboxMenuItem())

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(settingsSelected), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsItem.isEnabled = true
        menu.addItem(settingsItem)

        checkForUpdatesItem.target = self
        checkForUpdatesItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        checkForUpdatesItem.isEnabled = appUpdater.canCheckForUpdates
        menu.addItem(checkForUpdatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Markup", action: #selector(quitSelected), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)
    }

    private func makeInboxMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Feedback Inbox", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: nil)
        item.submenu = makeInboxMenu()
        item.isEnabled = true
        return item
    }

    private func makeInboxMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let projects = feedbackInbox.projects(for: settingsStore.settings.routes)
        guard !projects.isEmpty else {
            let emptyItem = NSMenuItem(title: "No Projects Configured", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)

            let settingsItem = NSMenuItem(title: "Open Settings...", action: #selector(settingsSelected), keyEquivalent: "")
            settingsItem.target = self
            settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            settingsItem.isEnabled = true
            menu.addItem(settingsItem)
            return menu
        }

        for (index, project) in projects.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }

            let headerItem = NSMenuItem(title: shortMenuTitle(project.title), action: nil, keyEquivalent: "")
            headerItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            headerItem.toolTip = project.feedbackDirectoryURL.path
            headerItem.isEnabled = false
            menu.addItem(headerItem)

            if project.items.isEmpty {
                let emptyItem = NSMenuItem(title: "No Feedback Yet", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                menu.addItem(emptyItem)
            } else {
                for feedback in project.items {
                    menu.addItem(makeFeedbackMenuItem(feedback))
                }
            }

            let folderItem = NSMenuItem(title: "Open Feedback Folder", action: #selector(openProjectFeedbackFolderSelected), keyEquivalent: "")
            folderItem.target = self
            folderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            folderItem.representedObject = project.feedbackDirectoryURL
            folderItem.isEnabled = true
            menu.addItem(folderItem)
        }

        return menu
    }

    private func makeFeedbackMenuItem(_ feedback: FeedbackInboxItem) -> NSMenuItem {
        let title = shortMenuTitle("\(displayDate(for: feedback.createdAt)) \(feedback.title)")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        item.toolTip = "\(feedback.title)\n\(feedback.directoryURL.path)"
        item.submenu = makeFeedbackActionMenu(feedback)
        item.isEnabled = true
        return item
    }

    private func makeFeedbackActionMenu(_ feedback: FeedbackInboxItem) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let titleItem = NSMenuItem(title: shortMenuTitle(feedback.title), action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())

        let editItem = NSMenuItem(title: "Edit Feedback", action: #selector(editFeedbackSelected), keyEquivalent: "")
        editItem.target = self
        editItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        editItem.representedObject = feedback
        editItem.isEnabled = true
        menu.addItem(editItem)

        let screenshotItem = NSMenuItem(title: "Open Screenshot", action: #selector(openFeedbackScreenshotSelected), keyEquivalent: "")
        screenshotItem.target = self
        screenshotItem.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        screenshotItem.representedObject = feedback
        screenshotItem.isEnabled = feedback.screenshotURL != nil
        menu.addItem(screenshotItem)

        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealFeedbackSelected), keyEquivalent: "")
        revealItem.target = self
        revealItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        revealItem.representedObject = feedback
        revealItem.isEnabled = true
        menu.addItem(revealItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: "Move to Trash", action: #selector(deleteFeedbackSelected), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        deleteItem.representedObject = feedback
        deleteItem.isEnabled = true
        menu.addItem(deleteItem)

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

    @objc private func openProjectFeedbackFolderSelected(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch {
            showError(title: "Could Not Open Folder", message: error.localizedDescription)
        }
    }

    @objc private func checkForUpdatesSelected(_ sender: NSMenuItem) {
        appUpdater.checkForUpdates(sender)
    }

    @objc private func editFeedbackSelected(_ sender: NSMenuItem) {
        guard let feedback = sender.representedObject as? FeedbackInboxItem else { return }
        NSWorkspace.shared.open(feedback.instructionURL)
    }

    @objc private func openFeedbackScreenshotSelected(_ sender: NSMenuItem) {
        guard let feedback = sender.representedObject as? FeedbackInboxItem,
              let screenshotURL = feedback.screenshotURL
        else {
            return
        }

        NSWorkspace.shared.open(screenshotURL)
    }

    @objc private func revealFeedbackSelected(_ sender: NSMenuItem) {
        guard let feedback = sender.representedObject as? FeedbackInboxItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([feedback.directoryURL])
    }

    @objc private func deleteFeedbackSelected(_ sender: NSMenuItem) {
        guard let feedback = sender.representedObject as? FeedbackInboxItem else { return }

        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: feedback.directoryURL, resultingItemURL: &trashedURL)
        } catch {
            showError(title: "Could Not Delete Feedback", message: error.localizedDescription)
        }
    }

    @objc private func quitSelected() {
        quit()
    }

    private func displayDate(for date: Date?) -> String {
        guard let date else {
            return ""
        }

        let formatter = DateFormatter()
        formatter.locale = .current
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
        }
        return formatter.string(from: date)
    }

    private func shortMenuTitle(_ title: String, limit: Int = 30) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else {
            return trimmed
        }

        return "\(trimmed.prefix(max(0, limit - 3)))..."
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }
}
