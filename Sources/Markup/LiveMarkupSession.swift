import AppKit

/// A borderless, fully transparent-looking window that carries the live
/// glass areas for one display. Key events are offered to the session first
/// so Escape/Return work no matter where the mouse is.
///
/// WindowServer hit-tests composited alpha, not AppKit's `hitTest(_:)`. A
/// fully clear overlay therefore never sees `mouseDown` — the click lands
/// in the app below, Markup (an accessory app) loses key status, and the
/// crosshair snaps back. `hitTestFill` is invisible but non-zero so the
/// drag stays in this window.
final class LiveSelectionWindow: NSWindow {
    /// Invisible as an overlay, but above WindowServer's zero-alpha skip.
    static let hitTestFill = NSColor.black.withAlphaComponent(0.02)

    var onKeyEvent: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyEvent?(event) == true {
            return
        }

        super.sendEvent(event)
    }
}

/// The 2.0 replacement for the screenshot editor: one live session spanning
/// every display. The desktop stays visible and live; the session only adds
/// glass areas, caption chips, and one floating HUD. Nothing is captured
/// until the user saves.
///
/// Subclasses NSResponder for its main-actor isolation, so the explicitly
/// `@MainActor` dictation controller can be driven directly — the same
/// footing the 1.x annotation view controller had.
final class LiveMarkupSession: NSResponder {
    let draft = LiveMarkupDraft()

    var onSaveRequested: (() -> Void)?
    var onCancelled: (() -> Void)?

    private let dictation = NoteDictationController()
    /// The app that was frontmost when the session started, before Markup
    /// activated. Used to break ties when a larger window (often a browser
    /// overlay) is listed in front of the window the user was actually on.
    private let originProcessID: pid_t?
    private var windows: [LiveSelectionWindow] = []
    private var views: [LiveSelectionView] = []
    private var hud: SessionHUDView?
    private var isEditingActiveNote = false
    /// True between the start of a new-area drag and mouse-up, so speech
    /// during the drag stays off the previous area.
    private var pendingNewArea = false
    private var isEnded = false
    private var becomeActiveObserver: NSObjectProtocol?
    private var didPushCursor = false

    var isActive: Bool {
        !windows.isEmpty && !isEnded
    }

    init(originProcessID: pid_t? = nil) {
        self.originProcessID = originProcessID
        super.init()
        configureDictation()
    }

    required init?(coder: NSCoder) {
        nil
    }

    // MARK: - Lifecycle

    func begin() {
        guard windows.isEmpty else { return }

        activateForSession()

        for screen in NSScreen.screens {
            let window = LiveSelectionWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = false
            window.backgroundColor = LiveSelectionWindow.hitTestFill
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.isMovable = false
            window.animationBehavior = .none
            window.onKeyEvent = { [weak self] event in
                self?.handleKeyEvent(event) ?? false
            }

            let view = LiveSelectionView(session: self)
            window.contentView = view
            window.initialFirstResponder = view
            window.setFrame(screen.frame, display: true)

            windows.append(window)
            views.append(view)
        }

        installHUD()
        startActivationObserver()
        presentWindows()

        // Activation is cooperative and often finishes on a later turn;
        // makeKey() is a no-op until Markup is actually active.
        DispatchQueue.main.async { [weak self] in
            self?.presentWindows()
        }

        dictation.startListening()
        refreshAll()
    }

    func refocus() {
        activateForSession()
        presentWindows()
    }

    /// Commits in-flight dictation, stops the mic, and hides every session
    /// window so save-time captures and prompt panels see a clean screen.
    func suspendForSave() {
        commitAllVolatile()
        dictation.teardown()
        popCrosshairIfNeeded()
        for window in windows {
            window.orderOut(nil)
        }
    }

    func resumeAfterFailedSave() {
        activateForSession()
        presentWindows()
        dictation.startListening()
        refreshAll()
    }

    func end() {
        guard !isEnded else { return }
        isEnded = true
        pendingNewArea = false
        stopActivationObserver()
        popCrosshairIfNeeded()
        dictation.teardown()
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows = []
        views = []
        hud = nil
    }

    // MARK: - View callbacks

    /// Called as soon as a drag is a real new-area gesture. Speech from this
    /// moment on belongs to the area that will be created on mouse-up.
    func startNewAreaDrag() {
        guard !pendingNewArea, draft.canAddArea, draft.activeArea != nil else { return }

        commitVolatileIntoActiveArea()
        pendingNewArea = true
        dictation.beginNewTarget()
        refreshTexts()
        updateHUD()
    }

