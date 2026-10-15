import AppKit

/// Owns the live markup session and the save pipeline. 2.0 inverts the 1.x
/// order: the hotkey opens a live glass session immediately (no capture),
/// and pixels are read from the screen only when the user saves — one
/// capture per area, grouped into one feedback bundle per route.
@MainActor
final class CaptureCoordinator {
    var onSessionStateChanged: ((Bool) -> Void)?

    var isSessionActive: Bool {
        session?.isActive == true || deliveryController != nil
    }

    var isDeliveringFeedback: Bool { deliveryController != nil }

    private let settingsStore: SettingsStore
    private let capturer = AreaCapturer()
    private let bundleWriter = FeedbackBundleWriter()
    private var session: LiveMarkupSession?
    private var deliveryController: FeedbackDeliveryController?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /// Hotkey and menu entry point: starts a session, or brings the current
    /// one back to the front.
    func captureFeedback() {
        if let deliveryController {
            deliveryController.present()
            return
        }
        if let session, session.isActive {
            session.refocus()
            return
        }

        startSession()
    }

    func cancelCurrentFeedback() {
        if let deliveryController {
            deliveryController.window?.performClose(nil)
            return
        }
        session?.end()
        clearSession()
    }

    /// Receipts make delivery recoverable from the inbox after closing the
    /// progress window or relaunching. Opening details never starts an upload.
    func showDelivery(for bundleURL: URL) {
        guard session == nil, deliveryController == nil else {
            captureFeedback()
            return
        }
        do {
            let receiptURL = bundleURL.appendingPathComponent("cloud-delivery.json")
            let receipt: CloudDeliveryReceipt?
            let destinationID: UUID
            if FileManager.default.fileExists(atPath: receiptURL.path) {
                let decoded = try JSONDecoder().decode(CloudDeliveryReceipt.self, from: Data(contentsOf: receiptURL))
                receipt = decoded
                destinationID = decoded.destinationID
            } else {
                struct Attempt: Decodable { let destinationID: UUID }
                let attempt = try JSONDecoder().decode(Attempt.self, from: Data(contentsOf: bundleURL.appendingPathComponent("cloud-delivery-attempt.json")))
                receipt = nil
                destinationID = attempt.destinationID
            }
            guard let destination = settingsStore.settings.destinations.first(where: { $0.id == destinationID }) else {
                throw MarkupError("This destination has been disconnected. The delivery receipt and your feedback remain in the local bundle.")
            }
            try receipt?.validate(for: destination)
            let metadata = try JSONDecoder().decode(FeedbackMetadata.self, from: Data(contentsOf: bundleURL.appendingPathComponent(FeedbackAssetNames.metadata)))
            let job = FeedbackDeliveryJob(
                routeKey: metadata.hostedApp?.routeKey ?? metadata.browser?.routeKey ?? metadata.app.bundleId,
                routeName: metadata.hostedApp?.routeName ?? metadata.browser?.routeName ?? metadata.app.name,
                bundleURL: bundleURL, destination: destination, receipt: receipt,
                error: receipt?.complete == true ? nil : receipt == nil
                    ? "The previous send did not receive a confirmed response. Check \(destination.provider.displayName) for the issue before sending again. Markup will not create a duplicate."
                    : "This issue was created, but screenshot delivery is unfinished. Try Again resumes the same issue.",
                canRetry: receipt != nil
            )
            presentDelivery(jobs: [job], sendImmediately: false)
        } catch {
            showAlert(title: "Could Not Open Delivery", message: error.localizedDescription)
        }
    }

    // MARK: - Session lifecycle

