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
                message: "Focus the app window and try again. If this keeps happening, check Screen Recording and Accessibility permissions for punchlist."
            )
            return
        }

        let controller = AnnotationWindowController(
            captured: captured,
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
            NSLog("punchlist: saved feedback bundle to \(url.path)")
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
        if let route = settingsStore.route(for: captured.bundleId) {
            return route
        }

        overlayController?.window?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.message = "Choose the project folder for \(captured.appName)"
        panel.prompt = "Use This Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let projectRoot = panel.url else {
            return nil
        }

        let feedbackPath = promptFeedbackPath(appName: captured.appName)
        settingsStore.upsertRoute(
            bundleId: captured.bundleId,
            appName: captured.appName,
            projectRoot: projectRoot,
            feedbackPath: feedbackPath
        )

        return settingsStore.route(for: captured.bundleId)
    }

    private func routeForSave(_ captured: CapturedWindow) -> AppRoute? {
        settingsStore.route(for: captured.bundleId) ?? requestRoute(for: captured)
    }

    private func promptFeedbackPath(appName: String) -> String {
        let alert = NSAlert()
        alert.messageText = "Feedback Folder"
        alert.informativeText = "Choose the relative folder inside this project for \(appName)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Use Default")

        let field = NSTextField(string: ".punchlist/feedback")
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field

        return alert.runModal() == .alertFirstButtonReturn
            ? field.stringValue.trimmedFeedbackPath
            : ".punchlist/feedback"
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
        alert.informativeText = "punchlist needs Screen Recording permission before it can show the screenshot editor. After enabling it, relaunch punchlist and try the hotkey again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
