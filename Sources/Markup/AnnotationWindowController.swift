import AppKit

final class AnnotationWindowController: NSWindowController {
    private let viewController: AnnotationViewController

    init(
        draft: FeedbackDraft,
        selectedShotID: UUID?,
        showsAppendBanner: Bool,
        onSave: @escaping () -> Void,
        onChangeRoute: @escaping (AppRoute?) -> AppRoute?,
        onCancel: @escaping () -> Void,
        onRecord: @escaping (UUID?) -> Void,
        onAddShot: @escaping () -> Void
    ) {
        viewController = AnnotationViewController(
            draft: draft,
            selectedShotID: selectedShotID,
            showsAppendBanner: showsAppendBanner,
            onSave: onSave,
            onChangeRoute: onChangeRoute,
            onCancel: onCancel,
            onRecord: onRecord,
            onAddShot: onAddShot
        )

        let screenFrame = NSScreen.allScreenFrame
        let window = AnnotationOverlayWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = viewController
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.onEscape = { [weak viewController] in
            viewController?.cancelAnnotation()
        }

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        NSLog("Markup: showing annotation editor")
        NSApp.activate(ignoringOtherApps: true)
        window?.setFrame(NSScreen.allScreenFrame, display: true)
        window?.orderFrontRegardless()
        window?.makeKey()
        window?.makeFirstResponder(viewController.initialFirstResponder)
    }
}

final class AnnotationOverlayWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}" {
            onEscape?()
            return
        }

        super.sendEvent(event)
    }
}

final class AnnotationViewController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate {
    private let draft: FeedbackDraft
    private var route: AppRoute?
    private let showsAppendBanner: Bool
    private let onSave: () -> Void
    private let onChangeRoute: (AppRoute?) -> AppRoute?
    private let onCancel: () -> Void
    private let onRecord: (UUID?) -> Void
    private let onAddShot: () -> Void

    private let canvas: AnnotationCanvasView
    private let projectRouteView = ProjectRouteView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let windowTitleLabel = NSTextField(labelWithString: "")
    private let helperLabel = NSTextField(labelWithString: "")
    private let appendBadge = BadgeLabel(text: "Adding to previous feedback")
    private let shotStrip = NSStackView()
    private let shotCountLabel = NSTextField(labelWithString: "")
    private let selectedShotLabel = NSTextField(labelWithString: "")
    private let labelField = NSTextField()
    private let noteTextView = PlaceholderTextView(placeholder: "Describe what should change, what looks wrong, or what the agent should fix.")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let addShotButton = NSButton(title: "Add Shot", target: nil, action: nil)
    private let deleteShotButton = NSButton(title: "Delete Shot", target: nil, action: nil)
    private let recordButton = NSButton(title: "Record 10s", target: nil, action: nil)
    private let recordingBadge = NSTextField(labelWithString: "")
    private var selectedShotID: UUID
    private var visibleAppendBadgeConstraints: [NSLayoutConstraint] = []

    var initialFirstResponder: NSResponder {
        canvas
    }

    init(
        draft: FeedbackDraft,
        selectedShotID: UUID?,
        showsAppendBanner: Bool,
        onSave: @escaping () -> Void,
        onChangeRoute: @escaping (AppRoute?) -> AppRoute?,
        onCancel: @escaping () -> Void,
        onRecord: @escaping (UUID?) -> Void,
        onAddShot: @escaping () -> Void
    ) {
        self.draft = draft
        self.route = draft.route
        self.showsAppendBanner = showsAppendBanner
        self.onSave = onSave
        self.onChangeRoute = onChangeRoute
        self.onCancel = onCancel
        self.onRecord = onRecord
        self.onAddShot = onAddShot

        let initialShot = selectedShotID
            .flatMap { id in draft.shots.first(where: { $0.id == id }) }
            ?? draft.shots.last
            ?? draft.shots[0]
        self.selectedShotID = initialShot.id
        canvas = AnnotationCanvasView(image: initialShot.captured.image)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        wireEvents()
        updateSelectedShotUI()
        updateSaveState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(canvas)
        canvas.setCaptureRegion(selectedShot.region)
    }

    func textDidChange(_ notification: Notification) {
        draft.note = noteTextView.string
        updateSaveState()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === labelField else { return }
        selectedShot.label = labelField.stringValue
        rebuildShotStrip()
    }

    private var selectedShot: FeedbackDraftShot {
        draft.shots.first(where: { $0.id == selectedShotID }) ?? draft.shots[0]
    }