    private func startSession() {
        guard ensureCaptureAccess() else { return }

        // Snapshot before Markup activates — after that the frontmost app
        // is Markup, and geometry has to recover the window the user was on.
        let originPID = Self.currentOriginProcessID()
        let session = LiveMarkupSession(
            originProcessID: originPID,
            dictationEngine: settingsStore.settings.dictationEngine
        )
        session.onSaveRequested = { [weak self] in
            self?.saveSession()
        }
        session.onCancelled = { [weak self] in
            self?.clearSession()
        }
        self.session = session

        let show = { [weak self] in
            guard let self, self.session === session else { return }
            session.begin()
            self.onSessionStateChanged?(true)
        }

        // First-run microphone permission must not appear on top of the
        // session; ask before the glass goes up.
        if NoteDictationController.needsMicrophonePrompt {
            Task { @MainActor in
                await NoteDictationController.requestMicrophoneAccessIfNeeded()
                Task { await NoteDictationController.prewarm(engine: self.settingsStore.settings.dictationEngine) }
                show()
            }
            return
        }

        Task { await NoteDictationController.prewarm(engine: settingsStore.settings.dictationEngine) }
        show()
    }

    private static func currentOriginProcessID() -> pid_t? {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != own
        else { return nil }
        return app.processIdentifier
    }

    private func clearSession() {
        session = nil
        onSessionStateChanged?(false)
    }

    // MARK: - Save

