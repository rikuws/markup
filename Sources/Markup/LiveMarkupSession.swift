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
    private struct PendingBatchSegment {
        var areaID: UUID
        var slice: BatchTranscriptionSlice
    }

    let draft = LiveMarkupDraft()

    var onSaveRequested: (() -> Void)?
    var onCancelled: (() -> Void)?

    private let dictation: NoteDictationController
    /// The app that was frontmost when the session started, before Markup
    /// activated. Used to break ties when a larger window (often a browser
    /// overlay) is listed in front of the window the user was actually on.
    private let originProcessID: pid_t?
    private var windows: [LiveSelectionWindow] = []
    private var views: [LiveSelectionView] = []
    private var hud: SessionHUDView?
    private var editingAreaID: UUID?
    /// True between the start of a new-area drag and mouse-up, so speech
    /// during the drag stays off the previous area.
    private var pendingNewArea = false
    private var batchChunkHasSpeech = false
    private var batchSpeakingAreaID: UUID?
    private var batchPendingCounts: [UUID: Int] = [:]
    private var deferredBatchText: [UUID: [String]] = [:]
    /// Completed speech heard before an area exists. These immutable slices
    /// are bound to the first successfully created area at mouse-up.
    private var unassignedBatchSlices: [BatchTranscriptionSlice] = []
    private var batchQueue: [PendingBatchSegment] = []
    private var batchWorker: Task<Void, Never>?
    private var batchPauseTask: Task<Void, Never>?
    private var isEnded = false
    private var isSaving = false
    private var becomeActiveObserver: NSObjectProtocol?
    private var didPushCursor = false

    var isActive: Bool {
        !windows.isEmpty && !isEnded
    }

    init(originProcessID: pid_t? = nil, dictationEngine: TranscriptionEngineKind = .appleSpeech) {
        self.originProcessID = originProcessID
        self.dictation = NoteDictationController(engineKind: dictationEngine)
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
        isSaving = false
        setSessionInteractionEnabled(true)
        activateForSession()
        presentWindows()
        dictation.startListening()
        refreshAll()
    }

    func end() {
        guard !isEnded else { return }
        isEnded = true
        pendingNewArea = false
        batchWorker?.cancel()
        batchPauseTask?.cancel()
        batchWorker = nil
        batchPauseTask = nil
        batchQueue.removeAll()
        batchPendingCounts.removeAll()
        deferredBatchText.removeAll()
        unassignedBatchSlices.removeAll()
        batchSpeakingAreaID = nil
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
        guard !pendingNewArea, draft.canAddArea else { return }

        pendingNewArea = true
        guard let previous = draft.activeArea else {
            refreshTexts()
            updateHUD()
            return
        }

        if dictation.usesBatchTranscription {
            batchSpeakingAreaID = nil
            enqueueCurrentBatchAudio(for: previous.id, reason: "new-area drag")
        } else {
            commitVolatileIntoActiveArea()
        }
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

        guard let area = draft.activeArea else {
            // There is nowhere safe to route an utterance from an abandoned
            // first drag. Drop it now so a later area does not inherit that
            // speech or an arbitrarily long tail of silence.
            if dictation.usesBatchTranscription {
                batchSpeakingAreaID = nil
                discardCurrentBatchAudio(reason: "abandoned drag without area")
                batchChunkHasSpeech = false
            }
            refreshTexts()
            updateHUD()
            return
        }
        if dictation.usesBatchTranscription {
            dictation.resumeTarget(adopting: area.note)
            if batchChunkHasSpeech {
                if dictation.speechDetected {
                    batchSpeakingAreaID = area.id
                } else {
                    enqueueCurrentBatchAudio(for: area.id, reason: "abandoned drag")
                }
            }
        } else {
            area.note = Self.joinNotes(area.note, dictation.committedText, dictation.volatileText)
            area.volatileNote = ""
            dictation.beginNewTarget(adopting: area.note)
        }
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
        editingAreaID = nil

        if dictation.usesBatchTranscription {
            batchSpeakingAreaID = nil
            enqueueUnassignedBatchAudio(for: area.id)
            enqueueCurrentBatchAudio(for: area.id, reason: "area mouse-up")
            dictation.beginNewTarget(adopting: area.note)
            if dictation.state == .listening, dictation.speechDetected {
                batchSpeakingAreaID = area.id
                batchChunkHasSpeech = true
            }
        }

        refreshAll()
        view.runWave(areaID: area.id, releasePoint: releasePoint)
    }

    func activateArea(id: UUID) {
        guard draft.activeAreaID != id, draft.areas.contains(where: { $0.id == id }) else { return }

        abortNewAreaDrag()
        if dictation.usesBatchTranscription {
            if let previousID = draft.activeAreaID {
                batchSpeakingAreaID = nil
                enqueueCurrentBatchAudio(for: previousID, reason: "area retarget")
            }
            draft.activate(id)
            dictation.beginNewTarget(adopting: draft.activeArea?.note ?? "")
            if dictation.state == .listening, dictation.speechDetected {
                batchSpeakingAreaID = id
                batchChunkHasSpeech = true
            }
            refreshAll()
            return
        }

        Task { @MainActor in
            await self.dictation.finalizeCurrentUtterance()
            self.commitVolatileIntoActiveArea()
            self.draft.activate(id)
            self.dictation.beginNewTarget(adopting: self.draft.activeArea?.note ?? "")
            self.refreshAll()
        }
    }

    func removeArea(id: UUID) {
        abortNewAreaDrag()
        let wasActive = draft.activeAreaID == id
        if wasActive, dictation.usesBatchTranscription {
            discardCurrentBatchAudio(reason: "active area deleted")
        }
        draft.removeArea(id: id)
        batchQueue.removeAll { $0.areaID == id }
        batchPendingCounts[id] = nil
        deferredBatchText[id] = nil
        if batchSpeakingAreaID == id {
            batchSpeakingAreaID = nil
        }
        if editingAreaID == id {
            editingAreaID = nil
        }

        if wasActive {
            dictation.beginNewTarget(adopting: draft.activeArea?.note ?? "")
            if dictation.usesBatchTranscription,
               dictation.state == .listening,
               dictation.speechDetected,
               let activeID = draft.activeAreaID {
                batchSpeakingAreaID = activeID
                batchChunkHasSpeech = true
            }
            editingAreaID = nil
        }

        refreshAll()
    }

    func noteEdited(id: UUID, text: String) {
        guard let area = draft.areas.first(where: { $0.id == id }) else { return }
        dictation.learnFromEdit(previous: area.note, edited: text)
        area.note = text
        area.volatileNote = ""
        if area.id == draft.activeAreaID {
            dictation.noteWasEdited(text)
        }
        refreshRecognitionContext()
        updateHUD()
    }

    func noteEditingChanged(id: UUID, isEditing: Bool) {
        if isEditing {
            editingAreaID = id
            activateArea(id: id)
        } else if editingAreaID == id {
            editingAreaID = nil
        }
        if !isEditing {
            applyDeferredBatchText(to: id)
            refreshTexts()
        }
    }

    func toggleListening() {
        switch dictation.state {
        case .unavailable:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .muted, .idle:
            dictation.startListening()
        case .listening, .preparing:
            muteListening()
        case .transcribing:
            break
        }
    }

    // MARK: - Keyboard

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        if isSaving {
            return true
        }

        // A note field is being edited; let the field editor own the keys.
        if event.window?.firstResponder is NSTextView {
            return false
        }

        switch event.keyCode {
        case 53: // Escape: mute first, cancel second.
            if dictation.state == .transcribing {
                return true
            }
            if dictation.isListening || dictation.state == .preparing {
                muteListening()
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
        guard !isSaving else { return }
        isSaving = true
        setSessionInteractionEnabled(false)
        for view in views {
            view.endNoteEditing()
        }
        abortNewAreaDrag()
        let pauseAlreadyInFlight = batchPauseTask

        Task { @MainActor in
            if self.dictation.usesBatchTranscription {
                if let pauseAlreadyInFlight {
                    // Preserve a Save click/Return pressed while Mute is still
                    // converting audio instead of silently dropping it.
                    await pauseAlreadyInFlight.value
                } else {
                    self.dictation.pauseBatchCapture()
                    self.batchSpeakingAreaID = nil
                    if let activeID = self.draft.activeAreaID {
                        self.enqueueCurrentBatchAudio(for: activeID, reason: "save")
                    } else {
                        self.holdCurrentBatchAudio(reason: "save without area")
                    }
                    self.batchChunkHasSpeech = false
                }

                guard !self.isEnded else { return }
                await self.waitForBatchQueue()
                guard !self.isEnded else { return }
                if pauseAlreadyInFlight == nil {
                    self.dictation.completeBatchPause()
                }
            } else {
                await self.dictation.finalizeCurrentUtterance()
                guard !self.isEnded else { return }
                self.commitVolatileIntoActiveArea()
            }

            // Ending editing before the await is normally sufficient because
            // mouse/key input is frozen, but repeat it at the mutation boundary
            // so a field editor can never overwrite a late ASR merge.
            for view in self.views {
                view.endNoteEditing()
            }
            self.applyAllDeferredBatchText()

            guard self.draft.isComplete else {
                self.isSaving = false
                self.setSessionInteractionEnabled(true)
                NSSound.beep()
                if self.dictation.usesBatchTranscription {
                    self.dictation.startListening()
                }
                // Retarget dictation at the first area still missing a note so
                // the user can just start talking.
                if let missing = self.draft.firstAreaMissingNote {
                    self.activateArea(id: missing.id)
                } else {
                    self.refreshAll()
                }
                return
            }

            self.onSaveRequested?()
        }
    }

    func cancel() {
        end()
        onCancelled?()
    }

    // MARK: - Dictation

    private func configureDictation() {
        dictation.onStateChanged = { [weak self] _ in
            self?.publishListenFeedback()
            self?.updateHUD()
        }
        dictation.onSpeechDetectedChanged = { [weak self] detected in
            guard let self else { return }
            self.hud?.listeningChip.speechDetected = detected
            if self.dictation.usesBatchTranscription {
                self.handleBatchSpeechDetected(detected)
            }
            self.publishListenFeedback()
        }
        dictation.onAudioLevelChanged = { [weak self] level in
            guard let self else { return }
            self.hud?.listeningChip.pushAudioLevel(level)
            for view in self.views {
                view.pushAudioLevel(level)
            }
        }
        dictation.onTranscriptChanged = { [weak self] committed, volatile in
            guard let self else { return }
            self.publishListenFeedback()
            if let editingAreaID = self.editingAreaID,
               editingAreaID == self.draft.activeAreaID {
                return
            }
            // During a new-area drag the controller already holds only this
            // target's speech; do not write it onto the previous area.
            guard !self.pendingNewArea, let area = self.draft.activeArea else { return }
            area.note = committed
            area.volatileNote = volatile
            self.refreshTexts()
            self.updateHUD()
            if volatile.isEmpty {
                self.refreshRecognitionContext()
            }
        }
    }

    private func publishListenFeedback() {
        let mode: LiveListenCapsule.Mode = {
            switch dictation.state {
            case .preparing: return .preparing
            case .listening: return .listening
            case .transcribing: return .transcribing
            default: return .off
            }
        }()
        for view in views {
            view.updateListenFeedback(
                committed: dictation.committedText,
                volatile: dictation.volatileText,
                mode: mode,
                speechDetected: dictation.speechDetected
            )
        }
    }

    private var annotationDictationPhases: [UUID: AnnotationDictationPhase] {
        var phases: [UUID: AnnotationDictationPhase] = [:]
        let existingIDs = Set(draft.areas.map(\.id))
        for (id, count) in batchPendingCounts where count > 0 && existingIDs.contains(id) {
            phases[id] = .transcribing
        }
        if let batchSpeakingAreaID, existingIDs.contains(batchSpeakingAreaID) {
            phases[batchSpeakingAreaID] = .listening
        }
        return phases
    }

    private func handleBatchSpeechDetected(_ detected: Bool) {
        guard dictation.state == .listening else {
            if !detected, batchSpeakingAreaID != nil {
                batchSpeakingAreaID = nil
                refreshTexts()
            }
            return
        }

        if detected {
            batchChunkHasSpeech = true
            if !pendingNewArea,
               let activeID = draft.activeAreaID,
               editingAreaID != activeID {
                batchSpeakingAreaID = activeID
                refreshTexts()
            }
            return
        }

        let targetID = batchSpeakingAreaID ?? (pendingNewArea ? nil : draft.activeAreaID)
        batchSpeakingAreaID = nil
        if let targetID, batchChunkHasSpeech, !pendingNewArea {
            enqueueCurrentBatchAudio(for: targetID, reason: "speech pause")
        } else if !pendingNewArea, draft.activeAreaID == nil, batchChunkHasSpeech {
            // Rotate ownerless speech into a bounded holding buffer. The first
            // successful mouse-up gives it a stable target without retaining
            // an arbitrarily long tail of silence in the live accumulator.
            holdCurrentBatchAudio(reason: "speech pause without area")
            batchChunkHasSpeech = false
        } else {
            refreshTexts()
        }
    }

    private func enqueueCurrentBatchAudio(for areaID: UUID, reason: String) {
        guard dictation.usesBatchTranscription else { return }
        guard let slice = dictation.captureCurrentBatchAudio(reason: reason) else { return }
        batchChunkHasSpeech = dictation.state == .listening && dictation.speechDetected
        enqueueBatchAudio(slice, for: areaID)
    }

    private func enqueueBatchAudio(_ slice: BatchTranscriptionSlice, for areaID: UUID) {
        guard slice.containsLikelySpeech else { return }
        batchPendingCounts[areaID, default: 0] += 1
        batchQueue.append(PendingBatchSegment(areaID: areaID, slice: slice))
        refreshTexts()
        startBatchWorkerIfNeeded()
    }

    private func enqueueUnassignedBatchAudio(for areaID: UUID) {
        let slices = unassignedBatchSlices
        unassignedBatchSlices.removeAll(keepingCapacity: true)
        for slice in slices {
            enqueueBatchAudio(slice, for: areaID)
        }
    }

    private func holdCurrentBatchAudio(reason: String) {
        guard dictation.usesBatchTranscription else { return }
        guard let slice = dictation.captureCurrentBatchAudio(reason: reason) else { return }
        batchChunkHasSpeech = dictation.state == .listening && dictation.speechDetected
        guard slice.containsLikelySpeech else { return }

        unassignedBatchSlices.append(slice)
        // Keep natural multi-sentence dictation, but cap ownerless history so
        // an unattended session cannot grow without bound. A single long
        // utterance is retained whole rather than truncated mid-word.
        while unassignedBatchSlices.count > 1,
              unassignedBatchSlices.count > 8
                || unassignedBatchSlices.reduce(0, { $0 + $1.audio.duration }) > 30 {
            unassignedBatchSlices.removeFirst()
        }
    }

    private func discardCurrentBatchAudio(reason: String) {
        guard dictation.usesBatchTranscription else { return }
        _ = dictation.captureCurrentBatchAudio(reason: reason)
        batchChunkHasSpeech = dictation.state == .listening && dictation.speechDetected
    }

    private func startBatchWorkerIfNeeded() {
        guard batchWorker == nil, !batchQueue.isEmpty else { return }
        batchWorker = Task { @MainActor [weak self] in
            await self?.runBatchWorker()
        }
    }

    private func runBatchWorker() async {
        while !Task.isCancelled, !batchQueue.isEmpty {
            let segment = batchQueue.removeFirst()
            let spoken = await dictation.transcribeBatchAudio(segment.slice)
            guard !Task.isCancelled, !isEnded else { break }
            applyBatchResult(spoken, to: segment.areaID)
        }
        batchWorker = nil
    }

    private func applyBatchResult(_ spoken: String, to areaID: UUID) {
        if let count = batchPendingCounts[areaID] {
            if count > 1 {
                batchPendingCounts[areaID] = count - 1
            } else {
                batchPendingCounts[areaID] = nil
            }
        }

        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if editingAreaID == areaID {
                deferredBatchText[areaID, default: []].append(trimmed)
            } else if let area = draft.areas.first(where: { $0.id == areaID }) {
                area.note = Self.joinNotes(area.note, trimmed)
                if draft.activeAreaID == areaID, !pendingNewArea {
                    dictation.syncBatchNote(area.note)
                }
                refreshRecognitionContext()
            }
        }

        refreshTexts()
        updateHUD()
    }

    private func applyDeferredBatchText(to areaID: UUID) {
        guard let parts = deferredBatchText.removeValue(forKey: areaID),
              !parts.isEmpty,
              let area = draft.areas.first(where: { $0.id == areaID }) else { return }
        area.note = Self.joinNotes(area.note, parts.joined(separator: " "))
        if draft.activeAreaID == areaID, !pendingNewArea {
            dictation.syncBatchNote(area.note)
        }
        refreshRecognitionContext()
    }

    private func applyAllDeferredBatchText() {
        for areaID in Array(deferredBatchText.keys) {
            applyDeferredBatchText(to: areaID)
        }
    }

    private func waitForBatchQueue() async {
        while let worker = batchWorker {
            await worker.value
        }
    }

    private func muteListening() {
        guard dictation.usesBatchTranscription else {
            dictation.mute()
            return
        }
        guard batchPauseTask == nil else { return }

        dictation.pauseBatchCapture()
        batchSpeakingAreaID = nil
        if let activeID = draft.activeAreaID {
            enqueueCurrentBatchAudio(for: activeID, reason: "mute")
        } else {
            holdCurrentBatchAudio(reason: "mute without area")
        }
        batchChunkHasSpeech = false
        refreshTexts()

        batchPauseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.waitForBatchQueue()
            guard !Task.isCancelled, !self.isEnded else { return }
            self.dictation.completeBatchPause()
            self.batchPauseTask = nil
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
        refreshRecognitionContext()
        let phases = annotationDictationPhases
        for view in views {
            view.reload(
                areas: entries(for: view),
                activeID: draft.activeAreaID,
                dictationPhases: phases
            )
        }
        updateHUD()
        publishListenFeedback()
    }

    private func refreshRecognitionContext() {
        var terms = TechnicalTranscriptResolver.sessionTerms(from: draft.areas)
        if let pid = originProcessID,
           let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
            terms.insert(name, at: 0)
        }
        dictation.updateSessionTerms(terms)
    }

    private func refreshTexts() {
        let phases = annotationDictationPhases
        for view in views {
            view.refreshChipTexts(
                areas: entries(for: view),
                activeID: draft.activeAreaID,
                dictationPhases: phases
            )
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
        publishListenFeedback()
    }

    private func updateHUD() {
        guard let hud else { return }

        hud.listeningChip.mode = {
            switch dictation.state {
            case .idle: return .muted
            case .preparing: return .preparing
            case .listening: return .listening
            case .transcribing: return .transcribing
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

    private func setSessionInteractionEnabled(_ isEnabled: Bool) {
        for view in views {
            view.setSessionInteractionEnabled(isEnabled)
        }
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