    private var selectedShotIndex: Int {
        draft.shots.firstIndex(where: { $0.id == selectedShotID }) ?? 0
    }

    private func wireEvents() {
        canvas.onSelectionChanged = { [weak self] in
            guard let self else { return }
            self.selectedShot.region = self.canvas.captureRegion
            self.rebuildShotStrip()
            self.updateSaveState()
        }
        canvas.onSelectionCompleted = { [weak self] in
            guard let self else { return }
            if self.canvas.captureRegion != nil {
                self.view.window?.makeFirstResponder(self.noteTextView)
            }
        }
        noteTextView.delegate = self
        noteTextView.string = draft.note
        labelField.delegate = self
    }

    private func buildLayout() {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = 12
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        headerLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        headerLabel.textColor = .white
        headerLabel.lineBreakMode = .byTruncatingMiddle

        windowTitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        windowTitleLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        windowTitleLabel.lineBreakMode = .byTruncatingMiddle

        helperLabel.font = .systemFont(ofSize: 12)
        helperLabel.textColor = NSColor.white.withAlphaComponent(0.68)
        helperLabel.lineBreakMode = .byTruncatingTail

        let titleStack = NSStackView(views: [headerLabel, windowTitleLabel, helperLabel])
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3
        titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        recordingBadge.textColor = .systemGreen
        recordingBadge.font = .systemFont(ofSize: 12, weight: .semibold)
        recordingBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let shortcutHints = NSStackView(views: [
            ShortcutHintView(key: "Esc", label: "Cancel"),
            ShortcutHintView(key: "Return", label: "Save")
        ])
        shortcutHints.translatesAutoresizingMaskIntoConstraints = false
        shortcutHints.orientation = .horizontal
        shortcutHints.spacing = 12
        shortcutHints.alignment = .centerY
        shortcutHints.setContentCompressionResistancePriority(.required, for: .horizontal)

        let rightControls = NSStackView(views: [shortcutHints, recordingBadge])
        rightControls.translatesAutoresizingMaskIntoConstraints = false
        rightControls.orientation = .horizontal
        rightControls.spacing = 14
        rightControls.alignment = .centerY
        rightControls.setContentCompressionResistancePriority(.required, for: .horizontal)

        appendBadge.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(titleStack)
        headerRow.addSubview(appendBadge)
        headerRow.addSubview(rightControls)

        visibleAppendBadgeConstraints = [
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: appendBadge.leadingAnchor, constant: -14),
            appendBadge.trailingAnchor.constraint(lessThanOrEqualTo: rightControls.leadingAnchor, constant: -14)
        ]

        projectRouteView.translatesAutoresizingMaskIntoConstraints = false
        projectRouteView.configure(captured: draft.primaryCapture, route: route)
        projectRouteView.onChange = { [weak self] in
            self?.changeRouteSelected()
        }

        shotStrip.orientation = .horizontal
        shotStrip.alignment = .centerY
        shotStrip.spacing = 10
        shotStrip.translatesAutoresizingMaskIntoConstraints = false

        shotCountLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        shotCountLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        shotCountLabel.alignment = .right

        let shotStripRow = NSStackView(views: [shotStrip, NSView(), shotCountLabel])
        shotStripRow.orientation = .horizontal
        shotStripRow.alignment = .centerY
        shotStripRow.spacing = 12

        selectedShotLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        selectedShotLabel.textColor = NSColor.white.withAlphaComponent(0.92)

        labelField.placeholderString = "Shot label (optional)"
        labelField.font = .systemFont(ofSize: 13, weight: .regular)
        labelField.lineBreakMode = .byTruncatingTail
        labelField.bezelStyle = .roundedBezel
        labelField.focusRingType = .default

        deleteShotButton.target = self
        deleteShotButton.action = #selector(deleteShotSelected)
        deleteShotButton.bezelStyle = .rounded

        let shotControls = NSStackView(views: [selectedShotLabel, labelField, deleteShotButton])
        shotControls.orientation = .horizontal
        shotControls.alignment = .centerY
        shotControls.spacing = 10

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        let noteSurface = AnnotationSurfaceView()
        noteSurface.translatesAutoresizingMaskIntoConstraints = false
        noteTextView.onFocusChanged = { [weak noteSurface] isFocused in
            noteSurface?.isActive = isFocused
        }