    /// Drag was abandoned (too small, or the session cannot take another
    /// area). Speech collected for the would-be area goes back to the
    /// previous target.
    func abortNewAreaDrag() {
        guard pendingNewArea else { return }
        pendingNewArea = false

        guard let area = draft.activeArea else { return }
        area.note = Self.joinNotes(area.note, dictation.committedText, dictation.volatileText)
        area.volatileNote = ""
        dictation.beginNewTarget(adopting: area.note)
        refreshTexts()
        updateHUD()
    }

    func commitSelection(
        localRect: NSRect,
        in view: LiveSelectionView,
        originPoint: NSPoint,
        releasePoint: NSPoint
    ) {
        guard draft.canAddArea else {
            NSSound.beep()
            abortNewAreaDrag()
            return
        }

        let globalRect = view.globalCGRect(forLocal: localRect)
        guard globalRect.width >= 4, globalRect.height >= 4 else {
            abortNewAreaDrag()
            return
        }

        let probe = view.globalCGPoint(forLocal: originPoint)
        let owner = AreaWindowResolver.owningWindow(
            under: globalRect,
            probe: probe,
            preferringProcessID: originProcessID
        ).map(AreaWindowResolver.owner(for:))

        let incomingNote = dictation.committedText
        let incomingVolatile = dictation.volatileText
        let alreadyRetargeted = pendingNewArea

        if !alreadyRetargeted {
            commitVolatileIntoActiveArea()
        }

        guard let area = draft.addArea(globalRect: globalRect, owner: owner) else {
            abortNewAreaDrag()
            return
        }

        pendingNewArea = false
        area.note = incomingNote
        area.volatileNote = incomingVolatile
        isEditingActiveNote = false

        refreshAll()
        view.runWave(areaID: area.id, releasePoint: releasePoint)
    }

    func activateArea(id: UUID) {
        guard draft.activeAreaID != id, draft.areas.contains(where: { $0.id == id }) else { return }

        abortNewAreaDrag()
        commitVolatileIntoActiveArea()
        draft.activate(id)
        dictation.beginNewTarget(adopting: draft.activeArea?.note ?? "")
        refreshAll()
    }

    func removeArea(id: UUID) {
        abortNewAreaDrag()
        let wasActive = draft.activeAreaID == id
        draft.removeArea(id: id)

        if wasActive {
            dictation.beginNewTarget(adopting: draft.activeArea?.note ?? "")
            isEditingActiveNote = false
        }

        refreshAll()
    }

    func noteEdited(id: UUID, text: String) {
        guard let area = draft.areas.first(where: { $0.id == id }) else { return }
        area.note = text
        area.volatileNote = ""
        if area.id == draft.activeAreaID {
            dictation.noteWasEdited(text)
        }
        updateHUD()
    }

    func noteEditingChanged(id: UUID, isEditing: Bool) {
        if isEditing {
            activateArea(id: id)
        }
        if id == draft.activeAreaID {
            isEditingActiveNote = isEditing
        }
        if !isEditing {
            refreshTexts()
        }
    }

    func toggleListening() {
        switch dictation.state {
        case .unavailable:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        default:
            dictation.toggleMuted()
        }
    }

    // MARK: - Keyboard

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // A note field is being edited; let the field editor own the keys.
        if event.window?.firstResponder is NSTextView {
            return false
        }

