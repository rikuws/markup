import AppKit

/// Owns the live markup session and the save pipeline. 2.0 inverts the 1.x
/// order: the hotkey opens a live glass session immediately (no capture),
/// and pixels are read from the screen only when the user saves — one
/// capture per area, grouped into one feedback bundle per route.
final class CaptureCoordinator {
    var onSessionStateChanged: ((Bool) -> Void)?

    var isSessionActive: Bool {
        session?.isActive == true
    }

    private let settingsStore: SettingsStore
    private let capturer = AreaCapturer()
    private let bundleWriter = FeedbackBundleWriter()
    private var session: LiveMarkupSession?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /// Hotkey and menu entry point: starts a session, or brings the current
    /// one back to the front.
    func captureFeedback() {
        if let session, session.isActive {
            session.refocus()
            return
        }

        startSession()
    }

    func cancelCurrentFeedback() {
        session?.end()
        clearSession()
    }

    // MARK: - Session lifecycle

    private func startSession() {
        guard ensureCaptureAccess() else { return }

        let session = LiveMarkupSession(capturer: capturer)
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
                Task { await NoteDictationController.prewarm() }
                show()
            }
            return
        }

        Task { await NoteDictationController.prewarm() }
        show()
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

        // Resolve every route before writing anything, prompting for
        // unknown apps. Cancelling any prompt aborts the save and returns
        // to the live session.
        let groups = draft.areasByRoute()
        var routes: [String: AppRoute] = [:]
        for group in groups {
            let name = group.areas.first?.routeName ?? "Desktop"
            guard let route = routeForSave(key: group.routeKey, name: name) else {
                session.resumeAfterFailedSave()
                return
            }
            routes[group.routeKey] = route
        }

        var savedURLs: [URL] = []
        do {
            for group in groups {
                guard let route = routes[group.routeKey] else { continue }
                let groupCaptures = captures.filter { capture in
                    group.areas.contains { $0.id == capture.area.id }
                }
                let url = try bundleWriter.write(captures: groupCaptures, route: route)
                savedURLs.append(url)
            }
        } catch {
            showAlert(title: "Could Not Save Feedback", message: error.localizedDescription)
            session.resumeAfterFailedSave()
            return
        }

        for url in savedURLs {
            NSLog("Markup: saved feedback bundle to \(url.path)")
            NSWorkspace.shared.noteFileSystemChanged(url.path)
        }
        NSSound(named: "Glass")?.play()

        let lastOwnerPID = draft.activeArea?.owner?.processIdentifier
        session.end()
        clearSession()

        if let lastOwnerPID {
            NSRunningApplication(processIdentifier: lastOwnerPID)?
                .activate(options: [.activateIgnoringOtherApps])
        }
    }

    // MARK: - Routes

    private func routeForSave(key: String, name: String) -> AppRoute? {
        if let route = settingsStore.route(for: key) {
            return route
        }

        NSApp.activate(ignoringOtherApps: true)
        return RoutePrompts.configureRoute(
            bundleId: key,
            appName: name,
            settingsStore: settingsStore,
            existingRoute: nil,
            asksFeedbackPath: true
        )
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