        let noteScroll = NSScrollView()
        noteScroll.translatesAutoresizingMaskIntoConstraints = false
        noteScroll.hasVerticalScroller = true
        noteScroll.hasHorizontalScroller = false
        noteScroll.autohidesScrollers = true
        noteScroll.borderType = .noBorder
        noteScroll.focusRingType = .none
        noteScroll.drawsBackground = false
        noteScroll.scrollerStyle = .overlay
        noteScroll.contentView.drawsBackground = false
        noteScroll.documentView = noteTextView
        noteTextView.frame = NSRect(x: 0, y: 0, width: 640, height: 150)
        noteTextView.minSize = NSSize(width: 0, height: 150)
        noteTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        noteTextView.isVerticallyResizable = true
        noteTextView.isHorizontallyResizable = false
        noteTextView.autoresizingMask = [.width]
        noteTextView.font = .systemFont(ofSize: 15, weight: .regular)
        noteTextView.textColor = .white
        noteTextView.insertionPointColor = .white
        noteTextView.focusRingType = .none
        noteTextView.drawsBackground = false
        noteTextView.backgroundColor = .clear
        noteTextView.textContainerInset = NSSize(width: 18, height: 16)
        noteTextView.textContainer?.lineFragmentPadding = 0
        noteTextView.textContainer?.lineBreakMode = .byWordWrapping
        noteTextView.updateWrappingWidth()
        noteTextView.isRichText = false
        noteTextView.allowsUndo = true
        noteSurface.installContentView(noteScroll)

        let noteLabel = NSTextField(labelWithString: "Note")
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        noteLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        recordButton.target = self
        recordButton.action = #selector(recordSelected)
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .large