        switch event.keyCode {
        case 53: // Escape: mute first, cancel second.
            if dictation.isListening || dictation.state == .preparing {
                dictation.mute()
                return true
            }
            cancel()
            return true
        case 36, 76: // Return / Enter
            requestSave()
            return true
        case 51 where event.modifierFlags.contains(.command): // Cmd+Delete
            if let active = draft.activeAreaID {
                removeArea(id: active)
                return true
            }
            return false
        default:
            return false
        }
    }

    func requestSave() {
        abortNewAreaDrag()
        commitVolatileIntoActiveArea()

        guard draft.isComplete else {
            NSSound.beep()
            // Retarget dictation at the first area still missing a note so
            // the user can just start talking.
            if let missing = draft.firstAreaMissingNote {
                activateArea(id: missing.id)
            } else {
                refreshAll()
            }
            return
        }

        onSaveRequested?()
    }

    func cancel() {
        end()
        onCancelled?()
    }

    // MARK: - Dictation

    private func configureDictation() {
        dictation.onStateChanged = { [weak self] _ in
            self?.updateHUD()
        }
        dictation.onSpeechDetectedChanged = { [weak self] detected in
            self?.hud?.listeningChip.speechDetected = detected
        }
        dictation.onTranscriptChanged = { [weak self] committed, volatile in
            guard let self, !self.isEditingActiveNote else { return }
            // During a new-area drag the controller already holds only this
            // target's speech; do not write it onto the previous area.
            guard !self.pendingNewArea, let area = self.draft.activeArea else { return }
            area.note = committed
            area.volatileNote = volatile
            self.refreshTexts()
            self.updateHUD()
        }
    }

    private static func joinNotes(_ parts: String...) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func commitVolatileIntoActiveArea() {
        guard let area = draft.activeArea else { return }
        area.note = area.combinedNote
        area.volatileNote = ""
    }

    private func commitAllVolatile() {
        abortNewAreaDrag()
        for area in draft.areas {
            area.note = area.combinedNote
            area.volatileNote = ""
        }
    }

    // MARK: - Rendering

    private func refreshAll() {
        for view in views {
            view.reload(areas: entries(for: view), activeID: draft.activeAreaID)
        }
        updateHUD()
    }

    private func refreshTexts() {
        for view in views {
            view.refreshChipTexts(areas: entries(for: view), activeID: draft.activeAreaID)
        }
    }

    private func entries(for view: LiveSelectionView) -> [(area: MarkupArea, index: Int)] {
        guard let window = view.window else { return [] }
        return draft.areas.enumerated().compactMap { offset, area in
            let cocoa = ScreenGeometry.cocoaRect(fromCG: area.globalRect)
            let center = NSPoint(x: cocoa.midX, y: cocoa.midY)
            guard window.frame.contains(center) else { return nil }
            return (area: area, index: offset + 1)
        }
    }

    private func installHUD() {
        guard hud == nil else { return }

        let mouse = NSEvent.mouseLocation
        let hostIndex = windows.firstIndex { $0.frame.contains(mouse) } ?? 0
        guard views.indices.contains(hostIndex) else { return }

        let hud = SessionHUDView()
        hud.onToggleListening = { [weak self] in
            self?.toggleListening()
        }
        hud.onSave = { [weak self] in
            self?.requestSave()
        }
        hud.onCancel = { [weak self] in
            self?.cancel()
        }
        views[hostIndex].addSubview(hud)
        self.hud = hud
        updateHUD()
    }

    private func updateHUD() {
        guard let hud else { return }

        hud.listeningChip.mode = {
            switch dictation.state {
            case .idle: return .muted
            case .preparing: return .preparing
            case .listening: return .listening
            case .muted: return .muted
            case .unavailable: return .unavailable
            }
        }()
        hud.update(
            areaCount: draft.areas.count,
            canSave: draft.isComplete,
            isListening: dictation.isListening
        )

        guard let host = hud.superview else { return }
        let size = hud.fittingSize
        let width = max(size.width, 360)
        let height = max(size.height, 40)
        hud.frame = NSRect(
            x: host.bounds.midX - width / 2,
            y: host.bounds.maxY - height - 24,
            width: width,
            height: height
        )
    }

    private func keyWindowUnderMouse() -> LiveSelectionWindow? {
        let mouse = NSEvent.mouseLocation
        return windows.first { $0.frame.contains(mouse) } ?? windows.first
    }

    private func activateForSession() {
        NSApp.activate(ignoringOtherApps: true)
        _ = NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }

    private func presentWindows() {
        guard !isEnded else { return }

        for window in windows {
            window.orderFrontRegardless()
        }

        // Don't steal key (and the chip field editor) if a session panel
        // already has it — didBecomeActive retries this path.
        if windows.contains(where: { $0.isKeyWindow }) {
            pushCrosshairIfNeeded()
            return
        }

        guard let window = keyWindowUnderMouse() else { return }
        window.makeKeyAndOrderFront(nil)
        if let view = window.contentView as? LiveSelectionView {
            window.makeFirstResponder(view)
            window.invalidateCursorRects(for: view)
        }
        pushCrosshairIfNeeded()
    }

    private func startActivationObserver() {
        guard becomeActiveObserver == nil else { return }
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.presentWindows()
        }
    }

    private func stopActivationObserver() {
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
            self.becomeActiveObserver = nil
        }
    }

    private func pushCrosshairIfNeeded() {
        guard !didPushCursor else { return }
        NSCursor.crosshair.push()
        didPushCursor = true
    }

    private func popCrosshairIfNeeded() {
        guard didPushCursor else { return }
        NSCursor.pop()
        didPushCursor = false
    }
}
