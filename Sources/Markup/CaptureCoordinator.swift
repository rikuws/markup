import AppKit

final class CaptureCoordinator {
    var onAppendModeChanged: ((Bool) -> Void)?
    var onRecordingStateChanged: ((Bool) -> Void)?

    var isAddingToCurrentFeedback: Bool {
        isArmedForAdditionalShot
    }

    var isRecording: Bool {
        recorder.isRecording || recordingProgressController != nil
    }

    private let settingsStore: SettingsStore
    private let capturer = ActiveWindowCapturer()
    private let bundleWriter = FeedbackBundleWriter()
    private let recorder = ScreenRecorder()
    private var overlayController: AnnotationWindowController?
    private var recordingProgressController: RecordingProgressWindowController?
    private var appendHUDController: AppendCaptureHUDController?
    private var draft: FeedbackDraft?
    private var shouldStopRecordingWhenStarted = false
    private var isArmedForAdditionalShot = false {
        didSet {
            guard oldValue != isArmedForAdditionalShot else { return }
            onAppendModeChanged?(isArmedForAdditionalShot)
        }
    }
    private let recordingDuration: TimeInterval = 10

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func captureFeedback(recordingURL: URL? = nil) {
        if recordingURL == nil, isRecording {
            stopActiveRecording()
            return
        }

        if let recordingURL, let draft {
            draft.recordingURL = recordingURL
            showAnnotation(for: draft, selectedShotID: nil, showsAppendBanner: draft.shots.count > 1)
            return
        }

        if isArmedForAdditionalShot {
            appendShotToCurrentDraft()
        } else {
            startNewDraft()
        }
    }

    func cancelCurrentFeedback() {
        overlayController?.close()
        overlayController = nil
        draft = nil
        clearAppendMode()
    }

    private func startNewDraft() {
        guard capturer.ensureScreenCapturePermission() else {
            showScreenRecordingPermissionAlert()
            return
        }

        guard let captured = capturer.captureActiveWindow() else {
            showAlert(
                title: "Could Not Capture Screen",
                message: "Focus the app window and try again. If this keeps happening, check Screen Recording and Accessibility permissions for Markup."
            )
            return
        }

        let draft = FeedbackDraft(
            primaryCapture: captured,
            route: settingsStore.route(for: captured.routeKey)
        )
        self.draft = draft
        showAnnotation(for: draft, selectedShotID: draft.shots.first?.id, showsAppendBanner: false)
    }

    private func appendShotToCurrentDraft() {
        guard let draft else {
            clearAppendMode()
            startNewDraft()
            return
        }

        guard draft.canAddShot else {
            NSSound.beep()
            clearAppendMode()
            showAnnotation(for: draft, selectedShotID: draft.shots.last?.id, showsAppendBanner: draft.shots.count > 1)
            return
        }

        guard capturer.ensureScreenCapturePermission() else {
            showScreenRecordingPermissionAlert()
            return
        }

        guard let captured = capturer.captureActiveWindow() else {
            showAlert(
                title: "Could Not Add Screenshot",
                message: "Focus the app window and press the Markup hotkey again."
            )
            showAppendHUD(for: draft)
            return
        }

        guard let shot = draft.append(captured: captured) else {
            NSSound.beep()
            clearAppendMode()
            showAnnotation(for: draft, selectedShotID: draft.shots.last?.id, showsAppendBanner: draft.shots.count > 1)
            return
        }

        clearAppendMode()
        showAnnotation(for: draft, selectedShotID: shot.id, showsAppendBanner: true)
    }

    private func showAnnotation(
        for draft: FeedbackDraft,
        selectedShotID: UUID?,
        showsAppendBanner: Bool
    ) {
        appendHUDController?.close()
        appendHUDController = nil

        let controller = AnnotationWindowController(
            draft: draft,
            selectedShotID: selectedShotID,
            showsAppendBanner: showsAppendBanner,
            onSave: { [weak self, weak draft] in
                guard let draft else { return }
                self?.saveFeedback(draft: draft)
            },
            onChangeRoute: { [weak self, weak draft] existingRoute in
                guard let self, let draft else { return nil }
                let updatedRoute = self.changeRoute(
                    for: draft.primaryCapture,
                    existingRoute: existingRoute
                )
                draft.route = updatedRoute
                return updatedRoute
            },
            onCancel: { [weak self, weak draft] in
                guard let self else { return }
                if self.draft === draft {
                    self.draft = nil
                }
                self.clearAppendMode()
                self.overlayController = nil
            },
            onRecord: { [weak self, weak draft] selectedShotID in
                guard let draft else { return }
                self?.recordClip(for: draft, selectedShotID: selectedShotID)
            },
            onAddShot: { [weak self, weak draft] in
                guard let draft else { return }
                self?.beginAddingShot(to: draft)
            }
        )

        overlayController = controller
        controller.show()
    }

    private func beginAddingShot(to draft: FeedbackDraft) {
        guard draft.canAddShot else {
            NSSound.beep()
            return
        }

        overlayController?.close()
        overlayController = nil
        isArmedForAdditionalShot = true
        showAppendHUD(for: draft)

        NSRunningApplication(processIdentifier: draft.primaryCapture.processIdentifier)?
            .activate(options: [.activateIgnoringOtherApps])
    }