        addShotButton.target = self
        addShotButton.action = #selector(addShotSelected)
        addShotButton.bezelStyle = .rounded
        addShotButton.controlSize = .large

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSelected))
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.keyEquivalent = "\u{1b}"

        saveButton.target = self
        saveButton.action = #selector(saveSelected)
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .large
        saveButton.contentTintColor = .controlAccentColor
        saveButton.keyEquivalent = "\r"

        let actions = NSStackView(views: [recordButton, addShotButton, NSView(), cancelButton, saveButton])
        actions.orientation = .horizontal
        actions.spacing = 12
        actions.alignment = .centerY
        actions.distribution = .fill

        let noteSection = NSView()
        noteSection.translatesAutoresizingMaskIntoConstraints = false
        noteSection.addSubview(noteLabel)
        noteSection.addSubview(noteSurface)

        container.addArrangedSubview(headerRow)
        container.addArrangedSubview(projectRouteView)
        container.addArrangedSubview(shotStripRow)
        container.addArrangedSubview(shotControls)
        container.addArrangedSubview(canvas)
        container.addArrangedSubview(noteSection)
        container.addArrangedSubview(actions)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            headerRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            titleStack.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor),
            titleStack.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            titleStack.topAnchor.constraint(greaterThanOrEqualTo: headerRow.topAnchor),
            titleStack.bottomAnchor.constraint(lessThanOrEqualTo: headerRow.bottomAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: rightControls.leadingAnchor, constant: -14),
            appendBadge.centerXAnchor.constraint(equalTo: headerRow.centerXAnchor),
            appendBadge.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            rightControls.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor),
            rightControls.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            rightControls.leadingAnchor.constraint(greaterThanOrEqualTo: headerRow.centerXAnchor, constant: 14),
            projectRouteView.heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
            shotStripRow.heightAnchor.constraint(equalToConstant: 76),
            labelField.heightAnchor.constraint(equalToConstant: 28),
            labelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            noteLabel.topAnchor.constraint(equalTo: noteSection.topAnchor),
            noteLabel.leadingAnchor.constraint(equalTo: noteSection.leadingAnchor, constant: 2),
            noteSurface.leadingAnchor.constraint(equalTo: noteSection.leadingAnchor),
            noteSurface.trailingAnchor.constraint(equalTo: noteSection.trailingAnchor),
            noteSurface.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 8),
            noteSurface.bottomAnchor.constraint(equalTo: noteSection.bottomAnchor),
            noteSurface.heightAnchor.constraint(equalToConstant: 156)
        ])
    }

    private func updateSelectedShotUI() {
        let shot = selectedShot
        let index = selectedShotIndex + 1
        headerLabel.stringValue = shot.captured.appName
        windowTitleLabel.stringValue = shot.captured.windowTitle
        helperLabel.stringValue = helperText(for: index)
        let showsBadge = showsAppendBanner || draft.shots.count > 1
        appendBadge.isHidden = !showsBadge
        for constraint in visibleAppendBadgeConstraints {
            constraint.isActive = showsBadge
        }
        recordingBadge.stringValue = draft.recordingURL == nil ? "" : "Recording attached"
        recordingBadge.isHidden = draft.recordingURL == nil
        shotCountLabel.stringValue = "\(draft.shots.count)/\(FeedbackDraft.maximumShots) shots"
        selectedShotLabel.stringValue = "Shot \(index)"
        labelField.stringValue = shot.label
        deleteShotButton.isEnabled = selectedShotIndex > 0
        recordButton.isEnabled = draft.recordingURL == nil
        addShotButton.isEnabled = draft.canAddShot
        canvas.configure(image: shot.captured.image, region: shot.region)
        rebuildShotStrip()
    }

    private func helperText(for index: Int) -> String {
        if draft.shots.count > 1 {
            return "Shot \(index) of \(draft.shots.count). Select the region for this view; the note applies to all shots."
        }

        return draft.recordingURL == nil
            ? "Drag one box around the issue, then write the instruction for the coding agent."
            : "Recording attached. Drag one box, add a note, then Save to write the feedback folder."
    }

    private func rebuildShotStrip() {
        for view in shotStrip.arrangedSubviews {
            shotStrip.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (offset, shot) in draft.shots.enumerated() {
            let thumbnail = ShotThumbnailView(
                shot: shot,
                index: offset + 1,
                isSelected: shot.id == selectedShotID
            )
            thumbnail.target = self
            thumbnail.action = #selector(shotThumbnailSelected(_:))
            shotStrip.addArrangedSubview(thumbnail)
            NSLayoutConstraint.activate([
                thumbnail.widthAnchor.constraint(equalToConstant: 112),
                thumbnail.heightAnchor.constraint(equalToConstant: 70)
            ])
        }
    }

    @objc private func shotThumbnailSelected(_ sender: ShotThumbnailView) {
        selectedShotID = sender.shotID
        updateSelectedShotUI()
        view.window?.makeFirstResponder(canvas)
    }

    @objc private func saveSelected() {
        guard draft.isComplete else {
            NSSound.beep()
            if draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                view.window?.makeFirstResponder(noteTextView)
            } else if let missing = draft.shots.first(where: { $0.region == nil }) {
                selectedShotID = missing.id
                updateSelectedShotUI()
                view.window?.makeFirstResponder(canvas)
            }
            return
        }

        onSave()
    }

    private func changeRouteSelected() {
        guard let updatedRoute = onChangeRoute(route) else {
            return
        }

        route = updatedRoute
        draft.route = updatedRoute
        projectRouteView.configure(captured: draft.primaryCapture, route: updatedRoute)
    }

    @objc private func cancelSelected() {
        cancelAnnotation()
    }

    func cancelAnnotation() {
        onCancel()
        view.window?.close()
    }

    @objc private func recordSelected() {
        onRecord(selectedShotID)
    }

    @objc private func addShotSelected() {
        guard draft.canAddShot else {
            NSSound.beep()
            return
        }

        onAddShot()
    }

    @objc private func deleteShotSelected() {
        let index = selectedShotIndex
        guard index > 0 else {
            NSSound.beep()
            return
        }

        draft.deleteShot(id: selectedShotID)
        let nextIndex = min(index, draft.shots.count - 1)
        selectedShotID = draft.shots[nextIndex].id
        updateSelectedShotUI()
        updateSaveState()
    }

    private func updateSaveState() {
        saveButton.isEnabled = draft.isComplete
        addShotButton.isEnabled = draft.canAddShot
        deleteShotButton.isEnabled = selectedShotIndex > 0
    }
}

final class BadgeLabel: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = text
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byClipping

        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        addSubview(label)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: size.width + 20, height: 22)
    }
}

final class ShotThumbnailView: NSControl {
    let shotID: UUID
    private let image: NSImage
    private let index: Int
    private let isSelectedShot: Bool
    private let hasRegion: Bool
    private let label: String

    init(shot: FeedbackDraftShot, index: Int, isSelected: Bool) {
        shotID = shot.id
        image = shot.captured.image
        self.index = index
        isSelectedShot = isSelected
        hasRegion = shot.region != nil
        label = shot.label.trimmingCharacters(in: .whitespacesAndNewlines)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        toolTip = label.isEmpty ? "Shot \(index)" : "Shot \(index): \(label)"
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outerRect = bounds.insetBy(dx: 1, dy: 1)
        let outer = NSBezierPath(roundedRect: outerRect, xRadius: 9, yRadius: 9)
        NSColor(calibratedWhite: 0.05, alpha: 0.96).setFill()
        outer.fill()

        let imageRect = outerRect.insetBy(dx: 5, dy: 5)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: imageRect, xRadius: 6, yRadius: 6).addClip()
        image.draw(in: aspectFillRect(for: image, inside: imageRect))
        NSColor.black.withAlphaComponent(0.12).setFill()
        imageRect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()

