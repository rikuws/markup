import AppKit

final class CaptureCoordinator {
    private let settingsStore: SettingsStore
    private let capturer = ActiveWindowCapturer()
    private let bundleWriter = FeedbackBundleWriter()
    private let recorder = ScreenRecorder()
    private var overlayController: AnnotationWindowController?
    private var recordingProgressController: RecordingProgressWindowController?
    private let recordingDuration: TimeInterval = 10

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func captureFeedback(recordingURL: URL? = nil) {
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

        let controller = AnnotationWindowController(
            captured: captured,
            route: settingsStore.route(for: captured.routeKey),
            recordingURL: recordingURL,
            onSave: { [weak self] note, region, annotatedImage, originalImage, recordingURL in
                self?.saveFeedback(
                    captured: captured,
                    note: note,
                    region: region,
                    annotatedImage: annotatedImage,
                    originalImage: originalImage,
                    recordingURL: recordingURL
                )
            },
            onChangeRoute: { [weak self] existingRoute in
                self?.changeRoute(for: captured, existingRoute: existingRoute)
            },
            onCancel: { [weak self] in
                self?.overlayController = nil
            },
            onRecord: { [weak self] in
                self?.recordClip(from: captured)
            }
        )

        overlayController = controller
        controller.show()
    }

    private func recordClip(from captured: CapturedWindow) {
        overlayController?.close()
        overlayController = nil

        NSRunningApplication(processIdentifier: captured.processIdentifier)?
            .activate(options: [.activateIgnoringOtherApps])

        let progressController = RecordingProgressWindowController(duration: recordingDuration)
        recordingProgressController = progressController
        progressController.show()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }

            self.recorder.record(
                duration: self.recordingDuration,
                onStarted: {
                    DispatchQueue.main.async {
                        progressController.markStarted()
                    }
                },
                completion: { [weak self] result in
                    DispatchQueue.main.async {
                        self?.recordingProgressController?.close()
                        self?.recordingProgressController = nil

                        switch result {
                        case .success(let url):
                            self?.captureFeedback(recordingURL: url)
                        case .failure(let error):
                            self?.showAlert(title: "Recording Failed", message: error.localizedDescription)
                            self?.captureFeedback()
                        }
                    }
                }
            )
        }
    }

    private func saveFeedback(
        captured: CapturedWindow,
        note: String,
        region: CaptureRegion,
        annotatedImage: NSImage,
        originalImage: NSImage,
        recordingURL: URL?
    ) {
        guard let route = routeForSave(captured) else {
            overlayController?.show()
            return
        }

        do {
            let url = try bundleWriter.write(
                captured: captured,
                route: route,
                note: note,
                region: region,
                annotatedImage: annotatedImage,
                originalImage: originalImage,
                recordingURL: recordingURL
            )
            NSLog("Markup: saved feedback bundle to \(url.path)")
            NSSound(named: "Glass")?.play()
            NSWorkspace.shared.noteFileSystemChanged(url.path)
        } catch {
            showAlert(title: "Could Not Save Feedback", message: error.localizedDescription)
            return
        }

        overlayController?.close()
        overlayController = nil
        NSRunningApplication(processIdentifier: captured.processIdentifier)?
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