    private func saveSession() {
        guard let session else { return }
        let draft = session.draft
        guard draft.isComplete else {
            NSSound.beep()
            return
        }

        // Hide the glass and stop the mic before touching the screen; the
        // capture filter also excludes Markup's windows as a second guard.
        session.suspendForSave()

        var captures: [AreaCapture] = []
        for area in draft.areas {
            guard let capture = capturer.capture(area: area) else {
                showAlert(
                    title: "Could Not Capture Area \(draft.index(of: area))",
                    message: "The screen under this area could not be captured. Check Screen Recording permission for Markup and try again."
                )
                session.resumeAfterFailedSave()
                return
            }
            captures.append(capture)
        }

        // Choose every destination before writing or uploading anything.
        // A remembered cloud choice is a suggestion, never upload consent.
        let groups = draft.areasByRoute()
        var choices: [String: DestinationPickerChoice] = [:]
        for group in groups {
            let picker = DestinationPickerController(
                routeName: group.areas.first?.routeName ?? "Desktop",
                destinations: settingsStore.settings.destinations,
                suggestedDestinationID: settingsStore.suggestedDestination(for: group.routeKey)?.id,
                areaCount: group.areas.count
            )
            guard let choice = picker.runModal() else {
                session.resumeAfterFailedSave()
                return
            }
            choices[group.routeKey] = choice
        }

        // Every destination keeps the standard local bundle for recovery.
        var routes: [String: AppRoute] = [:]
        for group in groups {
            let sample = group.areas.first
            guard let route = routeForSave(
                key: group.routeKey,
                name: sample?.routeName ?? "Desktop",
                hostedApp: sample?.owner?.hostedApp
            ) else {
                session.resumeAfterFailedSave()
                return
            }
            routes[group.routeKey] = route
        }

        var savedURLs: [URL] = []
        var jobs: [FeedbackDeliveryJob] = []
        do {
            for group in groups {
                guard let route = routes[group.routeKey] else { continue }
                let groupCaptures = captures.filter { capture in
                    group.areas.contains { $0.id == capture.area.id }
                }
                let url = try bundleWriter.write(captures: groupCaptures, route: route)
                savedURLs.append(url)
                if case .cloud(let destination) = choices[group.routeKey] {
                    jobs.append(FeedbackDeliveryJob(
                        routeKey: group.routeKey, routeName: route.appName,
                        bundleURL: url, destination: destination
                    ))
                }
            }
        } catch {
            // No cloud work has begun. Roll back only this attempt's new
            // bundles so returning to the draft cannot create duplicates.
            for url in savedURLs { try? FileManager.default.removeItem(at: url) }
            showAlert(title: "Could Not Save Feedback", message: error.localizedDescription)
            session.resumeAfterFailedSave()
            return
        }

        for url in savedURLs {
            NSLog("Markup: saved feedback bundle to \(url.path)")
            NSWorkspace.shared.noteFileSystemChanged(url.path)
        }
        for job in jobs { settingsStore.recordDeliveryBundle(job.bundleURL) }
        for group in groups {
            if case .local = choices[group.routeKey] {
                settingsStore.rememberDestination(nil, for: group.routeKey)
            }
        }
        NSSound(named: "Glass")?.play()

        let lastOwnerPID = draft.activeArea?.owner?.processIdentifier
        session.end()
        clearSession()

        if !jobs.isEmpty {
            presentDelivery(jobs: jobs, sendImmediately: true)
            return
        }

        if let lastOwnerPID {
            NSRunningApplication(processIdentifier: lastOwnerPID)?
                .activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func presentDelivery(jobs: [FeedbackDeliveryJob], sendImmediately: Bool) {
        let controller = FeedbackDeliveryController(jobs: jobs, settingsStore: settingsStore)
        controller.onClose = { [weak self] in
            self?.deliveryController = nil
            self?.onSessionStateChanged?(false)
        }
        deliveryController = controller
        onSessionStateChanged?(true)
        if sendImmediately { controller.model.send() }
        controller.present()
    }

    // MARK: - Routes

    private func routeForSave(key: String, name: String, hostedApp: HostedAppContext?) -> AppRoute? {
        let persist = (hostedApp?.persistRoute ?? true) && !HostedAppContext.isEphemeralRouteKey(key)
        if persist, let route = settingsStore.route(for: key) {
            return route
        }

        NSApp.activate(ignoringOtherApps: true)
        let existing = persist ? settingsStore.route(for: key) : nil
        let startingDirectory: URL?
        if hostedApp == nil {
            startingDirectory = nil
        } else {
            startingDirectory = existing?.projectRootURL
                ?? settingsStore.route(for: HostedAppContextResolver.appleSimulatorBundleId)?.projectRootURL
        }
        return RoutePrompts.configureRoute(
            bundleId: key,
            appName: name,
            settingsStore: settingsStore,
            existingRoute: existing,
            asksFeedbackPath: persist,
            persist: persist,
            startingDirectory: startingDirectory,
            message: hostedPromptMessage(hostedApp, name: name)
        )
    }

    private func hostedPromptMessage(_ hostedApp: HostedAppContext?, name: String) -> String? {
        guard let hostedApp, !hostedApp.persistRoute else { return nil }

        switch hostedApp.hostKind {
        case HostedAppContext.simulatorKind:
            return "This capture is from the Simulator. Markup couldn't tell which app is running, so choose the project that should receive this feedback."
        case HostedAppContext.androidEmulatorKind:
            return "This capture is from Android Emulator. Choose the project that should receive this feedback."
        default:
            return "This capture is from a simulated device. Choose the project folder for \(name)."
        }
    }

    // MARK: - Permissions and alerts

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func ensureCaptureAccess() -> Bool {
        switch capturer.screenCaptureAccess() {
        case .granted:
            return true
        case .blockedByDebugger:
            showDebuggerBlocksCaptureAlert()
            return false
        case .needsRelaunch:
            showPermissionGrantedRelaunchAlert()
            return false
        case .denied:
            showScreenRecordingPermissionAlert()
            return false
        }
    }

    private func showDebuggerBlocksCaptureAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording Can't Run Under the Debugger"
        alert.informativeText = """
        macOS will not give Markup a working Screen Recording permission while Xcode's debugger is attached. The system prompt can appear on every Run, and capture still fails after you relaunch from Xcode.

        Stop this session and Run the Markup scheme (Debug executable is off). Or relaunch Markup now without the debugger.
        """
        alert.addButton(withTitle: "Relaunch Without Debugger")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            DeveloperSession.relaunchDetached()
        }
    }

    private func showPermissionGrantedRelaunchAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Relaunch Markup to Finish Setup"
        alert.informativeText = "Screen Recording permission was granted, but macOS only applies it after Markup starts again. Microphone permission is requested on the next capture."
        alert.addButton(withTitle: "Relaunch Markup")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            DeveloperSession.relaunchDetached()
        }
    }

    private func showScreenRecordingPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Needed"
        alert.informativeText = deniedPermissionMessage()
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func deniedPermissionMessage() -> String {
        if let warning = DeveloperSession.tccStabilityWarning {
            return warning
        }

        return "Markup needs Screen Recording permission before it can save marked areas. After enabling it, relaunch Markup and try the hotkey again."
    }
}