        drawIndexBadge(in: imageRect)

        if !label.isEmpty {
            drawLabel(in: imageRect)
        } else if !hasRegion {
            drawNeedsRegion(in: imageRect)
        }

        let strokeColor = isSelectedShot
            ? NSColor.controlAccentColor.withAlphaComponent(0.95)
            : NSColor.white.withAlphaComponent(0.22)
        strokeColor.setStroke()
        outer.lineWidth = isSelectedShot ? 2 : 1
        outer.stroke()
    }

    private func drawIndexBadge(in rect: NSRect) {
        let text = "\(index)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let badgeRect = NSRect(
            x: rect.minX + 6,
            y: rect.maxY - size.height - 12,
            width: max(22, size.width + 12),
            height: size.height + 7
        )
        let badge = NSBezierPath(roundedRect: badgeRect, xRadius: 9, yRadius: 9)
        NSColor.black.withAlphaComponent(0.72).setFill()
        badge.fill()
        (text as NSString).draw(
            in: NSRect(
                x: badgeRect.minX + (badgeRect.width - size.width) / 2,
                y: badgeRect.minY + 3,
                width: size.width,
                height: size.height
            ),
            withAttributes: attributes
        )
    }

    private func drawLabel(in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let text = label as NSString
        let labelRect = NSRect(
            x: rect.minX + 6,
            y: rect.minY + 6,
            width: rect.width - 12,
            height: 14
        )
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: labelRect.insetBy(dx: -4, dy: -2), xRadius: 6, yRadius: 6).fill()
        text.draw(in: labelRect, withAttributes: attributes)
    }

    private func drawNeedsRegion(in rect: NSRect) {
        let text = "Needs region"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let labelRect = NSRect(
            x: rect.maxX - size.width - 12,
            y: rect.minY + 6,
            width: size.width + 8,
            height: size.height + 5
        )
        NSColor.systemYellow.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 7, yRadius: 7).fill()
        (text as NSString).draw(
            in: NSRect(
                x: labelRect.minX + 4,
                y: labelRect.minY + 3,
                width: size.width,
                height: size.height
            ),
            withAttributes: attributes
        )
    }

    private func aspectFillRect(for image: NSImage, inside rect: NSRect) -> NSRect {
        guard image.size.width > 0, image.size.height > 0 else { return rect }

        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

final class ProjectRouteView: NSView {
    var onChange: (() -> Void)?

    private let effectView = NSVisualEffectView()
    private let tintView = NSView()
    private let accentView = NSView()
    private let eyebrowLabel = NSTextField(labelWithString: "SAVING TO")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let changeButton = NSButton(title: "Change", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(captured: CapturedWindow, route: AppRoute?) {
        if let route {
            let projectName = route.projectRootURL.lastPathComponent.isEmpty
                ? route.projectRoot
                : route.projectRootURL.lastPathComponent
            let destination = route.feedbackDirectoryURL.path

            titleLabel.stringValue = projectName
            detailLabel.stringValue = destination
            detailLabel.toolTip = destination
            changeButton.title = "Change"
            accentView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
        } else {
            titleLabel.stringValue = "No project selected"
            detailLabel.stringValue = captured.routeName
            detailLabel.toolTip = captured.routeName
            changeButton.title = "Set Project"
            accentView.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.95).cgColor
        }
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: 12,
            cornerHeight: 12,
            transform: nil
        )
    }

    @objc private func changeSelected() {
        onChange?()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 12
        layer?.shadowOffset = NSSize(width: 0, height: -4)

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true

        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.80).cgColor
        tintView.layer?.cornerRadius = 12
        tintView.layer?.masksToBounds = true

        accentView.translatesAutoresizingMaskIntoConstraints = false
        accentView.wantsLayer = true
        accentView.layer?.cornerRadius = 2

        eyebrowLabel.font = .systemFont(ofSize: 10, weight: .bold)
        eyebrowLabel.textColor = NSColor.white.withAlphaComponent(0.50)
        eyebrowLabel.lineBreakMode = .byTruncatingTail

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle

        detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.66)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [eyebrowLabel, titleLabel, detailLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        changeButton.target = self
        changeButton.action = #selector(changeSelected)
        changeButton.bezelStyle = .rounded
        changeButton.controlSize = .large
        changeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let content = NSStackView(views: [accentView, textStack, NSView(), changeButton])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 12
        content.distribution = .fill

        addSubview(effectView)
        addSubview(tintView, positioned: .above, relativeTo: effectView)
        addSubview(content, positioned: .above, relativeTo: tintView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),

            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            accentView.widthAnchor.constraint(equalToConstant: 4),
            accentView.heightAnchor.constraint(equalTo: content.heightAnchor, multiplier: 0.70)
        ])
    }
}