    private func showAppendHUD(for draft: FeedbackDraft) {
        appendHUDController?.close()
        appendHUDController = AppendCaptureHUDController(
            shotIndex: draft.nextShotIndex,
            hotKeyDisplay: settingsStore.settings.hotKey.normalized.displayString
        )
        appendHUDController?.show()
    }

    private func clearAppendMode() {
        appendHUDController?.close()
        appendHUDController = nil
        isArmedForAdditionalShot = false
    }

    private func recordClip(for draft: FeedbackDraft, selectedShotID: UUID?) {
        overlayController?.close()
        overlayController = nil

        let selectedCapture = selectedShotID
            .flatMap { id in draft.shots.first(where: { $0.id == id })?.captured }
            ?? draft.primaryCapture
        NSRunningApplication(processIdentifier: selectedCapture.processIdentifier)?
            .activate(options: [.activateIgnoringOtherApps])

        let hotKeyDisplay = settingsStore.settings.hotKey.normalized.displayString
        let progressController = RecordingProgressWindowController(
            duration: recordingDuration,
            stopShortcutDisplay: hotKeyDisplay
        )
        recordingProgressController = progressController
        progressController.show()
        onRecordingStateChanged?(true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak draft] in
            guard let self, let draft else { return }

            self.recorder.record(
                duration: self.recordingDuration,
                onStarted: {
                    DispatchQueue.main.async {
                        progressController.markStarted()
                        if self.shouldStopRecordingWhenStarted {
                            self.shouldStopRecordingWhenStarted = false
                            progressController.markStopping()
                            self.recorder.stop()
                        }
                    }
                },
                completion: { [weak self, weak draft] result in
                    DispatchQueue.main.async {
                        guard let self, let draft else { return }
                        self.shouldStopRecordingWhenStarted = false
                        self.recordingProgressController?.close()
                        self.recordingProgressController = nil
                        self.onRecordingStateChanged?(false)

                        switch result {
                        case .success(let url):
                            draft.recordingURL = url
                        case .failure(let error):
                            self.showAlert(title: "Recording Failed", message: error.localizedDescription)
                        }

                        self.showAnnotation(
                            for: draft,
                            selectedShotID: selectedShotID,
                            showsAppendBanner: draft.shots.count > 1
                        )
                    }
                }
            )
        }
    }

    private func stopActiveRecording() {
        guard isRecording else { return }

        shouldStopRecordingWhenStarted = true
        recordingProgressController?.markStopping()
        if recorder.isRecording {
            recorder.stop()
        }
    }

    private func saveFeedback(draft: FeedbackDraft) {
        guard draft.isComplete else {
            NSSound.beep()
            return
        }

        guard let route = routeForSave(draft.primaryCapture) else {
            overlayController?.show()
            return
        }
        draft.route = route

        do {
            let url = try bundleWriter.write(draft: draft, route: route)
            NSLog("Markup: saved feedback bundle to \(url.path)")
            NSSound(named: "Glass")?.play()
            NSWorkspace.shared.noteFileSystemChanged(url.path)
        } catch {
            showAlert(title: "Could Not Save Feedback", message: error.localizedDescription)
            return
        }

        overlayController?.close()
        overlayController = nil
        self.draft = nil
        clearAppendMode()
        NSRunningApplication(processIdentifier: draft.primaryCapture.processIdentifier)?
            .activate(options: [.activateIgnoringOtherApps])
    }

    private func requestRoute(for captured: CapturedWindow) -> AppRoute? {
        if let route = settingsStore.route(for: captured.routeKey) {
            return route
        }

        return changeRoute(for: captured, existingRoute: nil)
    }

    private func routeForSave(_ captured: CapturedWindow) -> AppRoute? {
        settingsStore.route(for: captured.routeKey) ?? requestRoute(for: captured)
    }

    private func changeRoute(for captured: CapturedWindow, existingRoute: AppRoute?) -> AppRoute? {
        let currentRoute = existingRoute ?? settingsStore.route(for: captured.routeKey)

        return withOverlayTemporarilyHidden {
            RoutePrompts.configureRoute(
                bundleId: captured.routeKey,
                appName: captured.routeName,
                settingsStore: settingsStore,
                existingRoute: currentRoute,
                asksFeedbackPath: currentRoute == nil
            )
        }
    }

    private func withOverlayTemporarilyHidden<T>(_ action: () -> T) -> T {
        let overlayWindow = overlayController?.window
        let shouldRestoreOverlay = overlayWindow?.isVisible == true

        if shouldRestoreOverlay {
            overlayWindow?.orderOut(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
        let result = action()

        if shouldRestoreOverlay {
            overlayWindow?.orderFrontRegardless()
            overlayWindow?.makeKey()
        }

        return result
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showScreenRecordingPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Needed"
        alert.informativeText = "Markup needs Screen Recording permission before it can show the screenshot editor. After enabling it, relaunch Markup and try the hotkey again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
