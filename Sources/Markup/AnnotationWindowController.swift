import AppKit

final class AnnotationWindowController: NSWindowController {
    private let viewController: AnnotationViewController

    init(
        captured: CapturedWindow,
        route: AppRoute?,
        recordingURL: URL?,
        onSave: @escaping (String, CaptureRegion, NSImage, NSImage, URL?) -> Void,
        onChangeRoute: @escaping (AppRoute?) -> AppRoute?,
        onCancel: @escaping () -> Void,
        onRecord: @escaping () -> Void
    ) {
        viewController = AnnotationViewController(
            captured: captured,
            route: route,
            recordingURL: recordingURL,
            onSave: onSave,
            onChangeRoute: onChangeRoute,
            onCancel: onCancel,
            onRecord: onRecord
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

final class AnnotationViewController: NSViewController, NSTextViewDelegate {
    private let captured: CapturedWindow
    private var route: AppRoute?
    private let recordingURL: URL?
    private let onSave: (String, CaptureRegion, NSImage, NSImage, URL?) -> Void
    private let onChangeRoute: (AppRoute?) -> AppRoute?
    private let onCancel: () -> Void
    private let onRecord: () -> Void

    private let canvas: AnnotationCanvasView
    private let projectRouteView = ProjectRouteView()
    private let noteTextView = PlaceholderTextView(placeholder: "Describe what should change, what looks wrong, or what the agent should fix.")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let recordingBadge = NSTextField(labelWithString: "")

    var initialFirstResponder: NSResponder {
        canvas
    }

    init(
        captured: CapturedWindow,
        route: AppRoute?,
        recordingURL: URL?,
        onSave: @escaping (String, CaptureRegion, NSImage, NSImage, URL?) -> Void,
        onChangeRoute: @escaping (AppRoute?) -> AppRoute?,
        onCancel: @escaping () -> Void,
        onRecord: @escaping () -> Void
    ) {
        self.captured = captured
        self.route = route
        self.recordingURL = recordingURL
        self.onSave = onSave
        self.onChangeRoute = onChangeRoute
        self.onCancel = onCancel
        self.onRecord = onRecord
        canvas = AnnotationCanvasView(image: captured.image)
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
        canvas.onSelectionChanged = { [weak self] in
            guard let self else { return }
            self.updateSaveState()
        }
        canvas.onSelectionCompleted = { [weak self] in
            guard let self else { return }
            if self.canvas.captureRegion != nil {
                self.view.window?.makeFirstResponder(self.noteTextView)
            }
        }
        noteTextView.delegate = self
        updateSaveState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(canvas)
    }

    func textDidChange(_ notification: Notification) {
        updateSaveState()
    }

    private func buildLayout() {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = 12
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        let header = NSTextField(labelWithString: captured.appName)
        header.font = .systemFont(ofSize: 17, weight: .semibold)
        header.textColor = .white
        header.lineBreakMode = .byTruncatingMiddle

        let windowTitle = NSTextField(labelWithString: captured.windowTitle)
        windowTitle.font = .systemFont(ofSize: 12, weight: .medium)
        windowTitle.textColor = NSColor.white.withAlphaComponent(0.72)
        windowTitle.lineBreakMode = .byTruncatingMiddle

        let helperText = recordingURL == nil
            ? "Drag one box around the issue, then write the instruction for the coding agent."
            : "Recording attached. Drag one box, add a note, then Save to write the feedback folder."
        let helper = NSTextField(labelWithString: helperText)
        helper.font = .systemFont(ofSize: 12)
        helper.textColor = NSColor.white.withAlphaComponent(0.68)
        helper.lineBreakMode = .byTruncatingTail

        let titleStack = NSStackView(views: [header, windowTitle, helper])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3

        recordingBadge.stringValue = recordingURL == nil ? "" : "Recording attached"
        recordingBadge.textColor = .systemGreen
        recordingBadge.font = .systemFont(ofSize: 12, weight: .semibold)
        recordingBadge.isHidden = recordingURL == nil

        let shortcutHints = NSStackView(views: [
            ShortcutHintView(key: "Esc", label: "Cancel"),
            ShortcutHintView(key: "Return", label: "Save")
        ])
        shortcutHints.orientation = .horizontal
        shortcutHints.spacing = 12
        shortcutHints.alignment = .centerY
        shortcutHints.setContentCompressionResistancePriority(.required, for: .horizontal)

        let headerRow = NSStackView(views: [titleStack, NSView(), shortcutHints, recordingBadge])
        headerRow.orientation = .horizontal
        headerRow.spacing = 14
        headerRow.alignment = .centerY
        headerRow.distribution = .fill

        projectRouteView.translatesAutoresizingMaskIntoConstraints = false
        projectRouteView.configure(captured: captured, route: route)
        projectRouteView.onChange = { [weak self] in
            self?.changeRouteSelected()
        }

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true

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
        noteTextView.frame = NSRect(x: 0, y: 0, width: 640, height: 160)
        noteTextView.minSize = NSSize(width: 0, height: 160)
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
        noteTextView.string = ""
        noteSurface.installContentView(noteScroll)

        let noteLabel = NSTextField(labelWithString: "Note")
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        noteLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        let recordButton = NSButton(title: "Record 10s", target: self, action: #selector(recordSelected))
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .large
        recordButton.isEnabled = recordingURL == nil

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

        let actions = NSStackView(views: [recordButton, NSView(), cancelButton, saveButton])
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
        container.addArrangedSubview(canvas)
        container.addArrangedSubview(noteSection)
        container.addArrangedSubview(actions)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            projectRouteView.heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
            noteLabel.topAnchor.constraint(equalTo: noteSection.topAnchor),
            noteLabel.leadingAnchor.constraint(equalTo: noteSection.leadingAnchor, constant: 2),
            noteSurface.leadingAnchor.constraint(equalTo: noteSection.leadingAnchor),
            noteSurface.trailingAnchor.constraint(equalTo: noteSection.trailingAnchor),
            noteSurface.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 8),
            noteSurface.bottomAnchor.constraint(equalTo: noteSection.bottomAnchor),
            noteSurface.heightAnchor.constraint(equalToConstant: 166)
        ])
    }

    @objc private func saveSelected() {
        guard let region = canvas.captureRegion else {
            NSSound.beep()
            return
        }

        let note = noteTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else {
            NSSound.beep()
            view.window?.makeFirstResponder(noteTextView)
            return
        }

        guard let annotated = ScreenshotAnnotator.annotatedImage(source: captured.image, region: region) else {
            NSSound.beep()
            return
        }

        onSave(note, region, annotated, captured.image, recordingURL)
    }

    private func changeRouteSelected() {
        guard let updatedRoute = onChangeRoute(route) else {
            return
        }

        route = updatedRoute
        projectRouteView.configure(captured: captured, route: updatedRoute)
    }

    @objc private func cancelSelected() {
        cancelAnnotation()
    }

    func cancelAnnotation() {
        onCancel()
        view.window?.close()
    }

    @objc private func recordSelected() {
        onRecord()
    }

    private func updateSaveState() {
        let note = noteTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        saveButton.isEnabled = canvas.captureRegion != nil && !note.isEmpty
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