final class AnnotationSurfaceView: NSView {
    private let effectView = NSVisualEffectView()
    private let tintView = NSView()
    private let strokeView = AnnotationSurfaceStrokeView()

    var isActive = false {
        didSet {
            guard oldValue != isActive else { return }
            strokeView.isActive = isActive
            layer?.shadowOpacity = isActive ? 0.30 : 0.20
            layer?.shadowRadius = isActive ? 18 : 14
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func installContentView(_ contentView: NSView) {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView, positioned: .above, relativeTo: tintView)

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1)
        ])

        addSubview(strokeView, positioned: .above, relativeTo: contentView)
        NSLayoutConstraint.activate([
            strokeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            strokeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            strokeView.topAnchor.constraint(equalTo: topAnchor),
            strokeView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: 14,
            cornerHeight: 14,
            transform: nil
        )
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.20
        layer?.shadowRadius = 14
        layer?.shadowOffset = NSSize(width: 0, height: -5)

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 14
        effectView.layer?.masksToBounds = true

        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.82).cgColor
        tintView.layer?.cornerRadius = 14
        tintView.layer?.masksToBounds = true

        strokeView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(effectView)
        addSubview(tintView, positioned: .above, relativeTo: effectView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

final class AnnotationSurfaceStrokeView: NSView {
    var isActive = false {
        didSet {
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let outerRect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let outer = NSBezierPath(roundedRect: outerRect, xRadius: 14, yRadius: 14)
        let outerColor = isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.88)
            : NSColor.white.withAlphaComponent(0.24)
        outerColor.setStroke()
        outer.lineWidth = isActive ? 1.5 : 1
        outer.stroke()

        let innerRect = bounds.insetBy(dx: 1.75, dy: 1.75)
        let inner = NSBezierPath(roundedRect: innerRect, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(isActive ? 0.10 : 0.24).setStroke()
        inner.lineWidth = 1
        inner.stroke()
    }
}

final class PlaceholderTextView: NSTextView {
    var onFocusChanged: ((Bool) -> Void)?
    private var placeholder = ""

    init(placeholder: String) {
        super.init(frame: .zero)
        self.placeholder = placeholder
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateWrappingWidth()
        needsDisplay = true
    }

    fileprivate func updateWrappingWidth() {
        guard let textContainer else { return }

        let horizontalInset = textContainerInset.width * 2
        let wrappingWidth = max(1, bounds.width - horizontalInset)
        textContainer.widthTracksTextView = false
        textContainer.containerSize = NSSize(
            width: wrappingWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.white.withAlphaComponent(0.45),
            .paragraphStyle: paragraph
        ]
        let rect = NSRect(
            x: textContainerInset.width,
            y: textContainerInset.height,
            width: max(0, bounds.width - textContainerInset.width * 2),
            height: max(0, bounds.height - textContainerInset.height * 2)
        )
        (placeholder as NSString).draw(in: rect, withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            onFocusChanged?(true)
            needsDisplay = true
        }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            onFocusChanged?(false)
            needsDisplay = true
        }
        return didResign
    }
}

final class ShortcutHintView: NSStackView {
    init(key: String, label: String) {
        let keycap = KeycapView(text: key)
        let action = NSTextField(labelWithString: label)
        action.font = .systemFont(ofSize: 11, weight: .medium)
        action.textColor = NSColor.white.withAlphaComponent(0.62)

        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 5
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(keycap)
        addArrangedSubview(action)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class KeycapView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        layer?.borderWidth = 0.5

        label.stringValue = text
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.78)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        return NSSize(width: max(26, labelSize.width + 12), height: 20)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private extension NSScreen {
    static var allScreenFrame: NSRect {
        let frames = screens.map(\.frame)
        guard let first = frames.first else {
            return NSRect(x: 0, y: 0, width: 1280, height: 800)
        }

        return frames.dropFirst().reduce(first) { $0.union($1) }
    }
}
